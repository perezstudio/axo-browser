import Foundation
import Testing
import AxoCRXTestSupport
@testable import AxoCRX

struct ManifestTests {
    let folder = temporaryFolder()

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func write(_ json: String, bom: Bool = false) throws {
        let data = (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(json.utf8)
        try data.write(to: folder.appending(path: "manifest.json"))
    }

    @Test func readsNameVersionAndManifestVersion() throws {
        try write(#"{"name": "__MSG_appName__", "version": "2.1.0", "manifest_version": 3, "permissions": ["storage"]}"#, bom: true)
        #expect(try ExtensionManifest.read(fromExtensionAt: folder) == ExtensionManifest(name: "__MSG_appName__", version: "2.1.0", manifestVersion: 3))
    }

    @Test func missingInvalidAndUnsupportedManifestsAreRejected() throws {
        #expect(throws: ExtensionManifest.Error.missing) { try ExtensionManifest.read(fromExtensionAt: folder) }
        try write("{ not json")
        #expect(throws: ExtensionManifest.Error.invalid) { try ExtensionManifest.read(fromExtensionAt: folder) }
        try write(#"{"name": "Old", "version": "1", "manifest_version": 1}"#)
        #expect(throws: ExtensionManifest.Error.unsupportedManifestVersion(1)) { try ExtensionManifest.read(fromExtensionAt: folder) }
    }
}
