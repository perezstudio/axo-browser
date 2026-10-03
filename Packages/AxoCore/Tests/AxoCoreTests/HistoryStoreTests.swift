import AxoPersistence
import Foundation
import GRDB
import Testing
@testable import AxoCore

struct HistoryStoreTests {
    let store: TabStore
    let history: HistoryStore
    let profileID: Profile.ID

    init() async throws {
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
        history = store.history
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func visitsAreCountedAndTitlesKept() async throws {
        let page = url("https://swift.org/documentation")
        try await history.recordVisit(to: page, title: "Swift Documentation", profileID: profileID)
        try await history.recordVisit(to: page, title: "", profileID: profileID)

        let item = try #require(try await history.recent(profileID: profileID).first)
        #expect(item.visitCount == 2)
        #expect(item.title == "Swift Documentation", "An empty title doesn't replace a known one")

        try await history.updateTitle("The Swift Book", for: page, profileID: profileID)
        #expect(try await history.recent(profileID: profileID).first?.title == "The Swift Book")
    }

    @Test(arguments: ["about:blank", "data:text/html,hi", "file:///tmp/page.html"])
    func onlyWebPagesAreRecorded(address: String) async throws {
        try await history.recordVisit(to: url(address), title: "x", profileID: profileID)
        #expect(try await history.recent(profileID: profileID).isEmpty)
    }

    @Test func searchMatchesWordPrefixesInTitlesAndURLs() async throws {
        try await history.recordVisit(to: url("https://developer.apple.com/documentation/webkit"), title: "WebKit", profileID: profileID)
        try await history.recordVisit(to: url("https://github.com/groue/GRDB.swift"), title: "GRDB on GitHub", profileID: profileID)

        #expect(try await history.search("webk", profileID: profileID).map(\.title) == ["WebKit"])
        #expect(try await history.search("groue", profileID: profileID).map(\.title) == ["GRDB on GitHub"], "URLs are searched too")
        #expect(try await history.search("apple docum", profileID: profileID).map(\.title) == ["WebKit"], "Every word must match")
        #expect(try await history.search("nothing", profileID: profileID).isEmpty)
        #expect(try await history.search("   ", profileID: profileID).isEmpty)
        // Quotes and other FTS syntax in what people type must not throw.
        _ = try await history.search("\"unbalanced (paren OR", profileID: profileID)
    }

    @Test func frequentAndRecentPagesRankHigher() async throws {
        let now = Date()
        let old = now.addingTimeInterval(-60 * 86_400)
        try await history.recordVisit(to: url("https://news.example.com/rarely"), title: "News archive", profileID: profileID, at: old)
        for _ in 0..<5 {
            try await history.recordVisit(to: url("https://news.example.com/daily"), title: "News today", profileID: profileID, at: now)
        }

        #expect(try await history.search("news", profileID: profileID, now: now).map(\.title) == ["News today", "News archive"])
    }

    @Test func profilesKeepSeparateHistory() async throws {
        let other = try await store.createProfile(name: "Work")
        try await history.recordVisit(to: url("https://bank.example.com"), title: "Bank", profileID: profileID)

        #expect(try await history.search("bank", profileID: other.id).isEmpty)
        try await history.clear(profileID: profileID)
        #expect(try await history.search("bank", profileID: profileID).isEmpty)
    }

    @Test func searchingFiftyThousandPagesStaysFast() async throws {
        // Seed 50,000 pages in one transaction, then time searches the way the command bar runs
        // them: one per keystroke.
        let words = ["swift", "webkit", "axolotl", "browser", "sqlite", "design", "notes", "travel", "recipe", "music"]
        let profileID = profileID
        try await store.database.writer.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO historyItem (profileID, url, title, visitCount, lastVisitedAt) VALUES (?, ?, ?, ?, ?)
                """)
            for i in 0..<50_000 {
                let a = words[i % words.count], b = words[(i / 10) % words.count]
                try statement.execute(arguments: [
                    profileID, "https://\(a).example.com/\(b)/\(i)", "\(a.capitalized) \(b) page \(i)",
                    i % 7 + 1, Date(timeIntervalSinceNow: -Double(i) * 60),
                ])
            }
        }

        let queries = ["s", "sw", "swi", "swif", "swift", "swift w", "swift web", "axolotl notes", "rec", "music travel"]
        var durations: [Duration] = []
        for query in queries {
            let start = ContinuousClock.now
            let results = try await history.search(query, profileID: profileID)
            durations.append(ContinuousClock.now - start)
            #expect(results.count <= 8)
        }
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2], worst = sorted.last!
        print("Command bar history search over 50,000 pages: median \(median), worst \(worst)")
        // Generous ceilings for a debug build on a busy machine; the printed numbers are the baseline.
        #expect(median < .milliseconds(50))
        #expect(worst < .milliseconds(250))
    }
}
