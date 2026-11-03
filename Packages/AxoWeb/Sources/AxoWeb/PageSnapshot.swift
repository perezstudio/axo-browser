import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Captures small, compressed images of pages for hibernated tabs.
@MainActor
enum PageSnapshot {
    /// The snapshot width in pixels, at 1x. Small enough to keep hibernated tabs cheap, large
    /// enough to stand in for the page while it restores.
    static let width: CGFloat = 640

    /// Captures the visible part of `page` as JPEG data, or `nil` if its engine can't snapshot it.
    /// Only the capture runs on the main actor; scaling and encoding don't.
    static func capture(_ page: any EnginePage) async -> Data? {
        guard let image = await page.snapshot(width: width), let cgImage = cgImage(from: image) else { return nil }
        let maxWidth = Int(width)
        return await Task.detached(priority: .utility) {
            jpegData(from: cgImage, maxWidth: maxWidth)
        }.value
    }

    private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if os(macOS)
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        // Not every UIImage has a CGImage behind it (one made from a CIImage doesn't); draw those.
        if let cgImage = image.cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
        #endif
    }

    /// Scales `image` down to `maxWidth` pixels across (engines return it at the screen's scale,
    /// which would make each hibernated tab's snapshot several times larger), in sRGB, and
    /// encodes it as a JPEG, which is far smaller in memory than a bitmap.
    nonisolated static func jpegData(from image: CGImage, maxWidth: Int) -> Data? {
        let scale = min(1, Double(maxWidth) / Double(max(image.width, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        // White under the page, so anything transparent doesn't turn black in the JPEG.
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The image's own colour space (often the display's) is converted to sRGB as it's drawn.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
