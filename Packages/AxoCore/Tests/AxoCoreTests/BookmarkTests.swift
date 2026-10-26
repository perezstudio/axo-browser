import Foundation
import Testing
@testable import AxoCore

struct BookmarkTests {
    let store: TabStore
    let home: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
    }

    private func url(_ name: String) -> URL { URL(string: "https://\(name).example/")! }

    private func pinnedTab(_ name: String, in spaceID: Space.ID, folder: Folder.ID? = nil) async throws -> Tab {
        let tab = try await store.openTab(url: url(name), title: name, in: spaceID)
        try await store.setPinned(true, tabID: tab.id)
        if let folder { try await store.movePinnedItem(.tab(tab.id), into: folder, after: nil) }
        return tab
    }

    private var tree: BookmarkTree {
        get async throws { try await store.bookmarkTree(profileID: home.profileID) }
    }

    /// The tree as titles, folders with their contents in brackets.
    private func describe(_ items: [BookmarkItem]) -> String {
        items.map { $0.url == nil ? "\($0.title)[\(describe($0.children))]" : $0.title }.joined(separator: ", ")
    }

    private func change(_ kind: BookmarkChange.Kind, _ id: UUID, in place: BookmarkPlace, at index: Int = 0, title: String = "", url: URL? = nil) -> BookmarkChange {
        BookmarkChange(kind: kind, id: id, place: place, index: index, title: title, url: url)
    }

    private func apply(_ change: BookmarkChange) async throws {
        try await store.applyBookmarkChange(change, profileID: home.profileID, currentSpaceID: home.id)
    }

    @Test func favoritesAreTheBarAndSpacesHoldTheirPinnedSections() async throws {
        let mail = try await store.favorites.add(url: url("mail"), title: "Mail", profileID: home.profileID)
        let docs = try await pinnedTab("Docs", in: home.id)
        let team = try await store.createFolder(named: "Team", in: home.id)
        _ = try await pinnedTab("Wiki", in: home.id, folder: team.id)
        try await store.updateTab(id: docs.id, url: url("elsewhere"), title: "Docs")
        _ = try await store.openTab(url: url("unpinned"), in: home.id)
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let otherProfile = try await store.createProfile(name: "Other")
        _ = try await store.favorites.add(url: url("theirs"), profileID: otherProfile.id)

        let tree = try await self.tree
        #expect(tree.bar == [BookmarkItem(id: mail.id, title: "Mail", url: url("mail"))])
        #expect(describe(tree.other) == "Home[Docs, Team[Wiki]], Work[]", "Unpinned tabs aren't bookmarks")
        #expect(tree.other.map(\.id) == [home.id, work.id])
        #expect(tree.other[0].children[0].url == url("Docs"), "A pinned tab's bookmark is its home page")
    }

    @Test func theTreeStreamsChanges() async throws {
        var changes = store.observeBookmarkTree(profileID: home.profileID).makeAsyncIterator()
        #expect(try await changes.next()?.bar.isEmpty == true)
        _ = try await store.favorites.add(url: url("mail"), title: "Mail", profileID: home.profileID)
        #expect(try await changes.next()?.bar.map(\.title) == ["Mail"])
    }

    @Test func extensionsCreateFavoritesPinnedTabsAndFolders() async throws {
        let first = try await store.favorites.add(url: url("first"), title: "First", profileID: home.profileID)
        let docs = try await pinnedTab("Docs", in: home.id)

        let mail = UUID(), team = UUID(), wiki = UUID(), loose = UUID()
        try await apply(change(.created, mail, in: .bar, at: 0, title: "Mail", url: url("mail")))
        try await apply(change(.created, team, in: .inside(home.id), at: 0, title: "Team"))
        try await apply(change(.created, wiki, in: .inside(team), at: 0, title: "Wiki", url: url("wiki")))
        try await apply(change(.created, loose, in: .other, at: 1, title: "Loose", url: url("loose")))
        try await apply(change(.created, UUID(), in: .bar, at: 0, title: "Folder in the bar"))

        let tree = try await self.tree
        #expect(tree.bar.map(\.id) == [mail, first.id], "A favorite, at its place")
        #expect(describe(tree.other) == "Home[Team[Wiki], Docs, Loose]", "Bookmarks among the Spaces go to the current one")
        #expect(tree.other[0].children.map(\.id) == [team, docs.id, loose], "Items keep the extension's IDs")
        #expect(try await store.tab(id: wiki)?.isPinned == true)
    }

    @Test func extensionsRenameAndRepointBookmarks() async throws {
        let mail = try await store.favorites.add(url: url("mail"), title: "Mail", profileID: home.profileID)
        let docs = try await pinnedTab("Docs", in: home.id)
        let team = try await store.createFolder(named: "Team", in: home.id)

        try await apply(change(.updated, mail.id, in: .bar, title: "Inbox", url: url("inbox")))
        try await apply(change(.updated, docs.id, in: .inside(home.id), title: "Notes", url: url("notes")))
        try await apply(change(.updated, team.id, in: .inside(home.id), title: "Crew"))
        try await apply(change(.updated, home.id, in: .other, title: "Personal"))

        let tree = try await self.tree
        #expect(tree.bar == [BookmarkItem(id: mail.id, title: "Inbox", url: url("inbox"))])
        #expect(describe(tree.other) == "Personal[Notes, Crew[]]")
        #expect(tree.other[0].children[0].url == url("notes"))
        #expect(try await store.tab(id: docs.id)?.url == url("Docs"), "The open page stays; its home changes")
    }

    @Test func extensionsMoveBookmarksWithinWhatTheSidebarCanHold() async throws {
        let mail = try await store.favorites.add(url: url("mail"), title: "Mail", profileID: home.profileID)
        let docs = try await pinnedTab("Docs", in: home.id)
        let wiki = try await pinnedTab("Wiki", in: home.id)
        let team = try await store.createFolder(named: "Team", in: home.id)
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)

        try await apply(change(.moved, wiki.id, in: .inside(team.id), at: 0))
        #expect(describe(try await tree.other) == "Home[Docs, Team[Wiki]], Work[]")
        try await apply(change(.moved, team.id, in: .inside(home.id), at: 0))
        #expect(describe(try await tree.other) == "Home[Team[Wiki], Docs], Work[]")

        try await apply(change(.moved, docs.id, in: .bar, at: 0))
        #expect(try await tree.bar.map(\.id) == [docs.id, mail.id], "A pinned tab moved to the bar becomes a favorite")
        try await apply(change(.moved, mail.id, in: .inside(home.id), at: 1))
        #expect(describe(try await tree.other) == "Home[Team[Wiki], Mail], Work[]", "A favorite moved to a Space becomes a pinned tab")

        try await apply(change(.moved, work.id, in: .other, at: 0))
        #expect(try await tree.other.map(\.id) == [work.id, home.id], "Spaces reorder")

        try await apply(change(.moved, mail.id, in: .inside(work.id), at: 0))
        try await apply(change(.moved, team.id, in: .bar, at: 0))
        #expect(describe(try await tree.other) == "Work[], Home[Team[Wiki], Mail]", "Moves between Spaces and folders to the bar don't happen")
    }

    @Test func extensionsRemoveBookmarksButNotSpaces() async throws {
        let mail = try await store.favorites.add(url: url("mail"), title: "Mail", profileID: home.profileID)
        let docs = try await pinnedTab("Docs", in: home.id)
        let team = try await store.createFolder(named: "Team", in: home.id)
        _ = try await pinnedTab("Wiki", in: home.id, folder: team.id)

        try await apply(change(.removed, mail.id, in: .bar))
        try await apply(change(.removed, docs.id, in: .inside(home.id)))
        try await apply(change(.removed, team.id, in: .inside(home.id)))
        try await apply(change(.removed, home.id, in: .other))

        let tree = try await self.tree
        #expect(tree.bar.isEmpty)
        #expect(describe(tree.other) == "Home[Wiki]", "A removed folder's contents stay")
    }

    @Test func extensionsCantReachAnotherProfilesSpaces() async throws {
        let otherProfile = try await store.createProfile(name: "Other")
        let theirs = try await store.createSpace(name: "Theirs", profileID: otherProfile.id)
        let theirFolder = try await store.createFolder(named: "Their Folder", in: theirs.id)
        let docs = try await pinnedTab("Docs", in: home.id)
        let mail = try await store.favorites.add(url: url("mail"), title: "Mail", profileID: home.profileID)

        try await apply(change(.created, UUID(), in: .inside(theirs.id), title: "Sneaky", url: url("sneaky")))
        try await apply(change(.created, UUID(), in: .inside(theirFolder.id), title: "Sneaky folder"))
        try await apply(change(.moved, docs.id, in: .inside(theirs.id), at: 0))
        try await apply(change(.moved, mail.id, in: .inside(theirFolder.id), at: 0))

        let theirTree = try await store.bookmarkTree(profileID: otherProfile.id)
        #expect(describe(theirTree.other) == "Theirs[Their Folder[]]", "Nothing reaches the other profile")
        #expect(describe(try await tree.other) == "Home[Docs]")
        #expect(try await tree.bar.map(\.id) == [mail.id])
    }

    @Test func archivedPinnedTabsAreLeftOut() async throws {
        let a = try await pinnedTab("A", in: home.id)
        let hidden = try await pinnedTab("Hidden", in: home.id)
        let b = try await pinnedTab("B", in: home.id)
        try await store.archiveTab(id: hidden.id)
        #expect(describe(try await tree.other) == "Home[A, B]")

        let c = UUID()
        try await apply(change(.created, c, in: .inside(home.id), at: 2, title: "C", url: url("c")))
        #expect(try await tree.other[0].children.map(\.id) == [a.id, b.id, c], "Placed by what the extension sees")
        try await apply(change(.moved, a.id, in: .inside(home.id), at: 2))
        #expect(try await tree.other[0].children.map(\.id) == [b.id, c, a.id])

        try await apply(change(.updated, hidden.id, in: .inside(home.id), title: "Renamed"))
        try await apply(change(.removed, hidden.id, in: .inside(home.id)))
        #expect(try await store.tab(id: hidden.id)?.title == "Hidden", "Extensions can't see or change archived tabs")
    }

    @Test func onlyWebPagesBecomeBookmarks() async throws {
        let mail = try await store.favorites.add(url: url("mail"), title: "Mail", profileID: home.profileID)
        try await apply(change(.created, UUID(), in: .bar, title: "Script", url: URL(string: "javascript:alert(1)")!))
        try await apply(change(.created, UUID(), in: .inside(home.id), title: "File", url: URL(string: "file:///etc/hosts")!))
        try await apply(change(.updated, mail.id, in: .bar, title: "Mail", url: URL(string: "chrome://settings")!))

        let tree = try await self.tree
        #expect(tree.bar == [BookmarkItem(id: mail.id, title: "Mail", url: url("mail"))])
        #expect(describe(tree.other) == "Home[]")
    }

    @Test func otherProfilesBookmarksAreLeftAlone() async throws {
        let otherProfile = try await store.createProfile(name: "Other")
        let theirs = try await store.favorites.add(url: url("theirs"), profileID: otherProfile.id)
        try await apply(change(.removed, theirs.id, in: .bar))
        #expect(try await store.favorites.favorites(for: otherProfile.id).count == 1)
    }
}
