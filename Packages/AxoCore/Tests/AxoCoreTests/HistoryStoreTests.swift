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

    @Test func importedHistoryMergesWithExistingPages() async throws {
        let known = url("https://swift.org")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        try await history.recordVisit(to: known, title: "", profileID: profileID, at: recent)

        let imported = try await history.importItems([
            HistoryItem(profileID: UUID(), url: known, title: "Swift", visitCount: 5, lastVisitedAt: old),
            HistoryItem(profileID: UUID(), url: url("https://webkit.org"), title: "WebKit", visitCount: 2, lastVisitedAt: old),
            HistoryItem(profileID: UUID(), url: url("chrome://settings"), title: "Settings", visitCount: 9, lastVisitedAt: old),
        ], profileID: profileID)

        #expect(imported == 2, "Only web pages are imported")
        let items = try await history.recent(profileID: profileID)
        #expect(items.map(\.url) == [known, url("https://webkit.org")])
        #expect(items[0].visitCount == 6 && items[0].lastVisitedAt == recent, "Visits add up and the later time wins")
        #expect(items[0].title == "Swift", "An imported title fills in a missing one")
        #expect(items[1].profileID == profileID)
        #expect(try await history.search("webkit", profileID: profileID).count == 1, "Imported pages are searchable")
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

    @Test func pagesAreDeletedPerProfile() async throws {
        let other = try await store.createProfile(name: "Work").id
        for page in ["https://a.example/", "https://b.example/", "https://c.example/"] {
            try await history.recordVisit(to: url(page), title: "", profileID: profileID)
        }
        try await history.recordVisit(to: url("https://a.example/"), title: "", profileID: other)

        try await history.delete([url("https://a.example/"), url("https://c.example/")], profileID: profileID)
        #expect(try await history.recent(profileID: profileID).map(\.url) == [url("https://b.example/")])
        #expect(try await history.recent(profileID: other).count == 1, "Other profiles keep theirs")

        try await history.clear(profileID: profileID)
        #expect(try await history.recent(profileID: profileID).isEmpty)
        #expect(try await history.recent(profileID: other).count == 1)
    }

    @Test func deletingByRangeKeepsPagesVisitedOutsideIt() async throws {
        let now = Date()
        try await history.recordVisit(to: url("https://old.example/"), title: "", profileID: profileID, at: now.addingTimeInterval(-86_400 * 30))
        try await history.recordVisit(to: url("https://new.example/"), title: "", profileID: profileID, at: now)
        try await history.delete(
            [url("https://old.example/"), url("https://new.example/")],
            lastVisitedIn: now.addingTimeInterval(-3_600)...now.addingTimeInterval(1), profileID: profileID
        )
        #expect(try await history.recent(profileID: profileID).map(\.url) == [url("https://old.example/")])
    }

    @Test func deletingManyPagesAtOnceWorks() async throws {
        let pages = (0..<40_000).map { url("https://site\($0).example/") }
        _ = try await history.importItems(
            pages.map { HistoryItem(profileID: profileID, url: $0, title: "", visitCount: 1, lastVisitedAt: Date()) },
            profileID: profileID
        )
        try await history.delete(pages, profileID: profileID)
        #expect(try await history.recent(profileID: profileID).isEmpty)
    }

    // MARK: Ranking (#121)

    @Test func typedPagesRankAbovePagesOnlyReachedByLinks() async throws {
        let now = Date()
        let linked = url("https://docs.example/swift-guide")
        let typed = url("https://swift-notes.example/")
        // The linked page is visited more often; the typed one was typed twice.
        for _ in 0..<3 { try await history.recordVisit(to: linked, title: "Swift Guide", profileID: profileID, at: now) }
        try await history.recordVisit(to: typed, title: "Swift Notes", profileID: profileID, at: now)
        try await history.recordTypedVisit(to: typed, profileID: profileID)
        try await history.recordTypedVisit(to: typed, profileID: profileID)
        let results = try await history.search("swift", profileID: profileID, now: now)
        #expect(results.first?.url == typed)
        #expect(results.first?.typedCount == 2)
    }

    @Test func aPageTypedBeforeItLoadsIsAddedWithNoVisits() async throws {
        let page = url("https://new.example/")
        try await history.recordTypedVisit(to: page, profileID: profileID)
        let item = try #require(try await history.recent(profileID: profileID).first)
        #expect(item.url == page && item.typedCount == 1 && item.visitCount == 0)
        try await history.recordVisit(to: page, title: "New", profileID: profileID)
        let visited = try #require(try await history.recent(profileID: profileID).first)
        #expect(visited.visitCount == 1 && visited.typedCount == 1)
    }

    @Test func theStartOfTheSiteOrTitleRanksAboveTheMiddleOfATitle() {
        let now = Date()
        func item(_ address: String, _ title: String) -> HistoryItem {
            HistoryItem(profileID: profileID, url: url(address), title: title, visitCount: 1, lastVisitedAt: now)
        }
        let site = item("https://github.com/", "Home")
        let titleStart = item("https://learn.example/a", "Git basics")
        let middle = item("https://learn.example/b", "Learning git")
        #expect(HistoryStore.matchQuality(of: item("https://www.github.com/", "x"), for: "github.com") == 4, "The whole site")
        #expect(HistoryStore.matchQuality(of: site, for: "git") == 2)
        #expect(HistoryStore.matchQuality(of: titleStart, for: "git") == 1)
        #expect(HistoryStore.matchQuality(of: middle, for: "git") == 0)
        let scores = [site, titleStart, middle].map { HistoryStore.score($0, relevance: -1, now: now, query: "git") }
        #expect(scores == scores.sorted(by: >), "Same relevance, visits, and age: the better match wins")
    }

    @Test func aQueryLearnsWhichPageItLedTo() async throws {
        let now = Date()
        let mail = url("https://mail.example/")
        let maps = url("https://maps.example/")
        try await history.recordVisit(to: mail, title: "Mail", profileID: profileID, at: now)
        for _ in 0..<5 { try await history.recordVisit(to: maps, title: "Maps", profileID: profileID, at: now) }
        #expect(try await history.search("ma", profileID: profileID, now: now).first?.url == maps, "Visited more")

        try await history.recordChoice(query: "  MAI  ", url: mail, profileID: profileID)
        try await history.recordChoice(query: "mai", url: mail, profileID: profileID)
        #expect(try await history.search("mai", profileID: profileID, now: now).first?.url == mail, "The same query")
        #expect(try await history.search("ma", profileID: profileID, now: now).first?.url == mail, "A shorter query it starts with")

        let otherProfile = try await store.createProfile(name: "Work").id
        try await history.recordVisit(to: maps, title: "Maps", profileID: otherProfile, at: now)
        try await history.recordVisit(to: mail, title: "Mail", profileID: otherProfile, at: now)
        for _ in 0..<5 { try await history.recordVisit(to: maps, title: "Maps", profileID: otherProfile, at: now) }
        #expect(try await history.search("ma", profileID: otherProfile, now: now).first?.url == maps, "Choices stay in their profile")

        try await history.clear(profileID: profileID)
        let left = try await store.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commandChoice WHERE profileID = ?", arguments: [profileID])
        }
        #expect(left == 0, "Clearing history clears what was learned from it")
    }

    @Test func choicesAreCappedLeastRecentFirst() async throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(HistoryStore.maxChoices + 5) {
            try await history.recordChoice(query: "q\(i)", url: url("https://p\(i).example/"), profileID: profileID,
                                           at: start.addingTimeInterval(Double(i)))
        }
        let (count, oldest) = try await store.database.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM commandChoice") ?? 0,
             try String.fetchOne(db, sql: "SELECT query FROM commandChoice ORDER BY lastChosenAt LIMIT 1"))
        }
        #expect(count == HistoryStore.maxChoices)
        #expect(oldest == "q5", "The five least recently used went")
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
        // CI's hosted iOS simulator runs far slower than any device or Mac (a limit of that
        // virtual machine, set through TEST_RUNNER_AXO_HOSTED_RUNNER), so there the searches run
        // and their times print, but the ceilings aren't held; on Macs, CI's included, they are.
        #if targetEnvironment(simulator)
        let checksCeilings = ProcessInfo.processInfo.environment["AXO_HOSTED_RUNNER"] != "1"
        #else
        let checksCeilings = true
        #endif
        if checksCeilings {
            #expect(median < .milliseconds(50))
            #expect(worst < .milliseconds(250))
        }
    }
}
