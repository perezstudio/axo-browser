import AxoCRX
import Compression
import CryptoKit
import Foundation
import Security

// Builders for test fixtures, shared by the AxoCRX and AxoExtensions tests. Not shipped in the app.

/// Builds zip archives byte by byte, including malformed ones the extractor must refuse.
public struct ZipBuilder {
    public struct Entry {
        public var name: String
        public var data: Data
        public var deflate = false
        public var isSymlink = false
        public var corruptCRC = false

        public init(name: String, data: Data, deflate: Bool = false, isSymlink: Bool = false, corruptCRC: Bool = false) {
            self.name = name
            self.data = data
            self.deflate = deflate
            self.isSymlink = isSymlink
            self.corruptCRC = corruptCRC
        }
    }

    public var entries: [Entry] = []

    public init() {}

    public mutating func add(_ name: String, _ text: String, deflate: Bool = false) {
        entries.append(Entry(name: name, data: Data(text.utf8), deflate: deflate))
    }

    public func build() -> Data {
        var local = Data(), central = Data()
        for entry in entries {
            let stored = entry.deflate ? Self.deflate(entry.data) : entry.data
            let crc = Self.crc32(entry.data) ^ (entry.corruptCRC ? 1 : 0)
            let name = Data(entry.name.utf8)
            let offset = UInt32(local.count)
            let localHeader: [Data] = [
                Self.u32(0x0403_4B50), Self.u16(20), Self.u16(0), Self.u16(entry.deflate ? 8 : 0),
                Self.u16(0), Self.u16(0), Self.u32(crc), Self.u32(UInt32(stored.count)),
                Self.u32(UInt32(entry.data.count)), Self.u16(UInt16(name.count)), Self.u16(0), name, stored,
            ]
            localHeader.forEach { local.append($0) }
            let mode: UInt32 = entry.isSymlink ? 0o120777 : 0o100644
            let centralHeader: [Data] = [
                Self.u32(0x0201_4B50), Self.u16(3 << 8 | 20), Self.u16(20), Self.u16(0),
                Self.u16(entry.deflate ? 8 : 0), Self.u16(0), Self.u16(0), Self.u32(crc),
                Self.u32(UInt32(stored.count)), Self.u32(UInt32(entry.data.count)),
                Self.u16(UInt16(name.count)), Self.u16(0), Self.u16(0), Self.u16(0), Self.u16(0),
                Self.u32(mode << 16), Self.u32(offset), name,
            ]
            centralHeader.forEach { central.append($0) }
        }
        let endParts: [Data] = [
            Self.u32(0x0605_4B50), Self.u16(0), Self.u16(0), Self.u16(UInt16(entries.count)),
            Self.u16(UInt16(entries.count)), Self.u32(UInt32(central.count)), Self.u32(UInt32(local.count)), Self.u16(0),
        ]
        let end = endParts.reduce(Data(), +)
        return local + central + end
    }

    /// CRC-32 (IEEE), computed independently of the code under test.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc = ~UInt32(0)
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return ~crc
    }

    static func deflate(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: data.count + 64)
        let count = data.withUnsafeBytes { source in
            compression_encode_buffer(&output, output.count, source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(output.prefix(count))
    }

    public static func u16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    public static func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}

/// Builds CRX3 files signed with freshly generated RSA keys.
public struct CRXBuilder {
    public let developerKey: SecKey
    public let developerPublicKeyInfo: Data

    public init() throws {
        (developerKey, developerPublicKeyInfo) = try Self.makeKey()
    }

    /// A 2048-bit RSA key and its SubjectPublicKeyInfo DER.
    public static func makeKey() throws -> (SecKey, Data) {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        // SEQUENCE { SEQUENCE { rsaEncryption OID, NULL }, BIT STRING { 0x00, RSAPublicKey } }
        let algorithm = der(0x30, Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]))
        return (key, der(0x30, algorithm + der(0x03, Data([0]) + pkcs1)))
    }

    /// A CRX3 file for `zip`.
    ///
    /// - Parameters:
    ///   - extraSigner: Another key to add a proof for, like the Chrome Web Store's.
    ///   - signWith: Sign with this key instead of the developer key (to make bad signatures).
    public func build(zip: Data, extraSigner: (SecKey, Data)? = nil, signWith: SecKey? = nil, version: UInt32 = 3) throws -> Data {
        let crxID = Data(SHA256.hash(data: developerPublicKeyInfo).prefix(16))
        let signedHeaderData = Self.field(1, crxID)
        var message = Data("CRX3 SignedData\u{0}".utf8) + ZipBuilder.u32(UInt32(signedHeaderData.count)) + signedHeaderData + zip
        let developerSignature = try Self.sign(message, with: signWith ?? developerKey)
        var header = Self.field(2, Self.field(1, developerPublicKeyInfo) + Self.field(2, developerSignature))
        if let (key, info) = extraSigner {
            header += Self.field(2, Self.field(1, info) + Self.field(2, try Self.sign(message, with: key)))
        }
        header += Self.field(10000, signedHeaderData)
        message = Data()
        return Data("Cr24".utf8) + ZipBuilder.u32(version) + ZipBuilder.u32(UInt32(header.count)) + header + zip
    }

    static func sign(_ message: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return signature
    }

    /// A length-delimited protobuf field.
    static func field(_ number: UInt64, _ value: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(value.count)) + value
    }

    static func varint(_ value: UInt64) -> Data {
        var value = value, bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return Data(bytes)
    }

    static func der(_ tag: UInt8, _ contents: Data) -> Data {
        let count = contents.count
        let length: Data = count < 0x80 ? Data([UInt8(count)])
            : count < 0x100 ? Data([0x81, UInt8(count)])
            : Data([0x82, UInt8(count >> 8), UInt8(count & 0xFF)])
        return Data([tag]) + length + contents
    }
}

/// A new temporary folder path (not yet created).
public func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "AxoCRXTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// A minimal valid extension as a zip.
public func sampleExtensionZip(name: String = "Sample", manifestVersion: Int = 3) -> Data {
    var zip = ZipBuilder()
    zip.add("manifest.json", #"{"name": "\#(name)", "version": "1.0", "manifest_version": \#(manifestVersion)}"#, deflate: true)
    zip.add("background.js", "console.log('hello from \(name)')")
    zip.add("icons/", "")
    zip.add("icons/readme.txt", "icons go here", deflate: true)
    return zip.build()
}
