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
    /// and the CSS color at its top. Colors that don't parse, or are mostly see-through, are
    /// left out.
    public init(themeColors: [(color: String, media: String)], topColor: String?) {
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
        if let topColor, let color = PageColor(css: topColor), color.isOpaqueEnough {
            self.topColor = color
        }
    }

    /// The color to tint with in the light or dark appearance: the matching `theme-color`, the
    /// plain one, then the page's top color.
    public func color(isDark: Bool) -> PageColor? {
        (isDark ? darkThemeColor : lightThemeColor) ?? themeColor ?? topColor
    }

    /// Reads a page's colors, in Axo's page-text world so the page can't see or change it. It
    /// normalizes colors through a detached canvas, which leaves the page's DOM untouched.
    @MainActor
    static func read(from page: any EnginePage) async -> PageColors? {
        guard let result = try? await page.callJavaScript(script, arguments: [:], in: PageText.world),
              let values = result as? [String: Any] else { return nil }
        let metas = (values["metas"] as? [[String]] ?? []).compactMap { row -> (color: String, media: String)? in
            row.count == 2 ? (row[0], row[1]) : nil
        }
        return PageColors(themeColors: metas, topColor: values["top"] as? String)
    }

    /// The script `read(from:)` runs.
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
        const metas = Array.from(document.querySelectorAll('meta[name="theme-color" i]'))
          .map(meta => [normalize(meta.getAttribute('content') || ''), meta.getAttribute('media') || ''])
          .filter(row => row[0]);
        const clear = (color) => !color || color === 'transparent' || /^rgba\\(.*,\\s*0\\)$/.test(color);
        let top = null;
        const start = document.elementFromPoint(Math.floor(window.innerWidth / 2), 1);
        for (let element = start; element && !top; element = element.parentElement) {
          const color = getComputedStyle(element).backgroundColor;
          if (!clear(color)) top = color;
        }
        for (const element of [document.body, document.documentElement]) {
          if (top || !element) continue;
          const color = getComputedStyle(element).backgroundColor;
          if (!clear(color)) top = color;
        }
        return { metas, top };
        """
}
