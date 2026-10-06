import AxoCore
import Foundation
import Testing
@testable import AxoSync

/// Two devices syncing through a fake cloud.
struct SyncStoreTests {
    let cloud = FakeCloud()
    let mac: Device
    let iPad: Device

    init() throws {
        mac = try Device(cloud: cloud)
        iPad = try Device(cloud: cloud)
    }

    /// Creates a Space with a pinned tab inside a folder on the Mac.
    private func makeSidebar() async throws -> (space: Space, folder: Folder, tab: AxoCore.Tab) {
        let space = try await mac.tabs.bootstrap()
        let folder = try await mac.tabs.createFolder(named: "Reading", in: space.id)
        let tab = try await mac.tabs.openTab(url: URL(string: "https://example.com/news")!, title: "News", in: space.id)
        try await mac.tabs.setPinned(true, tabID: tab.id)
        try await mac.tabs.movePinnedItem(.tab(tab.id), into: folder.id, after: nil)
        return (space, folder, try #require(try await mac.tabs.tab(id: tab.id)))
    }

    @Test func spacesFoldersAndPinnedTabsReachTheOtherDevice() async throws {
        let (space, folder, tab) = try await makeSidebar()
        let unpinned = try await mac.tabs.openTab(url: URL(string: "https://example.com/once")!, in: space.id)
        try await mac.sync()
        try await iPad.sync()

        #expect(try await iPad.tabs.spaces().map(\.name) == ["Home"])
        #expect(try await iPad.tabs.profiles().map(\.name) == ["Default"])
        #expect(try await iPad.tabs.folders(in: space.id).map(\.name) == ["Reading"])
        let synced = try #require(try await iPad.tabs.tab(id: tab.id))
        #expect(synced.isPinned && synced.folderID == folder.id && synced.sortKey == tab.sortKey)
        #expect(synced.url == tab.url && synced.homeURL == tab.url && synced.title == "News")
        #expect(try await iPad.tabs.tab(id: unpinned.id) == nil, "Unpinned tabs stay on their device")
        #expect(try await mac.sync.pendingChanges().isEmpty)
        #expect(try await iPad.sync.pendingChanges().isEmpty, "Changes from iCloud aren't sent back")
    }

    @Test func movesAndRenamesFollowButPageChangesDont() async throws {
        let (space, folder, tab) = try await makeSidebar()
        try await mac.sync()
        try await iPad.sync()

        // On the iPad, the pinned tab browses away from its home page.
        let elsewhere = URL(string: "https://example.com/elsewhere")!
        try await iPad.tabs.updateTab(id: tab.id, url: elsewhere, title: "Elsewhere")
        #expect(try await iPad.sync.pendingChanges().isEmpty, "Browsing in a pinned tab isn't a change")

        try await mac.tabs.renameSpace(id: space.id, to: "Personal")
        try await mac.tabs.renameFolder(id: folder.id, to: "Later")
        try await mac.tabs.movePinnedItem(.tab(tab.id), into: nil, after: nil)
        try await mac.sync()
        try await iPad.sync()

        #expect(try await iPad.tabs.spaces().map(\.name) == ["Personal"])
        #expect(try await iPad.tabs.folders(in: space.id).map(\.name) == ["Later"])
        let moved = try #require(try await iPad.tabs.tab(id: tab.id))
        #expect(moved.folderID == nil)
        #expect(moved.url == elsewhere && moved.title == "Elsewhere", "The iPad keeps the page it's showing")
    }

    @Test func unpinningAndDeletingRemoveFromTheOtherDevice() async throws {
        let (space, folder, tab) = try await makeSidebar()
        let other = try await mac.tabs.createSpace(name: "Work", profileID: space.profileID)
        let workTab = try await mac.tabs.openTab(url: URL(string: "https://example.com/work")!, in: other.id)
        try await mac.tabs.setPinned(true, tabID: workTab.id)
        try await mac.sync()
        try await iPad.sync()
        #expect(try await iPad.tabs.spaces().count == 2)

        try await mac.tabs.setPinned(false, tabID: tab.id)
        try await mac.tabs.deleteFolder(id: folder.id)
        try await mac.tabs.deleteSpace(id: other.id)
        try await mac.sync()
        try await iPad.sync()

        #expect(try await iPad.tabs.tab(id: tab.id) == nil)
        #expect(try await iPad.tabs.folders(in: space.id).isEmpty)
        #expect(try await iPad.tabs.spaces().map(\.name) == ["Home"])
        #expect(try await iPad.tabs.tab(id: workTab.id) == nil)
        #expect(await cloud.recordCount == 2, "Only the profile and the Home Space are left")
    }

    @Test func theLaterChangeWinsAConflictWhicheverIsSentFirst() async throws {
        let space = try await mac.tabs.bootstrap()
        try await mac.sync()
        try await iPad.sync()

        // The Mac renames first; the iPad renames later but sends first.
        try await mac.tabs.renameSpace(id: space.id, to: "From the Mac")
        try await Task.sleep(for: .milliseconds(20))
        try await iPad.tabs.renameSpace(id: space.id, to: "From the iPad")
        try await iPad.sync()
        try await mac.sync()
        try await iPad.sync()
        #expect(try await mac.tabs.spaces().map(\.name) == ["From the iPad"])
        #expect(try await iPad.tabs.spaces().map(\.name) == ["From the iPad"])

        // The other way around: the earlier change is sent first, and the later one still wins.
        try await mac.tabs.renameSpace(id: space.id, to: "Earlier")
        try await Task.sleep(for: .milliseconds(20))
        try await iPad.tabs.renameSpace(id: space.id, to: "Later")
        try await mac.sync()
        try await iPad.sync()
        try await mac.sync()
        #expect(try await mac.tabs.spaces().map(\.name) == ["Later"])
        #expect(try await iPad.tabs.spaces().map(\.name) == ["Later"])
        #expect(try await mac.sync.pendingChanges().isEmpty)
        #expect(try await iPad.sync.pendingChanges().isEmpty)
    }

    @Test func recordsWaitForParentsThatArriveLater() async throws {
        let (space, folder, tab) = try await makeSidebar()
        let inner = try await mac.tabs.createFolder(named: "Inner", in: space.id, parent: folder.id)
        try await mac.sync(sendOnly: true)

        // The tab and the inner folder arrive first, then everything else.
        let all = await cloud.changes(since: 0).saved
        let early = all.filter { [tab.id, inner.id].contains($0.record.id.id) }
        try await iPad.sync.applyRemoteChanges(saved: early, deleted: [])
        #expect(try await iPad.sync.parkedRecordCount() == 2)
        #expect(try await iPad.tabs.tab(id: tab.id) == nil)

        try await iPad.sync.applyRemoteChanges(saved: all.filter { !early.contains($0) }, deleted: [])
        #expect(try await iPad.sync.parkedRecordCount() == 0)
        #expect(try await iPad.tabs.tab(id: tab.id)?.folderID == folder.id)
        #expect(Set(try await iPad.tabs.folders(in: space.id).map(\.name)) == ["Reading", "Inner"])
        #expect(try await iPad.sync.pendingChanges().isEmpty)
    }

    @Test func anEditToARecordDeletedElsewhereBringsItBack() async throws {
        let (_, folder, _) = try await makeSidebar()
        try await mac.sync()
        try await iPad.sync()

        // The Mac deletes the folder while the iPad, not yet knowing, renames it.
        try await mac.tabs.deleteFolder(id: folder.id)
        try await mac.sync()
        try await iPad.tabs.renameFolder(id: folder.id, to: "Keep")
        try await iPad.sync(sendOnly: true)
        #expect(await cloud.record(SyncRecordID(.folder, folder.id))?.fields["name"] == "Keep")
        try await mac.sync()
        #expect(try await mac.tabs.folders(in: folder.spaceID).map(\.name) == ["Keep"])
    }

    @Test func everythingCanBeMarkedForSendingAndMetadataReset() async throws {
        _ = try await makeSidebar()
        try await mac.sync()
        #expect(try await mac.sync.pendingChanges().isEmpty)

        try await mac.sync.markEverythingChanged()
        #expect(Set(try await mac.sync.pendingChanges().map(\.id.type)) == [.profile, .space, .folder, .tab])

        try await mac.sync.saveEngineState(Data("state".utf8))
        #expect(try await mac.sync.engineState() == Data("state".utf8))
        try await mac.sync.resetSyncMetadata()
        #expect(try await mac.sync.engineState() == nil)
        #expect(try await mac.sync.pendingChanges().isEmpty)
        #expect(try await mac.tabs.spaces().count == 1, "The sidebar itself stays")
    }

    @Test func outgoingRecordsCarryTheRowAndTheChangeTime() async throws {
        let (space, folder, tab) = try await makeSidebar()
        let change = try #require(try await mac.sync.pendingChanges().first { $0.id.type == .tab })
        let outgoing = try #require(try await mac.sync.outgoingRecord(for: change.id))
        #expect(outgoing.systemFields == nil)
        #expect(outgoing.record.modifiedAt == change.changedAt)
        #expect(outgoing.record.fields == [
            "spaceID": space.id.uuidString.lowercased(),
            "folderID": folder.id.uuidString.lowercased(),
            "url": "https://example.com/news",
            "title": "News",
            "sortKey": tab.sortKey,
        ])
        try await mac.tabs.setPinned(false, tabID: tab.id)
        #expect(try await mac.sync.outgoingRecord(for: change.id) == nil, "An unpinned tab is sent as a deletion")
    }

    @Test func aNewDevicesUntouchedHomeSpaceMergesIntoTheSyncedOnes() async throws {
        let (space, _, _) = try await makeSidebar()
        try await mac.sync()

        // The iPad starts with its own Home Space and an open tab, then syncs for the first time.
        let localHome = try await iPad.tabs.bootstrap()
        let open = try await iPad.tabs.openTab(url: URL(string: "https://example.com/reading")!, in: localHome.id)
        try await iPad.fetch()
        #expect(try await iPad.tabs.spaces().count == 2)
        let merge = try #require(try await iPad.sync.finishFirstSync())
        #expect(merge.removed == localHome.id && merge.mergedInto == space.id)
        #expect(try await iPad.sync.hasFinishedFirstSync())

        #expect(try await iPad.tabs.spaces().map(\.id) == [space.id])
        #expect(try await iPad.tabs.profiles().map(\.id) == [space.profileID], "The unused local profile goes too")
        #expect(try await iPad.tabs.tab(id: open.id)?.spaceID == space.id, "Open tabs move into the synced Space")
        try await iPad.sync()
        #expect(await cloud.recordCount == 4, "Nothing from the untouched Space was sent")
        #expect(try await iPad.sync.pendingChanges().isEmpty)
    }

    @Test func aNewDeviceWithItsOwnSetupKeepsIt() async throws {
        _ = try await makeSidebar()
        try await mac.sync()

        let localHome = try await iPad.tabs.bootstrap()
        let pinned = try await iPad.tabs.openTab(url: URL(string: "https://example.com/mine")!, in: localHome.id)
        try await iPad.tabs.setPinned(true, tabID: pinned.id)
        try await iPad.fetch()
        #expect(try await iPad.sync.finishFirstSync() == nil)
        try await iPad.sync()
        try await mac.sync()
        #expect(try await mac.tabs.spaces().count == 2, "Both Spaces sync")
        #expect(try await mac.tabs.tab(id: pinned.id)?.isPinned == true)
    }

    @Test func theFirstDeviceSendsEverything() async throws {
        _ = try await makeSidebar()
        try await mac.fetch()
        #expect(try await mac.sync.finishFirstSync() == nil)
        try await mac.sync()
        #expect(await cloud.recordCount == 4)
    }

    @Test func spaceColorsAndIconsSync() async throws {
        let space = try await mac.tabs.bootstrap()
        try await mac.sync()
        try await iPad.sync()
        try await mac.tabs.setSpaceAppearance(id: space.id, color: "teal", icon: "leaf")
        try await mac.sync()
        try await iPad.sync()
        let synced = try #require(try await iPad.tabs.spaces().first)
        #expect(synced.color == "teal" && synced.icon == "leaf")

        try await iPad.tabs.setSpaceAppearance(id: space.id, color: nil, icon: nil)
        try await iPad.sync()
        try await mac.sync()
        #expect(try await mac.tabs.spaces().first?.color == nil, "Clearing syncs too")
    }

    @Test func favoritesSyncWithTheirProfile() async throws {
        let home = try await mac.tabs.bootstrap()
        let tab = try await mac.tabs.openTab(url: URL(string: "https://example.com/mail")!, title: "Mail", in: home.id)
        let favorite = try await mac.tabs.favorites.add(fromTab: tab.id)
        try await mac.sync()
        try await iPad.sync()
        #expect(try await iPad.tabs.favorites.favorites(for: home.profileID).map(\.url) == [favorite.url])

        try await mac.tabs.favorites.remove(favorite.id)
        try await mac.sync()
        try await iPad.sync()
        #expect(try await iPad.tabs.favorites.favorites(for: home.profileID).isEmpty)
    }
}
