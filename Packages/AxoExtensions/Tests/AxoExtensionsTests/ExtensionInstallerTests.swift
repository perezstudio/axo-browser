import AxoCRX
import AxoCRXTestSupport
import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoExtensions

@MainActor
struct ExtensionInstallerTests {
    let installer = ExtensionInstaller(root: temporaryFolder())
    let profileID = UUID()
    let builder: CRXBuilder

    init() throws {
        builder = try CRXBuilder()
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: installer.folder(for: profileID).path)
    }

    @Test func installingACRXUnpacksItUnderItsID() throws {
        let installed = try installer.install(crx: try builder.build(zip: sampleExtensionZip(name: "Notes")), for: profileID)

        #expect(installed.manifest.name == "Notes")
        #expect(installed.folder.lastPathComponent == installed.id)
        #expect(!installed.isUnpacked)
        #expect(FileManager.default.fileExists(atPath: installed.folder.appending(path: "background.js").path))
        #expect(installer.installedExtensions(for: profileID) == [installed])
    }

    @Test func installingAgainUpdatesInPlace() throws {
        _ = try installer.install(crx: try builder.build(zip: sampleExtensionZip(name: "Old")), for: profileID)
        let updated = try installer.install(crx: try builder.build(zip: sampleExtensionZip(name: "New")), for: profileID)

        #expect(installer.installedExtensions(for: profileID).map(\.manifest.name) == ["New"])
        #expect(try leftovers() == [updated.id], "No staging folders are left behind")
    }

    @Test func badPackagesLeaveNothingBehind() throws {
        var tampered = try builder.build(zip: sampleExtensionZip())
        tampered[tampered.count - 30] ^= 0xFF
        #expect(throws: CRXError.invalidSignature) { try installer.install(crx: tampered, for: profileID) }

        var noManifest = ZipBuilder()
        noManifest.add("background.js", "1")
        #expect(throws: ExtensionManifest.Error.missing) {
            try installer.install(crx: try builder.build(zip: noManifest.build()), for: profileID)
        }
        #expect(installer.installedExtensions(for: profileID).isEmpty)
        #expect(try leftovers().isEmpty)
    }

    @Test func profilesHaveSeparateExtensions() throws {
        _ = try installer.install(crx: try builder.build(zip: sampleExtensionZip()), for: profileID)
        #expect(installer.installedExtensions(for: UUID()).isEmpty)
    }

    @Test func uninstallingRemovesTheFiles() throws {
        let installed = try installer.install(crx: try builder.build(zip: sampleExtensionZip()), for: profileID)
        try installer.uninstall(installed, for: profileID)
        #expect(installer.installedExtensions(for: profileID).isEmpty)
    }

    @Test func unpackedFoldersAreUsedInPlaceWithAPathDerivedID() throws {
        let folder = temporaryFolder()
        try ZipArchive.extract(sampleExtensionZip(name: "Dev"), to: folder)

        let first = try installer.inspectUnpacked(at: folder)
        let again = try installer.inspectUnpacked(at: folder.appending(path: "."))

        #expect(first.isUnpacked && first.folder == folder && first.manifest.name == "Dev")
        #expect(first.id == again.id, "The same folder always gets the same ID")
        #expect(first.id != (try installer.inspectUnpacked(at: try copy(folder))).id)

        try installer.uninstall(first, for: profileID)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "manifest.json").path), "Unpacked folders are never deleted")
        #expect(throws: ExtensionInstallError.folderNotFound) { try installer.inspectUnpacked(at: temporaryFolder()) }
    }

    @Test func webKitLoadsAnInstalledExtension() async throws {
        let installed = try installer.install(crx: try builder.build(zip: sampleExtensionZip(name: "Loadable")), for: profileID)

        let webExtension = try await installed.load()

        #expect(webExtension.displayName == "Loadable")
        #expect(webExtension.version == "1.0")
        #expect(webExtension.manifestVersion == 3)
    }

    private func copy(_ folder: URL) throws -> URL {
        let destination = temporaryFolder()
        try FileManager.default.copyItem(at: folder, to: destination)
        return destination
    }
}
