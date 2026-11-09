import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Pinned tabs and favorites show their icons with no page loaded: at launch, after a reset to
/// their home page, and when their home redirects to another host (#160).
@MainActor
struct SavedFaviconTests {
    let store: TabStore
    let model: BrowserModel

    init() async throws {
        store = try TabStore.makeInMemory()
        model = Self.makeModel(store: store)
        await model.start()
    }

    private static func makeModel(store: TabStore) -> BrowserModel {
        let pool = WebViewPool(engine: FakeEngine())
        pool.reportsScreenTimeUsage = false
        let model = BrowserModel(store: store, pool: pool)
        model.announce = { _ in }
        return model
    }

    /// Two 1 px PNGs, standing in for normalized favicons.
    private func icon() throws -> Data {
        try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="))
    }
    private func otherIcon() throws -> Data {
        try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="))
    }

    /// A pinned tab whose page is live, at its home.
    private func pinnedTab(home: String) async throws -> (AxoCore.Tab.ID, FakePage) {
        await model.openTab(url: URL(string: home)!)
        let id = try #require(model.selectedTabID)
        await model.setPinned(true, tabID: id)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        return (id, page)
    }

    private func saved(_ key: String) async throws -> Data? {
        try await store.favicons(forHosts: [key])[key]
    }

    @Test func aPinnedTabWhoseHomeRedirectsShowsItsIconAfterAResetAndRelaunch() async throws {
        let (id, page) = try await pinnedTab(home: "https://gmail.com")
        // The home redirected: the page has no history of its own.
        let landed = URL(string: "https://mail.google.com/mail/u/0")!
        page.navigate(to: landed, title: "Inbox")
        model.pool.onFaviconChange?(id, landed, try icon())
        try await waitUntilAsync { try await saved(Favicon.homeKey(for: id)) != nil }

        try await store.resetPinnedTab(id: id)
        let relaunched = Self.makeModel(store: store)
        await relaunched.start()
        let tab = try #require(relaunched.tabs.first { $0.id == id })
        #expect(tab.url.host() == "gmail.com", "Reset to its home page, which has no icon of its own")
        try await waitUntil { relaunched.favicon(for: tab) != nil }
    }

    @Test func aPageReachedByAFollowedLinkIsntTheHomesIcon() async throws {
        let (id, page) = try await pinnedTab(home: "https://gmail.com")
        page.canGoBack = true
        let elsewhere = URL(string: "https://youtube.com/watch")!
        page.navigate(to: elsewhere, title: "Video")
        model.pool.onFaviconChange?(id, elsewhere, try icon())
        try await waitUntilAsync { try await saved("youtube.com") != nil }
        #expect(try await saved(Favicon.homeKey(for: id)) == nil, "Not the home's icon")
        #expect(try await saved("gmail.com") == nil, "Nor gmail.com's")
    }

    @Test func aLaterHomeIconReplacesAWrongOne() async throws {
        let (id, page) = try await pinnedTab(home: "https://gmail.com")
        // The first load landed on a sign-in page.
        let signIn = URL(string: "https://accounts.google.com/signin")!
        page.navigate(to: signIn, title: "Sign in")
        model.pool.onFaviconChange?(id, signIn, try otherIcon())
        try await waitUntilAsync { try await saved(Favicon.homeKey(for: id)) == (try otherIcon()) }

        let inbox = URL(string: "https://mail.google.com/mail/u/0")!
        page.navigate(to: inbox, title: "Inbox")
        model.pool.onFaviconChange?(id, inbox, try icon())
        try await waitUntilAsync { try await saved(Favicon.homeKey(for: id)) == (try icon()) }
    }

    @Test func aHomeIconBelongsToItsTabOnly() async throws {
        let (id, page) = try await pinnedTab(home: "https://example.com")
        let elsewhere = URL(string: "https://intranet.example.org/home")!
        page.navigate(to: elsewhere, title: "Home")
        model.pool.onFaviconChange?(id, elsewhere, try icon())
        try await waitUntilAsync { try await saved(Favicon.homeKey(for: id)) != nil }
        #expect(try await saved("example.com") == nil, "Another tab or profile on example.com doesn't get it")
        let other = AxoCore.Tab(spaceID: UUID(), url: URL(string: "https://example.com")!, sortKey: "a")
        #expect(model.favicon(for: other) == nil)
    }

    @Test func aFavoritesSavedIconShowsAtLaunchWithNoPage() async throws {
        let space = try #require(model.space)
        let favorite = try await store.favorites.add(url: URL(string: "https://github.com")!, title: "GitHub", profileID: space.profileID)
        try await store.saveFavicon(try icon(), for: URL(string: "https://github.com/login")!)

        let relaunched = Self.makeModel(store: store)
        await relaunched.start()
        try await waitUntil { relaunched.favorites.contains { $0.id == favorite.id } }
        try await waitUntil { relaunched.favicon(for: favorite.tab(in: space.id)) != nil }
    }

    @Test func anIconSavedAfterItsHostWasLookedUpShows() async throws {
        let space = try #require(model.space)
        // A tab with no page, on a host with no icon yet.
        let tab = try await store.openTab(url: URL(string: "https://apple.com/mac")!, in: space.id)
        try await waitUntil { model.tabs.contains { $0.id == tab.id } }
        await model.loadSavedFavicons()
        #expect(model.favicon(for: tab) == nil, "Nothing saved yet")

        // Saved elsewhere (another window, which keeps icons of its own).
        try await store.saveFavicon(try icon(), for: URL(string: "https://apple.com")!)
        await model.loadSavedFavicons()
        #expect(model.favicon(for: tab) != nil)
    }
}
