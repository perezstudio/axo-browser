import Foundation

/// A pane of Axo's Settings window, in the order its sidebar lists them (the Settings board's:
/// General, Profiles, Spaces, Link Routing, Site Customizations, iCloud). Search (#132) and
/// Website Permissions (#133) join when they're built.
///
/// The raw value is what Settings remembers as the last pane used, so keep existing ones stable.
nonisolated public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case profiles
    case spaces
    case linkRouting
    case siteCustomizations
    case iCloud

    public var id: String { rawValue }

    /// The pane's name, in the sidebar and the window's title.
    public var title: String {
        switch self {
        case .general: "General"
        case .profiles: "Profiles"
        case .spaces: "Spaces"
        case .linkRouting: "Link Routing"
        case .siteCustomizations: "Site Customizations"
        case .iCloud: "iCloud"
        }
    }

    /// The pane's SF Symbol in the sidebar.
    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .profiles: "person.2"
        case .spaces: "square.stack"
        case .linkRouting: "arrow.triangle.branch"
        case .siteCustomizations: "paintbrush"
        case .iCloud: "icloud"
        }
    }

    /// The accessibility identifier of the pane's sidebar row, such as `settingsPane.general`.
    public var rowIdentifier: String { "settingsPane.\(rawValue)" }

    /// Words for the settings in the pane, which the sidebar's search matches besides the title.
    /// Keep them in step with the pane's controls.
    public var keywords: [String] {
        switch self {
        case .general:
            ["navigation bar", "address bar", "address", "sidebar", "above the page", "toolbar", "tint", "color",
             "theme color", "full website address", "url", "edit the address", "command bar"]
        case .profiles:
            ["profile", "add profile", "delete profile", "rename", "website data", "cookies", "logins", "clear",
             "extensions"]
        case .spaces:
            ["space", "add space", "delete space", "rename", "color", "icon", "theme", "background", "profile"]
        case .linkRouting:
            ["links", "rules", "domain", "app", "other apps", "default browser", "mini window", "open in"]
        case .siteCustomizations:
            ["css", "javascript", "styles", "scripts", "customize", "site", "domain"]
        case .iCloud:
            ["sync", "icloud", "devices", "sync now", "status", "spaces", "folders", "pinned tabs", "favorites"]
        }
    }

    /// Whether the pane's title or one of its keywords contains every word of `query`, ignoring
    /// case and accents. An empty query matches every pane.
    public func matches(_ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = ([title] + keywords).joined(separator: " ")
        return words.allSatisfy { word in
            haystack.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The panes `query` matches among `panes`, in their order.
    public static func filtered(_ panes: [SettingsPane], by query: String) -> [SettingsPane] {
        panes.filter { $0.matches(query) }
    }
}
