import Foundation
import GRDB

/// A fake `~/Library/Application Support` with Arc and Chrome data, built in code.
struct BrowserFixtures {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AxoImportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ text: String, to path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A Chromium `History` database with the columns Axo reads.
    /// - Parameter pages: (url, title, visit count, Chromium time, hidden).
    func writeHistory(to path: String, pages: [(String, String, Int, Int64, Bool)]) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
                    visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
                    last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL)
                """)
            for (address, title, visits, time, hidden) in pages {
                try db.execute(
                    sql: "INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?)",
                    arguments: [address, title, visits, time, hidden]
                )
            }
        }
    }

    /// Chromium time for a date: microseconds since January 1, 1601.
    static func chromiumTime(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
    }

    /// Arc's sidebar with two Spaces on two profiles, folders, a split view, favorites for each
    /// profile, and an item kind Axo doesn't know.
    static let arcSidebar = """
    {"version": 1, "sidebar": {"containers": [{"global": {}}, {
      "topAppsContainerIDs": [{"default": true}, "top-default", {"custom": {"_0": {"machineID": "m", "directoryBasename": "Profile 1"}}}, "top-work"],
      "spaces": [
        "space-home", {"id": "space-home", "title": "Personal", "profile": {"default": true},
                       "containerIDs": ["pinned", "home-pinned", "unpinned", "home-unpinned"]},
        "space-work", {"id": "space-work", "title": "Work", "profile": {"custom": {"_0": {"machineID": "m", "directoryBasename": "Profile 1"}}},
                       "containerIDs": ["pinned", "work-pinned", "unpinned", "work-unpinned"]}
      ],
      "items": [
        "top-default", {"id": "top-default", "title": null, "childrenIds": ["fav-mail"], "data": {"itemContainer": {"containerType": {"topApps": {}}}}},
        "fav-mail", {"id": "fav-mail", "title": null, "childrenIds": [], "parentID": "top-default", "data": {"tab": {"savedURL": "https://mail.example.com/", "savedTitle": "Mail"}}},
        "top-work", {"id": "top-work", "title": null, "childrenIds": ["fav-cal"], "data": {"itemContainer": {"containerType": {"topApps": {}}}}},
        "fav-cal", {"id": "fav-cal", "title": null, "childrenIds": [], "parentID": "top-work", "data": {"tab": {"savedURL": "https://calendar.example.com/", "savedTitle": "Calendar"}}},
        "home-pinned", {"id": "home-pinned", "title": null, "childrenIds": ["news", "recipes", "easel"], "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-home"}}}}},
        "news", {"id": "news", "title": "My News", "childrenIds": [], "parentID": "home-pinned", "data": {"tab": {"savedURL": "https://news.example.com/", "savedTitle": "News Site"}}},
        "recipes", {"id": "recipes", "title": "Recipes", "childrenIds": ["soup", "baking"], "parentID": "home-pinned", "data": {"list": {}}},
        "soup", {"id": "soup", "title": null, "childrenIds": [], "parentID": "recipes", "data": {"tab": {"savedURL": "https://food.example.com/soup", "savedTitle": "Soup"}}},
        "baking", {"id": "baking", "title": null, "childrenIds": ["bread"], "parentID": "recipes", "data": {"list": {}}},
        "bread", {"id": "bread", "title": null, "childrenIds": [], "parentID": "baking", "data": {"tab": {"savedURL": "https://food.example.com/bread", "savedTitle": "Bread"}}},
        "easel", {"id": "easel", "title": "Sketch", "childrenIds": [], "parentID": "home-pinned", "data": {"easel": {}}},
        "home-unpinned", {"id": "home-unpinned", "title": null, "childrenIds": ["split"], "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-home"}}}}},
        "split", {"id": "split", "title": null, "childrenIds": ["left", "right"], "parentID": "home-unpinned", "data": {"splitView": {}}},
        "left", {"id": "left", "title": null, "childrenIds": [], "parentID": "split", "data": {"tab": {"savedURL": "https://left.example.com/", "savedTitle": "Left"}}},
        "right", {"id": "right", "title": null, "childrenIds": [], "parentID": "split", "data": {"tab": {"savedURL": "https://right.example.com/", "savedTitle": "Right"}}},
        "work-pinned", {"id": "work-pinned", "title": null, "childrenIds": ["docs"], "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-work"}}}}},
        "docs", {"id": "docs", "title": null, "childrenIds": [], "parentID": "work-pinned", "data": {"tab": {"savedURL": "https://docs.example.com/", "savedTitle": "Docs"}}},
        "work-unpinned", {"id": "work-unpinned", "title": null, "childrenIds": [], "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "space-work"}}}}}
      ]}]}}
    """

    static let localState = """
    {"profile": {"info_cache": {"Profile 1": {"name": "Work"}, "Default": {"name": "Personal"}, "Profile 10": {"name": ""}, "Profile 2": {"name": "Side"}}}}
    """

    static let chromeBookmarks = """
    {"roots": {
      "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
        {"type": "url", "name": "WebKit", "url": "https://webkit.org/"},
        {"type": "folder", "name": "Swift", "children": [{"type": "url", "name": "Forums", "url": "https://forums.swift.org/"}]},
        {"type": "folder", "name": "Empty", "children": []}
      ]},
      "other": {"type": "folder", "name": "Other bookmarks", "children": [{"type": "url", "name": "Recipes", "url": "https://food.example.com/"}]},
      "synced": {"type": "folder", "name": "Mobile bookmarks", "children": []}
    }, "version": 1}
    """
}
