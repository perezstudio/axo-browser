import Foundation
import GRDB

/// A browsing profile with its own isolated website data (cookies, storage, cache).
///
/// AxoWeb creates one `WKWebsiteDataStore(forIdentifier:)` per profile, using ``id`` as the
/// identifier. Spaces point at a profile.
public struct Profile: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profile"

    /// The profile's identifier, also used as its website data store identifier.
    public var id: UUID
    /// The name shown in the interface.
    public var name: String

    /// Creates a profile.
    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// A Space: a named set of tabs in the sidebar, tied to one profile.
public struct Space: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "space"

    /// The Space's identifier.
    public var id: UUID
    /// The profile whose website data this Space uses.
    public var profileID: UUID
    /// The name shown in the interface.
    public var name: String
    /// The Space's position among its siblings. See ``SortKey``.
    public var sortKey: String

    /// Creates a Space.
    public init(id: UUID = UUID(), profileID: UUID, name: String, sortKey: String) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.sortKey = sortKey
    }
}

/// A tab in a Space's sidebar.
///
/// This is persisted state only. A tab may or may not have a live web view; AxoWeb's pool maps
/// tab IDs to web views separately, so hibernated tabs are just rows.
public struct Tab: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tab"

    /// The tab's identifier.
    public var id: UUID
    /// The Space the tab belongs to.
    public var spaceID: UUID
    /// The page the tab shows.
    public var url: URL
    /// The page title, or an empty string before the page reports one.
    public var title: String
    /// The tab's position within its Space. See ``SortKey``.
    public var sortKey: String
    /// Whether the tab is pinned. Pinned tabs sit above the others, never auto-archive, and
    /// reset to ``homeURL`` instead of closing.
    public var isPinned: Bool
    /// When the tab was archived, or `nil` while it is in the sidebar.
    public var archivedAt: Date?
    /// The page a pinned tab returns to when it's closed or reset. `nil` for unpinned tabs.
    public var homeURL: URL?
    /// When the tab was last shown. Unpinned tabs archive after a period without being shown.
    public var lastActiveAt: Date

    /// Creates a tab.
    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        url: URL,
        title: String = "",
        sortKey: String,
        isPinned: Bool = false,
        archivedAt: Date? = nil,
        homeURL: URL? = nil,
        lastActiveAt: Date = Date()
    ) {
        self.id = id
        self.spaceID = spaceID
        self.url = url
        self.title = title
        self.sortKey = sortKey
        self.isPinned = isPinned
        self.archivedAt = archivedAt
        self.homeURL = homeURL
        self.lastActiveAt = lastActiveAt
    }

    /// Whether a pinned tab has navigated away from its home page.
    public var hasLeftHome: Bool {
        guard isPinned, let homeURL else { return false }
        return url != homeURL
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let spaceID = Column(CodingKeys.spaceID)
        public static let sortKey = Column(CodingKeys.sortKey)
        public static let archivedAt = Column(CodingKeys.archivedAt)
        public static let isPinned = Column(CodingKeys.isPinned)
        public static let lastActiveAt = Column(CodingKeys.lastActiveAt)
    }
}

extension Space {
    /// Column names, for building queries.
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let profileID = Column(CodingKeys.profileID)
        public static let sortKey = Column(CodingKeys.sortKey)
    }
}

/// A site's icon, shared by every tab on that host.
public struct Favicon: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "favicon"

    /// The lowercased host the icon belongs to, such as `www.apple.com`.
    public var host: String
    /// The icon as PNG data, normalized by AxoWeb.
    public var data: Data
    /// When the icon was last fetched.
    public var updatedAt: Date

    /// Creates a favicon record.
    public init(host: String, data: Data, updatedAt: Date = Date()) {
        self.host = host.lowercased()
        self.data = data
        self.updatedAt = updatedAt
    }

    /// The key used to look up a page's icon: its lowercased host, or `nil` if it has none.
    public static func key(for url: URL) -> String? {
        url.host()?.lowercased()
    }
}
