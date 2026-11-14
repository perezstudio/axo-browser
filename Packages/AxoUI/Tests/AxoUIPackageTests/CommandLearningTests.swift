import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// What the command bar learns from choices (#121), on a fake engine so nothing reaches the
/// network: pages "commit" through the pool's `onPageChange`, as an engine reports them.
@MainActor
struct CommandLearningTests {
    let model: BrowserModel
    var store: TabStore { model.store }

    init() async throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    private var profileID: Profile.ID { model.space!.profileID }

    private func choices(for query: String) async throws -> [String] {
        try await store.database.writer.read { [profileID] db in
            try String.fetchAll(db, sql: "SELECT url FROM commandChoice WHERE profileID = ? AND query = ?", arguments: [profileID, query])
        }
    }

    /// Types `text` in the command bar and runs the address row it offers first.
    private func type(_ text: String) async throws -> AxoCore.Tab.ID {
        model.showCommandBar()
        model.setCommandQuery(text)
        guard case .open = model.commandResults.first else {
            Issue.record("The typed text comes first")
            throw CancellationError()
        }
        await model.runCommand(at: 0)
        return try #require(model.selectedTabID)
    }

    @Test func choosingAHistoryPageIsLearnedAndClearingHistoryForgetsIt() async throws {
        let mail = URL(string: "https://mail.example/")!
        try await store.history.recordVisit(to: mail, title: "Mail", profileID: profileID)
        model.showCommandBar()
        model.setCommandQuery("mai")
        try await waitUntil { model.commandResults.contains { if case .history = $0 { true } else { false } } }
        let index = try #require(model.commandResults.firstIndex { if case .history = $0 { true } else { false } })
        await model.runCommand(at: index)
        try await waitUntilAsync { try await choices(for: "mai") == [mail.absoluteString] }

        try await store.history.clear(profileID: profileID)
        #expect(try await choices(for: "mai").isEmpty)
    }

    /// `typed.example` commits as `https://typed.example/`: that page counts as typed and as the
    /// query's choice, with no second row for the address as typed.
    @Test func aTypedAddressIsLearnedForThePageItCommits() async throws {
        let tabID = try await type("typed.example")
        let committed = URL(string: "https://typed.example/")!
        model.pool.onPageChange?(tabID, committed, "Typed")
        try await waitUntilAsync { try await choices(for: "typed.example") == [committed.absoluteString] }
        let rows = try await store.history.recent(profileID: profileID, limit: 20).filter { $0.url.host() == "typed.example" }
        #expect(rows.count == 1, "One row: the page that loaded")
        #expect(rows.first?.url == committed && rows.first?.typedCount == 1 && rows.first?.visitCount == 1)
    }

    /// An address that never loads (it lands elsewhere) teaches nothing, and the tab's next page
    /// isn't counted as typed either.
    @Test func anAddressThatLandsOnAnotherSiteIsntLearned() async throws {
        let tabID = try await type("nowhere.example")
        model.pool.onPageChange?(tabID, URL(string: "https://elsewhere.example/")!, "Elsewhere")
        try await waitUntilAsync { try await !store.history.recent(profileID: profileID).isEmpty }
        model.pool.onPageChange?(tabID, URL(string: "https://nowhere.example/")!, "Later")
        try await waitUntilAsync { try await store.history.recent(profileID: profileID).count == 2 }
        #expect(try await store.history.recent(profileID: profileID).allSatisfy { $0.typedCount == 0 })
        #expect(try await choices(for: "nowhere.example").isEmpty)
    }

    /// A search the command bar took for an address because it has a dot teaches nothing.
    @Test func aSearchWithADotIsntLearned() async throws {
        model.showCommandBar()
        model.setCommandQuery("node.js tutorial")
        guard case .open(let url, _, _) = model.commandResults.first else { Issue.record("A search row comes first"); return }
        #expect(SearchEngine.isResultsPage(url))
        await model.runCommand(at: 0)
        let tabID = try #require(model.selectedTabID)
        model.pool.onPageChange?(tabID, url, "node.js tutorial - Search")
        try await waitUntilAsync { try await !store.history.recent(profileID: profileID).isEmpty }
        #expect(try await store.history.recent(profileID: profileID).allSatisfy { $0.typedCount == 0 })
        #expect(try await choices(for: "node.js tutorial").isEmpty)
    }
}
