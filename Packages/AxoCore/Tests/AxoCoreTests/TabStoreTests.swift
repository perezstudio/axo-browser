import AxoPersistence
import Foundation
import GRDB
import Testing
@testable import AxoCore

struct TabStoreTests {
    let database: AppDatabase
    let store: TabStore

    init() throws {
        database = try AppDatabase.makeInMemory()
        store = TabStore(database: database)
    }

    private func url(_ path: String) -> URL {
        URL(string: "https://example.com/\(path)")!
    }

    private func titles(in space: Space) async throws -> [String] {
        try await store.tabs(in: space.id).map(\.title)
    }

    // MARK: Bootstrap

    @Test func bootstrapCreatesADefaultProfileAndSpaceOnce() async throws {
        let first = try await store.bootstrap()
        let second = try await store.bootstrap()

        #expect(first == second)
        #expect(first.name == TabStore.defaultSpaceName)
        let profiles = try await database.writer.read { try Profile.fetchAll($0) }
        #expect(profiles.map(\.name) == [TabStore.defaultProfileName])
        #expect(first.profileID == profiles.first?.id)
        #expect(try await store.spaces() == [first])
    }

    // MARK: Opening and ordering

    @Test func openTabsAppendByDefault() async throws {
        let space = try await store.bootstrap()
        for name in ["one", "two", "three"] {
            try await store.openTab(url: url(name), title: name, in: space.id)
        }
        #expect(try await titles(in: space) == ["one", "two", "three"])
    }

    @Test func openTabAtStartAndAfterAnotherTab() async throws {
        let space = try await store.bootstrap()
        let one = try await store.openTab(url: url("one"), title: "one", in: space.id)
        try await store.openTab(url: url("three"), title: "three", in: space.id)
        try await store.openTab(url: url("zero"), title: "zero", in: space.id, at: .start)
        try await store.openTab(url: url("two"), title: "two", in: space.id, at: .after(one.id))

        #expect(try await titles(in: space) == ["zero", "one", "two", "three"])
    }

    @Test func movingATabUpdatesOnlyThatTab() async throws {
        let space = try await store.bootstrap()
        let one = try await store.openTab(url: url("one"), title: "one", in: space.id)
        let two = try await store.openTab(url: url("two"), title: "two", in: space.id)
        let three = try await store.openTab(url: url("three"), title: "three", in: space.id)

        try await store.moveTab(id: three.id, to: .after(one.id))
        #expect(try await titles(in: space) == ["one", "three", "two"])
        #expect(try await store.tab(id: one.id)?.sortKey == one.sortKey)
        #expect(try await store.tab(id: two.id)?.sortKey == two.sortKey)

        try await store.moveTab(id: one.id, to: .end)
        #expect(try await titles(in: space) == ["three", "two", "one"])

        try await store.moveTab(id: one.id, to: .start)
        #expect(try await titles(in: space) == ["one", "three", "two"])
    }

    @Test func movingATabAfterItselfDoesNothing() async throws {
        let space = try await store.bootstrap()
        let one = try await store.openTab(url: url("one"), title: "one", in: space.id)
        try await store.moveTab(id: one.id, to: .after(one.id))
        #expect(try await store.tab(id: one.id) == one)
    }

    @Test func insertingAfterATabWithADuplicateKeyStillWorks() async throws {
        // Two devices can produce the same key; sync merges keep both rows.
        let space = try await store.bootstrap()
        let one = try await store.openTab(url: url("one"), title: "one", in: space.id)
        let twin = Tab(spaceID: space.id, url: url("twin"), title: "twin", sortKey: one.sortKey)
        try await database.writer.write { try twin.insert($0) }

        let after = try await store.openTab(url: url("after"), title: "after", in: space.id, at: .after(one.id))
        #expect(after.sortKey > one.sortKey)
        #expect(try await titles(in: space).last == "after")
    }

    @Test func sameKeysAreOrderedByID() async throws {
        let space = try await store.bootstrap()
        let ids = [UUID(), UUID(), UUID()]
        try await database.writer.write { db in
            for id in ids {
                try Tab(id: id, spaceID: space.id, url: self.url("x"), sortKey: "a0").insert(db)
            }
        }
        let fetched = try await store.tabs(in: space.id).map(\.id)
        let expected = try await database.writer.read { db in
            try UUID.fetchAll(db, sql: "SELECT id FROM tab ORDER BY id")
        }
        #expect(fetched == expected)
    }

