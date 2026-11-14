import Foundation

/// A Space's theme for the window's background, like Arc's Space themes (#137): one color or a
/// gradient of up to three, a light, dark, or automatic mode, how see-through it is, and how
/// much grain lies over it. A Space with no theme (`Space.theme == nil`) uses the system's
/// sidebar material.
///
/// Stored on the Space as JSON (GRDB encodes nested `Codable` values that way), and synced with
/// it. Decoding is forgiving, since a theme can come from another device or a newer Axo: unknown
/// modes become automatic, out-of-range numbers are clamped, and colors that don't parse are
/// dropped. A theme with no readable color doesn't decode at all, and the Space reads as having
/// none.
nonisolated public struct SpaceTheme: Codable, Hashable, Sendable {
    /// Whether the theme looks light or dark.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Light or dark with the system's appearance.
        case automatic
        /// Always light, with dark text.
        case light
        /// Always dark, with light text.
        case dark
    }

    /// The most colors a gradient has.
    public static let maxColors = 3

    /// The theme's colors, top to bottom: one, or a gradient of up to ``maxColors``. Never empty.
    public private(set) var colors: [ThemeColor]
    /// Whether the theme looks light or dark.
    public var mode: Mode
    /// How see-through the background is, from 0 (solid color) to 1 (the desktop shows through
    /// the system's blur, with a little of the color left).
    public var transparency: Double {
        didSet { transparency = Self.unit(transparency) }
    }
    /// How much grain lies over the color, from 0 (none) to 1 (Arc's strongest).
    public var grain: Double {
        didSet { grain = Self.unit(grain) }
    }

    /// A theme. Colors past ``maxColors`` are dropped, an empty list becomes a neutral gray, and
    /// the numbers are clamped to 0...1.
    public init(colors: [ThemeColor], mode: Mode = .automatic, transparency: Double = 0, grain: Double = 0) {
        self.colors = colors.isEmpty ? [ThemeColor(red: 0.6, green: 0.6, blue: 0.62)] : Array(colors.prefix(Self.maxColors))
        self.mode = mode
        self.transparency = Self.unit(transparency)
        self.grain = Self.unit(grain)
    }

    /// Replaces the colors, with the same rules as ``init(colors:mode:transparency:grain:)``.
    public mutating func setColors(_ colors: [ThemeColor]) {
        self = SpaceTheme(colors: colors, mode: mode, transparency: transparency, grain: grain)
    }

    private enum CodingKeys: String, CodingKey {
        case colors, mode, transparency, grain
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hexes = (try? container.decodeIfPresent([String].self, forKey: .colors)) ?? []
        let colors = hexes.compactMap(ThemeColor.init(hex:))
        guard !colors.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .colors, in: container, debugDescription: "A theme needs a color")
        }
        let mode = (try? container.decodeIfPresent(String.self, forKey: .mode)).flatMap { $0 }.flatMap(Mode.init(rawValue:))
        self.init(
            colors: colors,
            mode: mode ?? .automatic,
            transparency: (try? container.decodeIfPresent(Double.self, forKey: .transparency)).flatMap { $0 } ?? 0,
            grain: (try? container.decodeIfPresent(Double.self, forKey: .grain)).flatMap { $0 } ?? 0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colors.map(\.hex), forKey: .colors)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encode(transparency, forKey: .transparency)
        try container.encode(grain, forKey: .grain)
    }

    /// A number clamped to 0...1, with NaN as 0.
    static func unit(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}

