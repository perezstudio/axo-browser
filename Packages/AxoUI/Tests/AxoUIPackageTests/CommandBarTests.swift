import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct CommandBarTests {
    let store: TabStore
    let pool: WebViewPool
    let model: BrowserModel
    let directory: URL

    init() async throws {
        store = try TabStore.makeInMemory()
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        model = BrowserModel(store: store, pool: pool)
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoCommandTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
    }

    private func page(_ name: String) throws -> URL {
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var profileID: Profile.ID { model.space!.profileID }

    // MARK: Ranking

    @Test func typedTextComesFirstAsAPageOrASearch() {
        let tab = AxoCore.Tab(spaceID: UUID(), url: URL(string: "https://swift.org")!, title: "Swift", sortKey: "a0")

        let address = CommandRanking.immediateResults(for: "swift.org", tabs: [tab], availableActions: [])
        guard case .open(let url, let isSearch, _) = address.first else { Issue.record("Expected an open row"); return }
        #expect(url.absoluteString == "https://swift.org" && !isSearch)

        let search = CommandRanking.immediateResults(for: "swift", tabs: [tab], availableActions: [])
        guard case .open(_, let searching, _) = search.first else { Issue.record("Expected a search row"); return }
        #expect(searching)
        #expect(search.contains(.tab(tab)), "Matching tabs follow")
    }

    @Test func everyWordMustMatchAndCaseIsIgnored() {
        #expect(CommandRanking.matches("swift DOCS", in: "The Swift Docs"))
        #expect(!CommandRanking.matches("swift python", in: "The Swift Docs"))
        #expect(!CommandRanking.matches("  ", in: "anything"))
    }

    @Test func historyAlreadyOpenAsATabIsLeftOut() {
        let url = URL(string: "https://swift.org")!
        let tab = AxoCore.Tab(spaceID: UUID(), url: url, sortKey: "a0")
        let open = HistoryItem(profileID: UUID(), url: url, title: "Swift", visitCount: 1, lastVisitedAt: Date())
        let other = HistoryItem(profileID: UUID(), url: URL(string: "https://example.com")!, title: "Example", visitCount: 1, lastVisitedAt: Date())

        #expect(CommandRanking.historyResults([open, other], excludingOpen: [tab]) == [.history(other)])
    }

    // MARK: Model

    @Test func emptyQueryListsOpenTabs() async throws {
        await model.openTab(url: try page("one"))
        model.showCommandBar()
        #expect(model.commandResults.count == 1)
        guard case .tab = model.commandResults.first else { Issue.record("Expected a tab row"); return }
    }

    @Test func runningATabRowSwitchesToIt() async throws {
        await model.openTab(url: try page("alpha"))
        let alpha = try #require(model.selectedTabID)
        await model.openTab(url: try page("beta"))

        model.showCommandBar()
        model.setCommandQuery("alpha")
        let index = try #require(model.commandResults.firstIndex { if case .tab = $0 { true } else { false } })
        await model.runCommand(at: index)

        #expect(model.selectedTabID == alpha)
        #expect(model.tabs.count == 2, "Switching doesn't open a new tab")
    }

    @Test func runningAnActionRow() async throws {
        await model.openTab(url: try page("one"))
        model.showCommandBar()
        model.setCommandQuery("pin")
        let index = try #require(model.commandResults.firstIndex(of: .action(.pinTab)))
        await model.runCommand(at: index)
        #expect(model.pinnedTabs.count == 1)
        #expect(!model.availableActions.contains(.pinTab))
        #expect(model.availableActions.contains(.unpinTab))
    }

    @Test func selectionStaysWithinResults() async throws {
        model.showCommandBar()
        model.setCommandQuery("new")
        let count = model.commandResults.count
        #expect(count > 1)
        model.moveCommandSelection(by: -1)
        #expect(model.commandSelection == 0)
        model.moveCommandSelection(by: 100)
        #expect(model.commandSelection == count - 1)
    }

    @Test func reopeningTheBarStartsFresh() async throws {
        await model.openTab(url: try page("one"))
        model.showCommandBar()
        model.setCommandQuery("zzz-no-match")
        model.hideCommandBar()
        await model.openTab(url: try page("two"))

        model.showCommandBar()
        #expect(model.commandQuery.isEmpty)
        #expect(model.commandResults.count == 2, "Both open tabs are listed")
        #expect(model.commandSelection == 0)
    }

    @Test func resettingTheSameQueryKeepsTheHighlight() async throws {
        // On Return, a text field commits its value again; that must not move the highlight.
        model.showCommandBar()
        model.setCommandQuery("new")
        model.moveCommandSelection(by: 1)
        model.setCommandQuery("new")
        #expect(model.commandSelection == 1)
    }

    @Test func historyAppearsAfterTheImmediateRowsAndOpensInANewTab() async throws {
        try await store.history.recordVisit(to: URL(string: "https://webkit.org/blog")!, title: "WebKit Blog", profileID: profileID)
        model.showCommandBar()
        model.setCommandQuery("webkit blog")
        try await waitUntil { model.commandResults.contains { if case .history = $0 { true } else { false } } }
        guard case .open = model.commandResults.first else { Issue.record("Typed text stays first"); return }

        let index = try #require(model.commandResults.firstIndex { if case .history = $0 { true } else { false } })
        await model.runCommand(at: index)
        #expect(model.tabs.last?.url == URL(string: "https://webkit.org/blog")!)
    }

    @Test func pageChangesAreRecordedAsVisitsAndTitles() async throws {
        await model.openTab(url: try page("start"))
        let tabID = try #require(model.selectedTabID)
        let article = URL(string: "https://example.com/article")!

        pool.onPageChange?(tabID, article, "")
        pool.onPageChange?(tabID, article, "An Article")
        try await waitUntilAsync {
            try await store.history.recent(profileID: profileID).first?.title == "An Article"
        }
        let item = try #require(try await store.history.recent(profileID: profileID).first)
        #expect(item.visitCount == 1, "A title update isn't another visit")
    }
}
