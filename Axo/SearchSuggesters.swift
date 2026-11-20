import AxoUI
import Foundation
import Synchronization

/// Fetches search engines' suggestions over the network (#132), outside test runs. Requests carry
/// nothing of any profile's: an ephemeral session with no cookies, cache, or credentials, so
/// whichever profile's Space asks, the engine learns only the text typed.
struct NetworkSearchSuggester: SearchSuggesting {
    /// The session, shared by every request.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A slow answer is worth nothing once the next keystroke comes.
        configuration.timeoutIntervalForRequest = 3
        return URLSession(configuration: configuration)
    }()

    func suggestionsData(from url: URL) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { throw URLError(.unsupportedURL) }
        let (data, response) = try await Self.session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= SearchSuggestions.maximumResponseSize else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Suggestions in test runs, which never reach the network: for "pond" it answers "pond life"
/// and "pond plants", whatever the engine. It counts the requests, so tests can tell none went out.
final class StandInSearchSuggester: SearchSuggesting {
    private let requests = Mutex<[URL]>([])

    /// Every request so far.
    var requestedURLs: [URL] { requests.withLock { $0 } }

    func suggestionsData(from url: URL) async throws -> Data {
        requests.withLock { $0.append(url) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { ["q", "query"].contains($0.name) }?.value ?? ""
        return try JSONSerialization.data(withJSONObject: [query, ["\(query) life", "\(query) plants"]])
    }
}
