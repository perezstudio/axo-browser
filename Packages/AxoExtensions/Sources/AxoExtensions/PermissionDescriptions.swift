import Foundation

/// Plain-language descriptions of what an extension can do, for install and permission prompts.
///
/// Wording follows Axo's voice for permissions: plain and direct, saying what the extension can
/// do rather than naming the API.
public enum PermissionDescriptions {
    /// One line per capability, most significant first: site access, then named permissions.
    /// Permissions with nothing worth telling people (such as `alarms`) are left out.
    public static func lines(permissions: [String], matchPatterns: [String]) -> [String] {
        var lines: [String] = []
        if let sites = siteLine(for: matchPatterns) { lines.append(sites) }
        let named = Set(permissions)
        lines += order.compactMap { named.contains($0) ? descriptions[$0] : nil }
        return lines
    }

    /// The site-access line, or `nil` if the extension doesn't reach any sites.
    static func siteLine(for patterns: [String]) -> String? {
        guard !patterns.isEmpty else { return nil }
        if patterns.contains(where: isAllSites) {
            return "Read and change your data on all websites"
        }
        let hosts = Array(Set(patterns.compactMap(host(of:)))).sorted()
        guard !hosts.isEmpty else { return "Read and change your data on some websites" }
        let shown = hosts.prefix(3).joined(separator: ", ")
        let more = hosts.count > 3 ? " and \(hosts.count - 3) more" : ""
        return "Read and change your data on \(shown)\(more)"
    }

    static func isAllSites(_ pattern: String) -> Bool {
        pattern == "<all_urls>" || pattern.hasPrefix("*://*/") || pattern.hasPrefix("http://*/")
            || pattern.hasPrefix("https://*/") || pattern == "*://*"
    }

    /// `*://*.example.com/*` → `example.com`.
    static func host(of pattern: String) -> String? {
        guard let schemeEnd = pattern.range(of: "://") else { return nil }
        let rest = pattern[schemeEnd.upperBound...]
        var host = String(rest.prefix { $0 != "/" })
        if host.hasPrefix("*.") { host.removeFirst(2) }
        return host.isEmpty || host == "*" ? nil : host
    }

    private static let order = [
        "nativeMessaging", "webRequest", "declarativeNetRequestWithHostAccess", "cookies",
        "tabs", "webNavigation", "scripting", "declarativeNetRequest", "declarativeNetRequestFeedback",
        "clipboardWrite", "contextMenus", "menus", "unlimitedStorage",
    ]

    private static let descriptions: [String: String] = [
        "nativeMessaging": "Talk to apps installed on this Mac",
        "webRequest": "Watch your network requests",
        "declarativeNetRequestWithHostAccess": "Block and change content on websites it can reach",
        "cookies": "Read and change cookies for websites it can reach",
        "tabs": "See your open tabs and their addresses",
        "webNavigation": "See the pages you visit as you browse",
        "scripting": "Run its code on websites it can reach",
        "declarativeNetRequest": "Block content on any page",
        "declarativeNetRequestFeedback": "See which content it blocked",
        "clipboardWrite": "Copy text to your clipboard",
        "contextMenus": "Add items to menus when you Control-click",
        "menus": "Add items to menus when you Control-click",
        "unlimitedStorage": "Store an unlimited amount of data on this Mac",
    ]
}
