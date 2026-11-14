import Testing
@testable import AxoUI

/// The Settings window's panes and the sidebar's search (#85).
struct SettingsPaneTests {
    @Test func panesAreInTheBoardsOrder() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Profiles", "Spaces", "Link Routing", "Site Customizations", "iCloud"])
    }

    @Test func rawValuesStayStableForTheRememberedPane() {
        // Settings remembers the last pane by raw value; renaming one would forget it.
        #expect(SettingsPane.allCases.map(\.rawValue) == ["general", "profiles", "spaces", "linkRouting", "siteCustomizations", "iCloud"])
        #expect(SettingsPane.linkRouting.rowIdentifier == "settingsPane.linkRouting")
    }

    @Test func everyPaneHasASymbolAndKeywords() {
        for pane in SettingsPane.allCases {
            #expect(!pane.systemImage.isEmpty)
            #expect(!pane.keywords.isEmpty, "\(pane) can be found by its settings")
        }
    }

    @Test func anEmptyQueryShowsEveryPane() {
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "") == SettingsPane.allCases)
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "   ") == SettingsPane.allCases)
    }

    @Test func searchFindsAPaneByItsSettings() {
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "navigation bar") == [.general])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "cookies") == [.profiles])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "CSS") == [.siteCustomizations])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "sync") == [.iCloud])
    }

    @Test func searchMatchesTitlesIgnoringCaseAndAccents() {
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "link rout") == [.linkRouting])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "PRÓFILES") == [.profiles])
    }

    @Test func everyWordMustMatch() {
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "theme icon") == [.spaces])
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "sync cookies").isEmpty)
        #expect(SettingsPane.filtered(SettingsPane.allCases, by: "zebra").isEmpty)
    }

    @Test func filteringKeepsTheOfferedPanesOrder() {
        let withoutICloud = SettingsPane.allCases.filter { $0 != .iCloud }
        #expect(SettingsPane.filtered(withoutICloud, by: "sync").isEmpty, "No iCloud pane, no match")
        #expect(SettingsPane.filtered(withoutICloud, by: "profile") == [.profiles, .spaces])
    }
}
