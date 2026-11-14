import Foundation

/// The search engines Axo offers: Google by default, with Bing and DuckDuckGo as the alternatives
/// (decided in November 2026; see `docs/ui-plan.md`). Settings › Search (#132) lets each profile
/// choose among them; until then every search uses ``default``.
nonisolated public enum SearchEngine: String, CaseIterable, Sendable {
    case google
    case bing
    case duckDuckGo

    /// The engine searches use unless someone chooses another.
    public static let `default`: SearchEngine = .google

    /// The engine's name, as Settings shows it.
    public var name: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .duckDuckGo: "DuckDuckGo"
        }
    }

    /// The engine's results page, without a query. Searches add `q=` to it.
    public var resultsURL: URL {
        switch self {
        case .google: URL(string: "https://www.google.com/search")!
        case .bing: URL(string: "https://www.bing.com/search")!
        case .duckDuckGo: URL(string: "https://duckduckgo.com/")!
        }
    }

    /// Whether `url` is one of the engines' results pages for a query, such as a search the
    /// command bar made from text it took for an address ("node.js tutorial").
    public static func isResultsPage(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "q" }) == true else { return false }
        return allCases.contains { engine in
            engine.resultsURL.host() == url.host() && engine.resultsURL.path() == url.path()
        }
    }

    /// The results page for `query`.
    public func searchURL(for query: String) -> URL {
        var components = URLComponents(url: resultsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}
