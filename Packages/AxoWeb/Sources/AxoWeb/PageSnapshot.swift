import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    static func jpegData(from image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        #else
        // Redraw at 1x: WebKit returns an image at the screen's scale, which would make each
        // hibernated tab's snapshot several times larger.
        let scale = min(1, width / max(image.size.width, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.7) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        #endif
    }
}
