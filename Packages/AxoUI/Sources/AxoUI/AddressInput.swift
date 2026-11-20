import AxoCore
import Foundation

/// Turns what someone types in the address field into a URL to load.
///
/// Text with a scheme loads as is, text that looks like a host gets `https://` (or `http://` for
/// local hosts), and anything else becomes a search, with an engine's keyword ("k axolotls") or
/// the profile's engine (``SearchContext``).
nonisolated public enum AddressInput {

    private static let schemesWithoutSlashes: Set<String> = ["about", "data", "mailto", "javascript"]
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// Returns the URL to load for `text`, or `nil` if the text is empty.
    public static func url(from text: String, search: SearchContext = .default) -> URL? {
        resolve(text, search: search)?.url
    }

    /// The URL to load for `text` and whether it's a search, or `nil` if the text is empty.
    public static func resolve(_ text: String, search: SearchContext = .default) -> (url: URL, isSearch: Bool)? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        // A keyword and a space searches with that engine, before anything else is tried.
        if let keyword = SearchEngine.keywordSearch(in: input, engines: search.engines) {
            return (keyword.engine.searchURL(for: keyword.query), true)
        }
        guard let url = address(from: input) else { return (search.engine.searchURL(for: input), true) }
        return (url, false)
    }

    /// The address `input` names, or `nil` when it's a search.
    private static func address(from input: String) -> URL? {

        if input.contains("://"), !input.contains(where: \.isWhitespace),
           let url = URL(string: input), url.scheme != nil {
            return url
        }
        if let colon = input.firstIndex(of: ":"),
           schemesWithoutSlashes.contains(input[..<colon].lowercased()),
           let url = URL(string: input) {
            return url
        }
        if !input.contains(where: \.isWhitespace), let url = hostURL(from: input) {
            return url
        }
        return nil
    }

    /// Returns the search URL for `query`, with `search`'s engine (or a keyword's).
    public static func searchURL(for query: String, search: SearchContext = .default) -> URL {
        search.searchURL(for: query)
    }

    /// `example.com/path` becomes `https://example.com/path`; `localhost:3000` becomes `http://…`.
    private static func hostURL(from input: String) -> URL? {
        let hostAndPort = input.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let host = hostAndPort.hasPrefix("[")
            ? String(hostAndPort.prefix { $0 != "]" }) + "]"
            : String(hostAndPort.prefix { $0 != ":" })
        let lowercasedHost = host.lowercased()
        let isLocal = localHosts.contains(lowercasedHost)
            || lowercasedHost.hasSuffix(".localhost")
            || lowercasedHost.hasSuffix(".test")
        let looksLikeHost = isLocal
            || (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix("."))
        guard looksLikeHost else { return nil }
        guard let url = URL(string: (isLocal ? "http://" : "https://") + input), url.host != nil else { return nil }
        return url
    }
}
