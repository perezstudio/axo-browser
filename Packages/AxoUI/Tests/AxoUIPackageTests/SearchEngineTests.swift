import Foundation
import Testing
@testable import AxoUI

struct SearchEngineTests {
    @Test func googleIsTheDefault() {
        #expect(SearchEngine.default == .google)
        #expect(AddressInput.searchURL(for: "axolotl").absoluteString == "https://www.google.com/search?q=axolotl")
    }

    @Test func bingAndDuckDuckGoAreTheAlternatives() {
        #expect(SearchEngine.allCases == [.google, .bing, .duckDuckGo])
        #expect(SearchEngine.allCases.map(\.name) == ["Google", "Bing", "DuckDuckGo"])
    }

    @Test(arguments: [
        (SearchEngine.google, "https://www.google.com/search?q=axolotl%20facts"),
        (SearchEngine.bing, "https://www.bing.com/search?q=axolotl%20facts"),
        (SearchEngine.duckDuckGo, "https://duckduckgo.com/?q=axolotl%20facts"),
    ])
    func eachEngineSearchesItsResultsPage(engine: SearchEngine, expected: String) {
        #expect(engine.searchURL(for: "axolotl facts").absoluteString == expected)
    }

    @Test func queriesAreEncoded() throws {
        let url = SearchEngine.google.searchURL(for: "a&b=c #1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "q", value: "a&b=c #1")])
    }
}

/// Telling an engine's results page from other pages (#121).
struct SearchResultsPageTests {
    @Test func everyEnginesResultsPageIsRecognized() {
        for engine in SearchEngine.allCases {
            #expect(SearchEngine.isResultsPage(engine.searchURL(for: "node.js tutorial")), "\(engine)")
        }
    }

    @Test func otherPagesAreNot() {
        #expect(!SearchEngine.isResultsPage(URL(string: "https://duckduckgo.com/")!), "A home page has no query")
        #expect(!SearchEngine.isResultsPage(URL(string: "https://www.google.com/maps?q=pond")!))
        #expect(!SearchEngine.isResultsPage(URL(string: "https://example.com/search?q=pond")!))
    }
}
