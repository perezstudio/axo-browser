import Foundation

/// The parts of an extension's `manifest.json` Axo checks before installing.
public struct ExtensionManifest: Decodable, Hashable, Sendable {
    /// The extension's name. May be a `__MSG_name__` placeholder for a localized name.
    public var name: String
    /// The extension's version string.
    public var version: String
    /// 2 or 3.
    public var manifestVersion: Int

    enum CodingKeys: String, CodingKey {
        case name, version
        case manifestVersion = "manifest_version"
    }

    /// Errors reading a manifest.
    public enum Error: Swift.Error, Equatable, Sendable {
        /// There's no `manifest.json` at the top of the extension.
        case missing
        /// `manifest.json` isn't valid JSON or lacks a name, version, or manifest version.
        case invalid
        /// The manifest version isn't 2 or 3.
        case unsupportedManifestVersion(Int)
    }

    /// Reads and checks the manifest at the top of an extension folder.
    public static func read(fromExtensionAt folder: URL) throws -> ExtensionManifest {
        let url = folder.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: url) else { throw Error.missing }
        // Chrome tolerates a UTF-8 byte order mark; so does Axo.
        let trimmed = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let manifest = try? JSONDecoder().decode(ExtensionManifest.self, from: Data(trimmed)) else { throw Error.invalid }
        guard [2, 3].contains(manifest.manifestVersion) else { throw Error.unsupportedManifestVersion(manifest.manifestVersion) }
        return manifest
    }
}
