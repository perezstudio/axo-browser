import AxoUI
import Foundation
import Synchronization

/// Refuses redirects that leave https or the original host, so a suggestions address can't forward
/// what's typed elsewhere. It holds no state, so it's Sendable.
nonisolated final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allows(request.url, from: task.originalRequest?.url) ? request : nil)
    }

    /// Whether a redirect to `url` from `original` stays on https and the same host.
    static func allows(_ url: URL?, from original: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return host == original?.host()?.lowercased()
    }
}

/// Fetches search engines' suggestions over the network (#132), outside test runs. Requests carry
/// nothing of any profile's: an ephemeral session with no cookies, cache, or credentials, so
/// whichever profile's Space asks, the engine learns only the text typed. Only https is fetched,
/// redirects never leave the engine's host, and answers stop at
/// ``SearchSuggestions/maximumResponseSize`` and a few seconds in all.
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
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
    }()

    func suggestionsData(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        let (bytes, response) = try await Self.session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Int64(SearchSuggestions.maximumResponseSize) else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > SearchSuggestions.maximumResponseSize { throw URLError(.dataLengthExceedsMaximum) }
        }
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
