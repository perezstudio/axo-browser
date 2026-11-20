import AxoCore
import Foundation
import Synchronization

/// How text people type becomes a search (#132): the engine of the shown Space's profile, and
/// every engine's keyword ("k axolotls" searches with the engine whose keyword is `k`).
nonisolated public struct SearchContext: Hashable, Sendable {
    /// The engine plain searches use.
    public var engine: SearchEngine
    /// Every engine, for keywords and for recognizing results pages.
    public var engines: [SearchEngine]

    /// A context.
    public init(engine: SearchEngine, engines: [SearchEngine]) {
        self.engine = engine
        self.engines = engines
    }

    /// Google, with the built-in engines' keywords: before the database's engines are read, and
    /// in tests that don't care.
    public static let `default` = SearchContext(engine: .default, engines: SearchEngine.builtIns)

    /// The results page for `query`, with a keyword's engine when it starts with one.
    public func searchURL(for text: String) -> URL {
        if let keyword = SearchEngine.keywordSearch(in: text, engines: engines) {
            return keyword.engine.searchURL(for: keyword.query)
        }
        return engine.searchURL(for: text)
    }

    /// Whether `url` is any visible engine's results page.
    public func isResultsPage(_ url: URL) -> Bool {
        engines.contains { !$0.isHidden && $0.searchTerms(in: url) != nil }
    }
}

/// The engines the browser knows, for code that formats addresses without a model at hand (the
/// address bar's text, ``AddressDisplay``). ``BrowserModel`` keeps it current; it's only ever
/// read to recognize a results page, so a moment's lag between windows is harmless.
nonisolated enum KnownSearchEngines {
    private static let storage = Mutex<[SearchEngine]>(SearchEngine.builtIns)

    /// Every visible engine.
    static var all: [SearchEngine] {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue.filter { !$0.isHidden } } }
    }
}
