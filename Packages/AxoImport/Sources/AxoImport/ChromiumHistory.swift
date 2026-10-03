import AxoCore
import Foundation
import GRDB

/// Browsing history from a Chromium `History` database (Chrome's, or one of Arc's profiles).
public enum ChromiumHistory {
    /// The most pages read from one history file. Older pages are left out, which keeps imports
    /// and the search index quick.
    public static let pageLimit = 50_000

    /// Reads the most recently visited web pages, newest first.
    ///
    /// The browser may be running and holding the file open, so this reads a copy.
    ///
    /// - Parameters:
    ///   - url: The `History` file.
    ///   - limit: The most pages to read.
    /// - Returns: Pages as ``HistoryItem``s, with a placeholder profile ID. ``HistoryStore``
    ///   assigns the real one when importing.
    /// - Throws: ``ImportError`` if the file can't be read or isn't a Chromium history database.
    public static func pages(at url: URL, limit: Int = pageLimit) throws -> [HistoryItem] {
        try withCopy(of: url) { db in
            try Row.fetchAll(db, sql: """
                SELECT url, title, visit_count, last_visit_time FROM urls
                WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
                ORDER BY last_visit_time DESC
                LIMIT ?
                """, arguments: [limit])
            .compactMap { row in
                guard let address = row["url"] as String?, let page = URL(string: address) else { return nil }
                return HistoryItem(
                    profileID: UUID(),
                    url: page,
                    title: row["title"] as String? ?? "",
                    visitCount: max(1, row["visit_count"] as Int? ?? 1),
                    lastVisitedAt: date(fromChromiumTime: row["last_visit_time"] as Int64? ?? 0)
                )
            }
        }
    }

    /// Counts the web pages ``pages(at:limit:)`` would read.
    public static func pageCount(at url: URL, limit: Int = pageLimit) throws -> Int {
        try withCopy(of: url) { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM urls
                WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
                """) ?? 0
            return min(count, limit)
        }
    }

    /// Chromium stores times as microseconds since January 1, 1601 (UTC).
    static func date(fromChromiumTime time: Int64) -> Date {
        Date(timeIntervalSince1970: Double(time) / 1_000_000 - 11_644_473_600)
    }

    /// Copies the database (and its write-ahead log, if any) to a temporary folder and reads it.
    private static func withCopy<T>(of url: URL, _ read: (Database) throws -> T) throws -> T {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { throw ImportError.notFound(url) }
        let folder = manager.temporaryDirectory.appending(path: "AxoImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: folder) }
        let copy = folder.appending(path: "History")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.copyItem(at: url, to: copy)
            let wal = URL(fileURLWithPath: url.path + "-wal")
            if manager.fileExists(atPath: wal.path) {
                try manager.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
        } catch {
            throw ImportError.unreadable(url)
        }
        do {
            return try DatabaseQueue(path: copy.path).read(read)
        } catch {
            throw ImportError.unrecognizedFormat(url)
        }
    }
}
