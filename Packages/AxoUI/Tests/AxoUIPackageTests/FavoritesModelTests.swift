import AxoCore
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

@MainActor
struct FavoritesModelTests {
    let store: TabStore
    let model: BrowserModel

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        await model.start()
    }

    /// Opens and selects a tab on a page that never loads (a closed loopback port).
    private func openTab(_ path: String) async throws -> AxoCore.Tab.ID {
        await model.openTab(url: URL(string: "http://127.0.0.1:9/\(path)")!)
        return try #require(model.selectedTabID)
    }

    @Test func aTabBecomesAFavoriteWithoutReloading() async throws {
        let id = try await openTab("mail")
        let webView = try #require(model.pool.liveWebView(for: id))

        await model.addToFavorites(id)
        #expect(model.favorites.map(\.id) == [id])
        #expect(!model.tabs.contains { $0.id == id }, "It leaves the sidebar's tabs")
        #expect(model.selectedTabID == id && model.selectedTab == nil)
        #expect(model.shownTab?.id == id, "It's still showing")
        #expect(model.pool.liveWebView(for: id) === webView, "Same page, no reload")
    }

    @Test func favoritesAreSharedByTheProfilesSpaces() async throws {
        let id = try await openTab("mail")
        await model.addToFavorites(id)
        let home = try #require(model.space)
        let webView = try #require(model.pool.liveWebView(for: id))

        await model.createSpace(name: "Work")
        try await waitUntil { model.space?.name == "Work" }
        #expect(model.favorites.map(\.id) == [id], "Same profile, same favorites")
        model.select(id)
        #expect(model.pool.liveWebView(for: id) === webView, "The same page in every Space")

        await model.createSpace(name: "Private", newProfileName: "Private")
        try await waitUntil { model.space?.name == "Private" }
        try await waitUntil { model.favorites.isEmpty }
        #expect(model.shownTab == nil, "Another profile doesn't show it")

        await model.selectSpace(home.id)
        try await waitUntil { model.favorites.map(\.id) == [id] }
    }

    @Test func closingUnloadsAndRemovingDeletes() async throws {
        let tab = try await openTab("news")
        let id = try await openTab("mail")
        await model.addToFavorites(id)

        await model.closeSelectedTab()
        #expect(model.pool.liveWebView(for: id) == nil, "Its page unloads")
        #expect(model.favorites.map(\.id) == [id], "It stays a favorite")
        #expect(model.selectedTabID == tab, "The sidebar's first tab shows")

        await model.removeFavorite(id)
        #expect(model.favorites.isEmpty)
        try await waitUntilAsync { try await store.favorites.favorites(for: model.space!.profileID).isEmpty }
    }

    @Test func aFavoriteGoesBackToPinnedKeepingItsPage() async throws {
        let id = try await openTab("mail")
        await model.addToFavorites(id)
        let webView = try #require(model.pool.liveWebView(for: id))
        await model.moveFavoriteToPinned(id)
        #expect(model.favorites.isEmpty)
        #expect(model.selectedTab?.isPinned == true)
        #expect(model.pool.liveWebView(for: id) === webView)
    }

    @Test func favoritesReorderAndOpenByNumber() async throws {
        let profileID = try #require(model.space).profileID
        let a = try await store.favorites.add(url: URL(string: "http://127.0.0.1:9/a")!, profileID: profileID)
        let b = try await store.favorites.add(url: URL(string: "http://127.0.0.1:9/b")!, profileID: profileID)
        try await waitUntil { model.favorites.count == 2 }

        await model.moveFavorite(b.id, by: -1)
        try await waitUntil { model.favorites.map(\.id) == [b.id, a.id] }
        model.showFavorite(at: 1)
        #expect(model.selectedTabID == a.id && model.shownTab?.url == a.url)
        model.showFavorite(at: 5)
        #expect(model.selectedTabID == a.id, "No favorite there")
    }

    @Test func theCommandBarFindsFavorites() async throws {
        let profileID = try #require(model.space).profileID
        let favorite = try await store.favorites.add(url: URL(string: "http://127.0.0.1:9/inbox")!, title: "Inbox", profileID: profileID)
        try await waitUntil { model.favorites.count == 1 }
        model.showCommandBar()
        model.setCommandQuery("Inbox")
        #expect(model.commandResults.contains { if case .tab(let tab) = $0 { tab.id == favorite.id } else { false } })
    }
}
