import AppKit
import WebKit

/// Captures small, compressed images of pages for hibernated tabs.
@MainActor
enum PageSnapshot {
    /// The snapshot width in points. Small enough to keep hibernated tabs cheap, large enough to
    /// stand in for the page while it restores.
    static let width: CGFloat = 640

    /// Captures the visible part of `webView` as JPEG data, or `nil` if WebKit can't snapshot it.
    static func capture(_ webView: WKWebView) async -> Data? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(width))
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        return jpegData(from: image)
    }

    /// Encodes `image` as a JPEG, which is far smaller in memory than a bitmap.
    static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
