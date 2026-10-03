import AxoCRX
import AxoCore
import CryptoKit
import Foundation
import WebKit

/// An extension installed for a profile.
public struct InstalledExtension: Hashable, Sendable {
    /// Chrome's extension ID: from the developer's key for CRX installs, or from the folder path
    /// for unpacked (developer mode) extensions, as Chrome does.
    public var id: String
    /// The checked manifest.
    public var manifest: ExtensionManifest
    /// The extension's files.
    public var folder: URL
    /// Whether it was loaded unpacked from a folder Axo doesn't manage (developer mode).
    public var isUnpacked: Bool
}

/// Errors installing an extension.
public enum ExtensionInstallError: Error, Equatable, Sendable {
    /// The extension's files couldn't be written.
    case couldNotWrite
    /// The folder isn't there.
    case folderNotFound
}

/// Installs Chrome extensions for a profile: verified CRX files are unpacked into Axo's own
/// folder, and unpacked folders are checked and used in place (developer mode).
///
/// Every install is checked before it's kept: CRX signatures are verified, archives are
/// extracted safely, and the manifest must be valid. A failed install leaves nothing behind.
public struct ExtensionInstaller: Sendable {
    /// Where installed extensions live: one folder per profile, one per extension inside it.
    public let root: URL

    /// Creates an installer that keeps extensions in `root`.
    public init(root: URL) {
        self.root = root
    }

    /// The folder for a profile's installed extensions.
    public func folder(for profileID: Profile.ID) -> URL {
        root.appending(path: profileID.uuidString, directoryHint: .isDirectory)
    }

    /// Installs (or updates) an extension from a CRX file's contents.
    ///
    /// - Throws: `CRXError`, `ZipError`, `ExtensionManifest.Error`, or ``ExtensionInstallError``.
    @discardableResult
    public func install(crx data: Data, for profileID: Profile.ID) throws -> InstalledExtension {
        let package = try CRXPackage(data)
        let fileManager = FileManager.default
        let profileFolder = folder(for: profileID)
        try fileManager.createDirectory(at: profileFolder, withIntermediateDirectories: true)

        // Extract to a staging folder first, so a bad archive never touches an installed copy.
        let staging = profileFolder.appending(path: ".installing-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        try ZipArchive.extract(package.zipArchive, to: staging)
        let manifest = try ExtensionManifest.read(fromExtensionAt: staging)

        let destination = profileFolder.appending(path: package.extensionID, directoryHint: .isDirectory)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw ExtensionInstallError.couldNotWrite
        }
        return InstalledExtension(id: package.extensionID, manifest: manifest, folder: destination, isUnpacked: false)
    }

    /// Checks an unpacked extension folder for developer mode. The folder is used where it is.
    public func inspectUnpacked(at folder: URL) throws -> InstalledExtension {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExtensionInstallError.folderNotFound
        }
        let manifest = try ExtensionManifest.read(fromExtensionAt: folder)
        return InstalledExtension(id: Self.unpackedID(for: folder), manifest: manifest, folder: folder, isUnpacked: true)
    }

    /// The extensions installed from CRX files for a profile, by ID. Folders that no longer hold
    /// a valid extension are skipped.
    public func installedExtensions(for profileID: Profile.ID) -> [InstalledExtension] {
        let profileFolder = folder(for: profileID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profileFolder.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .compactMap { id in
                // Built the same way as in install(crx:for:), so the two compare equal.
                let folder = profileFolder.appending(path: id, directoryHint: .isDirectory)
                return (try? ExtensionManifest.read(fromExtensionAt: folder)).map {
                    InstalledExtension(id: id, manifest: $0, folder: folder, isUnpacked: false)
                }
            }
    }

    /// Removes an extension installed from a CRX file. Unpacked folders are never deleted.
    public func uninstall(_ installed: InstalledExtension, for profileID: Profile.ID) throws {
        guard !installed.isUnpacked else { return }
        let expected = folder(for: profileID).appending(path: installed.id, directoryHint: .isDirectory)
        guard installed.folder.standardizedFileURL == expected.standardizedFileURL else { return }
        try FileManager.default.removeItem(at: expected)
    }

    /// Chrome's ID for an unpacked extension: derived from its folder's absolute path.
    static func unpackedID(for folder: URL) -> String {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return CRXPackage.extensionID(fromIDBytes: Data(SHA256.hash(data: Data(path.utf8)).prefix(16)))
    }
}

extension InstalledExtension {
    /// Loads the extension with WebKit, which validates it fully and reports any errors.
    @MainActor
    public func load() async throws -> WKWebExtension {
        try await WKWebExtension(resourceBaseURL: folder)
    }
}
