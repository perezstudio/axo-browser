import Foundation

/// Finding a host's site among WebKit's website data records, which are named for their site's
/// registrable domain (`github.com` for `gist.github.com`), or the host itself where it has none
/// (an IP address, `localhost`).
nonisolated public enum WebsiteDataSite {
    /// The record name that holds `host`'s data, lowercased: the longest name that is `host` or a
    /// domain `host` is under. The longest is the registrable domain, so a record for a public
    /// suffix it's under (`github.io` for `me.github.io`) is never chosen over it; without a public
    /// suffix list, such a record is chosen only when the host's own site has no data. `nil` when
    /// no record matches, or for a name without a dot that isn't the host itself, which would be a
    /// top-level domain.
    public static func recordName(forHost host: String, among names: [String]) -> String? {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !host.isEmpty else { return nil }
        return names
            .map { $0.lowercased() }
            .filter { name in
                guard !name.isEmpty else { return false }
                if name == host { return true }
                return name.contains(".") && host.hasSuffix("." + name)
            }
            .max { $0.count < $1.count }
    }
}
