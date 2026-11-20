import AxoPersistence
import Foundation
import GRDB

/// A search engine (#132): Google, Bing, and DuckDuckGo built in (Google is what a profile uses
/// until it picks another, decided in November 2026; see `docs/ui-plan.md`), and custom engines
/// people add with a search URL holding `%s` for what they type.
public struct SearchEngine: Hashable, Identifiable, Sendable {
    /// The engine's identifier. Built-in engines have fixed ones, the same on every device, so
    /// their changes sync.
    public var id: UUID
    /// The name Settings shows.
    public var name: String
    /// The results page, with `%s` where the query goes.
    public var urlTemplate: String
    /// The OpenSearch suggestions address, with `%s`, if the engine has one.
    public var suggestionsTemplate: String?
    /// Typed before a space in the command bar or address field ("k axolotls"), it searches
    /// with this engine. `nil` for none.
    public var keyword: String?
    /// A built-in engine someone removed, which Settings can bring back.
    public var isHidden: Bool
    /// The engine's place in Settings' list. See ``SortKey``.
    public var sortKey: String

    /// Creates an engine.
    public init(id: UUID = UUID(), name: String, urlTemplate: String, suggestionsTemplate: String? = nil, keyword: String? = nil,
                isHidden: Bool = false, sortKey: String) {
        self.id = id
        self.name = name
        self.urlTemplate = urlTemplate
        self.suggestionsTemplate = suggestionsTemplate
        self.keyword = keyword
        self.isHidden = isHidden
        self.sortKey = sortKey
    }

    // MARK: Built-in engines

    /// Google, which searches unless a profile picks another engine. It can't be removed.
    public static let google = SearchEngine(
        id: UUID(uuidString: "6F7E0C1A-0000-4000-8000-000000000001")!, name: "Google",
        urlTemplate: "https://www.google.com/search?q=%s",
        suggestionsTemplate: "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=%s",
        sortKey: "a0")
    /// Bing.
    public static let bing = SearchEngine(
        id: UUID(uuidString: "6F7E0C1A-0000-4000-8000-000000000002")!, name: "Bing",
        urlTemplate: "https://www.bing.com/search?q=%s",
        suggestionsTemplate: "https://api.bing.com/osjson.aspx?query=%s",
        sortKey: "a1")
    /// DuckDuckGo.
    public static let duckDuckGo = SearchEngine(
        id: UUID(uuidString: "6F7E0C1A-0000-4000-8000-000000000003")!, name: "DuckDuckGo",
        urlTemplate: "https://duckduckgo.com/?q=%s",
        suggestionsTemplate: "https://duckduckgo.com/ac/?q=%s&type=list",
        sortKey: "a2")

    /// The built-in engines, as they ship: with no keywords, since a one-letter keyword would
    /// take over everyday text ("b 52 bomber", "d day"); people add their own in Settings.
    public static let builtIns: [SearchEngine] = [.google, .bing, .duckDuckGo]
    /// The engine searches use unless a profile picks another.
    public static let `default`: SearchEngine = .google

