import AppKit
import Foundation
import WebKit

/// Finds, fetches, and normalizes a page's icon.
///
/// The page's `<link rel="icon">` candidates are read in an isolated content world, so page
/// scripts can't see or tamper with the lookup. Icons are fetched with an ephemeral session that
/// carries no cookies, so loading an icon never identifies the user to the site.
enum FaviconLoader {
    /// A `<link>` element that declares an icon.
    struct Candidate: Equatable, Sendable {
        var href: String
        var rel: String
        var sizes: String
        var type: String
    }

    /// The edge length, in pixels, of the PNGs Axo stores.
    static let iconSize = 64
    /// Icons larger than this are ignored.
    static let maximumDownloadSize = 512 * 1024

    private static let session = URLSession(configuration: .ephemeral)

    /// Reads the icon `<link>` elements of the page in `webView`.
    @MainActor
    static func candidates(in webView: WKWebView) async -> [Candidate] {
        let script = """
        return Array.from(document.querySelectorAll('link[rel]'))
            .filter(link => /(^|\\s)(icon|apple-touch-icon)(\\s|$)/i.test(link.rel))
            .map(link => [link.href, link.rel.toLowerCase(), link.getAttribute('sizes') || '', link.type || '']);
        """
        let contentWorld = WKContentWorld.world(name: "AxoFavicons")
        guard let result = try? await webView.callAsyncJavaScript(script, contentWorld: contentWorld),
              let rows = result as? [[String]] else { return [] }
        return rows.compactMap { row in
            guard row.count == 4 else { return nil }
            return Candidate(href: row[0], rel: row[1], sizes: row[2], type: row[3])
        }
    }

    /// Picks the icon URL to fetch for a page: the best declared icon, or `/favicon.ico` for
    /// http(s) pages that declare none.
    static func bestIconURL(from candidates: [Candidate], pageURL: URL) -> URL? {
        let best = candidates
            .filter { !$0.href.isEmpty }
            .compactMap { candidate in iconURL(from: candidate.href).map { (candidate, $0) } }
            .max { score($0.0) < score($1.0) }
        if let best {
            return best.1
        }
        guard let scheme = pageURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Parses an `href` that WebKit already resolved. Unlike plain `URL(string:)`, this never
    /// re-encodes existing `%` escapes, which would corrupt inline `data:` icons that contain
    /// literal spaces.
    static func iconURL(from href: String) -> URL? {
        URL(string: href, encodingInvalidCharacters: false)
            ?? URL(string: href.replacingOccurrences(of: " ", with: "%20"), encodingInvalidCharacters: false)
    }

    /// Higher is better: scalable icons first, then the smallest bitmap at least ``iconSize``
    /// pixels wide (it scales down cleanly), then the largest smaller one.
    static func score(_ candidate: Candidate) -> Int {
        let sizes = candidate.sizes.lowercased()
        if sizes.contains("any") || candidate.type.lowercased().contains("svg") || candidate.href.lowercased().hasSuffix(".svg") {
            return 1_000
        }
        let declared = sizes.split(separator: " ").compactMap { token -> Int? in
            let parts = token.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]) else { return nil }
            return width
        }
        let fallback = candidate.rel.contains("apple-touch-icon") ? 180 : 16
        let size = declared.max() ?? fallback
        return size >= iconSize ? 500 - size / 8 : size
    }

    /// Downloads an icon, returning `nil` for failures, error statuses, or oversized files.
    static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard !data.isEmpty, data.count <= maximumDownloadSize else { return nil }
        return data
    }

    /// Redraws any image format AppKit can read (ICO, PNG, SVG, …) as a square PNG of
    /// ``iconSize`` pixels, centered and scaled to fit. Returns `nil` if the data isn't an image.
    @MainActor
    static func normalize(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: iconSize, pixelsHigh: iconSize,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        let side = CGFloat(iconSize)
        let scale = min(side / image.size.width, side / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(
            x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2,
            width: drawSize.width, height: drawSize.height
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