    // MARK: Errors

    @Test func movingAMissingTabThrows() async throws {
        let missing = UUID()
        await #expect(throws: TabStoreError.tabNotFound(missing)) {
            try await store.moveTab(id: missing, to: .end)
        }
    }

    @Test func anchoringToATabInAnotherSpaceThrows() async throws {
        let home = try await store.bootstrap()
        let work = Space(profileID: home.profileID, name: "Work", sortKey: try SortKey.between(home.sortKey, nil))
        try await database.writer.write { try work.insert($0) }
        let homeTab = try await store.openTab(url: url("home"), in: home.id)

        await #expect(throws: TabStoreError.anchorInDifferentSpace(homeTab.id)) {
            try await store.openTab(url: url("work"), in: work.id, at: .after(homeTab.id))
        }
    }

    // MARK: Updating and closing

    @Test func updateTabChangesURLAndTitle() async throws {
        let space = try await store.bootstrap()
        let tab = try await store.openTab(url: url("old"), in: space.id)
        try await store.updateTab(id: tab.id, url: url("new"), title: "New")

        let updated = try #require(try await store.tab(id: tab.id))
        #expect(updated.url == url("new"))
        #expect(updated.title == "New")
        #expect(updated.sortKey == tab.sortKey)
    }

    @Test func deleteTabRemovesItAndIgnoresMissingTabs() async throws {
        let space = try await store.bootstrap()
        let tab = try await store.openTab(url: url("one"), in: space.id)
        try await store.deleteTab(id: tab.id)
        try await store.deleteTab(id: tab.id)
        #expect(try await store.tabs(in: space.id).isEmpty)
    }

    @Test func archivedTabsAreHiddenFromTheSidebar() async throws {
        let space = try await store.bootstrap()
        var tab = try await store.openTab(url: url("old"), title: "old", in: space.id)
        try await store.openTab(url: url("new"), title: "new", in: space.id)
        tab.archivedAt = Date()
        try await database.writer.write { [tab] in try tab.update($0) }

        #expect(try await titles(in: space) == ["new"])
    }

    // MARK: Observation

    @Test func observingTabsDeliversChanges() async throws {
        let space = try await store.bootstrap()
        let observation = ValueObservation.tracking(TabStore.tabsRequest(in: space.id).fetchAll)
        var iterator = observation.values(in: database.writer).makeAsyncIterator()

        #expect(try await iterator.next()?.isEmpty == true)
        try await store.openTab(url: url("one"), title: "one", in: space.id)
        #expect(try await iterator.next()?.map(\.title) == ["one"])
    }

    @Test func observeTabsStreamsTheListAfterEachChange() async throws {
        let space = try await store.bootstrap()
        var iterator = store.observeTabs(in: space.id).makeAsyncIterator()

        #expect(try await iterator.next()?.isEmpty == true)
        let tab = try await store.openTab(url: url("one"), title: "one", in: space.id)
        #expect(try await iterator.next()?.map(\.title) == ["one"])
        try await store.updateTab(id: tab.id, url: url("one"), title: "renamed")
        #expect(try await iterator.next()?.map(\.title) == ["renamed"])
    }

    @Test func openOnDiskKeepsTabsAcrossStores() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Axo.sqlite")

        let first = try TabStore.openOnDisk(at: file)
        let space = try await first.bootstrap()
        try await first.openTab(url: url("kept"), title: "kept", in: space.id)

        let second = try TabStore.openOnDisk(at: file)
        #expect(try await second.bootstrap() == space)
        #expect(try await second.tabs(in: space.id).map(\.title) == ["kept"])
    }

    // MARK: Favicons

    @Test func faviconsAreSavedPerHostAndReplaced() async throws {
        let png = Data([1, 2, 3]), newer = Data([4, 5, 6])
        try await store.saveFavicon(png, for: URL(string: "https://Example.com/a")!)
        try await store.saveFavicon(newer, for: URL(string: "https://example.com/b")!)
        try await store.saveFavicon(png, for: URL(string: "https://swift.org")!)

        let icons = try await store.favicons(forHosts: ["example.com", "SWIFT.org", "missing.com"])
        #expect(icons == ["example.com": newer, "swift.org": png])
    }

    @Test func homeIconsAreKeptByIDApartFromHosts() async throws {
        let id = UUID(), first = Data([1, 2, 3]), later = Data([4, 5, 6])
        try await store.saveHomeFavicon(first, for: id)
        try await store.saveHomeFavicon(later, for: id)
        let key = Favicon.homeKey(for: id)
        #expect(try await store.favicons(forHosts: [key]) == [key: later], "The latest replaces the last")
        #expect(Favicon.key(for: URL(string: "https://home:1/")!) != key, "Never a host's key")
        #expect(try await store.favicons(forHosts: ["home"]).isEmpty)
    }

    @Test func homeIconsGoWhenNothingCanShowThem() async throws {
        let space = try await store.bootstrap()
        let icon = Data([1, 2, 3])
        func hasIcon(_ id: UUID) async throws -> Bool {
            try await !store.favicons(forHosts: [Favicon.homeKey(for: id)]).isEmpty
        }
        func pinnedTab() async throws -> Tab {
            let tab = try await store.openTab(url: url("home"), title: "Home", in: space.id)
            try await store.setPinned(true, tabID: tab.id)
            try await store.saveHomeFavicon(icon, for: tab.id)
            return tab
        }

        let archived = try await pinnedTab()
        try await store.archiveTab(id: archived.id)
        #expect(try await hasIcon(archived.id), "An archived tab can come back, with its icon")

        let unpinned = try await pinnedTab()
        try await store.setPinned(false, tabID: unpinned.id)
        #expect(try await !hasIcon(unpinned.id))

        let rehomed = try await pinnedTab()
        try await store.setHomeURL(url("elsewhere"), tabID: rehomed.id)
        #expect(try await !hasIcon(rehomed.id), "Its icon was the old home page's")

        let deleted = try await pinnedTab()
        try await store.deleteTab(id: deleted.id)
        #expect(try await !hasIcon(deleted.id))

        let madeFavorite = try await pinnedTab()
        try await store.favorites.add(fromTab: madeFavorite.id)
        #expect(try await hasIcon(madeFavorite.id), "The favorite takes the tab's ID and home")
        try await store.favorites.moveToPinned(madeFavorite.id, in: space.id)
        #expect(try await hasIcon(madeFavorite.id), "And back")
        try await store.favorites.add(fromTab: madeFavorite.id)
        try await store.favorites.remove(madeFavorite.id)
        #expect(try await !hasIcon(madeFavorite.id))

        let other = try await store.createSpace(name: "Other", profileID: space.profileID)
        let inOther = try await store.openTab(url: url("home"), title: "Home", in: other.id)
        try await store.setPinned(true, tabID: inOther.id)
        try await store.saveHomeFavicon(icon, for: inOther.id)
        _ = try await store.deleteSpace(id: other.id)
        #expect(try await !hasIcon(inOther.id), "It goes with its Space")
        #expect(try await hasIcon(archived.id), "Other tabs' icons stay")
    }

    @Test func urlsWithoutAHostHaveNoFavicon() async throws {
        try await store.saveFavicon(Data([1]), for: URL(string: "about:blank")!)
        #expect(Favicon.key(for: URL(string: "about:blank")!) == nil)
        let count = try await database.writer.read { try Favicon.fetchCount($0) }
        #expect(count == 0)
        #expect(try await store.favicons(forHosts: []).isEmpty)
    }

    @Test func aTabCanOpenWithAGivenID() async throws {
        let space = try await store.bootstrap()
        let id = UUID()
        let tab = try await store.openTab(id: id, url: URL(string: "https://example.com")!, in: space.id)
        #expect(tab.id == id)
        #expect(try await store.tab(id: id) != nil)
    }

    @Test func tabsAreFoundAcrossSpacesByTitleOrAddress() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let mail = try await store.openTab(url: URL(string: "https://mail.example.com")!, title: "Inbox", in: home.id)
        let docs = try await store.openTab(url: URL(string: "https://docs.example.com")!, title: "Design Doc", in: work.id)
        let old = try await store.openTab(url: URL(string: "https://old.example.com/docs")!, title: "Old", in: work.id)
        try await store.archiveTab(id: old.id)
        try await store.markActive(id: mail.id, at: Date().addingTimeInterval(60))

        #expect(try await store.searchTabs(matching: "DOC").map(\.id) == [docs.id], "Case-insensitive; archived tabs are left out")
        #expect(try await store.searchTabs(matching: "mail.example").map(\.id) == [mail.id])
        #expect(try await store.searchTabs(matching: "").map(\.id) == [mail.id, docs.id], "Most recently used first")
        #expect(try await store.searchTabs(matching: "", limit: 1).count == 1)
    }

    // MARK: Moving to another Space

    @Test func movingATabToAnotherSpaceAppendsItThere() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let tab = try await store.openTab(url: url("a"), title: "A", in: home.id)
        try await store.openTab(url: url("b"), title: "B", in: work.id)

        try await store.moveTab(id: tab.id, toSpace: work.id)
        #expect(try await titles(in: home).isEmpty)
        #expect(try await titles(in: work) == ["B", "A"])
    }

    @Test func aMovedPinnedTabLeavesItsFolderAndStaysPinned() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let tab = try await store.openTab(url: url("a"), title: "A", in: home.id)
        try await store.setPinned(true, tabID: tab.id)
        let folder = try await store.createFolder(named: "Reading", in: home.id)
        try await store.movePinnedItem(.tab(tab.id), into: folder.id, after: nil)

        try await store.moveTab(id: tab.id, toSpace: work.id)
        let moved = try #require(try await store.tab(id: tab.id))
        #expect(moved.spaceID == work.id)
        #expect(moved.isPinned)
        #expect(moved.folderID == nil, "A folder belongs to its Space")
    }

    @Test func aMovedTabLeavesItsSplit() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let a = try await store.openTab(url: url("a"), title: "A", in: home.id)
        let b = try await store.openTab(url: url("b"), title: "B", in: home.id)
        _ = try await store.addToSplit(b.id, with: a.id)

        try await store.moveTab(id: b.id, toSpace: work.id)
        #expect(try await store.tab(id: b.id)?.splitID == nil)
    }

    @Test func aTabDoesntMoveToAnotherProfilesSpace() async throws {
        let home = try await store.bootstrap()
        let other = try await store.createProfile(name: "Personal")
        let personal = try await store.createSpace(name: "Personal", profileID: other.id)
        let tab = try await store.openTab(url: url("a"), title: "A", in: home.id)

        await #expect(throws: TabStoreError.spaceOfAnotherProfile(personal.id)) {
            try await store.moveTab(id: tab.id, toSpace: personal.id)
        }
        #expect(try await store.tab(id: tab.id)?.spaceID == home.id)
    }

    @Test func archivingSeveralTabsInOneWrite() async throws {
        let home = try await store.bootstrap()
        let a = try await store.openTab(url: url("a"), title: "A", in: home.id)
        let b = try await store.openTab(url: url("b"), title: "B", in: home.id)
        try await store.openTab(url: url("c"), title: "C", in: home.id)
        _ = try await store.addToSplit(b.id, with: a.id)

        try await store.archiveTabs(ids: [a.id, b.id, UUID()])
        #expect(try await titles(in: home) == ["C"])
        #expect(try await store.archivedTabs(in: home.id).count == 2)
        #expect(try await store.tab(id: b.id)?.splitID == nil, "The split ended with them")
    }

    @Test func tabsArchivedTogetherReopenInTheirOrder() async throws {
        let home = try await store.bootstrap()
        // Eight, so random IDs can't put them in order by luck.
        let names = ["a", "b", "c", "e", "f", "g", "h", "i"]
        let tabs = try await names.asyncMap { try await store.openTab(url: url($0), title: $0.uppercased(), in: home.id) }
        // Already archived: skipped, keeping its own date.
        let earlier = try await store.openTab(url: url("d"), title: "D", in: home.id)
        let earlierDate = Date(timeIntervalSince1970: 1_000)
        try await store.archiveTab(id: earlier.id, at: earlierDate)

        try await store.archiveTabs(ids: tabs.map(\.id) + [earlier.id], at: Date(timeIntervalSince1970: 2_000))
        // Reopen Closed Tab takes the most recent first and puts it at the end: the top one first
        // brings them back in their order.
        #expect(try await store.archivedTabs(in: home.id).map(\.title) == names.map { $0.uppercased() } + ["D"])
        #expect(try await store.tab(id: earlier.id)?.archivedAt == earlierDate)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
