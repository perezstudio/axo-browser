import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Search suggestions (#132): when they're asked for, reading OpenSearch answers, and the command
/// bar showing them below Axo's own results.
struct SearchSuggestionParsingTests {
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    @Test func openSearchAnswersAreRead() throws {
        let data = try json(["pond", ["pond life", "Pond", "pond plants", "pond life", "pond fish", "pond pumps", "pond liners"]])
        #expect(SearchSuggestions.parse(data, query: "pond") == ["pond life", "pond plants", "pond fish", "pond pumps"],
                "At most four, no repeats, never the query itself")
    }

    @Test func otherAnswersReadAsNone() throws {
        #expect(SearchSuggestions.parse(Data("not json".utf8), query: "a").isEmpty)
        #expect(SearchSuggestions.parse(try json(["a"]), query: "a").isEmpty)
        #expect(SearchSuggestions.parse(try json(["a": ["b"]]), query: "a").isEmpty)
        #expect(SearchSuggestions.parse(try json(["a", [1, 2]]), query: "a").isEmpty)
        #expect(SearchSuggestions.parse(try json(["a", ["line\u{2028}break", "a\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}", "ok"]]), query: "a") == ["ok"],
                "No separators or piles of combining marks")
        let huge = try json(["a", [String(repeating: "x", count: SearchSuggestions.maximumResponseSize)]])
        #expect(SearchSuggestions.parse(huge, query: "a").isEmpty, "Too large")
    }

    @Test func suggestionsCantHideWhatTheySay() throws {
        let data = try json(["pay", ["paypal\u{202E}moc.live", "pay\u{0007}bell", "pay bills"]])
        #expect(SearchSuggestions.parse(data, query: "pay") == ["pay bills"])
    }

    @Test(arguments: ["", "   ", "example.com", "https://example.com/a b", "localhost:3000", "data:text/html,hi"])
    func addressesAndEmptyTextSendNothing(text: String) {
        #expect(SearchSuggestions.request(for: text, search: .default) == nil)
    }

    @Test func longTextSendsNothing() {
        let long = String(repeating: "word ", count: 50)
        #expect(SearchSuggestions.request(for: long, search: .default) == nil)
    }

    @Test func aSearchAsksItsEngineOrAKeywordsEngine() throws {
        var kagi = SearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s",
                                suggestionsTemplate: "https://kagi.com/api/autosuggest?q=%s", keyword: "k", sortKey: "a3")
        let search = SearchContext(engine: .duckDuckGo, engines: SearchEngine.builtIns + [kagi])
        let plain = try #require(SearchSuggestions.request(for: "pond life", search: search))
        #expect(plain.url.absoluteString == "https://duckduckgo.com/ac/?q=pond%20life&type=list")
        let keyword = try #require(SearchSuggestions.request(for: "k pond", search: search))
        #expect(keyword.engine.id == kagi.id)
        #expect(keyword.query == "pond")
        kagi.suggestionsTemplate = nil
        #expect(SearchSuggestions.request(for: "k pond", search: SearchContext(engine: .google, engines: [kagi])) == nil,
                "An engine without suggestions is never asked")
    }
}

/// The command bar asking for suggestions as you type.
@MainActor
struct SearchSuggestionModelTests {
    /// Records requests and answers like an engine.
    final class FakeSuggester: SearchSuggesting, @unchecked Sendable {
        // @unchecked: touched only on the main actor, where the tests and the model run.
        var urls: [URL] = []
        /// When set, answers wait until the test resumes them.
        var holdsAnswers = false
        var heldAnswers: [CheckedContinuation<Void, Never>] = []
        func suggestionsData(from url: URL) async throws -> Data {
            urls.append(url)
            if holdsAnswers { await withCheckedContinuation { heldAnswers.append($0) } }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            return try JSONSerialization.data(withJSONObject: [query, ["\(query) life", "\(query) plants"]])
        }
    }

    /// Holds each debounce until the test lets it go.
    @MainActor final class Pauses {
        var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async { await withCheckedContinuation { waiting.append($0) } }
        /// Lets the waiting pause go, once one is waiting (the request starts on a later turn).
        func release() async {
            for _ in 0..<200 where waiting.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
            for _ in 0..<20 { await Task.yield() }
        }
    }

    let model: BrowserModel
    let suggester = FakeSuggester()
    let pauses = Pauses()

