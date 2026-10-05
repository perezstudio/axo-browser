import AxoCore
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

@MainActor
struct ProfileManagementTests {
    let store: TabStore
    let model: BrowserModel
    private let removed = Removed()

    private final class Removed {
        var profiles: [Profile.ID] = []
    }

    init() async throws {
        store = try TabStore.makeInMemory()
        let pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        let removed = removed
        pool.removeDataStore = { removed.profiles.append($0) }
        model = BrowserModel(store: store, pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    @Test func profilesAreListedAddedAndRenamed() async throws {
        try await waitUntil { model.allProfiles.count == 1 }
        let work = try #require(await model.addProfile(named: "work"))
        await model.renameProfile(work.id, to: "Work")
        try await waitUntil { model.allProfiles.map(\.name) == [TabStore.defaultProfileName, "Work"] }
        #expect(model.spaces(using: work.id).isEmpty)
        #expect(model.spaces(using: try #require(model.space).profileID).count == 1)
    }

    @Test func deletingAProfileMovesItsSpacesAndRemovesItsData() async throws {
        let home = try #require(model.space)
        let work = try #require(await model.addProfile(named: "Work"))
        await model.openTab(url: URL(string: "about:blank")!)
        let tabID = try #require(model.selectedTabID)
        let oldWebView = try #require(model.pool.liveWebView(for: tabID))

        await model.deleteProfile(home.profileID, movingSpacesTo: work.id)
        try await waitUntil { model.space?.profileID == work.id }
        #expect(removed.profiles == [home.profileID])
        #expect(model.allProfiles.map(\.id) == [work.id])
        #expect(model.selectedTabID == tabID, "The tab stays selected")
        #expect(model.pool.liveWebView(for: tabID) !== oldWebView, "Its page reloads with the new profile's data")
    }

    @Test func spacesMoveBetweenProfiles() async throws {
        let home = try #require(model.space)
        let work = try #require(await model.addProfile(named: "Work"))
        await model.moveSpace(home.id, toProfile: work.id)
        try await waitUntil { model.space?.profileID == work.id }
        #expect(model.spaces(using: work.id).map(\.id) == [home.id])
    }

    @Test func theLastProfileCantBeDeleted() async throws {
        let home = try #require(model.space)
        await model.deleteProfile(home.profileID, movingSpacesTo: nil)
        #expect(model.alertMessage != nil)
        #expect(removed.profiles.isEmpty)
    }
}
