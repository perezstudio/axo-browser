import Foundation
import Testing
@testable import AxoCore

/// Space themes (#137): storing them, and drawing them so the sidebar stays readable.
struct SpaceThemeTests {
    let blue = ThemeColor(hex: "#2a6f97")!

    @Test func colorsReadAndWriteAsHex() {
        #expect(ThemeColor(hex: "#336699") == ThemeColor(red: 0x33 / 255, green: 0x66 / 255, blue: 0x99 / 255))
        #expect(ThemeColor(hex: "FFCC00")?.hex == "#ffcc00")
        for text in ["", "#fff", "#12345", "#1234567", "#gg0000", "red", "#-12345"] {
            #expect(ThemeColor(hex: text) == nil, "\(text)")
        }
    }

    @Test func themesKeepOneToThreeColorsAndClampTheirNumbers() {
        let many = SpaceTheme(colors: Array(repeating: blue, count: 5), transparency: 2, grain: -1)
        #expect(many.colors.count == SpaceTheme.maxColors)
        #expect(many.transparency == 1 && many.grain == 0)
        #expect(SpaceTheme(colors: []).colors.count == 1, "A theme always has a color")
        var theme = SpaceTheme(colors: [blue])
        theme.transparency = .nan
        theme.grain = 7
        #expect(theme.transparency == 0 && theme.grain == 1)
    }

    @Test func decodingForgivesWhatAnotherDeviceSends() throws {
        func decode(_ json: String) -> SpaceTheme? {
            try? JSONDecoder().decode(SpaceTheme.self, from: Data(json.utf8))
        }
        let theme = try #require(decode(##"{"colors":["#2a6f97","nope","#ffffff"],"mode":"sepia","transparency":3,"grain":0.5,"future":true}"##))
        #expect(theme.colors.map(\.hex) == ["#2a6f97", "#ffffff"], "Unreadable colors are dropped")
        #expect(theme.mode == .automatic, "Unknown modes are automatic")
        #expect(theme.transparency == 1 && theme.grain == 0.5)
        #expect(decode(##"{"colors":["#2a6f97"]}"##) == SpaceTheme(colors: [blue]), "Missing values take their defaults")
        #expect(decode(##"{"colors":[]}"##) == nil, "No color, no theme")

        let original = SpaceTheme(colors: [blue, .white], mode: .dark, transparency: 0.25, grain: 0.75)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SpaceTheme.self, from: data) == original)
    }

    @Test func automaticFollowsTheSystemAndTheOtherModesDont() {
        let theme = SpaceTheme(colors: [blue], mode: .automatic)
        #expect(theme.resolved(systemIsDark: true).isDark)
        #expect(!theme.resolved(systemIsDark: false).isDark)
        #expect(SpaceTheme(colors: [blue], mode: .dark).resolved(systemIsDark: false).isDark)
        #expect(!SpaceTheme(colors: [blue], mode: .light).resolved(systemIsDark: true).isDark)
    }

    /// The contrast the sidebar's text has over a resolved color, as drawn over the material.
    private func textContrast(_ resolved: ResolvedSpaceTheme, _ index: Int = 0) -> Double {
        let material = resolved.isDark ? SpaceTheme.darkMaterial : SpaceTheme.lightMaterial
        let text = resolved.isDark ? SpaceTheme.darkText : SpaceTheme.lightText
        return text.contrast(with: material.mixed(with: resolved.colors[index], amount: resolved.colorOpacity))
    }

    @Test func readableColorsAreLeftAsChosen() {
        let pale = ThemeColor(hex: "#e8f1f8")!
        #expect(SpaceTheme(colors: [pale], mode: .light).resolved(systemIsDark: false).colors == [pale])
        let deep = ThemeColor(hex: "#14213d")!
        #expect(SpaceTheme(colors: [deep], mode: .dark).resolved(systemIsDark: false).colors == [deep])
    }

    @Test func midLuminanceColorsAreAdjustedJustEnoughForTheText() {
        // Mid-luminance colors read poorly with either black or white text.
        for hex in ["#808080", "#2a6f97", "#e07a5f", "#3d9970", "#ff00ff", "#ffff00", "#000080"] {
            let color = ThemeColor(hex: hex)!
            for mode in [SpaceTheme.Mode.light, .dark] {
                let resolved = SpaceTheme(colors: [color], mode: mode).resolved(systemIsDark: false)
                #expect(textContrast(resolved) >= 4.5, "\(hex) \(mode)")
                #expect(textContrast(resolved) < 4.8 || resolved.colors[0] == color, "\(hex) \(mode): adjusted no further than needed")
                let strict = SpaceTheme(colors: [color], mode: mode).resolved(systemIsDark: false, increaseContrast: true)
                #expect(textContrast(strict) >= 7, "\(hex) \(mode) with Increase Contrast")
            }
        }
    }

    @Test func everyColorOfAGradientIsReadable() {
        let gradient = SpaceTheme(colors: [ThemeColor(hex: "#ffffff")!, ThemeColor(hex: "#777777")!, ThemeColor(hex: "#000000")!], mode: .dark)
        let resolved = gradient.resolved(systemIsDark: false)
        #expect(resolved.colors.count == 3)
        for index in resolved.colors.indices { #expect(textContrast(resolved, index) >= 4.5, "Color \(index)") }
    }

    @Test func transparencyShowsTheMaterialUnlessReduceTransparencyIsOn() {
        let theme = SpaceTheme(colors: [blue], transparency: 1)
        #expect(abs(theme.resolved(systemIsDark: false).colorOpacity - SpaceTheme.leastColorOpacity) < 1e-9, "A little color stays")
        #expect(SpaceTheme(colors: [blue], transparency: 0).resolved(systemIsDark: false).colorOpacity == 1)
        #expect(theme.resolved(systemIsDark: false, reduceTransparency: true).colorOpacity == 1)
        for mode in [SpaceTheme.Mode.light, .dark] {
            let seeThrough = SpaceTheme(colors: [ThemeColor(hex: "#808080")!], mode: mode, transparency: 0.5).resolved(systemIsDark: false)
            #expect(textContrast(seeThrough) >= 4.5, "\(mode)")
        }
    }

    @Test func increaseContrastHalvesTheGrain() {
        let theme = SpaceTheme(colors: [blue], grain: 1)
        #expect(theme.resolved(systemIsDark: false).grainOpacity == SpaceTheme.mostGrainOpacity)
        #expect(theme.resolved(systemIsDark: false, increaseContrast: true).grainOpacity == SpaceTheme.mostGrainOpacity / 2)
        #expect(SpaceTheme(colors: [blue]).resolved(systemIsDark: false).grainOpacity == 0)
    }

    @Test func anInactiveWindowsColorsFadeTowardTheSystems() {
        let theme = SpaceTheme(colors: [ThemeColor(hex: "#e63946")!], mode: .light)
        let active = theme.resolved(systemIsDark: false)
        let inactive = theme.resolved(systemIsDark: false, isActive: false)
        let material = SpaceTheme.lightMaterial
        #expect(inactive.colors[0].contrast(with: material) < active.colors[0].contrast(with: material))
        #expect(textContrast(inactive) >= 4.5)
    }
}
