import AxoCRX
import Foundation

/// Downloads extensions from the Chrome Web Store as `.crx` files, through Google's update
/// service (the address Chrome itself uses).
public struct WebStoreDownloader: Sendable {
    /// Fetches a URL's contents. Replace it in tests, which must never use the network.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

    private let fetch: Fetch

    /// Creates a downloader. The default fetches with `URLSession.shared`.
    public init(fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0) }) {
        self.fetch = fetch
    }

    /// The Chrome version reported to the update service. It only needs to be recent enough for
    /// current extensions.
    static let chromeVersion = "140.0"

    /// The update service's download address for an extension, or `nil` if `id` isn't a valid
    /// extension ID.
    public static func downloadURL(for id: String) -> URL? {
        guard id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }) else { return nil }
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&uc"),
        ]
        return components.url
    }

    /// Downloads an extension and checks that it's a signed CRX3 package for that same ID.
    ///
    /// - Returns: The package's bytes.
    /// - Throws: ``WebStoreError``, or the package's ``CRXError``.
    public func download(_ id: String) async throws -> Data {
        guard let url = Self.downloadURL(for: id) else { throw WebStoreError.invalidExtensionID(id) }
        let (data, response) = try await fetch(url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw WebStoreError.downloadFailed(status: status)
        }
        guard !data.isEmpty else { throw WebStoreError.downloadFailed(status: nil) }
        let package = try CRXPackage(data)
        guard package.extensionID == id else {
            throw WebStoreError.unexpectedExtension(requested: id, received: package.extensionID)
        }
        return data
    }
}

/// Why an extension couldn't come from the Chrome Web Store.
public enum WebStoreError: Error, Equatable, LocalizedError {
    /// The ID isn't a Chrome extension ID.
    case invalidExtensionID(String)
    /// The store didn't send the extension (an HTTP status, or nothing at all).
    case downloadFailed(status: Int?)
    /// The package is a different extension than the one asked for.
    case unexpectedExtension(requested: String, received: String)

    public var errorDescription: String? {
        switch self {
        case .invalidExtensionID: "That isn't a Chrome extension."
        case .downloadFailed: "The Chrome Web Store didn't send the extension. Try again in a moment."
        case .unexpectedExtension: "The Chrome Web Store sent a different extension than the one chosen, so Axo didn't install it."
        }
    }
}
