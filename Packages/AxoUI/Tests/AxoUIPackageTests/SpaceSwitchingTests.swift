import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct SpaceSwitchingTests {
    let store: TabStore
    let pool: WebViewPool
    let model: BrowserModel
    let directory: URL

    init() async throws {
        store = try TabStore.makeInMemory()
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        model = BrowserModel(store: store, pool: pool)
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoSpaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
    }

    private func page(_ name: String) throws -> URL {
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func creatingASpaceSwitchesToItAndSharesTheProfileByDefault() async throws {
        let home = try #require(model.space)
        await model.createSpace(name: "Work")

        #expect(model.spaces.map(\.name) == ["Home", "Work"])
        #expect(model.space?.name == "Work")
        #expect(model.space?.profileID == home.profileID)
        #expect(model.tabs.isEmpty)
    }

    @Test func aSeparateProfileGetsItsOwnWebsiteData() async throws {
        let home = try #require(model.space)
        await model.createSpace(name: "Banking", newProfileName: "Banking")
        let banking = try #require(model.space)

        #expect(banking.profileID != home.profileID)
        #expect(pool.dataStore(for: banking.profileID) !== pool.dataStore(for: home.profileID))
        #expect(await model.profiles().map(\.name).contains("Banking"))
    }

    @Test func eachSpaceRemembersItsSelectedTab() async throws {
        let home = try #require(model.space)
        await model.openTab(url: try page("a"))
        await model.openTab(url: try page("b"))
        let first = try #require(model.tabs.first?.id)
        model.select(first)

        await model.createSpace(name: "Work")
        await model.openTab(url: try page("w"))
        #expect(model.tabs.map(\.url.lastPathComponent) == ["w.html"])

        await model.selectSpace(home.id)
        #expect(model.tabs.map(\.url.lastPathComponent) == ["a.html", "b.html"])
        #expect(model.selectedTabID == first)
    }

    @Test func nextAndPreviousWrapAroundAndIndexesSelect() async throws {
        await model.createSpace(name: "Work")
        await model.createSpace(name: "Play")
        #expect(model.space?.name == "Play")

        await model.selectNextSpace()
        #expect(model.space?.name == "Home")
        await model.selectPreviousSpace()
        #expect(model.space?.name == "Play")
        await model.selectSpace(at: 1)
        #expect(model.space?.name == "Work")
        await model.selectSpace(at: 7)
        #expect(model.space?.name == "Work", "Out-of-range indexes do nothing")
    }

    @Test func deletingTheShownSpaceClosesItsTabsAndShowsANeighbor() async throws {
        await model.createSpace(name: "Work")
        await model.openTab(url: try page("w"))
        let workTab = try #require(model.selectedTabID)
        #expect(pool.isLive(workTab))
        let work = try #require(model.space)

        await model.deleteSpace(work.id)

        #expect(model.spaces.map(\.name) == ["Home"])
        #expect(model.space?.name == "Home")
        #expect(!pool.isLive(workTab))
        #expect(try await store.tab(id: workTab) == nil)
    }

    @Test func theLastSpaceStays() async throws {
        let home = try #require(model.space)
        await model.deleteSpace(home.id)
        #expect(model.spaces.map(\.id) == [home.id])
        #expect(model.alertMessage == nil)
    }

    @Test func renamingUpdatesTheSwitcherAndTheShownSpace() async throws {
        let home = try #require(model.space)
        await model.renameSpace(home.id, to: "Personal")
        #expect(model.space?.name == "Personal")
        #expect(model.spaces.first?.name == "Personal")
    }

    @Test func launchOpensTheRememberedSpaceAndReportsChanges() async throws {
        await model.createSpace(name: "Work")
        let work = try #require(model.space)

        var reported: [Space.ID] = []
        let relaunched = BrowserModel(store: store, pool: pool, initialSpaceID: work.id)
        relaunched.onSpaceChange = { reported.append($0) }
        await relaunched.start()

        #expect(relaunched.space?.id == work.id)
        #expect(reported == [work.id])

        let fallback = BrowserModel(store: store, pool: pool, initialSpaceID: UUID())
        await fallback.start()
        #expect(fallback.space?.name == "Home", "A missing Space falls back to the first")
    }

    /// Changes made elsewhere, such as by iCloud sync, reach the shown Space.
    @Test func theShownSpaceFollowsRenamesAndDeletionsFromElsewhere() async throws {
        let home = try #require(model.space)
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        try await waitUntil { model.spaces.count == 2 }

        try await store.renameSpace(id: home.id, to: "Personal")
        try await waitUntil { model.space?.name == "Personal" }

        await model.selectSpace(work.id)
        try await store.deleteSpace(id: work.id)
        try await waitUntil { model.space?.id == home.id }
        #expect(model.spaces.map(\.id) == [home.id])
    }
}
