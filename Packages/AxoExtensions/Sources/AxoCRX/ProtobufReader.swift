import Foundation

/// Reads the protobuf wire format, just enough for CRX3 headers: varints and length-delimited
/// fields. Other wire types are skipped.
struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case skipped
    }

    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// The next field, or `nil` at the end.
    mutating func nextField() throws -> (number: UInt64, value: Value)? {
        guard offset < bytes.count else { return nil }
        let key = try readVarint()
        let number = key >> 3
        switch key & 0x7 {
        case 0:
            return (number, .varint(try readVarint()))
        case 1:
            try skip(8)
            return (number, .skipped)
        case 2:
            let length = try readVarint()
            guard length <= UInt64(bytes.count - offset) else { throw CRXError.malformedHeader }
            let value = Data(bytes[offset..<(offset + Int(length))])
            offset += Int(length)
            return (number, .bytes(value))
        case 5:
            try skip(4)
            return (number, .skipped)
        default:
            throw CRXError.malformedHeader
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count, shift < 64 else { throw CRXError.malformedHeader }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private mutating func skip(_ count: Int) throws {
        guard offset + count <= bytes.count else { throw CRXError.malformedHeader }
        offset += count
    }
}