    /// Whether this is one of the built-in engines, whose name and addresses come from Axo.
    public var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }
    /// Whether it can be removed (hidden, for a built-in one). Google can't: it's what profiles
    /// fall back to.
    public var isRemovable: Bool { id != Self.google.id }

    /// The engine a profile searches with: its choice when that's a visible engine in
    /// `engines`, otherwise Google.
    public static func engine(for profile: Profile?, in engines: [SearchEngine]) -> SearchEngine {
        guard let chosen = profile?.searchEngineID,
              let engine = engines.first(where: { $0.id == chosen && !$0.isHidden }) else {
            return engines.first { $0.id == google.id } ?? .google
        }
        return engine
    }

    // MARK: Searching

    /// The results page for `query`.
    public func searchURL(for query: String) -> URL {
        // Filling fails only for text that can't be percent-encoded; then the engine's page
        // without the query, never another engine (which would send the text elsewhere).
        Self.fill(urlTemplate, with: query)
            ?? URL(string: urlTemplate.replacingOccurrences(of: "%s", with: ""))
            ?? URL(string: "about:blank")!
    }

    /// The suggestions address for `query`, if the engine has one.
    public func suggestionsURL(for query: String) -> URL? {
        suggestionsTemplate.flatMap { Self.fill($0, with: query) }
    }

    /// The search terms when `url` is this engine's results page for them: the same host and
    /// path as its template, with the query item the template puts `%s` in.
    public func searchTerms(in url: URL) -> String? {
        guard let template = URLComponents(string: urlTemplate.replacingOccurrences(of: "%s", with: Self.marker)),
              let page = URLComponents(url: url, resolvingAgainstBaseURL: false),
              page.scheme?.lowercased() == template.scheme?.lowercased(),
              page.host?.lowercased() == template.host?.lowercased(),
              page.path == template.path || (page.path.isEmpty && template.path == "/") || (page.path == "/" && template.path.isEmpty),
              let name = template.queryItems?.first(where: { $0.value?.contains(Self.marker) == true })?.name,
              let raw = page.percentEncodedQueryItems?.first(where: { $0.name == name })?.value,
              // Engines' own search boxes send spaces as "+" (form encoding); a typed plus
              // arrives encoded (%2B), so it stays a plus.
              let terms = raw.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding,
              !terms.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return terms
    }

    /// Characters a query keeps as they are; everything else is percent-encoded, so `&`, `=`,
    /// `+`, `#`, and `%` in what someone types stay part of the query.
    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#%?/;:@$,!'()*"))
    /// Stands in for `%s` while a template is parsed.
    private static let marker = "AXOSEARCHTERMS"

    private static func fill(_ template: String, with query: String) -> URL? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: queryAllowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    // MARK: Checking what people type

    /// What's wrong with an engine's fields, for Settings to say.
    public enum Problem: Error, Equatable, Sendable {
        /// No name.
        case missingName
        /// The search URL isn't an http or https address.
        case notWebAddress
        /// The search URL has no `%s` for the query.
        case missingQuery
        /// The suggestions URL isn't an https address with `%s`.
        case badSuggestionsAddress
        /// The keyword has spaces.
        case keywordHasSpaces
        /// Another engine has the keyword.
        case keywordInUse(String)

        /// What Settings says.
        public var message: String {
            switch self {
            case .missingName: "Give the search engine a name."
            case .notWebAddress: "The search URL must start with https:// or http://."
            case .missingQuery: "The search URL needs %s where your search goes."
            case .badSuggestionsAddress: "The suggestions URL must start with https:// and contain %s."
            case .keywordHasSpaces: "A keyword can’t have spaces."
            case .keywordInUse(let name): "\(name) already uses that keyword."
            }
        }
    }

    /// Checks a search or suggestions template: an http(s) address with `%s` that parses once
    /// filled in.
    static func isValidTemplate(_ template: String) -> Bool {
        guard template.contains("%s"),
              let url = fill(template, with: "test"),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host()?.isEmpty == false,
              // What people type never chooses the site: no %s in the host.
              let marked = URLComponents(string: template.replacingOccurrences(of: "%s", with: marker)),
              marked.host?.contains(marker) == false else { return false }
        return true
    }

    /// The first problem with these fields, checked against the `others` engines' keywords.
    public static func problem(name: String, urlTemplate: String, suggestionsTemplate: String?, keyword: String?,
                               others: [SearchEngine]) -> Problem? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingName }
        let template = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: template.replacingOccurrences(of: "%s", with: "x"))?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return .notWebAddress }
        if !template.contains("%s") { return .missingQuery }
        guard isValidTemplate(template) else { return .notWebAddress }
        if let suggestions = suggestionsTemplate?.trimmingCharacters(in: .whitespacesAndNewlines), !suggestions.isEmpty,
           !isValidSuggestionsTemplate(suggestions) {
            return .badSuggestionsAddress
        }
        if let keyword = normalizedKeyword(keyword) {
            if keyword.contains(where: \.isWhitespace) { return .keywordHasSpaces }
            if let other = others.first(where: { !$0.isHidden && $0.keyword?.lowercased() == keyword.lowercased() }) {
                return .keywordInUse(other.name)
            }
        }
        return nil
    }

    /// Checks a suggestions template: as a search template, but https only, since suggestions
    /// carry what's typed as it's typed.
    static func isValidSuggestionsTemplate(_ template: String) -> Bool {
        isValidTemplate(template) && template.lowercased().hasPrefix("https://")
    }

    /// A keyword as stored: trimmed, `nil` when empty.
    static func normalizedKeyword(_ keyword: String?) -> String? {
        let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The engine and query when `text` starts with a visible engine's keyword and a space
    /// ("k axolotls"), the first such engine in `engines`' order.
    public static func keywordSearch(in text: String, engines: [SearchEngine]) -> (engine: SearchEngine, query: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return nil }
        let word = trimmed[..<space].lowercased()
        let query = trimmed[space...].trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty,
              let engine = engines.first(where: { !$0.isHidden && $0.keyword?.lowercased() == word }) else { return nil }
        return (engine, query)
    }
}

