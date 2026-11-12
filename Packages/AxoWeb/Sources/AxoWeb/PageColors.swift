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
        func number(_ part: Substring) -> Double? {
            Double(part).flatMap { $0.isFinite ? $0 : nil }
        }
        func channel(_ part: String) -> Double? {
            if part.hasSuffix("%") { return number(part.dropLast()).map { $0 / 100 } }
            return number(Substring(part)).map { $0 / 255 }
        }
        func opacity(_ part: String) -> Double? {
            if part.hasSuffix("%") { return number(part.dropLast()).map { $0 / 100 } }
            return number(Substring(part))
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
    ///
    /// `isComplete` is false when the top color was needed but the page couldn't be drawn (it has
    /// no size yet, or the snapshot failed), so it's worth reading again. `nil` if the script
    /// failed (the page navigated meanwhile).
    @MainActor
    static func read(from page: any EnginePage) async -> (colors: PageColors, isComplete: Bool)? {
        guard let result = try? await page.callJavaScript(script, arguments: [:], in: PageText.world),
              let rows = result as? [[String]] else { return nil }
        let metas = rows.compactMap { row -> (color: String, media: String)? in
            row.count == 2 ? (row[0], row[1]) : nil
        }
        var colors = PageColors(themeColors: metas, topColor: nil)
        guard colors.needsTopColor else { return (colors, true) }
        guard !page.view.bounds.isEmpty, let image = await page.snapshot(width: snapshotWidth),
              let cgImage = PageSnapshot.cgImage(from: image) else { return (colors, false) }
        colors.topColor = topEdgeColor(of: cgImage, widthInPoints: snapshotWidth)
        return (colors, true)
    }

    /// The width, in points, of the snapshot the top color comes from: wide enough that its top
    /// few points are a pixel row or more.
    static let snapshotWidth: CGFloat = 320

    /// How far down from the page's top, in points, its top color is averaged: about what meets
    /// the toolbar, so a thin header's color isn't mixed with the page below it.
    static let topEdgeDepth: CGFloat = 4

    /// The average color of an image's top ``topEdgeDepth`` points (at least one pixel row), in
    /// sRGB, or `nil` if it's mostly see-through. `widthInPoints` is the width the image shows,
    /// for its scale.
    nonisolated static func topEdgeColor(of image: CGImage, widthInPoints: CGFloat) -> PageColor? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = Double(image.width) / Double(max(widthInPoints, 1))
        let rows = min(image.height, max(1, Int((Double(topEdgeDepth) * scale).rounded())))
        // CGImage crops from its top-left corner.
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: rows)) else { return nil }
        let width = min(strip.width, 64)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: rows, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        // Drawn into sRGB, so the image's own colour space (often the display's) is converted.
        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: rows))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * rows * 4)
        var totals = [Double](repeating: 0, count: 4)
        for offset in stride(from: 0, to: width * rows * 4, by: 4) {
            for channel in 0..<4 { totals[channel] += Double(pixels[offset + channel]) }
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
        // An invalid color leaves fillStyle as it was, so set it to two placeholders in turn: a
        // valid color gives the same answer after both, an invalid one gives each placeholder.
        const parse = (value, placeholder) => {
          context.fillStyle = placeholder;
          context.fillStyle = value;
          return String(context.fillStyle);
        };
        const normalize = (value) => {
          if (!context || !value) return null;
          const first = parse(value, '#010203');
          return first === parse(value, '#030201') ? first : null;
        };
        // Queries about the color scheme are sorted out in Swift, for both appearances; any other
        // query (a width) counts only if it matches now.
        const applies = (media) => {
          if (!media.trim() || /prefers-color-scheme/i.test(media)) return true;
          try { return window.matchMedia(media).matches; } catch { return false; }
        };
        return Array.from(document.querySelectorAll('meta[name="theme-color" i]'))
          .map(meta => [normalize(meta.getAttribute('content') || ''), meta.getAttribute('media') || ''])
          .filter(row => row[0] && applies(row[1]));
        """
}
