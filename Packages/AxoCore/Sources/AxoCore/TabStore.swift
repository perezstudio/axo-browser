import AxoPersistence
import Foundation
import GRDB

/// Where to place a tab in its Space's list.
public enum TabPosition: Hashable, Sendable {
    /// Before every other tab.
    case start
    /// After every other tab.
    case end
    /// Directly after the tab with this ID.
    case after(Tab.ID)
}

/// Errors thrown by ``TabStore``.
public enum TabStoreError: Error, Equatable {
    /// No tab with this ID exists.
    case tabNotFound(Tab.ID)
    /// The tab used as a position anchor is in a different Space.
    case anchorInDifferentSpace(Tab.ID)
}

/// Reads and writes the sidebar model: profiles, Spaces, and tabs.
///
/// Writes run off the main actor through the database's single writer, each in its own
/// transaction. To keep SwiftUI in sync, observe ``tabsRequest(in:)`` with `ValueObservation`
/// or GRDBQuery instead of re-fetching.
public final class TabStore: Sendable {
    /// The name of the profile created on first launch.
    public static let defaultProfileName = "Default"
    /// The name of the Space created on first launch.
    public static let defaultSpaceName = "Home"

    private let database: AppDatabase

    /// Creates a store over `database`.
    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Spaces

    /// Returns the first Space, creating a default profile and Space if none exist yet.
    ///
    /// Call this on launch before showing a window.
    @discardableResult
    public func bootstrap() async throws -> Space {
        try await database.writer.write { db in
            if let space = try Space.order(Space.Columns.sortKey, Space.Columns.id).fetchOne(db) {
                return space
            }
            let profile = try Profile.fetchOne(db) ?? Profile(name: Self.defaultProfileName)
            try profile.save(db)
            let space = Space(profileID: profile.id, name: Self.defaultSpaceName, sortKey: SortKey.initial)
            try space.insert(db)
            return space
        }
    }

    /// Returns every Space in sidebar order.
    public func spaces() async throws -> [Space] {
        try await database.writer.read { db in
            try Space.order(Space.Columns.sortKey, Space.Columns.id).fetchAll(db)
        }
    }

    // MARK: Tabs

    /// The request for a Space's tabs that are not archived, in sidebar order.
    ///
    /// Use it with `ValueObservation` or GRDBQuery to keep a view up to date.
    public static func tabsRequest(in spaceID: Space.ID) -> QueryInterfaceRequest<Tab> {
        Tab
            .filter(Tab.Columns.spaceID == spaceID)
            .filter(Tab.Columns.archivedAt == nil)
            .order(Tab.Columns.sortKey, Tab.Columns.id)
    }

    /// Returns a Space's tabs that are not archived, in sidebar order.
    public func tabs(in spaceID: Space.ID) async throws -> [Tab] {
        try await database.writer.read { db in
            try Self.tabsRequest(in: spaceID).fetchAll(db)
        }
    }

    /// Returns the tab with `id`, or `nil` if it doesn't exist.
    public func tab(id: Tab.ID) async throws -> Tab? {
        try await database.writer.read { db in
            try Tab.fetchOne(db, id: id)
        }
    }

    /// Creates a tab for `url` in a Space.
    ///
    /// - Parameters:
    ///   - url: The page to open.
    ///   - title: The page title if already known.
    ///   - spaceID: The Space to add the tab to.
    ///   - position: Where to place the tab. Defaults to the end of the list.
    /// - Returns: The new tab.
    @discardableResult
    public func openTab(
        url: URL,
        title: String = "",
        in spaceID: Space.ID,
        at position: TabPosition = .end
    ) async throws -> Tab {
        try await database.writer.write { db in
            let sortKey = try Self.sortKey(for: position, in: spaceID, excluding: nil, db)
            let tab = Tab(spaceID: spaceID, url: url, title: title, sortKey: sortKey)
            try tab.insert(db)
            return tab
        }
    }

    /// Moves a tab within its Space. Only the moved tab's row changes.
    ///
    /// - Throws: ``TabStoreError`` if the tab or the anchor tab doesn't exist, or the anchor is
    ///   in another Space.
    public func moveTab(id: Tab.ID, to position: TabPosition) async throws {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: id) else { throw TabStoreError.tabNotFound(id) }
            if case .after(let anchorID) = position, anchorID == id { return }
            tab.sortKey = try Self.sortKey(for: position, in: tab.spaceID, excluding: id, db)
            try tab.update(db)
        }
    }

    /// Updates a tab's page and title, for example after a navigation.
    ///
    /// - Throws: ``TabStoreError/tabNotFound(_:)`` if the tab doesn't exist.
    public func updateTab(id: Tab.ID, url: URL, title: String) async throws {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: id) else { throw TabStoreError.tabNotFound(id) }
            tab.url = url
            tab.title = title
            try tab.update(db)
        }
    }

    /// Closes a tab, deleting it. Archiving closed tabs arrives in Milestone 2.
    ///
    /// Closing a tab that doesn't exist does nothing.
    public func closeTab(id: Tab.ID) async throws {
        _ = try await database.writer.write { db in
            try Tab.deleteOne(db, id: id)
        }
    }

    // MARK: Ordering

    /// Computes a sort key for `position` among a Space's tabs, ignoring the tab being moved.
    private static func sortKey(
        for position: TabPosition,
        in spaceID: Space.ID,
        excluding excludedID: Tab.ID?,
        _ db: Database
    ) throws -> String {
        var siblings = Tab.filter(Tab.Columns.spaceID == spaceID)
        if let excludedID {
            siblings = siblings.filter(Tab.Columns.id != excludedID)
        }
        switch position {
        case .start:
            let first = try siblings.order(Tab.Columns.sortKey, Tab.Columns.id).fetchOne(db)
            return try SortKey.between(nil, first?.sortKey)
        case .end:
            let last = try siblings.order(Tab.Columns.sortKey.desc, Tab.Columns.id.desc).fetchOne(db)
            return try SortKey.between(last?.sortKey, nil)
        case .after(let anchorID):
            guard let anchor = try Tab.fetchOne(db, id: anchorID) else {
                throw TabStoreError.tabNotFound(anchorID)
            }
            guard anchor.spaceID == spaceID else { throw TabStoreError.anchorInDifferentSpace(anchorID) }
            // The next distinct key, so ties left by a sync merge can't produce an invalid range.
            let next = try siblings
                .filter(Tab.Columns.sortKey > anchor.sortKey)
                .order(Tab.Columns.sortKey)
                .fetchOne(db)
            return try SortKey.between(anchor.sortKey, next?.sortKey)
        }
    }
}
