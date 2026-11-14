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
    /// How many times the page was opened by typing its address (in the address field or the
    /// command bar) rather than through a link, which counts for more in the command bar (#121).
    public var typedCount: Int

    /// Creates a history item. ``HistoryStore`` assigns ``id`` when it's saved.
    public init(id: Int64? = nil, profileID: Profile.ID, url: URL, title: String, visitCount: Int, lastVisitedAt: Date, typedCount: Int = 0) {
        self.id = id
        self.profileID = profileID
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
        self.typedCount = typedCount
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
        public static let typedCount = Column(CodingKeys.typedCount)
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

    /// Counts a page opened by typing its address (#121). A page not in history yet is added
    /// with no visits; its visit is recorded when it loads.
    public func recordTypedVisit(to url: URL, profileID: Profile.ID, at date: Date = Date()) async throws {
        guard Self.records(url) else { return }
        try await database.writer.write { db in
            if var item = try HistoryItem
                .filter(HistoryItem.Columns.profileID == profileID)
                .filter(HistoryItem.Columns.url == url)
                .fetchOne(db) {
                item.typedCount += 1
                try item.update(db)
            } else {
                var item = HistoryItem(profileID: profileID, url: url, title: "", visitCount: 0, lastVisitedAt: date, typedCount: 1)
                try item.insert(db)
            }
        }
    }

    /// The most choices kept per profile; the least recently used go first.
    static let maxChoices = 500

    /// Remembers that `query` led to `url` in the command bar (#121), so the same query, or a
    /// shorter one it starts with, ranks that page higher next time.
    public func recordChoice(query: String, url: URL, profileID: Profile.ID, at date: Date = Date()) async throws {
        let query = Self.normalized(query)
        guard !query.isEmpty, Self.records(url) else { return }
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO commandChoice (profileID, query, url, count, lastChosenAt) VALUES (?, ?, ?, 1, ?)
                ON CONFLICT (profileID, query, url) DO UPDATE SET count = count + 1, lastChosenAt = excluded.lastChosenAt
                """, arguments: [profileID, query, url.absoluteString, date])
            try db.execute(sql: """
                DELETE FROM commandChoice WHERE profileID = ? AND rowid NOT IN (
                    SELECT rowid FROM commandChoice WHERE profileID = ? ORDER BY lastChosenAt DESC LIMIT ?)
                """, arguments: [profileID, profileID, Self.maxChoices])
        }
    }

    /// A query as choices are kept: trimmed, lowercased, with single spaces.
    static func normalized(_ query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
    /// was visited, how often it was typed, how well the query matches its address and title, and
    /// how often the query (or a longer one that starts with it) led to it before (#121).
    public func search(_ query: String, profileID: Profile.ID, limit: Int = 8, now: Date = Date()) async throws -> [HistoryItem] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let normalized = Self.normalized(query)
        let (candidates, choices) = try await database.writer.read { db in
            let candidates = try Row.fetchAll(db, sql: """
                SELECT historyItem.*, historyItem_ft.rank AS relevance
                FROM historyItem
                JOIN historyItem_ft ON historyItem_ft.rowid = historyItem.id
                WHERE historyItem_ft MATCH ? AND historyItem.profileID = ?
                ORDER BY historyItem_ft.rank
                LIMIT ?
                """, arguments: [pattern, profileID, limit * 4])
            .map { row in (item: try HistoryItem(row: row), relevance: row["relevance"] as Double) }
            // Choices for this query, and for longer queries that start with it.
            var choices: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT url, SUM(count) AS count FROM commandChoice
                WHERE profileID = ? AND substr(query, 1, length(?)) = ?
                GROUP BY url
                """, arguments: [profileID, normalized, normalized]) {
                choices[row["url"]] = row["count"]
            }
            return (candidates, choices)
        }
        let scored = candidates.map { candidate in
            (candidate.item, Self.score(candidate.item, relevance: candidate.relevance, now: now, query: normalized,
                                        choices: choices[candidate.item.url.absoluteString] ?? 0))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Higher is better. FTS5's rank is negative, with more relevant matches more negative.
    static func score(_ item: HistoryItem, relevance: Double, now: Date, query: String = "", choices: Int = 0) -> Double {
        let days = max(0, now.timeIntervalSince(item.lastVisitedAt) / 86_400)
        let frequency = log(Double(item.visitCount) + 1)
        let recency = 1 / (1 + days / 7)
        let typed = 1.5 * log(Double(item.typedCount) + 1)
        let learned = 3 * log(Double(choices) + 1)
        return -relevance + frequency + 2 * recency + typed + matchQuality(of: item, for: query) + learned
    }

    /// How well a normalized query matches a page: its whole address or site (4), the start of
    /// its host, after any www. (2), or the start of its title (1), above a match in the middle of a
    /// title (0).
    static func matchQuality(of item: HistoryItem, for query: String) -> Double {
        guard let word = query.split(separator: " ").first.map(String.init) else { return 0 }
        let host = (item.url.host()?.lowercased() ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored)
        var address = item.url.absoluteString.lowercased()
        if let scheme = address.range(of: "://") { address.removeSubrange(address.startIndex..<scheme.upperBound) }
        if address.hasPrefix("www.") { address.removeFirst(4) }
        if address.hasSuffix("/") { address.removeLast() }
        if query == address || query == host { return 4 }
        if host.hasPrefix(word) { return 2 }
        if item.title.lowercased().hasPrefix(word) { return 1 }
        return 0
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

    /// Deletes pages from a profile's history, in one transaction.
    ///
    /// - Parameter lastVisitedIn: Deletes only pages last visited in this range, such as the
    ///   range of visits another copy of history deleted; `nil` deletes them whenever visited.
    public func delete(_ urls: [URL], lastVisitedIn range: ClosedRange<Date>? = nil, profileID: Profile.ID) async throws {
        guard !urls.isEmpty else { return }
        try await database.writer.write { db in
            // In batches, below SQLite's limit on a statement's arguments.
            for start in stride(from: 0, to: urls.count, by: 500) {
                var request = HistoryItem
                    .filter(HistoryItem.Columns.profileID == profileID)
                    .filter(urls[start..<min(start + 500, urls.count)].contains(HistoryItem.Columns.url))
                if let range {
                    request = request.filter(range.contains(HistoryItem.Columns.lastVisitedAt))
                }
                // The command bar's choices for the pages deleted go with them, so a deleted page
                // visited again doesn't come back with what it had learned.
                let deleted = try String.fetchAll(db, request.select(HistoryItem.Columns.url))
                try request.deleteAll(db)
                if !deleted.isEmpty {
                    let marks = Array(repeating: "?", count: deleted.count).joined(separator: ", ")
                    try db.execute(sql: "DELETE FROM commandChoice WHERE profileID = ? AND url IN (\(marks))",
                                   arguments: StatementArguments([profileID.databaseValue] + deleted.map(\.databaseValue)))
                }
            }
        }
    }

    /// Deletes a profile's history, and the command bar's choices learned from it.
    public func clear(profileID: Profile.ID) async throws {
        _ = try await database.writer.write { db in
            try HistoryItem.filter(HistoryItem.Columns.profileID == profileID).deleteAll(db)
            try db.execute(sql: "DELETE FROM commandChoice WHERE profileID = ?", arguments: [profileID])
        }
    }
}

extension TabStore {
    /// History in the same database as the sidebar.
    public var history: HistoryStore {
        HistoryStore(database: database)
    }
}