/// An opaque sRGB color in a Space theme, stored as `#rrggbb`.
nonisolated public struct ThemeColor: Hashable, Sendable {
    /// The red component, from 0 to 1.
    public var red: Double
    /// The green component, from 0 to 1.
    public var green: Double
    /// The blue component, from 0 to 1.
    public var blue: Double

    /// A color from components, clamped to 0...1 and rounded to the 8 bits per channel it's
    /// stored with, so a color equals itself read back (the editor compares them).
    public init(red: Double, green: Double, blue: Double) {
        func channel(_ value: Double) -> Double { (SpaceTheme.unit(value) * 255).rounded() / 255 }
        self.red = channel(red)
        self.green = channel(green)
        self.blue = channel(blue)
    }

    /// A color from `#rrggbb` (the `#` is optional), or `nil` for anything else.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// The color as `#rrggbb`, lowercase.
    public var hex: String {
        let parts = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return "#" + parts.map { String(format: "%02x", $0) }.joined()
    }

    /// The color's relative luminance, as WCAG defines it: 0 for black, 1 for white.
    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between two colors, from 1 (the same) to 21 (black and white).
    public func contrast(with other: ThemeColor) -> Double {
        let (lighter, darker) = luminance > other.luminance ? (luminance, other.luminance) : (other.luminance, luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The color mixed with another: `amount` 0 is this color, 1 the other.
    public func mixed(with other: ThemeColor, amount: Double) -> ThemeColor {
        let amount = SpaceTheme.unit(amount)
        return ThemeColor(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                          blue: blue + (other.blue - blue) * amount)
    }

    /// White.
    public static let white = ThemeColor(red: 1, green: 1, blue: 1)
    /// Black.
    public static let black = ThemeColor(red: 0, green: 0, blue: 0)
}

extension ThemeColor: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let color = ThemeColor(hex: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a #rrggbb color: \(text)")
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// How a theme is drawn for the window's current conditions: whether it's light or dark, its
/// colors adjusted so the sidebar's text stays readable, and how strong the color and grain
/// layers are.
nonisolated public struct ResolvedSpaceTheme: Hashable, Sendable {
    /// Whether the sidebar is drawn dark, with light text.
    public var isDark: Bool
    /// The colors to draw, top to bottom and evenly spaced: the theme's colors, and for a
    /// gradient, readable stops between them.
    public var colors: [ThemeColor]
    /// The color layer's opacity over the system material, from 0 to 1.
    public var colorOpacity: Double
    /// The grain layer's opacity, from 0 to 1.
    public var grainOpacity: Double
}

extension SpaceTheme {
    /// How many parts each step of a gradient is split into for its contrast stops.
    static let gradientSteps = 8
    /// How much higher than the target a gradient's stops' contrast is.
    static let gradientMargin = 1.05
    /// The color layer's opacity at full transparency: a little color stays, so the theme still
    /// shows over the desktop.
    static let leastColorOpacity = 0.15
    /// The grain layer's opacity at full grain: subtle, like Arc's strongest.
    static let mostGrainOpacity = 0.3
    /// The system material's color behind the theme, roughly, in the light and dark appearances,
    /// for working out contrast where the color is see-through.
    static let lightMaterial = ThemeColor(red: 0.93, green: 0.93, blue: 0.93)
    static let darkMaterial = ThemeColor(red: 0.16, green: 0.16, blue: 0.16)
    /// The sidebar's text color, roughly, in the light and dark appearances.
    static let lightText = ThemeColor(red: 0.1, green: 0.1, blue: 0.1)
    static let darkText = ThemeColor(red: 0.95, green: 0.95, blue: 0.95)

    /// How to draw the theme.
    ///
    /// - Parameters:
    ///   - systemIsDark: Whether the system appearance is dark, for the automatic mode.
    ///   - reduceTransparency: Accessibility's Reduce Transparency, which makes the theme solid.
    ///   - increaseContrast: Accessibility's Increase Contrast, which halves the grain and raises
    ///     the text contrast the colors must leave from 4.5:1 to 7:1.
    ///   - isActive: Whether the window is the active one; an inactive window's colors fade
    ///     toward the system's, like other Mac windows.
    public func resolved(systemIsDark: Bool, reduceTransparency: Bool = false, increaseContrast: Bool = false,
                         isActive: Bool = true) -> ResolvedSpaceTheme {
        let isDark = switch mode {
        case .automatic: systemIsDark
        case .light: false
        case .dark: true
        }
        let colorOpacity = reduceTransparency ? 1 : 1 - transparency * (1 - Self.leastColorOpacity)
        let material = isDark ? Self.darkMaterial : Self.lightMaterial
        let text = isDark ? Self.darkText : Self.lightText
        let target = increaseContrast ? 7.0 : 4.5
        // A gradient's stops aim a little higher, since the colors drawn between two stops can
        // dip slightly below both.
        let stopTarget = colors.count > 1 ? target * Self.gradientMargin : target
        func readable(_ color: ThemeColor) -> ThemeColor {
            Self.readable(color, over: material, opacity: colorOpacity, text: text, toward: isDark ? .black : .white, target: stopTarget)
        }
        let stops = colors.map { readable(isActive ? $0 : $0.mixed(with: material, amount: 0.3)) }
        // Between two colors a gradient can be darker or lighter than both (red to green dips
        // through a dull olive), so stops every eighth of the way are made readable too.
        var drawn = [stops[0]]
        for (from, to) in zip(stops, stops.dropFirst()) {
            for step in 1..<Self.gradientSteps {
                drawn.append(readable(from.mixed(with: to, amount: Double(step) / Double(Self.gradientSteps))))
            }
            drawn.append(to)
        }
        return ResolvedSpaceTheme(
            isDark: isDark,
            colors: drawn,
            colorOpacity: colorOpacity,
            grainOpacity: grain * Self.mostGrainOpacity * (increaseContrast ? 0.5 : 1)
        )
    }

    /// The color mixed toward `base` (white for a light theme, black for a dark one) only as
    /// far as needed for `text` to reach `target` contrast over it, where the color lies at
    /// `opacity` over `material`.
    static func readable(_ color: ThemeColor, over material: ThemeColor, opacity: Double, text: ThemeColor,
                         toward base: ThemeColor, target: Double) -> ThemeColor {
        func shown(_ color: ThemeColor) -> ThemeColor { material.mixed(with: color, amount: opacity) }
        if text.contrast(with: shown(color)) >= target { return color }
        // Contrast only grows as the color nears the base, so search for the least mix that's enough.
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if text.contrast(with: shown(color.mixed(with: base, amount: middle))) >= target { high = middle } else { low = middle }
        }
        return color.mixed(with: base, amount: high)
    }
}