    init() async throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        model.searchSuggester = suggester
        let pauses = pauses
        model.suggestionSleep = { _ in await pauses.wait() }
        await model.start()
    }

    private var suggestions: [String] {
        model.commandResults.compactMap { if case .suggestion(let text, _) = $0 { text } else { nil } }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func suggestionsComeBelowTheBarsOwnResults() async throws {
        model.showCommandBar()
        model.setCommandQuery("pond")
        #expect(suggester.urls.isEmpty, "Nothing goes out before the pause")
        await pauses.release()
        await waitUntil { !suggestions.isEmpty }
        #expect(suggestions == ["pond life", "pond plants"])
        guard case .open(_, true, _) = model.commandResults.first else { Issue.record("The typed search comes first"); return }
        let firstSuggestion = try #require(model.commandResults.firstIndex { if case .suggestion = $0 { true } else { false } })
        #expect(model.commandResults[firstSuggestion...].allSatisfy { if case .suggestion = $0 { true } else { false } },
                "Suggestions are last")
        #expect(suggester.urls.first?.host() == "suggestqueries.google.com", "The profile's engine (Google)")
    }

    @Test func eachKeystrokeCancelsTheLastRequest() async throws {
        model.showCommandBar()
        model.setCommandQuery("p")
        model.setCommandQuery("po")
        model.setCommandQuery("pond")
        await pauses.release()
        await waitUntil { !suggestions.isEmpty }
        #expect(suggester.urls.count == 1, "Only the last text was sent")
        #expect(suggestions == ["pond life", "pond plants"])
    }

    @Test func choosingASuggestionSearchesForIt() async throws {
        model.showCommandBar()
        model.setCommandQuery("pond")
        await pauses.release()
        await waitUntil { !suggestions.isEmpty }
        let index = try #require(model.commandResults.firstIndex { $0.title == "pond plants" })
        await model.runCommand(at: index)
        let tabID = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: tabID) as? FakePage)
        #expect(page.loads.last == SearchEngine.google.searchURL(for: "pond plants"))
    }

    @Test func addressesSendNothing() async throws {
        model.showCommandBar()
        model.setCommandQuery("example.com")
        #expect(model.searchSuggestionTask == nil, "No request was even scheduled")
        #expect(suggester.urls.isEmpty)
    }

    @Test func aProfileWithSuggestionsOffSendsNothing() async throws {
        let profileID = try #require(model.space?.profileID)
        await model.setShowsSearchSuggestions(false, forProfile: profileID)
        await waitUntil { model.allProfiles.first?.showsSearchSuggestions == false }
        model.showCommandBar()
        model.setCommandQuery("pond")
        #expect(model.searchSuggestionTask == nil)
        #expect(suggester.urls.isEmpty)
    }

    @Test func theProfilesEngineIsAsked() async throws {
        let profileID = try #require(model.space?.profileID)
        await model.setSearchEngine(.duckDuckGo, forProfile: profileID)
        await waitUntil { model.searchContext.engine.id == SearchEngine.duckDuckGo.id }
        model.showCommandBar()
        model.setCommandQuery("pond")
        await pauses.release()
        await waitUntil { !suggester.urls.isEmpty }
        #expect(suggester.urls.first?.host() == "duckduckgo.com")
    }

    @Test func closingTheBarDropsALateAnswer() async throws {
        model.showCommandBar()
        model.setCommandQuery("pond")
        model.hideCommandBar()
        await pauses.release()
        #expect(suggester.urls.isEmpty, "The request was cancelled with the bar")
    }

    @Test func withoutASuggesterNothingIsAsked() async throws {
        model.searchSuggester = nil
        model.showCommandBar()
        model.setCommandQuery("pond")
        #expect(model.searchSuggestionTask == nil)
    }

    @Test func nothingIsSentBeforeTheProfilesAreRead() async throws {
        model.allProfiles = [] // just after launch, or while the Space moves to another profile
        model.showCommandBar()
        model.setCommandQuery("pond")
        #expect(model.searchSuggestionTask == nil, "An unread switch counts as off")
    }

    @Test func aLateAnswerAfterTheBarClosesShowsNothing() async throws {
        suggester.holdsAnswers = true
        model.showCommandBar()
        model.setCommandQuery("pond")
        await pauses.release()
        await waitUntil { !suggester.heldAnswers.isEmpty }
        model.hideCommandBar()
        model.showCommandBar()
        model.setCommandQuery("pond")
        suggester.heldAnswers.removeFirst().resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(suggestions.isEmpty, "The first bar's answer doesn't reach the second")
    }

    @Test func anAnswerAfterTheSwitchTurnsOffShowsNothing() async throws {
        let profileID = try #require(model.space?.profileID)
        suggester.holdsAnswers = true
        model.showCommandBar()
        model.setCommandQuery("pond")
        await pauses.release()
        await waitUntil { !suggester.heldAnswers.isEmpty }
        await model.setShowsSearchSuggestions(false, forProfile: profileID)
        await waitUntil { model.allProfiles.first?.showsSearchSuggestions == false }
        suggester.heldAnswers.removeFirst().resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(suggestions.isEmpty)
    }

    @Test func historyArrivingAboveKeepsTheHighlightedRow() async throws {
        model.showCommandBar()
        model.setCommandQuery("pond")
        await pauses.release()
        await waitUntil { !suggestions.isEmpty }
        let index = try #require(model.commandResults.firstIndex { $0.title == "pond plants" })
        model.moveCommandSelection(by: index - model.commandSelection)
        let page = HistoryItem(profileID: try #require(model.space?.profileID), url: URL(string: "https://example.com/pond")!, title: "Pond", visitCount: 1, lastVisitedAt: .now)
        model.insertLocalCommandResults([.history(page)])
        #expect(model.commandResults[model.commandSelection].title == "pond plants")
    }

    @Test func aSuggestionChosenWhileEditingAnAddressLoadsInThatTab() async throws {
        await model.openTab(url: URL(string: "https://example.com/")!)
        let tabID = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: tabID) as? FakePage)
        model.editAddress()
        model.setCommandQuery("pond")
        await pauses.release()
        await waitUntil { !suggestions.isEmpty }
        let index = try #require(model.commandResults.firstIndex { $0.title == "pond life" })
        await model.runCommand(at: index)
        #expect(model.selectedTabID == tabID, "No new tab")
        #expect(page.loads.last == SearchEngine.google.searchURL(for: "pond life"))
    }
}
