import AxoCore
import SwiftUI

#if os(macOS)
import AppKit

/// Draws the shown Space's theme behind the sidebar (#137) and gives the sidebar's content the
/// theme's light or dark appearance, so its text, icons, and selection read on any theme. With
/// no theme, the sidebar keeps the system's material and the window's own appearance.
///
/// The theme is resolved here, from the window's appearance (before this view overrides it for
/// the sidebar), Reduce Transparency, Increase Contrast, and whether the window is active.
struct SpaceThemeModifier: ViewModifier {
    let theme: SpaceTheme?
    /// The Space shown, so switching Spaces cross-fades the background while editing a theme
    /// changes it at once.
    let spaceID: Space.ID?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        let resolved = theme?.resolved(systemIsDark: colorScheme == .dark, reduceTransparency: reduceTransparency,
                                       increaseContrast: contrast == .increased, isActive: appearsActive)
        content
            .environment(\.colorScheme, resolved.map { $0.isDark ? .dark : .light } ?? colorScheme)
            .background {
                ZStack {
                    if let resolved {
                        SpaceThemeBackground(theme: resolved)
                            // One view per Space, so a change of Space cross-fades from the old
                            // look to the new one, while editing changes it in place.
                            .id(spaceID)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: spaceID)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

/// A resolved theme's layers: the system's behind-window material in the theme's appearance,
/// the color (or gradient) over it as solid as the transparency allows, and a tiled grain
/// texture, pre-rendered once, so it costs nothing while scrolling or resizing.
struct SpaceThemeBackground: View {
    let theme: ResolvedSpaceTheme

    var body: some View {
        ZStack {
            ThemeMaterial(isDark: theme.isDark)
            fill.opacity(theme.colorOpacity)
            if theme.grainOpacity > 0 {
                Image(decorative: ThemeGrain.image, scale: 2)
                    .resizable(resizingMode: .tile)
                    // Overlay leaves mid-gray neutral, so grain adds texture without graying the color.
                    .blendMode(.overlay)
                    .opacity(theme.grainOpacity)
            }
        }
    }

    @ViewBuilder
    private var fill: some View {
        let colors = theme.colors.map(Color.init(themeColor:))
        if colors.count == 1 {
            colors[0]
        } else {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The system's sidebar material, blending with what's behind the window, in a light or dark
/// appearance of its own. It dims with the window, as other Mac windows' sidebars do.
private struct ThemeMaterial: NSViewRepresentable {
    let isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

/// The grain texture: gray noise, made once from a fixed seed so it never shimmers, and tiled.
enum ThemeGrain {
    /// The tile's size in pixels.
    static let size = 128

    /// The tile: gray pixels spread evenly from black to white, averaging mid-gray.
    static let image: CGImage = makeImage()

    private static func makeImage() -> CGImage {
        var state: UInt32 = 0x2545_F491
        var pixels = [UInt8](repeating: 0, count: size * size)
        for index in pixels.indices {
            // xorshift: cheap, and the same every launch.
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            pixels[index] = UInt8(truncatingIfNeeded: state % 256)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
#endif
