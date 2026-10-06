import Foundation
import Testing
@testable import AxoCore

struct FavoriteStoreTests {
    let store: TabStore
    let home: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
    }

    private var favorites: FavoriteStore { store.favorites }

    @Test func favoritesBelongToAProfileInGridOrder() async throws {
        let a = try await favorites.add(url: URL(string: "https://a.example")!, title: "A", profileID: home.profileID)
        let b = try await favorites.add(url: URL(string: "https://b.example")!, profileID: home.profileID)
        let other = try await store.createProfile(name: "Work")
        try await favorites.add(url: URL(string: "https://c.example")!, profileID: other.id)

        #expect(try await favorites.favorites(for: home.profileID).map(\.id) == [a.id, b.id])
        #expect(try await favorites.favorites(for: other.id).count == 1, "Profiles keep their own")
        await #expect(throws: TabStoreError.self) {
            try await favorites.add(url: URL(string: "https://d.example")!, profileID: UUID())
        }
    }

    @Test func aTabBecomesAFavoriteKeepingItsID() async throws {
        let tab = try await store.openTab(url: URL(string: "https://example.com/now")!, title: "Now", in: home.id)
        let favorite = try await favorites.add(fromTab: tab.id)
        #expect(favorite.id == tab.id, "The web view carries over")
        #expect(favorite.url == tab.url && favorite.title == "Now" && favorite.profileID == home.profileID)
        #expect(try await store.tab(id: tab.id) == nil, "It leaves the sidebar")

        let pinned = try await store.openTab(url: URL(string: "https://example.com/away")!, in: home.id)
        try await store.setPinned(true, tabID: pinned.id)
        try await store.updateTab(id: pinned.id, url: URL(string: "https://example.com/elsewhere")!, title: "")
        #expect(try await favorites.add(fromTab: pinned.id).url == URL(string: "https://example.com/away")!, "A pinned tab brings its home page")
    }

    @Test func favoritesReorderMoveToPinnedAndGo() async throws {
        let a = try await favorites.add(url: URL(string: "https://a.example")!, profileID: home.profileID)
        let b = try await favorites.add(url: URL(string: "https://b.example")!, profileID: home.profileID)
        let c = try await favorites.add(url: URL(string: "https://c.example")!, profileID: home.profileID)

        try await favorites.move(c.id, after: nil)
        #expect(try await favorites.favorites(for: home.profileID).map(\.id) == [c.id, a.id, b.id])
        try await favorites.move(c.id, after: b.id)
        #expect(try await favorites.favorites(for: home.profileID).map(\.id) == [a.id, b.id, c.id])

        let tab = try await favorites.moveToPinned(a.id, in: home.id)
        #expect(tab.id == a.id && tab.isPinned && tab.homeURL == a.url)
        #expect(try await favorites.favorites(for: home.profileID).map(\.id) == [b.id, c.id])

        try await favorites.setHome(URL(string: "https://b.example/new")!, title: "New", for: b.id)
        #expect(try await favorites.favorites(for: home.profileID).first?.title == "New")
        try await favorites.remove(b.id)
        #expect(try await favorites.search("c.example", profileID: home.profileID).map(\.id) == [c.id])
        #expect(try await favorites.search("B.EXAMPLE", profileID: home.profileID).isEmpty)
    }
}
