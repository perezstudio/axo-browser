import Compression
import Foundation

/// Errors extracting a zip archive.
public enum ZipError: Error, Equatable, Sendable {
    /// The data isn't a zip archive Axo can read.
    case notAZipArchive
    /// The archive uses something Axo doesn't support, such as Zip64, encryption, or a
    /// compression method other than stored or deflate.
    case unsupported(String)
    /// An entry's path would land outside the destination folder, or names a link.
    case unsafeEntry(String)
    /// An entry's data doesn't match its checksum or size.
    case corruptEntry(String)
    /// The archive expands to more than the size limit.
    case tooLarge
}

/// Extracts zip archives (the format inside CRX files) safely.
///
/// Only stored and deflate entries are supported, which covers extension packages. Paths are
/// checked so nothing is written outside the destination ("zip slip"), links are refused, every
/// entry's CRC-32 is verified, and the total expanded size is capped to stop zip bombs.
public enum ZipArchive {
    /// The most an archive may expand to: 512 MB.
    public static let defaultSizeLimit = 512 * 1024 * 1024

    /// Extracts `data` into `directory`, which must not exist yet or be empty.
    ///
    /// - Returns: The relative paths of the files written.
    @discardableResult
    public static func extract(_ data: Data, to directory: URL, sizeLimit: Int = defaultSizeLimit) throws -> [String] {
        let bytes = [UInt8](data)
        let entries = try centralDirectory(bytes)
        let declaredTotal = entries.reduce(0) { $0 + $1.uncompressedSize }
        guard declaredTotal <= sizeLimit else { throw ZipError.tooLarge }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var written: [String] = []
        var total = 0

        for entry in entries {
            let path = try safeRelativePath(entry.name)
            let destination = root.appending(path: path)
            guard destination.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw ZipError.unsafeEntry(entry.name) }
            if entry.name.hasSuffix("/") {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            let contents = try self.contents(of: entry, in: bytes)
            total += contents.count
            guard total <= sizeLimit else { throw ZipError.tooLarge }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: destination, options: .withoutOverwriting)
            written.append(path)
        }
        return written
    }

    // MARK: Central directory

    struct Entry {
        var name: String
        var method: UInt16
        var flags: UInt16
        var crc32: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
        var isSymlink: Bool
    }

    static func centralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        // The end-of-central-directory record is in the last 64 KB + 22 bytes.
        guard bytes.count >= 22 else { throw ZipError.notAZipArchive }
        let searchStart = max(0, bytes.count - 22 - 0xFFFF)
        guard let eocd = stride(from: bytes.count - 22, through: searchStart, by: -1)
            .first(where: { uint32(bytes, $0) == 0x0605_4B50 }) else { throw ZipError.notAZipArchive }
        let count = Int(uint16(bytes, eocd + 10))
        let directoryOffset = Int(uint32(bytes, eocd + 16))
        guard count != 0xFFFF, directoryOffset != 0xFFFF_FFFF else { throw ZipError.unsupported("Zip64") }

        var entries: [Entry] = []
        var offset = directoryOffset
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, uint32(bytes, offset) == 0x0201_4B50 else { throw ZipError.notAZipArchive }
            let madeBy = uint16(bytes, offset + 4) >> 8
            let flags = uint16(bytes, offset + 8)
            let method = uint16(bytes, offset + 10)
            let crc = uint32(bytes, offset + 16)
            let compressed = Int(uint32(bytes, offset + 20))
            let uncompressed = Int(uint32(bytes, offset + 24))
            let nameLength = Int(uint16(bytes, offset + 28))
            let extraLength = Int(uint16(bytes, offset + 30))
            let commentLength = Int(uint16(bytes, offset + 32))
            let externalAttributes = uint32(bytes, offset + 38)
            let localOffset = Int(uint32(bytes, offset + 42))
            guard offset + 46 + nameLength <= bytes.count else { throw ZipError.notAZipArchive }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            // On Unix-made archives the high 16 bits are the file mode; 0o120000 is a symlink.
            let isSymlink = madeBy == 3 && (externalAttributes >> 16) & 0o170000 == 0o120000
            entries.append(Entry(
                name: name, method: method, flags: flags, crc32: crc, compressedSize: compressed,
                uncompressedSize: uncompressed, localHeaderOffset: localOffset, isSymlink: isSymlink
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: Entries

    static func safeRelativePath(_ name: String) throws -> String {
        let components = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !name.hasPrefix("/"), !name.contains("\\"), !components.isEmpty,
              components.allSatisfy({ $0 != ".." && $0 != "." }) else { throw ZipError.unsafeEntry(name) }
        return components.joined(separator: "/")
    }

    static func contents(of entry: Entry, in bytes: [UInt8]) throws -> Data {
        guard !entry.isSymlink else { throw ZipError.unsafeEntry(entry.name) }
        guard entry.flags & 0x1 == 0 else { throw ZipError.unsupported("encrypted entries") }
        let local = entry.localHeaderOffset
        guard local + 30 <= bytes.count, uint32(bytes, local) == 0x0403_4B50 else { throw ZipError.corruptEntry(entry.name) }
        let start = local + 30 + Int(uint16(bytes, local + 26)) + Int(uint16(bytes, local + 28))
        guard start + entry.compressedSize <= bytes.count else { throw ZipError.corruptEntry(entry.name) }
        let compressed = bytes[start..<(start + entry.compressedSize)]

        let data: Data
        switch entry.method {
        case 0:
            data = Data(compressed)
        case 8:
            data = try inflate(compressed, expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard data.count == entry.uncompressedSize, CRC32.checksum(data) == entry.crc32 else {
            throw ZipError.corruptEntry(entry.name)
        }
        return data
    }

    /// Raw deflate, which `COMPRESSION_ZLIB` decodes.
    private static func inflate(_ input: ArraySlice<UInt8>, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = [UInt8](repeating: 0, count: expectedSize + 1)
        let written = input.withUnsafeBufferPointer { source in
            compression_decode_buffer(&output, output.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expectedSize else { throw ZipError.corruptEntry(name) }
        return Data(output.prefix(written))
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// CRC-32 (IEEE), as zip uses.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(~UInt32(0)) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }
}
