import AxoCore
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

@MainActor
struct SpaceSettingsModelTests {
    let store: TabStore
    let model: BrowserModel

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        await model.start()
    }

    @Test func spacesGetAColorAndIcon() async throws {
        let home = try #require(model.space)
        await model.setSpaceAppearance(home.id, color: .teal, icon: "leaf")
        try await waitUntil { model.space?.icon == "leaf" }
        #expect(model.space?.spaceColor == .teal)
        await model.setSpaceAppearance(home.id, color: nil, icon: nil)
        try await waitUntil { model.space?.icon == nil }
        #expect(model.space?.spaceColor == nil)
    }

    @Test func spacesReorder() async throws {
        let home = try #require(model.space)
        await model.createSpace(name: "Work")
        try await waitUntil { model.spaces.count == 2 }
        let work = try #require(model.spaces.last)
        await model.moveSpace(work.id, after: nil)
        try await waitUntil { model.spaces.map(\.id) == [work.id, home.id] }
    }

    @Test func colorsAndIconsHaveStableNamesAndSpokenTitles() {
        #expect(SpaceColor(rawValue: "pink") == .pink)
        #expect(SpaceColor.allCases.count == 12)
        #expect(SpaceColor.blue.title == "Blue")
        #expect(SpaceIcon.title(for: "briefcase") == "Briefcase")
        #expect(SpaceIcon.title(for: "unknown.symbol") == "unknown.symbol")
        #expect(Set(SpaceIcon.all.map(\.symbol)).count == SpaceIcon.all.count, "No duplicates")
    }
}
