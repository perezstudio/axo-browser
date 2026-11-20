import AxoPersistence
import Foundation
import GRDB
import Testing
@testable import AxoCore

/// Search engines (#132): templates, keywords, checking what people type, and each profile's
/// engine with Google to fall back on.
struct SearchEngineTests {
    @Test func googleIsTheDefaultWithBingAndDuckDuckGoOffered() {
        #expect(SearchEngine.default == .google)
        #expect(SearchEngine.builtIns.map(\.name) == ["Google", "Bing", "DuckDuckGo"])
        #expect(SearchEngine.builtIns.allSatisfy { SortKey.isValid($0.sortKey) })
        #expect(!SearchEngine.google.isRemovable)
        #expect(SearchEngine.bing.isRemovable)
        #expect(SearchEngine.builtIns.allSatisfy { $0.keyword == nil }, "No one-letter keywords taking over \"b 52 bomber\"")
    }

    @Test(arguments: [
        (SearchEngine.google, "https://www.google.com/search?q=axolotl%20facts"),
        (SearchEngine.bing, "https://www.bing.com/search?q=axolotl%20facts"),
        (SearchEngine.duckDuckGo, "https://duckduckgo.com/?q=axolotl%20facts"),
    ])
    func eachEngineSearchesItsResultsPage(engine: SearchEngine, expected: String) {
        #expect(engine.searchURL(for: "axolotl facts").absoluteString == expected)
    }

