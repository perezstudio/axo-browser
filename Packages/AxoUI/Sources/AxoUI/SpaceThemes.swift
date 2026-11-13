import AxoCore
import SwiftUI

/// A Space theme being edited (#137): the Space, the theme it had, and the draft the window
/// shows while the editor is open. Cancel restores ``original``.
nonisolated public struct ThemeEditing: Equatable, Sendable {
    /// The Space whose theme is edited.
    public var spaceID: Space.ID
    /// Its theme when editing began (`nil` is the system's material).
    public var original: SpaceTheme?
    /// The theme as edited so far.
    public var draft: SpaceTheme?
    /// Where the editor shows: a popover over the sidebar's Space dots, or a sheet in Settings.
    public var placement: Placement
    /// Whether the editor is open. After Done it closes while the draft stays shown until the
    /// saved theme has been read back.
    public var isOpen = true

    /// Where the theme editor shows.
    public enum Placement: Sendable {
        /// A popover from a Space's context menu in the sidebar.
        case sidebar
        /// A sheet in Settings › Spaces.
        case settings
    }
}

/// Ready-made themes, as in Arc: soft colors and gradients that stay out of the page's way.
/// Axo's own pinks are left out on purpose: pink is an accent, never a large surface
/// (CLAUDE.md's brand rules), though anyone can still choose it as a custom color.
nonisolated enum ThemePreset: CaseIterable, Identifiable {
    case sky, sage, sand, lavender, slate, ocean, dusk, forest, ember, midnight

    var id: Self { self }

    /// The preset's name, for VoiceOver and tooltips.
    var title: String {
        switch self {
        case .sky: "Sky"
        case .sage: "Sage"
        case .sand: "Sand"
        case .lavender: "Lavender"
        case .slate: "Slate"
        case .ocean: "Ocean"
        case .dusk: "Dusk"
        case .forest: "Forest"
        case .ember: "Ember"
        case .midnight: "Midnight"
        }
    }

    /// The preset's colors, top to bottom, as `#rrggbb`.
    var hexColors: [String] {
        switch self {
        case .sky: ["#cfe3f5"]
        case .sage: ["#d6e4d3"]
        case .sand: ["#efe3cf"]
        case .lavender: ["#e1dcf2"]
        case .slate: ["#3b4552"]
        case .ocean: ["#2a6f97", "#33718f"]
        case .dusk: ["#5b4b8a", "#8a5a44"]
        case .forest: ["#2d4a3e", "#3e6b4c"]
        case .ember: ["#7a2e2e", "#a8432f"]
        case .midnight: ["#14213d", "#1f3a5f", "#3a506b"]
        }
    }

    /// The preset as a theme: the light ones light, the deep ones dark. Each color is readable as
    /// it is (4.5:1 for the sidebar's text), so presets show exactly as their swatches.
    var theme: SpaceTheme {
        let colors = hexColors.compactMap(ThemeColor.init(hex:))
        let isLight = (colors.map(\.luminance).reduce(0, +) / Double(colors.count)) > 0.4
        return SpaceTheme(colors: colors, mode: isLight ? .light : .dark)
    }
}

extension Color {
    /// The SwiftUI color for a theme color.
    nonisolated init(themeColor: ThemeColor) {
        self.init(.sRGB, red: themeColor.red, green: themeColor.green, blue: themeColor.blue)
    }
}

extension ThemeColor {
    /// A theme color from a SwiftUI color (from the color picker), in sRGB; colors outside sRGB
    /// are clamped.
    init(color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }

    /// The system's spoken name for the color, such as "dark blue", for VoiceOver.
    var spokenName: String {
        #if os(macOS)
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).accessibilityName
        #else
        UIColor(red: red, green: green, blue: blue, alpha: 1).accessibilityName
        #endif
    }
}

extension Space {
    /// The color that marks the Space (its dot, its icon): its palette color, or its theme's
    /// first color when it has a theme and no palette color.
    var markerColor: Color? {
        spaceColor?.color ?? theme.map { Color(themeColor: $0.colors[0]) }
    }
}

extension BrowserModel {
    /// The theme the shown Space's window background uses: the draft while it's being edited,
    /// otherwise its saved theme.
    public var shownTheme: SpaceTheme? {
        guard let space else { return nil }
        if let themeEditing, themeEditing.spaceID == space.id { return themeEditing.draft }
        // The latest record: `spaces` can be read back (after Done) a moment before `space`.
        return (spaces.first { $0.id == space.id } ?? space).theme
    }

    /// Opens the theme editor for a Space. The window shows the draft as it changes when that
    /// Space is shown.
    public func beginEditingTheme(for spaceID: Space.ID, in placement: ThemeEditing.Placement) {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return }
        themeEditing = ThemeEditing(spaceID: spaceID, original: space.theme, draft: space.theme, placement: placement)
    }

    /// Changes the theme being edited, which the window shows at once.
    public func previewTheme(_ theme: SpaceTheme?) {
        guard themeEditing?.isOpen == true, themeEditing?.draft != theme else { return }
        themeEditing?.draft = theme
    }

    /// Closes the theme editor: Done saves the draft, Cancel puts the old theme back. After
    /// Done the draft stays shown until the saved Space has been read back, so the old theme
    /// never flashes. Only the first call counts (Esc and the popover closing both end up here).
    public func finishEditingTheme(save: Bool) async {
        guard var editing = themeEditing, editing.isOpen else { return }
        guard save, editing.draft != editing.original else {
            themeEditing = nil
            return
        }
        editing.isOpen = false
        themeEditing = editing
        await setSpaceTheme(editing.spaceID, theme: editing.draft)
        // Every read from here on sees the saved theme; one can be dropped for a newer read
        // still on its way, so read until one lands.
        for _ in 0..<3 where spaces.first(where: { $0.id == editing.spaceID })?.theme != editing.draft {
            _ = try? await refreshSpaces()
        }
        // A newer editor may have opened meanwhile.
        if themeEditing == editing { themeEditing = nil }
    }

    /// Sets a Space's theme; `nil` goes back to the system's material.
    public func setSpaceTheme(_ spaceID: Space.ID, theme: SpaceTheme?) async {
        do {
            try await store.setSpaceTheme(id: spaceID, theme: theme)
        } catch {
            report(error, "Axo couldn't change the Space's theme.")
        }
    }
}
