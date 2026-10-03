import CryptoKit
import Foundation
import Security

/// Errors reading a CRX file.
public enum CRXError: Error, Equatable, Sendable {
    /// The file doesn't start with `Cr24`.
    case notACRXFile
    /// The CRX format version isn't 3. (CRX2 is long retired by Chrome.)
    case unsupportedVersion(UInt32)
    /// The file ends before its header says it should.
    case truncated
    /// The header isn't a valid CRX3 header.
    case malformedHeader
    /// No RSA proof in the header comes from the key the extension ID is derived from.
    case missingDeveloperSignature
    /// The developer key's signature doesn't match the file's contents.
    case invalidSignature
}

/// A parsed, verified CRX3 file: Chrome's signed extension package.
///
/// A CRX3 file is `Cr24`, a version (3), a header length, a protobuf `CrxFileHeader`, then a
/// zip archive. The header holds signatures over the archive and a signed `crx_id`. Axo
/// requires a valid RSA-SHA256 signature from the key the extension ID is derived from, which
/// proves the archive is what that extension's developer published.
public struct CRXPackage: Sendable {
    /// The extension's ID: 32 letters `a`–`p`, derived from the developer's public key.
    public let extensionID: String
    /// The zip archive with the extension's files.
    public let zipArchive: Data

    private static let magic = Data("Cr24".utf8)
    private static let signedDataPrefix = Data("CRX3 SignedData\u{0}".utf8)

    /// Parses `data` and verifies its developer signature.
    ///
    /// - Throws: ``CRXError`` if the file isn't a valid, correctly signed CRX3 file.
    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Data(bytes[0..<4]) == Self.magic else { throw CRXError.notACRXFile }
        let version = Self.littleEndianUInt32(bytes, at: 4)
        guard version == 3 else { throw CRXError.unsupportedVersion(version) }
        let headerLength = Int(Self.littleEndianUInt32(bytes, at: 8))
        guard bytes.count >= 12 + headerLength else { throw CRXError.truncated }
        let header = Data(bytes[12..<(12 + headerLength)])
        let archive = Data(bytes[(12 + headerLength)...])

        let parsed = try CRXHeader(header)
        let signedHeaderData = try parsed.signedHeaderData ?? { throw CRXError.malformedHeader }()
        let crxID = try SignedData(signedHeaderData).crxID
        guard crxID.count == 16 else { throw CRXError.malformedHeader }

        // The developer proof is the RSA key whose hash starts with the signed crx_id.
        guard let developerProof = parsed.rsaProofs.first(where: { Self.idBytes(forPublicKey: $0.publicKey) == crxID }) else {
            throw CRXError.missingDeveloperSignature
        }
        var message = Self.signedDataPrefix
        var length = UInt32(signedHeaderData.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(signedHeaderData)
        message.append(archive)
        guard try Self.verifyRSA(signature: developerProof.signature, message: message, subjectPublicKeyInfo: developerProof.publicKey) else {
            throw CRXError.invalidSignature
        }

        extensionID = Self.extensionID(fromIDBytes: crxID)
        zipArchive = archive
    }

    // MARK: IDs

    /// The first 16 bytes of the SHA-256 of a public key (SubjectPublicKeyInfo DER).
    static func idBytes(forPublicKey key: Data) -> Data {
        Data(SHA256.hash(data: key).prefix(16))
    }

    /// Chrome's extension ID alphabet: each hex digit of the ID bytes becomes `a`–`p`.
    public static func extensionID(fromIDBytes bytes: Data) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 0x0F] }.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
    }

    /// The extension ID a public key (SubjectPublicKeyInfo DER) produces.
    public static func extensionID(forPublicKey key: Data) -> String {
        extensionID(fromIDBytes: idBytes(forPublicKey: key))
    }

    // MARK: Signatures

    static func verifyRSA(signature: Data, message: Data, subjectPublicKeyInfo: Data) throws -> Bool {
        let pkcs1 = try DER.rsaPublicKey(fromSubjectPublicKeyInfo: subjectPublicKeyInfo)
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else {
            throw CRXError.malformedHeader
        }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

/// One signature in a CRX3 header.
struct AsymmetricKeyProof {
    var publicKey = Data()
    var signature = Data()
}

/// The parts of a `CrxFileHeader` Axo uses.
struct CRXHeader {
    var rsaProofs: [AsymmetricKeyProof] = []
    var signedHeaderData: Data?

    init(_ data: Data) throws {
        var reader = ProtobufReader(data)
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (2, .bytes(let proof)): rsaProofs.append(try Self.proof(proof))
            case (10000, .bytes(let signed)): signedHeaderData = signed
            default: break   // ECDSA proofs (3) and unknown fields are ignored.
            }
        }
    }

    private static func proof(_ data: Data) throws -> AsymmetricKeyProof {
        var proof = AsymmetricKeyProof()
        var reader = ProtobufReader(data)
        while let field = try reader.nextField() {
            switch (field.number, field.value) {
            case (1, .bytes(let key)): proof.publicKey = key
            case (2, .bytes(let signature)): proof.signature = signature
            default: break
            }
        }
        return proof
    }
}

/// The signed part of a CRX3 header.
struct SignedData {
    var crxID = Data()

    init(_ data: Data) throws {
        var reader = ProtobufReader(data)
        while let field = try reader.nextField() {
            if case (1, .bytes(let id)) = (field.number, field.value) { crxID = id }
        }
    }
}
