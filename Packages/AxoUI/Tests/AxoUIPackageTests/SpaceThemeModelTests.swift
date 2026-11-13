import AxoCore
import Foundation
import SwiftUI
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Editing a Space's theme (#137): the window shows the draft, Cancel restores the old theme,
/// and Done saves it.
@MainActor
struct SpaceThemeModelTests {
    let store: TabStore
    let model: BrowserModel
    let ocean = ThemePreset.ocean.theme
    let sky = ThemePreset.sky.theme

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        await model.start()
    }

    @Test func theWindowShowsTheDraftWhileEditing() async throws {
        let home = try #require(model.space)
        #expect(model.shownTheme == nil, "Spaces start with the system's material")
        model.beginEditingTheme(for: home.id, in: .sidebar)
        model.previewTheme(ocean)
        #expect(model.shownTheme == ocean)
        #expect(try await store.spaces().first?.theme == nil, "Nothing is saved while editing")
    }

    @Test func cancelRestoresTheOldTheme() async throws {
        let home = try #require(model.space)
        await model.setSpaceTheme(home.id, theme: sky)
        try await waitUntil { model.space?.theme == sky }

        model.beginEditingTheme(for: home.id, in: .sidebar)
        model.previewTheme(ocean)
        await model.finishEditingTheme(save: false)
        #expect(model.themeEditing == nil)
        #expect(model.shownTheme == sky)
        #expect(try await store.spaces().first?.theme == sky)
    }

    @Test func doneSavesAndKeepsShowingTheDraftUntilItsSaved() async throws {
        let home = try #require(model.space)
        model.beginEditingTheme(for: home.id, in: .settings)
        model.previewTheme(ocean)
        await model.finishEditingTheme(save: true)
        #expect(model.themeEditing == nil)
        #expect(model.spaces.first { $0.id == home.id }?.theme == ocean, "The model read the saved Space back before closing")
        #expect(model.shownTheme == ocean, "So the old theme never flashes")
        #expect(try await store.spaces().first?.theme == ocean)
    }

    @Test func onlyTheFirstWayOfClosingCounts() async throws {
        // Esc cancels, then the popover closing asks to save: the cancel wins.
        let home = try #require(model.space)
        model.beginEditingTheme(for: home.id, in: .sidebar)
        model.previewTheme(ocean)
        await model.finishEditingTheme(save: false)
        await model.finishEditingTheme(save: true)
        #expect(try await store.spaces().first?.theme == nil)
    }

    @Test func theSystemMaterialIsAThemeChoiceToo() async throws {
        let home = try #require(model.space)
        await model.setSpaceTheme(home.id, theme: ocean)
        try await waitUntil { model.space?.theme == ocean }
        model.beginEditingTheme(for: home.id, in: .sidebar)
        model.previewTheme(nil)
        #expect(model.shownTheme == nil)
        await model.finishEditingTheme(save: true)
        #expect(try await store.spaces().first?.theme == nil)
    }

    @Test func aDraftShowsOnlyForItsOwnSpace() async throws {
        let home = try #require(model.space)
        await model.createSpace(name: "Work")
        try await waitUntil { model.spaces.count == 2 }
        let work = try #require(model.spaces.first { $0.id != home.id })
        await model.selectSpace(home.id)
        try await waitUntil { model.space?.id == home.id }
        model.beginEditingTheme(for: work.id, in: .settings)
        model.previewTheme(ocean)
        #expect(model.space?.id == home.id)
        #expect(model.shownTheme == nil, "Editing another Space's theme leaves the shown one's")
    }

    @Test func eachSpaceKeepsItsTheme() async throws {
        let home = try #require(model.space)
        await model.createSpace(name: "Work")
        try await waitUntil { model.spaces.count == 2 }
        let work = try #require(model.spaces.first { $0.id != home.id })
        await model.setSpaceTheme(home.id, theme: sky)
        await model.setSpaceTheme(work.id, theme: ocean)
        try await waitUntil { model.spaces.allSatisfy { $0.theme != nil } }

        await model.selectSpace(work.id)
        try await waitUntil { model.space?.id == work.id }
        #expect(model.shownTheme == ocean)
        await model.selectSpace(home.id)
        try await waitUntil { model.space?.id == home.id }
        #expect(model.shownTheme == sky)
    }

    @Test func aThemedSpaceIsMarkedWithItsFirstColorUnlessItHasOne() {
        var space = Space(profileID: UUID(), name: "Home", sortKey: "a0", theme: ocean)
        #expect(space.markerColor == Color(themeColor: ocean.colors[0]))
        space.color = SpaceColor.green.rawValue
        #expect(space.markerColor == SpaceColor.green.color)
        #expect(Space(profileID: UUID(), name: "Plain", sortKey: "a0").markerColor == nil)
    }

    @Test func presetsHaveNamesAndAreReadableAsTheyAre() {
        #expect(Set(ThemePreset.allCases.map(\.title)).count == ThemePreset.allCases.count)
        for preset in ThemePreset.allCases {
            let theme = preset.theme
            // Presets are chosen to need no adjustment for their text in either system appearance.
            for systemIsDark in [false, true] {
                #expect(theme.resolved(systemIsDark: systemIsDark).colors == theme.colors, "\(preset.title)")
            }
        }
    }

    @Test func presetsLeaveOutAxosPinks() {
        let pinks = ["#9b2a5c", "#ff9ec2", "#ffeef3"]
        for preset in ThemePreset.allCases {
            #expect(preset.hexColors.allSatisfy { !pinks.contains($0) }, "\(preset.title)")
        }
    }
}
