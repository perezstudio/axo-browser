import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// How typed text becomes a search (#132): the profile's engine, keywords, and recognizing any
/// engine's results page.
@MainActor
struct SearchContextTests {
    let kagi = SearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s", keyword: "k", sortKey: "a3")

    @Test func aFreshInstallSearchesWithGoogle() {
        #expect(AddressInput.url(from: "axolotl")?.absoluteString == "https://www.google.com/search?q=axolotl")
    }

    @Test func searchesUseTheContextsEngine() {
        let search = SearchContext(engine: kagi, engines: SearchEngine.builtIns + [kagi])
        let resolved = AddressInput.resolve("axolotl facts", search: search)
        #expect(resolved?.url.absoluteString == "https://kagi.com/search?q=axolotl%20facts")
        #expect(resolved?.isSearch == true)
        #expect(AddressInput.resolve("example.com", search: search)?.isSearch == false, "Addresses still load")
    }

    @Test func aKeywordSearchesWithItsEngineWhateverTheDefault() {
        var duckDuckGo = SearchEngine.duckDuckGo
        duckDuckGo.keyword = "d"
        let search = SearchContext(engine: .google, engines: [.google, .bing, duckDuckGo, kagi])
        #expect(AddressInput.url(from: "k axolotls", search: search)?.absoluteString == "https://kagi.com/search?q=axolotls")
        #expect(AddressInput.url(from: "d example.com", search: search)?.absoluteString == "https://duckduckgo.com/?q=example.com",
                "Even text that looks like an address")
        #expect(search.searchURL(for: "b news").host() == "www.google.com", "Bing has no keyword")
        #expect(AddressInput.url(from: "b 52 bomber")?.absoluteString == "https://www.google.com/search?q=b%2052%20bomber",
                "A fresh install has no keywords to take over everyday text")
    }

    @Test func theSearchRowNamesTheEngine() {
        let row = CommandResult.open(SearchEngine.bing.searchURL(for: "pond life"), isSearch: true, text: "b pond life")
        #expect(row.title == "Search Bing for “pond life”")
    }

    @Test func theCommandBarMarksSearchesFromAnyEngine() {
        let search = SearchContext(engine: kagi, engines: SearchEngine.builtIns + [kagi])
        let results = CommandRanking.immediateResults(for: "pond life", tabs: [], availableActions: [], search: search)
        guard case .open(let url, let isSearch, _) = results.first else { Issue.record("A search row comes first"); return }
        #expect(isSearch)
        #expect(url.host() == "kagi.com")
        let address = CommandRanking.immediateResults(for: "kagi.com", tabs: [], availableActions: [], search: search)
        guard case .open(_, let addressIsSearch, _) = address.first else { Issue.record("An address row comes first"); return }
        #expect(!addressIsSearch)
    }

    @Test func resultsPagesOfAnyVisibleEngineAreRecognized() {
        var hiddenBing = SearchEngine.bing
        hiddenBing.isHidden = true
        let search = SearchContext(engine: .google, engines: [.google, hiddenBing, kagi])
        #expect(search.isResultsPage(kagi.searchURL(for: "node.js")))
        #expect(!search.isResultsPage(SearchEngine.bing.searchURL(for: "node.js")), "Not a removed engine's")
        #expect(!search.isResultsPage(URL(string: "https://example.com/search?q=pond")!))
    }

    @Test func theAddressBarShowsTheTermsOfACustomEnginesResults() {
        let url = kagi.searchURL(for: "axolotl facts")
        #expect(AddressDisplay.searchTerms(in: url, engines: [kagi]) == "axolotl facts")
        #expect(AddressDisplay.searchTerms(in: kagi.searchURL(for: "paypal.com"), engines: [kagi]) == nil,
                "Terms that look like an address show the site instead")
    }
}

/// The model: each Space searches with its profile's engine.
@MainActor
struct SearchEngineModelTests {
    let model: BrowserModel
    let store: TabStore

    init() async throws {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theShownSpaceSearchesWithItsProfilesEngine() async throws {
        let profileID = try #require(model.space?.profileID)
        #expect(model.searchContext.engine.id == SearchEngine.google.id)
        await model.setSearchEngine(.duckDuckGo, forProfile: profileID)
        await waitUntil { model.searchContext.engine.id == SearchEngine.duckDuckGo.id }
        #expect(model.searchContext.engine.id == SearchEngine.duckDuckGo.id)

        await model.submitAddress("axolotl")
        let tabID = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: tabID) as? FakePage)
        #expect(page.loads.last?.host() == "duckduckgo.com")
    }

    @Test func aNewEngineCanBeAddedAndAProblemIsReported() async throws {
        let problem = await model.addSearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search", suggestionsTemplate: nil, keyword: nil)
        #expect(problem == .missingQuery)
        #expect(await model.addSearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s", suggestionsTemplate: nil, keyword: "k") == nil)
        await waitUntil { model.searchEngines.contains { $0.name == "Kagi" } }
        #expect(model.searchEngines.map(\.name) == ["Google", "Bing", "DuckDuckGo", "Kagi"])
    }

    @Test func removingTheProfilesEngineGoesBackToGoogle() async throws {
        let profileID = try #require(model.space?.profileID)
        _ = await model.addSearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s", suggestionsTemplate: nil, keyword: nil)
        await waitUntil { model.searchEngines.contains { $0.name == "Kagi" } }
        let kagi = try #require(model.searchEngines.first { $0.name == "Kagi" })
        await model.setSearchEngine(kagi, forProfile: profileID)
        await waitUntil { model.searchContext.engine.id == kagi.id }
        #expect(model.profiles(searchingWith: kagi).map(\.id) == [profileID])

        await model.removeSearchEngine(kagi)
        await waitUntil { model.searchContext.engine.id == SearchEngine.google.id }
        #expect(model.searchContext.engine.id == SearchEngine.google.id)
        #expect(model.profiles(searchingWith: .google).map(\.id) == [profileID])
    }
}
