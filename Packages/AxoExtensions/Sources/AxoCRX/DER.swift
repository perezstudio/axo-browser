import Foundation

/// Just enough DER to unwrap an RSA SubjectPublicKeyInfo, which CRX3 uses for public keys,
/// into the PKCS #1 `RSAPublicKey` the Security framework expects.
enum DER {
    /// `SEQUENCE { SEQUENCE { algorithm, parameters }, BIT STRING { RSAPublicKey } }`
    static func rsaPublicKey(fromSubjectPublicKeyInfo data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var offset = 0
        let outer = try element(bytes, at: &offset, expecting: 0x30)
        var inner = outer.lowerBound
        _ = try element(bytes, at: &inner, expecting: 0x30)   // AlgorithmIdentifier
        let bitString = try element(bytes, at: &inner, expecting: 0x03)
        // The first byte of a BIT STRING counts unused bits; keys always use whole bytes.
        guard bitString.count > 1, bytes[bitString.lowerBound] == 0 else { throw CRXError.malformedHeader }
        return Data(bytes[(bitString.lowerBound + 1)..<bitString.upperBound])
    }

    /// Reads one TLV element with the expected tag and returns the range of its contents.
    private static func element(_ bytes: [UInt8], at offset: inout Int, expecting tag: UInt8) throws -> Range<Int> {
        guard offset < bytes.count, bytes[offset] == tag else { throw CRXError.malformedHeader }
        offset += 1
        guard offset < bytes.count else { throw CRXError.malformedHeader }
        var length = Int(bytes[offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), offset + count <= bytes.count else { throw CRXError.malformedHeader }
            length = bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int($1) }
            offset += count
        }
        guard offset + length <= bytes.count else { throw CRXError.malformedHeader }
        let range = offset..<(offset + length)
        offset += length
        return range
    }
}
