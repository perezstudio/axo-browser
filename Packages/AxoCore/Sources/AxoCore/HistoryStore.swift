import AxoPersistence
import Foundation
import GRDB

/// A page in a profile's browsing history.
public struct HistoryItem: Codable, Hashable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "historyItem"

    /// The row ID, assigned when the item is first saved.
    public var id: Int64?
    /// The profile whose history this is. Profiles never see each other's history.
    public var profileID: Profile.ID
    /// The page.
    public var url: URL
    /// The page title, or an empty string if it has none.
    public var title: String
    /// How many times the page was visited.
    public var visitCount: Int
    /// The most recent visit.
    public var lastVisitedAt: Date

    /// Creates a history item. ``HistoryStore`` assigns ``id`` when it's saved.
    public init(id: Int64? = nil, profileID: Profile.ID, url: URL, title: String, visitCount: Int, lastVisitedAt: Date) {
        self.id = id
        self.profileID = profileID
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let profileID = Column(CodingKeys.profileID)
        public static let url = Column(CodingKeys.url)
        public static let title = Column(CodingKeys.title)
        public static let visitCount = Column(CodingKeys.visitCount)
        public static let lastVisitedAt = Column(CodingKeys.lastVisitedAt)
    }
}

/// Records and searches browsing history, per profile.
///
/// Only http and https pages are recorded. Searches use the FTS5 index, so they stay fast on
/// every keystroke even with a large history.
public final class HistoryStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over `database`. Usually reached through ``TabStore/history``.
    public init(database: AppDatabase) {
        self.database = database
    }

    /// Whether a URL belongs in history.
    public static func records(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Records a visit: adds the page, or counts another visit and updates its title and time.
    public func recordVisit(to url: URL, title: String, profileID: Profile.ID, at date: Date = Date()) async throws {
        guard Self.records(url) else { return }
        try await database.writer.write { db in
            if var item = try HistoryItem
                .filter(HistoryItem.Columns.profileID == profileID)
                .filter(HistoryItem.Columns.url == url)
                .fetchOne(db) {
                item.visitCount += 1
                item.lastVisitedAt = date
                if !title.isEmpty { item.title = title }
                try item.update(db)
            } else {
                var item = HistoryItem(profileID: profileID, url: url, title: title, visitCount: 1, lastVisitedAt: date)
                try item.insert(db)
            }
        }
    }

    /// Adds pages from another browser's history to a profile's history, in one transaction.
    ///
    /// Pages already in history add the imported visit count, keep the later visit time, and
    /// take the imported title only if they have none. Only http and https pages are added.
    ///
    /// - Parameter items: The pages to add. Their ``HistoryItem/id`` and
    ///   ``HistoryItem/profileID`` are ignored.
    /// - Returns: How many pages were added or updated.
    @discardableResult
    public func importItems(_ items: [HistoryItem], profileID: Profile.ID) async throws -> Int {
        let pages = items.filter { Self.records($0.url) && $0.visitCount > 0 }
        guard !pages.isEmpty else { return 0 }
        return try await database.writer.write { db in
            for page in pages {
                if var item = try HistoryItem
                    .filter(HistoryItem.Columns.profileID == profileID)
                    .filter(HistoryItem.Columns.url == page.url)
                    .fetchOne(db) {
                    item.visitCount += page.visitCount
                    item.lastVisitedAt = max(item.lastVisitedAt, page.lastVisitedAt)
                    if item.title.isEmpty { item.title = page.title }
                    try item.update(db)
                } else {
                    var item = page
                    item.id = nil
                    item.profileID = profileID
                    try item.insert(db)
                }
            }
            return pages.count
        }
    }

    /// Updates the title of a page already in history, for titles that arrive after the visit.
    public func updateTitle(_ title: String, for url: URL, profileID: Profile.ID) async throws {
        guard Self.records(url), !title.isEmpty else { return }
        _ = try await database.writer.write { db in
            try HistoryItem
                .filter(HistoryItem.Columns.profileID == profileID)
                .filter(HistoryItem.Columns.url == url)
                .updateAll(db, HistoryItem.Columns.title.set(to: title))
        }
    }

    /// Searches a profile's history by title and URL, matching every word as a prefix.
    ///
    /// Results are ranked by text relevance, then boosted by how often and how recently the page
    /// was visited.
    public func search(_ query: String, profileID: Profile.ID, limit: Int = 8, now: Date = Date()) async throws -> [HistoryItem] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let candidates = try await database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT historyItem.*, historyItem_ft.rank AS relevance
                FROM historyItem
                JOIN historyItem_ft ON historyItem_ft.rowid = historyItem.id
                WHERE historyItem_ft MATCH ? AND historyItem.profileID = ?
                ORDER BY historyItem_ft.rank
                LIMIT ?
                """, arguments: [pattern, profileID, limit * 4])
            .map { row in (item: try HistoryItem(row: row), relevance: row["relevance"] as Double) }
        }
        return candidates
            .sorted { Self.score($0.item, relevance: $0.relevance, now: now) > Self.score($1.item, relevance: $1.relevance, now: now) }
            .prefix(limit)
            .map(\.item)
    }

    /// Higher is better. FTS5's rank is negative, with more relevant matches more negative.
    static func score(_ item: HistoryItem, relevance: Double, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(item.lastVisitedAt) / 86_400)
        let frequency = log(Double(item.visitCount) + 1)
        let recency = 1 / (1 + days / 7)
        return -relevance + frequency + 2 * recency
    }

    /// A profile's most recently visited pages.
    public func recent(profileID: Profile.ID, limit: Int = 8) async throws -> [HistoryItem] {
        try await database.writer.read { db in
            try HistoryItem
                .filter(HistoryItem.Columns.profileID == profileID)
                .order(HistoryItem.Columns.lastVisitedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Deletes a profile's history.
    public func clear(profileID: Profile.ID) async throws {
        _ = try await database.writer.write { db in
            try HistoryItem.filter(HistoryItem.Columns.profileID == profileID).deleteAll(db)
        }
    }
}

extension TabStore {
    /// History in the same database as the sidebar.
    public var history: HistoryStore {
        HistoryStore(database: database)
    }
}
