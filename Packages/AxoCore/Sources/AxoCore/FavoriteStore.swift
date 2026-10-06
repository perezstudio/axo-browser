import AxoPersistence
import Foundation
import GRDB

/// A favorite: a page kept in the grid above the pinned tabs, shared by every Space of its
/// profile. Like a pinned tab, it has a home page it returns to when closed.
///
/// A favorite made from a tab keeps the tab's ID, so AxoWeb's pool keeps showing the same live
/// web view.
public struct Favorite: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "favorite"

    /// The favorite's identifier, also its web view's ID in the pool.
    public var id: UUID
    /// The profile whose Spaces show it.
    public var profileID: Profile.ID
    /// The home page.
    public var url: URL
    /// The home page's title, or an empty string.
    public var title: String
    /// Its place in the grid. See ``SortKey``.
    public var sortKey: String

    /// Creates a favorite.
    public init(id: UUID = UUID(), profileID: Profile.ID, url: URL, title: String = "", sortKey: String) {
        self.id = id
        self.profileID = profileID
        self.url = url
        self.title = title
        self.sortKey = sortKey
    }

    /// The table's columns, for queries.
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let profileID = Column(CodingKeys.profileID)
        public static let sortKey = Column(CodingKeys.sortKey)
    }

    /// A tab record standing in for the favorite, so it can be shown and searched like a tab.
    /// It belongs to `spaceID`, the Space showing it.
    public func tab(in spaceID: Space.ID) -> Tab {
        Tab(id: id, spaceID: spaceID, url: url, title: title, sortKey: sortKey, isPinned: true, homeURL: url)
    }
}

/// Errors thrown by ``FavoriteStore``.
public enum FavoriteError: Error, Equatable {
    /// No favorite with this ID exists.
    case favoriteNotFound(Favorite.ID)
}

/// Saves favorites, in the same database as the sidebar. Reach it through ``TabStore/favorites``.
public final class FavoriteStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over `database`.
    public init(database: AppDatabase) {
        self.database = database
    }

    private static func request(for profileID: Profile.ID) -> QueryInterfaceRequest<Favorite> {
        Favorite.filter(Favorite.Columns.profileID == profileID).order(Favorite.Columns.sortKey, Favorite.Columns.id)
    }

    /// A profile's favorites, in grid order.
    public func favorites(for profileID: Profile.ID) async throws -> [Favorite] {
        try await database.writer.read { db in try Self.request(for: profileID).fetchAll(db) }
    }

    /// Streams a profile's favorites: the current list first, then a new list after every change.
    public func observe(for profileID: Profile.ID) -> AsyncValueObservation<[Favorite]> {
        ValueObservation
            .tracking { db in try Self.request(for: profileID).fetchAll(db) }
            .values(in: database.writer)
    }

    /// Every favorite whose title or URL contains `text`, ignoring case, for the command bar.
    public func search(_ text: String, profileID: Profile.ID) async throws -> [Favorite] {
        let pattern = "%\(text)%"
        return try await database.writer.read { db in
            try Self.request(for: profileID)
                .filter(sql: "title LIKE ? OR url LIKE ?", arguments: [pattern, pattern])
                .fetchAll(db)
        }
    }

    /// Adds a favorite at the end of a profile's grid.
    @discardableResult
    public func add(url: URL, title: String = "", profileID: Profile.ID, id: UUID = UUID()) async throws -> Favorite {
        try await database.writer.write { db in
            guard try Profile.exists(db, id: profileID) else { throw TabStoreError.profileNotFound(profileID) }
            return try Self.insert(id: id, url: url, title: title, profileID: profileID, db)
        }
    }

    /// Makes a tab a favorite of its Space's profile: the favorite takes the tab's ID, current
    /// page (its home page, for a pinned tab), and title, and the tab leaves the sidebar.
    @discardableResult
    public func add(fromTab tabID: Tab.ID) async throws -> Favorite {
        try await database.writer.write { db in
            guard let tab = try Tab.fetchOne(db, id: tabID) else { throw TabStoreError.tabNotFound(tabID) }
            guard let space = try Space.fetchOne(db, id: tab.spaceID) else { throw TabStoreError.spaceNotFound(tab.spaceID) }
            try TabStore.leaveSplit(tabID, db)
            try Tab.deleteOne(db, id: tabID)
            return try Self.insert(id: tabID, url: tab.homeURL ?? tab.url, title: tab.title, profileID: space.profileID, db)
        }
    }

    private static func insert(id: UUID, url: URL, title: String, profileID: Profile.ID, _ db: Database) throws -> Favorite {
        let last = try request(for: profileID).fetchAll(db).last
        let favorite = Favorite(id: id, profileID: profileID, url: url, title: title, sortKey: try SortKey.between(last?.sortKey, nil))
        try favorite.insert(db)
        return favorite
    }

    /// Moves a favorite in the grid, directly after `anchor` or first when it's `nil`. Only the
    /// moved favorite's row changes.
    public func move(_ id: Favorite.ID, after anchor: Favorite.ID?) async throws {
        try await database.writer.write { db in
            guard var favorite = try Favorite.fetchOne(db, id: id) else { throw FavoriteError.favoriteNotFound(id) }
            let others = try Self.request(for: favorite.profileID).fetchAll(db).filter { $0.id != id }
            let index: Int
            if let anchor {
                guard let anchorIndex = others.firstIndex(where: { $0.id == anchor }) else { throw FavoriteError.favoriteNotFound(anchor) }
                index = anchorIndex + 1
            } else {
                index = 0
            }
            let before = index > 0 ? others[index - 1].sortKey : nil
            let after = index < others.count ? others[index].sortKey : nil
            favorite.sortKey = try SortKey.between(before, after)
            try favorite.update(db)
        }
    }

    /// Makes the current page a favorite's home page.
    public func setHome(_ url: URL, title: String, for id: Favorite.ID) async throws {
        try await database.writer.write { db in
            guard var favorite = try Favorite.fetchOne(db, id: id) else { throw FavoriteError.favoriteNotFound(id) }
            favorite.url = url
            favorite.title = title
            try favorite.update(db)
        }
    }

    /// Removes a favorite.
    public func remove(_ id: Favorite.ID) async throws {
        _ = try await database.writer.write { db in try Favorite.deleteOne(db, id: id) }
    }

    /// Turns a favorite into a pinned tab at the end of a Space's pinned section, keeping its
    /// ID (and so its live web view).
    @discardableResult
    public func moveToPinned(_ id: Favorite.ID, in spaceID: Space.ID) async throws -> Tab {
        try await database.writer.write { db in
            guard let favorite = try Favorite.fetchOne(db, id: id) else { throw FavoriteError.favoriteNotFound(id) }
            guard try Space.exists(db, id: spaceID) else { throw TabStoreError.spaceNotFound(spaceID) }
            try Favorite.deleteOne(db, id: id)
            let sortKey = try TabStore.sortKey(for: .end, in: spaceID, pinned: true, folder: nil, excluding: nil, db)
            let tab = Tab(id: id, spaceID: spaceID, url: favorite.url, title: favorite.title, sortKey: sortKey, isPinned: true, homeURL: favorite.url)
            try tab.insert(db)
            return try Tab.fetchOne(db, id: id) ?? tab
        }
    }
}

extension TabStore {
    /// Favorites, shared by every Space of a profile.
    public var favorites: FavoriteStore {
        FavoriteStore(database: database)
    }
}
