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

    @Test func closeTabRemovesItAndIgnoresMissingTabs() async throws {
        let space = try await store.bootstrap()
        let tab = try await store.openTab(url: url("one"), in: space.id)
        try await store.closeTab(id: tab.id)
        try await store.closeTab(id: tab.id)
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
}
