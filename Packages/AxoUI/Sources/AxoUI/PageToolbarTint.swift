import AxoWeb
import SwiftUI

/// Settings › General's "Tint the toolbar to match the page" (#107).
nonisolated public enum ToolbarTintSettings {
    /// The `@AppStorage` key, in the store the app picks (UI tests have their own). On by default.
    public static let storageKey = "tintsToolbarFromPage"
}

/// What the toolbar above the page is tinted with: the page's color.
nonisolated struct ToolbarTint: Equatable, Sendable {
    /// The background color.
    var color: PageColor

    /// The tint for a page's colors, or `nil` to leave the toolbar as it is: tinting is off, the
    /// navigation bar is in the sidebar (where the page has no toolbar of its own), or the page
    /// offers no color.
    static func tint(for colors: PageColors?, isDark: Bool, isEnabled: Bool, placement: NavigationBarPlacement) -> ToolbarTint? {
        guard showsTint(isEnabled: isEnabled, placement: placement), let color = colors?.color(isDark: isDark) else { return nil }
        return ToolbarTint(color: color)
    }

    /// Whether the toolbar shows pages' colors at all, so the pool reads them
    /// (`WebViewPool.readsPageColors`): the setting is on and the navigation bar is above the page.
    static func showsTint(isEnabled: Bool, placement: NavigationBarPlacement) -> Bool {
        isEnabled && placement == .page
    }
}

#if os(macOS)
/// Tints the window toolbar to the shown page's color, as Safari does, when the navigation bar
/// sits above the page and the setting is on. The bar has no text of its own (the title is
/// removed), and its glass buttons and address field pick their own text color for what's
/// behind them, so they stay readable on any color; forcing the toolbar's dark appearance on dark
/// colors made white text on pale tinted glass. The sidebar's list keeps Axo's own colors.
struct PageToolbarTint: ViewModifier {
    let page: WebTabState?
    /// The pool, told whether to read pages' colors while this toolbar shows them.
    let pool: WebViewPool
    let placement: NavigationBarPlacement
    @AppStorage(ToolbarTintSettings.storageKey) private var isEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let tint = ToolbarTint.tint(for: page?.pageColors, isDark: colorScheme == .dark, isEnabled: isEnabled, placement: placement)
        // One view either way (the page column must never be rebuilt, or its page would remount);
        // only the toolbar's style changes. No animation: one here would also animate whatever
        // else changes in the page column in the same update (a split opening, a notice).
        content
            .toolbarBackground(tint.map { Color(pageColor: $0.color) } ?? Color.clear, for: .windowToolbar)
            .toolbarBackgroundVisibility(tint == nil ? .automatic : .visible, for: .windowToolbar)
            .onChange(of: ToolbarTint.showsTint(isEnabled: isEnabled, placement: placement), initial: true) { _, shows in
                pool.readsPageColors = shows
            }
    }
}

extension Color {
    /// The SwiftUI color for a page's sRGB color.
    init(pageColor: PageColor) {
        self.init(.sRGB, red: pageColor.red, green: pageColor.green, blue: pageColor.blue, opacity: pageColor.alpha)
    }
}
#endif
