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
