import AxoPersistence
import Foundation
import GRDB

/// What Axo offers to system search (Spotlight): pinned tabs in every Space, and recent history.
public struct SearchableContent: Equatable, Sendable {
    /// A pinned tab, with the name of its Space.
    public struct PinnedTab: Equatable, Sendable {
        public var tab: Tab
        public var spaceName: String
    }

    /// A page from history, with the name of its profile.
    public struct Page: Equatable, Sendable {
        public var item: HistoryItem
        public var profileName: String
    }

    public var pinnedTabs: [PinnedTab]
    /// The most recently visited pages, newest first.
    public var history: [Page]
}

extension TabStore {
    /// Pinned tabs (not archived) in every Space, and the `historyLimit` most recently visited
    /// pages across profiles.
    public func searchableContent(historyLimit: Int = 500) async throws -> SearchableContent {
        try await database.writer.read { db in try Self.searchableContent(historyLimit: historyLimit, db) }
    }

    /// Streams ``searchableContent(historyLimit:)``: the current content first, then new content
    /// after every change to tabs, Spaces, profiles, or history.
    public func observeSearchableContent(historyLimit: Int = 500) -> AsyncValueObservation<SearchableContent> {
        ValueObservation
            .tracking { db in try Self.searchableContent(historyLimit: historyLimit, db) }
            .removeDuplicates()
            .values(in: database.writer)
    }

    private static func searchableContent(historyLimit: Int, _ db: Database) throws -> SearchableContent {
        let spaceNames = Dictionary(uniqueKeysWithValues: try Space.fetchAll(db).map { ($0.id, $0.name) })
        let profileNames = Dictionary(uniqueKeysWithValues: try Profile.fetchAll(db).map { ($0.id, $0.name) })
        let pinned = try Tab
            .filter(Tab.Columns.isPinned == true)
            .filter(Tab.Columns.archivedAt == nil)
            .order(Tab.Columns.spaceID, Tab.Columns.sortKey)
            .fetchAll(db)
            .map { SearchableContent.PinnedTab(tab: $0, spaceName: spaceNames[$0.spaceID] ?? "") }
        let history = try HistoryItem
            .order(HistoryItem.Columns.lastVisitedAt.desc)
            .limit(historyLimit)
            .fetchAll(db)
            .map { SearchableContent.Page(item: $0, profileName: profileNames[$0.profileID] ?? "") }
        return SearchableContent(pinnedTabs: pinned, history: history)
    }
}
