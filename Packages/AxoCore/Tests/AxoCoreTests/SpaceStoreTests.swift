import AxoPersistence
import Foundation
import GRDB
import Testing
@testable import AxoCore

struct SpaceStoreTests {
    let store: TabStore

    init() throws {
        store = try TabStore.makeInMemory()
    }

    @Test func createdSpacesGoAfterExistingOnes() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let play = try await store.createSpace(name: "Play", profileID: home.profileID)

        #expect(try await store.spaces().map(\.name) == ["Home", "Work", "Play"])
        #expect(work.sortKey > home.sortKey && play.sortKey > work.sortKey)
    }

    @Test func spacesNeedAnExistingProfile() async throws {
        _ = try await store.bootstrap()
        let missing = UUID()
        await #expect(throws: TabStoreError.profileNotFound(missing)) {
            try await store.createSpace(name: "Orphan", profileID: missing)
        }
    }

    @Test func renamingASpace() async throws {
        let home = try await store.bootstrap()
        try await store.renameSpace(id: home.id, to: "Personal")
        #expect(try await store.spaces().first?.name == "Personal")
        let missing = UUID()
        await #expect(throws: TabStoreError.spaceNotFound(missing)) { try await store.renameSpace(id: missing, to: "x") }
    }

    @Test func deletingASpaceDeletesItsTabsButKeepsItsProfile() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let tab = try await store.openTab(url: URL(string: "https://example.com")!, in: work.id)
        let kept = try await store.openTab(url: URL(string: "https://swift.org")!, in: home.id)

        let deleted = try await store.deleteSpace(id: work.id)

        #expect(deleted == [tab.id])
        #expect(try await store.spaces().map(\.id) == [home.id])
        #expect(try await store.tab(id: tab.id) == nil)
        #expect(try await store.tab(id: kept.id) != nil)
        #expect(try await store.profiles().map(\.id) == [home.profileID])
    }

    @Test func theLastSpaceCannotBeDeleted() async throws {
        let home = try await store.bootstrap()
        await #expect(throws: TabStoreError.cannotDeleteLastSpace) { try await store.deleteSpace(id: home.id) }
    }

    @Test func observingSpacesStreamsChanges() async throws {
        let home = try await store.bootstrap()
        var iterator = store.observeSpaces().makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.name) == ["Home"])
        try await store.createSpace(name: "Work", profileID: home.profileID)
        #expect(try await iterator.next()?.map(\.name) == ["Home", "Work"])
    }

    // MARK: Profiles

    @Test func profilesCanBeCreatedRenamedAndListedByName() async throws {
        _ = try await store.bootstrap()
        let work = try await store.createProfile(name: "work")
        try await store.createProfile(name: "Banking")
        try await store.renameProfile(id: work.id, to: "Work")

        #expect(try await store.profiles().map(\.name) == ["Banking", TabStore.defaultProfileName, "Work"])
    }

    @Test func profilesInUseCannotBeDeleted() async throws {
        let home = try await store.bootstrap()
        let spare = try await store.createProfile(name: "Spare")

        await #expect(throws: TabStoreError.profileInUse(home.profileID)) {
            try await store.deleteProfile(id: home.profileID)
        }
        try await store.deleteProfile(id: spare.id)
        #expect(try await store.profiles().map(\.id) == [home.profileID])
    }

    @Test func spacesMoveToAnotherProfileWithTheirTabs() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createProfile(name: "Work")
        let tab = try await store.openTab(url: URL(string: "https://example.com")!, in: home.id)

        #expect(try await store.moveSpace(id: home.id, toProfile: work.id) == [tab.id])
        #expect(try await store.spaces().first?.profileID == work.id)
        #expect(try await store.moveSpace(id: home.id, toProfile: work.id).isEmpty, "Already there")
        await #expect(throws: TabStoreError.profileNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)) {
            try await store.moveSpace(id: home.id, toProfile: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
        }
    }

    @Test func deletingAProfileMovesItsSpacesFirst() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createProfile(name: "Work")
        let tab = try await store.openTab(url: URL(string: "https://example.com")!, in: home.id)

        await #expect(throws: TabStoreError.profileInUse(home.profileID)) {
            try await store.deleteProfile(id: home.profileID, movingSpacesTo: nil)
        }
        #expect(try await store.deleteProfile(id: home.profileID, movingSpacesTo: work.id) == [tab.id])
        #expect(try await store.profiles().map(\.id) == [work.id])
        #expect(try await store.spaces().map(\.profileID) == [work.id])
        #expect(try await store.tab(id: tab.id) != nil, "The Space keeps its tabs")

        await #expect(throws: TabStoreError.cannotDeleteLastProfile) {
            try await store.deleteProfile(id: work.id, movingSpacesTo: nil)
        }
    }

    @Test func spacesHaveAnOptionalColorAndIcon() async throws {
        let home = try await store.bootstrap()
        #expect(home.color == nil && home.icon == nil)
        try await store.setSpaceAppearance(id: home.id, color: "blue", icon: "briefcase")
        let saved = try #require(try await store.spaces().first)
        #expect(saved.color == "blue" && saved.icon == "briefcase")
        try await store.setSpaceAppearance(id: home.id, color: nil, icon: nil)
        #expect(try await store.spaces().first?.color == nil)
    }

    @Test func spacesSaveAndClearATheme() async throws {
        let home = try await store.bootstrap()
        #expect(home.theme == nil, "New Spaces use the system's material")
        let theme = SpaceTheme(colors: [ThemeColor(hex: "#336699")!, ThemeColor(hex: "#ffcc00")!], mode: .dark, transparency: 0.4, grain: 0.25)
        try await store.setSpaceTheme(id: home.id, theme: theme)
        #expect(try await store.spaces().first?.theme == theme)
        try await store.setSpaceTheme(id: home.id, theme: nil)
        #expect(try await store.spaces().first?.theme == nil)
    }

    @Test func aThemeThatDoesntReadLeavesTheSpaceReadable() async throws {
        let home = try await store.bootstrap()
        for json in [##"{"colors":[]}"##, ##"{"colors":["not a color"]}"##, "not json", ##"{"mode":"dark"}"##] {
            try await store.database.writer.write { db in
                try db.execute(sql: "UPDATE space SET theme = ?", arguments: [json])
            }
            let space = try #require(try await store.spaces().first, "\(json)")
            #expect(space.id == home.id && space.theme == nil, "\(json)")
        }
    }

    @Test func otherSpaceChangesLeaveTheThemeAsStored() async throws {
        // Themes from another device or a newer Axo: an extra field, and a shape this one can't
        // read. Renaming, recoloring, reordering, or moving the Space must not rewrite them, or
        // the loss would sync everywhere.
        let home = try await store.bootstrap()
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        for json in [##"{"angle":45,"colors":["#ABCDEF"],"mode":"dark"}"##, ##"{"colors":[{"hex":"#336699"}]}"##] {
            try await store.database.writer.write { db in
                try db.execute(sql: "UPDATE space SET theme = ? WHERE id = ?", arguments: [json, home.id])
            }
            let other = try await store.createProfile(name: "Other")
            func stored() async throws -> String? {
                try await store.database.writer.read { db in
                    try String.fetchOne(db, sql: "SELECT theme FROM space WHERE id = ?", arguments: [home.id])
                }
            }
            try await store.renameSpace(id: home.id, to: "Personal")
            #expect(try await stored() == json, "Rename")
            try await store.setSpaceAppearance(id: home.id, color: "blue", icon: "house")
            #expect(try await stored() == json, "Color and icon")
            try await store.moveSpace(id: home.id, after: work.id)
            #expect(try await stored() == json, "Reorder")
            try await store.moveSpace(id: home.id, toProfile: other.id)
            #expect(try await stored() == json, "Another profile")
            try await store.deleteProfile(id: other.id, movingSpacesTo: home.profileID)
            #expect(try await stored() == json, "Its profile deleted")
        }
    }

    @Test func spacesReorderByMovingOneRow() async throws {
        let home = try await store.bootstrap()
        let work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let play = try await store.createSpace(name: "Play", profileID: home.profileID)

        try await store.moveSpace(id: play.id, after: nil)
        #expect(try await store.spaces().map(\.name) == ["Play", "Home", "Work"])
        try await store.moveSpace(id: play.id, after: work.id)
        #expect(try await store.spaces().map(\.name) == ["Home", "Work", "Play"])
        try await store.moveSpace(id: home.id, after: work.id)
        #expect(try await store.spaces().map(\.name) == ["Work", "Home", "Play"])
        #expect(try await store.spaces().first { $0.id == work.id }?.sortKey == work.sortKey, "Only the moved Space changes")
    }
}
