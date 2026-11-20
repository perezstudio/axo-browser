import AxoCore
import Foundation

/// Fetches an engine's search suggestions (#132): the app's network fetcher, which sends no
/// cookies or other profile data, or a stand-in in test runs, which never reaches the network.
public protocol SearchSuggesting: Sendable {
    /// The body of the suggestions response at `url` (OpenSearch suggestions JSON).
    func suggestionsData(from url: URL) async throws -> Data
}

/// Deciding when to ask for suggestions, and reading the answers.
nonisolated public enum SearchSuggestions {
    /// How long typing must pause before a request goes out.
    public static let debounce: Duration = .milliseconds(150)
    /// The most suggestions shown.
    public static let maximumCount = 4
    /// Longer text isn't sent: it's a pasted passage or an address being edited, not a search.
    public static let maximumQueryLength = 200
    /// Larger answers are ignored.
    public static let maximumResponseSize = 64 * 1024

    /// What to ask for `text`: the engine (a keyword's, or the context's) and the query, with the
    /// suggestions address. `nil` when nothing should be sent: empty or long text, text that
    /// opens an address (a URL or a host on this Mac), or an engine without suggestions.
    public static func request(for text: String, search: SearchContext) -> (engine: SearchEngine, query: String, url: URL)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumQueryLength,
              // An address being typed or pasted, even one a space turns into a search.
              !trimmed.contains("://"),
              let resolved = AddressInput.resolve(trimmed, search: search), resolved.isSearch else { return nil }
        let (engine, query) = SearchEngine.keywordSearch(in: trimmed, engines: search.engines) ?? (search.engine, trimmed)
        guard let url = engine.suggestionsURL(for: query) else { return nil }
        return (engine, query, url)
    }

    /// The suggestions in an OpenSearch answer (`["query", ["one", "two"], …]`): at most
    /// ``maximumCount``, without repeats or the query itself. Anything else reads as none.
    public static func parse(_ data: Data, query: String) -> [String] {
        guard data.count <= maximumResponseSize,
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2, let items = array[1] as? [Any] else { return [] }
        var seen: Set<String> = [query.lowercased()]
        var suggestions: [String] = []
        for case let item as String in items {
            let suggestion = item.trimmingCharacters(in: .whitespacesAndNewlines)
            // Control and formatting characters (right-to-left overrides) never show.
            guard !suggestion.isEmpty, suggestion.count <= maximumQueryLength,
                  !suggestion.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }),
                  seen.insert(suggestion.lowercased()).inserted else { continue }
            suggestions.append(suggestion)
            if suggestions.count == maximumCount { break }
        }
        return suggestions
    }
}

extension BrowserModel {
    /// Asks the shown Space's engine for suggestions for `query`, after ``SearchSuggestions/debounce``
    /// with no newer keystroke, and adds them below the command bar's own results. Nothing is
    /// sent while the profile has suggestions off, without a ``searchSuggester``, or for text
    /// that ``SearchSuggestions/request(for:search:)`` keeps back. Slow or failed answers show
    /// nothing; each keystroke cancels the last request.
    func requestSearchSuggestions(for query: String) {
        searchSuggestionTask?.cancel()
        searchSuggestionTask = nil
        guard let suggester = searchSuggester,
              allProfiles.first(where: { $0.id == space?.profileID })?.showsSearchSuggestions ?? true,
              let request = SearchSuggestions.request(for: query, search: searchContext) else { return }
        let sleep = suggestionSleep
        searchSuggestionTask = Task { [weak self] in
            await sleep(SearchSuggestions.debounce)
            guard !Task.isCancelled, self?.commandQuery == query else { return }
            guard let data = try? await suggester.suggestionsData(from: request.url) else { return }
            guard let self, !Task.isCancelled, self.commandQuery == query, self.isCommandBarVisible else { return }
            let suggestions = SearchSuggestions.parse(data, query: request.query)
            // Never what's already a row (the typed search itself).
            let shown = Set(self.commandResults.map(\.id))
            self.commandResults += suggestions
                .map { CommandResult.suggestion($0, url: request.engine.searchURL(for: $0)) }
                .filter { !shown.contains($0.id) }
        }
    }

    /// Adds Axo's own results (history) above any suggestions, which always come last.
    func insertLocalCommandResults(_ results: [CommandResult]) {
        let index = commandResults.firstIndex { if case .suggestion = $0 { true } else { false } } ?? commandResults.endIndex
        commandResults.insert(contentsOf: results, at: index)
    }

    /// Sets whether a profile shows its engine's suggestions.
    public func setShowsSearchSuggestions(_ shows: Bool, forProfile profileID: Profile.ID) async {
        do {
            try await store.searchEngines.setShowsSuggestions(shows, forProfile: profileID)
        } catch {
            report(error, "Axo couldn't change the profile's search suggestions.")
        }
    }
}
