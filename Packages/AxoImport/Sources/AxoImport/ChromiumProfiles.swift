import Foundation

/// A profile in a Chromium-based browser (Chrome, or Arc's `User Data` folder).
public struct ChromiumProfile: Hashable, Sendable, Identifiable {
    /// The profile's folder name, such as `Default` or `Profile 1`.
    public var directory: String
    /// The name the browser shows for it.
    public var name: String

    public var id: String { directory }

    /// Creates a profile.
    public init(directory: String, name: String) {
        self.directory = directory
        self.name = name
    }

    /// Reads the profiles listed in a Chromium `Local State` file, sorted by folder name with
    /// `Default` first.
    ///
    /// - Throws: ``ImportError`` if the file can't be read or isn't JSON.
    public static func profiles(inLocalState url: URL) throws -> [ChromiumProfile] {
        let root = try ImportError.jsonObject(try ImportError.read(url), from: url)
        let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: Any] ?? [:]
        return cache.map { directory, info in
            let name = ((info as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directory
            return ChromiumProfile(directory: directory, name: name)
        }
        .sorted { lhs, rhs in
            if (lhs.directory == "Default") != (rhs.directory == "Default") { return lhs.directory == "Default" }
            return lhs.directory.localizedStandardCompare(rhs.directory) == .orderedAscending
        }
    }
}
