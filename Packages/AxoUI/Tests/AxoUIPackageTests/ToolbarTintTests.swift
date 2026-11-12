import AxoWeb
import Testing
@testable import AxoUI

/// When the toolbar above the page takes the page's color (#107).
struct ToolbarTintTests {
    let colors = PageColors(themeColors: [
        (color: "rgb(155, 42, 92)", media: ""),
        (color: "rgb(28, 27, 31)", media: "(prefers-color-scheme: dark)"),
    ], topColor: nil)

    @Test func tintsAbovePageWithTheAppearancesColor() {
        #expect(ToolbarTint.tint(for: colors, isDark: false, isEnabled: true, placement: .page)?.color == PageColor(css: "rgb(155, 42, 92)"))
        #expect(ToolbarTint.tint(for: colors, isDark: true, isEnabled: true, placement: .page)?.color == PageColor(css: "rgb(28, 27, 31)"))
    }

    @Test func leavesTheToolbarAloneOtherwise() {
        #expect(ToolbarTint.tint(for: colors, isDark: false, isEnabled: false, placement: .page) == nil, "The setting is off")
        #expect(ToolbarTint.tint(for: colors, isDark: false, isEnabled: true, placement: .sidebar) == nil, "The navigation bar is in the sidebar")
        #expect(ToolbarTint.tint(for: nil, isDark: false, isEnabled: true, placement: .page) == nil, "The page hasn't loaded")
        #expect(ToolbarTint.tint(for: PageColors(), isDark: false, isEnabled: true, placement: .page) == nil, "It offers no color")
    }
}