/// A row of the `searchEngine` table: a custom engine, or a built-in one's changes.
struct SearchEngineRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "searchEngine"

    var id: UUID
    /// `nil` for a built-in engine, whose name comes from Axo.
    var name: String?
    /// `nil` for a built-in engine.
    var urlTemplate: String?
    var suggestionsTemplate: String?
    var keyword: String?
    var isHidden: Bool
    var sortKey: String

    /// The engine this row describes, or `nil` for a custom engine missing its fields.
    func engine() -> SearchEngine? {
        if var builtIn = SearchEngine.builtIns.first(where: { $0.id == id }) {
            builtIn.keyword = keyword
            builtIn.isHidden = isHidden && builtIn.isRemovable
            builtIn.sortKey = sortKey
            return builtIn
        }
        // Rows can arrive through sync without passing through Settings' checks, so a custom
        // engine that isn't a web address is left out rather than searched with.
        guard let name, let urlTemplate, SearchEngine.isValidTemplate(urlTemplate) else { return nil }
        let suggestionsTemplate = suggestionsTemplate.flatMap { SearchEngine.isValidSuggestionsTemplate($0) ? $0 : nil }
        return SearchEngine(id: id, name: name, urlTemplate: urlTemplate, suggestionsTemplate: suggestionsTemplate,
                            keyword: keyword, isHidden: false, sortKey: sortKey)
    }

    /// The row for `engine`: only its changes when it's built in.
    init(_ engine: SearchEngine) {
        id = engine.id
        name = engine.isBuiltIn ? nil : engine.name
        urlTemplate = engine.isBuiltIn ? nil : engine.urlTemplate
        suggestionsTemplate = engine.isBuiltIn ? nil : engine.suggestionsTemplate
        keyword = engine.keyword
        isHidden = engine.isHidden
        sortKey = engine.sortKey
    }
}

/// Errors from ``SearchEngineStore``.
public enum SearchEngineStoreError: Error, Equatable {
    /// No engine has that ID.
    case notFound(UUID)
    /// Google can't be removed.
    case notRemovable
    /// The fields have a problem.
    case invalid(SearchEngine.Problem)
}

