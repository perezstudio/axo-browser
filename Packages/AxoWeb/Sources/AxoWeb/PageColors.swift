import CoreGraphics
import Foundation

/// An sRGB color a page declares or draws, for tinting the toolbar to the page (#107).
nonisolated public struct PageColor: Equatable, Hashable, Sendable {
    /// The red component, from 0 to 1.
    public var red: Double
    /// The green component, from 0 to 1.
    public var green: Double
    /// The blue component, from 0 to 1.
    public var blue: Double
    /// The opacity, from 0 (transparent) to 1.
    public var alpha: Double

    /// A color from components from 0 to 1.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses the forms the engine's canvas and computed styles give: `#rrggbb`, `#rgb`,
    /// `rgb(r, g, b)`, `rgba(r, g, b, a)`, and `rgb(r g b / a)`. Anything else (`color(…)`,
    /// keywords) is `nil`.
    public init?(css: String) {
        let text = css.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") {
            var hex = String(text.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
            return
        }
        guard text.hasPrefix("rgb"), let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let inside = text[text.index(after: open)..<text.index(before: text.endIndex)]
        let parts = inside.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func channel(_ part: String) -> Double? {
            if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
            return Double(part).map { $0 / 255 }
        }
        func opacity(_ part: String) -> Double? {
            if part.hasSuffix("%") { return Double(part.dropLast()).map { $0 / 100 } }
            return Double(part)
        }
        guard let red = channel(parts[0]), let green = channel(parts[1]), let blue = channel(parts[2]),
              let alpha = parts.count == 4 ? opacity(parts[3]) : 1 else { return nil }
        let clamp = { (value: Double) in min(max(value, 0), 1) }
        self.init(red: clamp(red), green: clamp(green), blue: clamp(blue), alpha: clamp(alpha))
    }

    /// Whether the color is solid enough to tint with; a nearly see-through color says little
    /// about how the page looks.
    public var isOpaqueEnough: Bool { alpha >= 0.5 }

    /// Pure white.
    public static let white = PageColor(red: 1, green: 1, blue: 1)
}

/// The colors a page offers for the toolbar: its `theme-color` for light and dark appearances
/// (from `<meta name="theme-color">`, honoring `prefers-color-scheme` media queries), and the
/// color at its top, used when it declares none.
nonisolated public struct PageColors: Equatable, Sendable {
    /// The `theme-color` with no media query, or the first one whose query isn't about the
    /// color scheme.
    public var themeColor: PageColor?
    /// The `theme-color` for `(prefers-color-scheme: light)`.
    public var lightThemeColor: PageColor?
    /// The `theme-color` for `(prefers-color-scheme: dark)`.
    public var darkThemeColor: PageColor?
    /// The background color at the top of the page.
    public var topColor: PageColor?

    /// Colors from their parts.
    public init(themeColor: PageColor? = nil, lightThemeColor: PageColor? = nil, darkThemeColor: PageColor? = nil, topColor: PageColor? = nil) {
        self.themeColor = themeColor
        self.lightThemeColor = lightThemeColor
        self.darkThemeColor = darkThemeColor
        self.topColor = topColor
    }

    /// Colors from the page's `theme-color` tags (each a CSS color and its `media` attribute)
    /// and the color its top edge draws in. Colors that don't parse, or are mostly see-through,
    /// are left out.
    public init(themeColors: [(color: String, media: String)], topColor: PageColor?) {
        self.init()
        for (css, media) in themeColors {
            guard let color = PageColor(css: css), color.isOpaqueEnough else { continue }
            let query = media.lowercased().replacingOccurrences(of: " ", with: "")
            if query.contains("prefers-color-scheme:dark") {
                if darkThemeColor == nil { darkThemeColor = color }
            } else if query.contains("prefers-color-scheme:light") {
                if lightThemeColor == nil { lightThemeColor = color }
            } else if themeColor == nil {
                themeColor = color
            }
        }
        if let topColor, topColor.isOpaqueEnough { self.topColor = topColor }
    }

    /// Whether some appearance has no `theme-color`, so the page's top color would be used.
    var needsTopColor: Bool {
        themeColor == nil && (lightThemeColor == nil || darkThemeColor == nil)
    }

    /// The color to tint with in the light or dark appearance: the matching `theme-color`, the
    /// plain one, then the page's top color.
    public func color(isDark: Bool) -> PageColor? {
        (isDark ? darkThemeColor : lightThemeColor) ?? themeColor ?? topColor
    }

    /// Reads a page's colors: its `theme-color` tags, in Axo's page-text world so the page can't
    /// see or change the lookup (normalized through a detached canvas, which leaves the DOM
    /// untouched), and, when some appearance has none, the color its top edge draws in, from a
    /// small snapshot. Pixels, not styles: a transparent header over a photo or video draws the
    /// photo, while its styles would name the body's color behind it.
    @MainActor
    static func read(from page: any EnginePage) async -> PageColors? {
        guard let result = try? await page.callJavaScript(script, arguments: [:], in: PageText.world),
              let rows = result as? [[String]] else { return nil }
        let metas = rows.compactMap { row -> (color: String, media: String)? in
            row.count == 2 ? (row[0], row[1]) : nil
        }
        var colors = PageColors(themeColors: metas, topColor: nil)
        if colors.needsTopColor, let image = await page.snapshot(width: snapshotWidth),
           let cgImage = PageSnapshot.cgImage(from: image) {
            colors.topColor = topEdgeColor(of: cgImage)
        }
        return colors
    }

    /// The width, in points, of the snapshot the top color comes from: small, since only its top
    /// edge is read.
    static let snapshotWidth: CGFloat = 64

    /// The average color of an image's top rows (the top 2%, at least one), in sRGB, or `nil` if
    /// it's mostly see-through.
    nonisolated static func topEdgeColor(of image: CGImage) -> PageColor? {
        let width = 16
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(image.width, 1))).rounded()))
        let rows = max(1, height / 50)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        // Drawn into sRGB, so the image's own colour space (often the display's) is converted.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var totals = [Double](repeating: 0, count: 4)
        // Memory starts at the image's top row.
        for row in 0..<rows {
            for column in 0..<width {
                let offset = (row * width + column) * 4
                for channel in 0..<4 { totals[channel] += Double(pixels[offset + channel]) }
            }
        }
        let count = Double(rows * width) * 255
        let alpha = totals[3] / count
        guard alpha > 0 else { return nil }
        // Premultiplied, so divide the alpha back out.
        let color = PageColor(red: totals[0] / count / alpha, green: totals[1] / count / alpha,
                              blue: totals[2] / count / alpha, alpha: alpha)
        return color.isOpaqueEnough ? color : nil
    }

    /// The script `read(from:)` runs: each `theme-color` tag's color, normalized, and its media.
    static let script = """
        const context = document.createElement('canvas').getContext('2d');
        const sentinel = '#010203';
        const normalize = (value) => {
          if (!context || !value) return null;
          context.fillStyle = sentinel;
          context.fillStyle = value;
          const result = String(context.fillStyle);
          return result === sentinel && value.trim().toLowerCase() !== sentinel ? null : result;
        };
        return Array.from(document.querySelectorAll('meta[name="theme-color" i]'))
          .map(meta => [normalize(meta.getAttribute('content') || ''), meta.getAttribute('media') || ''])
          .filter(row => row[0]);
        """
}
