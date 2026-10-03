import Foundation
import Testing
import AxoExtensionsTestSupport
@testable import AxoCRX

struct CRXPackageTests {
    let builder: CRXBuilder

    init() throws {
        builder = try CRXBuilder()
    }

    @Test func aSignedPackageParsesWithItsDerivedID() throws {
        let zip = sampleExtensionZip()
        let package = try CRXPackage(try builder.build(zip: zip))

        #expect(package.zipArchive == zip)
        #expect(package.extensionID == CRXPackage.extensionID(forPublicKey: builder.developerPublicKeyInfo))
        #expect(package.extensionID.count == 32)
        #expect(package.extensionID.allSatisfy { ("a"..."p").contains($0) })
    }

    @Test func otherProofsLikeTheWebStoresAreAllowed() throws {
        let store = try CRXBuilder.makeKey()
        let package = try CRXPackage(try builder.build(zip: sampleExtensionZip(), extraSigner: store))
        #expect(package.extensionID == CRXPackage.extensionID(forPublicKey: builder.developerPublicKeyInfo))
    }

    @Test func aChangedArchiveFailsVerification() throws {
        var crx = try builder.build(zip: sampleExtensionZip())
        crx[crx.count - 30] ^= 0xFF
        #expect(throws: CRXError.invalidSignature) { try CRXPackage(crx) }
    }

    @Test func aSignatureFromAnotherKeyFails() throws {
        let (otherKey, _) = try CRXBuilder.makeKey()
        let crx = try builder.build(zip: sampleExtensionZip(), signWith: otherKey)
        #expect(throws: CRXError.invalidSignature) { try CRXPackage(crx) }
    }

    @Test func packagesWithoutTheDeveloperProofAreRejected() throws {
        // Swap the developer key for another, so no proof's key matches the signed crx_id.
        let other = try CRXBuilder()
        var crx = try builder.build(zip: sampleExtensionZip())
        let range = try #require(crx.range(of: builder.developerPublicKeyInfo))
        crx.replaceSubrange(range, with: other.developerPublicKeyInfo)
        #expect(throws: CRXError.missingDeveloperSignature) { try CRXPackage(crx) }
    }

    @Test func otherFilesAndVersionsAreRejected() throws {
        #expect(throws: CRXError.notACRXFile) { try CRXPackage(sampleExtensionZip()) }
        #expect(throws: CRXError.notACRXFile) { try CRXPackage(Data()) }
        #expect(throws: CRXError.unsupportedVersion(2)) { try CRXPackage(try builder.build(zip: sampleExtensionZip(), version: 2)) }
        let crx = try builder.build(zip: sampleExtensionZip())
        #expect(throws: CRXError.truncated) { try CRXPackage(crx.prefix(40)) }
    }

    @Test func extensionIDsUseChromesAlphabet() {
        #expect(CRXPackage.extensionID(fromIDBytes: Data([0x00, 0x1F, 0xFF])) == "aabppp")
    }
}