    @Test func queriesAreEncodedSoTheyStayOneQuery() throws {
        let url = SearchEngine.google.searchURL(for: "a&b=c #1 +2 50%")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "q", value: "a&b=c #1 +2 50%")])
        #expect(url.fragment == nil)
    }

    @Test func aTemplateCanPutTheQueryAnywhere() {
        let wiki = SearchEngine(name: "Wikipedia", urlTemplate: "https://en.wikipedia.org/w/index.php?search=%s&ns0=1", sortKey: "a3")
        #expect(wiki.searchURL(for: "axolotl").absoluteString == "https://en.wikipedia.org/w/index.php?search=axolotl&ns0=1")
        #expect(wiki.searchTerms(in: wiki.searchURL(for: "pond life")) == "pond life")
        let path = SearchEngine(name: "Docs", urlTemplate: "https://docs.example.com/search/%s", sortKey: "a4")
        #expect(path.searchURL(for: "a b").absoluteString == "https://docs.example.com/search/a%20b")
    }

    @Test func suggestionsUseTheirOwnTemplate() {
        #expect(SearchEngine.duckDuckGo.suggestionsURL(for: "axo")?.absoluteString == "https://duckduckgo.com/ac/?q=axo&type=list")
        #expect(SearchEngine(name: "None", urlTemplate: "https://x.example/?q=%s", sortKey: "a3").suggestionsURL(for: "axo") == nil)
    }

    @Test func resultsPagesAreRecognizedButOtherPagesAreNot() {
        for engine in SearchEngine.builtIns {
            #expect(engine.searchTerms(in: engine.searchURL(for: "node.js tutorial")) == "node.js tutorial", "\(engine.name)")
        }
        #expect(SearchEngine.duckDuckGo.searchTerms(in: URL(string: "https://duckduckgo.com/")!) == nil, "A home page has no query")
        #expect(SearchEngine.google.searchTerms(in: URL(string: "https://www.google.com/maps?q=pond")!) == nil)
        #expect(SearchEngine.google.searchTerms(in: URL(string: "https://example.com/search?q=pond")!) == nil)
    }

    @Test(arguments: [
        ("", "https://kagi.com/search?q=%s", nil as String?, nil as String?, SearchEngine.Problem.missingName),
        ("Kagi", "kagi.com/search?q=%s", nil, nil, .notWebAddress),
        ("Kagi", "javascript:alert(%s)", nil, nil, .notWebAddress),
        ("Kagi", "file:///tmp/%s", nil, nil, .notWebAddress),
        ("Kagi", "https://kagi.com/search", nil, nil, .missingQuery),
        ("Kagi", "https://kagi.com/search?q=%s", "ftp://kagi.com/%s", nil, .badSuggestionsAddress),
        ("Kagi", "https://kagi.com/search?q=%s", "https://kagi.com/suggest", nil, .badSuggestionsAddress),
        ("Kagi", "https://kagi.com/search?q=%s", nil, "k i", .keywordHasSpaces),
        ("Kagi", "https://%s/", nil, nil, .notWebAddress),
        ("Kagi", "https://%s.example.com/search", nil, nil, .notWebAddress),
        ("Kagi", "https://kagi.com/search?q=%s", "https://%s.kagi.com/", nil, .badSuggestionsAddress),
    ])
    func fieldsAreChecked(name: String, url: String, suggestions: String?, keyword: String?, problem: SearchEngine.Problem) {
        #expect(SearchEngine.problem(name: name, urlTemplate: url, suggestionsTemplate: suggestions, keyword: keyword,
                                     others: SearchEngine.builtIns) == problem)
    }

    @Test func aKeywordAnotherEngineUsesIsRefused() {
        var google = SearchEngine.google
        google.keyword = "g"
        #expect(SearchEngine.problem(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s", suggestionsTemplate: nil,
                                     keyword: "G", others: [google]) == .keywordInUse("Google"))
    }

    @Test func termsFromAnEnginesOwnSearchBoxReadAsTyped() {
        #expect(SearchEngine.google.searchTerms(in: URL(string: "https://www.google.com/search?q=axolotl+facts")!) == "axolotl facts")
        #expect(SearchEngine.google.searchTerms(in: URL(string: "https://www.google.com/search?q=1%2B1")!) == "1+1",
                "A typed plus stays a plus")
        #expect(SearchEngine.google.searchTerms(in: SearchEngine.google.searchURL(for: "c++ & rust")) == "c++ & rust")
        #expect(SearchEngine.google.searchTerms(in: URL(string: "http://www.google.com/search?q=axolotl")!) == nil,
                "Plain http isn't the engine's page")
    }

    @Test func goodFieldsPass() {
        #expect(SearchEngine.problem(name: "Kagi", urlTemplate: " https://kagi.com/search?q=%s ",
                                     suggestionsTemplate: "https://kagi.com/api/autosuggest?q=%s", keyword: "k",
                                     others: SearchEngine.builtIns) == nil)
    }

    @Test func aKeywordAndASpaceSearchWithThatEngine() throws {
        let kagi = SearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s", keyword: "k", sortKey: "a3")
        let engines = SearchEngine.builtIns + [kagi]
        let found = try #require(SearchEngine.keywordSearch(in: "K  axolotls in ponds ", engines: engines))
        #expect(found.engine.id == kagi.id)
        #expect(found.query == "axolotls in ponds")
        #expect(SearchEngine.keywordSearch(in: "k", engines: engines) == nil, "No query yet")
        #expect(SearchEngine.keywordSearch(in: "k ", engines: engines) == nil)
        #expect(SearchEngine.keywordSearch(in: "kayak trips", engines: engines) == nil, "The whole first word")
        var hidden = SearchEngine.bing
        hidden.isHidden = true
        #expect(SearchEngine.keywordSearch(in: "b news", engines: [hidden]) == nil, "A removed engine's keyword stops working")
    }

    @Test func aProfileSearchesWithItsChoiceOrGoogle() {
        let kagi = SearchEngine(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s", sortKey: "a3")
        let engines = SearchEngine.builtIns + [kagi]
        #expect(SearchEngine.engine(for: Profile(name: "Work", searchEngineID: kagi.id), in: engines).id == kagi.id)
        #expect(SearchEngine.engine(for: Profile(name: "Home"), in: engines).id == SearchEngine.google.id)
        #expect(SearchEngine.engine(for: Profile(name: "Old", searchEngineID: UUID()), in: engines).id == SearchEngine.google.id,
                "An engine that's gone (or hasn't synced yet) means Google")
        var hiddenBing = SearchEngine.bing
        hiddenBing.isHidden = true
        #expect(SearchEngine.engine(for: Profile(name: "B", searchEngineID: hiddenBing.id), in: [hiddenBing]).id == SearchEngine.google.id)
        #expect(SearchEngine.engine(for: nil, in: engines).id == SearchEngine.google.id)
    }
}

/// The store: adding, changing, removing, and restoring engines, and each profile's choice.
struct SearchEngineStoreTests {
    let store: TabStore
    let engines: SearchEngineStore
    let profileID: Profile.ID

    init() async throws {
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
        engines = store.searchEngines
    }

    private func profile() async throws -> Profile {
        try #require(try await store.profiles().first { $0.id == profileID })
    }

    @Test func aFreshDatabaseHasTheBuiltInEngines() async throws {
        #expect(try await engines.engines().map(\.name) == ["Google", "Bing", "DuckDuckGo"])
        #expect(try await profile().searchEngineID == nil, "Searching with Google")
    }

