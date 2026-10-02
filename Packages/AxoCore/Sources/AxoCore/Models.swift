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
    /// Whether the tab is pinned. Pinned tab behavior arrives in Milestone 2.
    public var isPinned: Bool
    /// When the tab was archived, or `nil` while it is in the sidebar.
    public var archivedAt: Date?

    /// Creates a tab.
    public init(
        id: UUID = UUID(),
        spaceID: UUID,
        url: URL,
        title: String = "",
        sortKey: String,
        isPinned: Bool = false,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.spaceID = spaceID
        self.url = url
        self.title = title
        self.sortKey = sortKey
        self.isPinned = isPinned
        self.archivedAt = archivedAt
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let spaceID = Column(CodingKeys.spaceID)
        public static let sortKey = Column(CodingKeys.sortKey)
        public static let archivedAt = Column(CodingKeys.archivedAt)
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
