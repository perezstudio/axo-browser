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
            // Control, formatting (right-to-left overrides), and line and paragraph separator
            // characters never show, nor piles of combining marks.
            let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
            guard !suggestion.isEmpty, suggestion.count <= maximumQueryLength,
                  !suggestion.unicodeScalars.contains(where: { hidden.contains($0.properties.generalCategory) }),
                  suggestion.unicodeScalars.filter({ $0.properties.generalCategory == .nonspacingMark }).count <= 8,
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
        guard let suggester = searchSuggester, let profileID = space?.profileID, showsSearchSuggestions(profileID),
              let request = SearchSuggestions.request(for: query, search: searchContext) else { return }
        let sleep = suggestionSleep
        searchSuggestionTask = Task { [weak self] in
            await sleep(SearchSuggestions.debounce)
            guard let self, !Task.isCancelled, self.isStill(query, profileID: profileID, engine: request.engine) else { return }
            guard let data = try? await suggester.suggestionsData(from: request.url) else { return }
            // The answer counts only for the text, profile, engine, and switch it was asked for.
            guard !Task.isCancelled, self.isStill(query, profileID: profileID, engine: request.engine) else { return }
            self.commandResults += SearchSuggestions.parse(data, query: request.query)
                .map { CommandResult.suggestion($0, url: request.engine.searchURL(for: $0)) }
        }
    }

    /// Whether a profile shows suggestions. A profile not read yet (just after launch, or while
    /// the shown Space moves to another profile) counts as off, so nothing is sent against a
    /// switch that's off.
    private func showsSearchSuggestions(_ profileID: Profile.ID) -> Bool {
        allProfiles.first { $0.id == profileID }?.showsSearchSuggestions ?? false
    }

    /// Whether the bar still shows `query` for the same profile, engine, and switch.
    private func isStill(_ query: String, profileID: Profile.ID, engine: SearchEngine) -> Bool {
        guard isCommandBarVisible, commandQuery == query, space?.profileID == profileID, showsSearchSuggestions(profileID) else { return false }
        let current = SearchSuggestions.request(for: query, search: searchContext)?.engine
        return current?.id == engine.id && current?.suggestionsTemplate == engine.suggestionsTemplate
    }

    /// Adds Axo's own results (history) above any suggestions, which always come last.
    func insertLocalCommandResults(_ results: [CommandResult]) {
        let index = commandResults.firstIndex { if case .suggestion = $0 { true } else { false } } ?? commandResults.endIndex
        commandResults.insert(contentsOf: results, at: index)
        // The highlighted row stays highlighted when rows arrive above it.
        if index <= commandSelection, commandSelection < commandResults.count - results.count { commandSelection += results.count }
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