    @Test func customEnginesAreAddedAtTheEndAndChecked() async throws {
        let kagi = try await engines.add(name: " Kagi ", urlTemplate: "https://kagi.com/search?q=%s", suggestionsTemplate: "", keyword: "k")
        #expect(kagi.name == "Kagi")
        #expect(kagi.suggestionsTemplate == nil)
        #expect(try await engines.engines().map(\.name) == ["Google", "Bing", "DuckDuckGo", "Kagi"])
        await #expect(throws: SearchEngineStoreError.invalid(.keywordInUse("Kagi"))) {
            try await engines.add(name: "Kayak", urlTemplate: "https://kayak.com/?q=%s", keyword: "K")
        }
        await #expect(throws: SearchEngineStoreError.invalid(.missingQuery)) {
            try await engines.add(name: "Broken", urlTemplate: "https://example.com/")
        }
    }

    @Test func aBuiltInEngineKeepsItsNameAndAddressesWhenEdited() async throws {
        var google = SearchEngine.google
        google.name = "Evil"
        google.urlTemplate = "https://evil.example/?q=%s"
        google.keyword = "goo"
        try await engines.update(google)
        let saved = try #require(try await engines.engines().first { $0.id == SearchEngine.google.id })
        #expect(saved.name == "Google")
        #expect(saved.urlTemplate == SearchEngine.google.urlTemplate)
        #expect(saved.keyword == "goo")
    }

    @Test func aCustomEngineCanBeEdited() async throws {
        var kagi = try await engines.add(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s")
        kagi.urlTemplate = "https://kagi.com/html/search?q=%s"
        kagi.keyword = " k "
        try await engines.update(kagi)
        let saved = try #require(try await engines.engines().first { $0.id == kagi.id })
        #expect(saved.urlTemplate == "https://kagi.com/html/search?q=%s")
        #expect(saved.keyword == "k")
        kagi.urlTemplate = "nope"
        await #expect(throws: SearchEngineStoreError.invalid(.notWebAddress)) { try await engines.update(kagi) }
    }

    @Test func removingAnEngineInUseMovesItsProfilesToGoogle() async throws {
        let kagi = try await engines.add(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s")
        try await engines.setEngine(kagi.id, forProfile: profileID)
        #expect(try await profile().searchEngineID == kagi.id)
        try await engines.remove(id: kagi.id)
        #expect(try await profile().searchEngineID == nil)
        #expect(try await !engines.engines().contains { $0.id == kagi.id }, "A custom engine is deleted")
    }

    @Test func removingABuiltInEngineHidesItUntilRestored() async throws {
        try await engines.setEngine(SearchEngine.bing.id, forProfile: profileID)
        try await engines.remove(id: SearchEngine.bing.id)
        #expect(try await engines.engines().first { $0.id == SearchEngine.bing.id }?.isHidden == true)
        #expect(try await profile().searchEngineID == nil)
        await #expect(throws: SearchEngineStoreError.notFound(SearchEngine.bing.id)) {
            try await engines.setEngine(SearchEngine.bing.id, forProfile: profileID)
        }
        try await engines.restoreBuiltIns()
        #expect(try await engines.engines().first { $0.id == SearchEngine.bing.id }?.isHidden == false)
    }

    @Test func restoringAnEngineLeavesATakenKeywordWithItsNewOwner() async throws {
        var bing = SearchEngine.bing
        bing.keyword = "b"
        try await engines.update(bing)
        try await engines.remove(id: SearchEngine.bing.id)
        let books = try await engines.add(name: "Books", urlTemplate: "https://books.example/?q=%s", keyword: "b")
        try await engines.restoreBuiltIns()
        let all = try await engines.engines()
        #expect(all.first { $0.id == SearchEngine.bing.id }?.keyword == nil)
        #expect(all.first { $0.id == books.id }?.keyword == "b")
    }

    @Test func twoEnginesSyncedWithOneKeywordLeaveItWithTheFirst() async throws {
        try await store.database.writer.write { db in
            let insert = "INSERT INTO searchEngine (id, name, urlTemplate, keyword, sortKey) VALUES (?, ?, 'https://x.example/?q=%s', 'x', ?)"
            try db.execute(sql: insert, arguments: [UUID(), "First", "a5"])
            try db.execute(sql: insert, arguments: [UUID(), "Second", "a6"])
        }
        let all = try await engines.engines()
        #expect(all.first { $0.name == "First" }?.keyword == "x")
        #expect(all.first { $0.name == "Second" }?.keyword == nil)
    }

    @Test func googleCantBeRemoved() async throws {
        await #expect(throws: SearchEngineStoreError.notRemovable) { try await engines.remove(id: SearchEngine.google.id) }
    }

    @Test func choosingGoogleStoresNothing() async throws {
        try await engines.setEngine(SearchEngine.duckDuckGo.id, forProfile: profileID)
        try await engines.setEngine(SearchEngine.google.id, forProfile: profileID)
        #expect(try await profile().searchEngineID == nil)
    }

    @Test func aProfileCanTurnSuggestionsOff() async throws {
        try await engines.setShowsSuggestions(false, forProfile: profileID)
        #expect(try await profile().showsSearchSuggestions == false)
    }

    @Test func aSyncedEngineThatIsntAWebAddressIsLeftOut() async throws {
        try await store.database.writer.write { db in
            try db.execute(sql: "INSERT INTO searchEngine (id, name, urlTemplate, sortKey) VALUES (?, 'Bad', 'javascript:alert(%s)', 'a5')",
                           arguments: [UUID()])
        }
        #expect(try await !engines.engines().contains { $0.name == "Bad" })
    }
}
