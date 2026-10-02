import Foundation

/// Turns what someone types in the address field into a URL to load.
///
/// Text with a scheme loads as is, text that looks like a host gets `https://` (or `http://` for
/// local hosts), and anything else becomes a search.
nonisolated public enum AddressInput {
    /// The search page for queries. DuckDuckGo is a placeholder default until search engine
    /// settings exist.
    public static let searchURL = URL(string: "https://duckduckgo.com/")!

    private static let schemesWithoutSlashes: Set<String> = ["about", "data", "mailto", "javascript"]
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// Returns the URL to load for `text`, or `nil` if the text is empty.
    public static func url(from text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

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
        return searchURL(for: input)
    }

    /// Returns the search URL for `query`.
    public static func searchURL(for query: String) -> URL {
        var components = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
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