/// Reads and changes the search engines and each profile's choice (#132). Writes sync through
/// the `searchEngine` and `profile` triggers.
public final class SearchEngineStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over Axo's database.
    public init(database: AppDatabase) {
        self.database = database
    }

    /// Every engine, hidden built-in ones included, in Settings' order.
    public func engines() async throws -> [SearchEngine] {
        try await database.writer.read { db in try Self.engines(db) }
    }

    /// Streams every engine, hidden built-in ones included: the current list first, then a new
    /// list after every change.
    public func observeEngines() -> AsyncValueObservation<[SearchEngine]> {
        ValueObservation.tracking { db in try Self.engines(db) }.values(in: database.writer)
    }

    static func engines(_ db: Database) throws -> [SearchEngine] {
        let rows = try SearchEngineRecord.fetchAll(db)
        var engines = SearchEngine.builtIns.filter { builtIn in !rows.contains { $0.id == builtIn.id } }
        engines += rows.compactMap { $0.engine() }
        engines.sort { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }
        // Two visible engines can end up with one keyword (two devices' changes meeting through
        // sync); the first keeps it, so a keyword always means one engine.
        var taken: Set<String> = []
        for index in engines.indices where !engines[index].isHidden {
            guard let keyword = engines[index].keyword?.lowercased() else { continue }
            if !taken.insert(keyword).inserted { engines[index].keyword = nil }
        }
        return engines
    }

    /// Adds a custom engine at the end of the list.
    @discardableResult
    public func add(name: String, urlTemplate: String, suggestionsTemplate: String? = nil, keyword: String? = nil) async throws -> SearchEngine {
        try await database.writer.write { db in
            let engines = try Self.engines(db)
            if let problem = SearchEngine.problem(name: name, urlTemplate: urlTemplate, suggestionsTemplate: suggestionsTemplate,
                                                  keyword: keyword, others: engines) {
                throw SearchEngineStoreError.invalid(problem)
            }
            let engine = SearchEngine(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                urlTemplate: urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
                suggestionsTemplate: Self.trimmed(suggestionsTemplate),
                keyword: SearchEngine.normalizedKeyword(keyword),
                sortKey: try SortKey.between(engines.last?.sortKey, nil))
            try SearchEngineRecord(engine).insert(db)
            return engine
        }
    }

    /// Changes an engine: a custom one's fields, or a built-in one's keyword (its name and
    /// addresses come from Axo).
    public func update(_ engine: SearchEngine) async throws {
        try await database.writer.write { db in
            let engines = try Self.engines(db)
            guard let current = engines.first(where: { $0.id == engine.id }) else { throw SearchEngineStoreError.notFound(engine.id) }
            var changed = current
            changed.keyword = SearchEngine.normalizedKeyword(engine.keyword)
            if !current.isBuiltIn {
                changed.name = engine.name.trimmingCharacters(in: .whitespacesAndNewlines)
                changed.urlTemplate = engine.urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                changed.suggestionsTemplate = Self.trimmed(engine.suggestionsTemplate)
            }
            if let problem = SearchEngine.problem(name: changed.name, urlTemplate: changed.urlTemplate,
                                                  suggestionsTemplate: changed.suggestionsTemplate, keyword: changed.keyword,
                                                  others: engines.filter { $0.id != engine.id }) {
                throw SearchEngineStoreError.invalid(problem)
            }
            try SearchEngineRecord(changed).save(db)
        }
    }

    /// Removes an engine: deletes a custom one, hides a built-in one. Profiles that searched
    /// with it go back to Google.
    public func remove(id: UUID) async throws {
        try await database.writer.write { db in
            guard var engine = try Self.engines(db).first(where: { $0.id == id }) else { throw SearchEngineStoreError.notFound(id) }
            guard engine.isRemovable else { throw SearchEngineStoreError.notRemovable }
            if engine.isBuiltIn {
                engine.isHidden = true
                try SearchEngineRecord(engine).save(db)
            } else {
                try SearchEngineRecord.deleteOne(db, key: id)
            }
            try db.execute(sql: "UPDATE profile SET searchEngineID = NULL WHERE searchEngineID = ?", arguments: [id])
        }
    }

    /// Brings back the built-in engines that were removed.
    public func restoreBuiltIns() async throws {
        try await database.writer.write { db in
            let engines = try Self.engines(db)
            var taken = Set(engines.filter { !$0.isHidden }.compactMap { $0.keyword?.lowercased() })
            for var engine in engines where engine.isBuiltIn && engine.isHidden {
                engine.isHidden = false
                // A keyword another engine took meanwhile stays with that engine.
                if let keyword = engine.keyword?.lowercased(), !taken.insert(keyword).inserted { engine.keyword = nil }
                try SearchEngineRecord(engine).save(db)
            }
        }
    }

    /// Sets the engine a profile searches with; `nil` (or Google) for Google.
    public func setEngine(_ engineID: UUID?, forProfile profileID: Profile.ID) async throws {
        try await database.writer.write { db in
            let id = engineID == SearchEngine.google.id ? nil : engineID
            if let id, try !Self.engines(db).contains(where: { $0.id == id && !$0.isHidden }) {
                throw SearchEngineStoreError.notFound(id)
            }
            try db.execute(sql: "UPDATE profile SET searchEngineID = ? WHERE id = ?", arguments: [id, profileID])
        }
    }

    /// Sets whether a profile shows its engine's suggestions.
    public func setShowsSuggestions(_ shows: Bool, forProfile profileID: Profile.ID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE profile SET showsSearchSuggestions = ? WHERE id = ?", arguments: [shows, profileID])
        }
    }

    private static func trimmed(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension TabStore {
    /// The search engines (#132).
    public var searchEngines: SearchEngineStore {
        SearchEngineStore(database: database)
    }
}
