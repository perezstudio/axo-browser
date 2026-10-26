import Foundation

/// Plain-language descriptions of what an extension can do, for install and permission prompts.
///
/// Wording follows Axo's voice for permissions: plain and direct, saying what the extension can
/// do rather than naming the API.
public enum PermissionDescriptions {
    /// One line per capability, most significant first: site access, then named permissions.
    /// Permissions with nothing worth telling people (such as `alarms`) are left out. Permissions
    /// Axo has no description for are still listed, by name, so a prompt never hides one.
    public static func lines(permissions: [String], matchPatterns: [String]) -> [String] {
        var lines: [String] = []
        if let sites = siteLine(for: matchPatterns) { lines.append(sites) }
        let named = Set(permissions)
        lines += order.compactMap { named.contains($0) ? descriptions[$0] : nil }
        let unknown = named.subtracting(descriptions.keys).subtracting(quiet).sorted()
        lines += unknown.map { "Use “\($0)”" }
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
        "debugger", "nativeMessaging", "proxy", "webRequest", "webRequestBlocking", "declarativeNetRequestWithHostAccess",
        "cookies", "history", "management", "privacy", "browsingData", "contentSettings", "userScripts",
        "clipboardRead", "tabCapture", "desktopCapture", "pageCapture", "tabs", "webNavigation", "scripting",
        "declarativeNetRequest", "declarativeNetRequestFeedback", "bookmarks", "readingList", "topSites",
        "sessions", "tabGroups", "downloads", "geolocation", "identity", "notifications", "clipboardWrite",
        "contextMenus", "menus", "unlimitedStorage",
    ]

    /// Permissions with nothing worth telling people: they don't reach your data or devices.
    private static let quiet: Set<String> = [
        "activeTab", "alarms", "background", "declarativeContent", "favicon", "fontSettings", "gcm",
        "i18n", "idle", "offscreen", "power", "runtime", "search", "sidePanel", "storage",
        "system.cpu", "system.display", "system.memory", "system.storage", "tts", "ttsEngine",
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
        "debugger": "Control your tabs with developer tools, including what they load and send",
        "proxy": "Send your network traffic through another server",
        "webRequestBlocking": "Block and change your network requests",
        "history": "Read and change your browsing history",
        "management": "See, turn off, and remove your other extensions",
        "privacy": "Change your privacy settings",
        "browsingData": "Delete your browsing data",
        "contentSettings": "Change which websites can use your camera, location, and other features",
        "userScripts": "Run scripts you add on the websites they're for",
        "clipboardRead": "Read what you copy",
        "tabCapture": "Record what your tabs show and play",
        "desktopCapture": "Ask to record your screen or a window",
        "pageCapture": "Save complete copies of pages",
        "bookmarks": "Read and change your favorites and pinned tabs",
        "readingList": "Read and change your reading list",
        "topSites": "See the websites you visit most",
        "sessions": "See tabs you recently closed",
        "tabGroups": "See and change your tab groups",
        "downloads": "Download files and manage your downloads",
        "geolocation": "Ask for your location",
        "identity": "Ask you to sign in to websites",
        "notifications": "Show notifications",
    ]
}
