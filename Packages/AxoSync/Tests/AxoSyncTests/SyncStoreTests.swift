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

    /// Spaces that arrive are reported by name, for VoiceOver (#174); renames, Spaces already
    /// here, and other records aren't.
    @Test func spacesThatArriveAreReportedByName() async throws {
        let (space, _, _) = try await makeSidebar()
        try await mac.sync()
        #expect(try await iPad.sync() == ["Home"])
        #expect(try await iPad.sync().isEmpty, "Nothing new")

        let reading = try await mac.tabs.createSpace(name: "Reading", profileID: space.profileID)
        try await mac.tabs.renameSpace(id: space.id, to: "Personal")
        try await mac.sync()
        #expect(try await iPad.sync() == ["Reading"], "Only the new Space, not the renamed one")
        try await mac.tabs.createFolder(named: "Later", in: reading.id)
        try await mac.sync()
        #expect(try await iPad.sync().isEmpty, "A folder isn't a Space")
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

    @Test func aPinnedTabMadeAFavoriteElsewhereKeepsItsHomeIcon() async throws {
        let (space, _, tab) = try await makeSidebar()
        try await mac.sync()
        try await iPad.sync()
        let icon = Data([1, 2, 3]), key = Favicon.homeKey(for: tab.id)
        try await iPad.tabs.saveHomeFavicon(icon, for: tab.id, home: tab.url)

        // The tab's deletion and the favorite's save arrive together.
        try await mac.tabs.favorites.add(fromTab: tab.id)
        try await mac.sync()
        try await iPad.sync()
        #expect(try await iPad.tabs.tab(id: tab.id) == nil)
        #expect(try await iPad.tabs.favorites.favorites(for: space.profileID).map(\.id) == [tab.id])
        #expect(try await iPad.tabs.favicons(forHosts: [key]) == [key: icon], "The favorite shows the tab's icon")

        try await mac.tabs.favorites.moveToPinned(tab.id, in: space.id)
        try await mac.sync()
        try await iPad.sync()
        #expect(try await iPad.tabs.tab(id: tab.id)?.isPinned == true)
        #expect(try await iPad.tabs.favicons(forHosts: [key]) == [key: icon], "And back")

        try await mac.tabs.deleteTab(id: tab.id)
        try await mac.sync()
        try await iPad.sync()
        #expect(try await iPad.tabs.favicons(forHosts: [key]).isEmpty, "A deletion from elsewhere deletes it")
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

    @Test func spaceThemesSyncAndReset() async throws {
        let space = try await mac.tabs.bootstrap()
        try await mac.sync()
        try await iPad.sync()
        let theme = SpaceTheme(colors: [ThemeColor(hex: "#2a6f97")!, ThemeColor(hex: "#a9d6e5")!], mode: .light, transparency: 0.3, grain: 0.5)
        try await mac.tabs.setSpaceTheme(id: space.id, theme: theme)
        try await mac.sync()
        try await iPad.sync()
        #expect(try await iPad.tabs.spaces().first?.theme == theme)

        try await iPad.tabs.setSpaceTheme(id: space.id, theme: nil)
        try await iPad.sync()
        try await mac.sync()
        #expect(try await mac.tabs.spaces().first?.theme == nil, "Going back to the system's material syncs too")
    }

    @Test func aThemeThisVersionCantReadSurvivesSyncAndLocalChanges() async throws {
        let space = try await mac.tabs.bootstrap()
        let json = ##"{"angle":45,"colors":["#ABCDEF"],"mode":"dark"}"##
        try await mac.tabs.database.writer.write { db in
            try db.execute(sql: "UPDATE space SET theme = ?", arguments: [json])
        }
        try await mac.sync()
        try await iPad.sync()
        // The iPad renames it; the theme it got goes back untouched.
        try await iPad.tabs.renameSpace(id: space.id, to: "Personal")
        try await iPad.sync()
        try await mac.sync()
        let stored = try await mac.tabs.database.writer.read { db in try String.fetchOne(db, sql: "SELECT theme FROM space") }
        #expect(stored == json)
        #expect(try await mac.tabs.spaces().first?.name == "Personal")
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

    // MARK: Search engines (#132)

    @Test func customEnginesHiddenBuiltInsAndAProfilesChoiceSync() async throws {
        let home = try await mac.tabs.bootstrap()
        let kagi = try await mac.tabs.searchEngines.add(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s",
                                                        suggestionsTemplate: "https://kagi.com/api/autosuggest?q=%s", keyword: "k")
        try await mac.tabs.searchEngines.remove(id: SearchEngine.bing.id)
        var google = SearchEngine.google
        google.keyword = "goo"
        try await mac.tabs.searchEngines.update(google)
        try await mac.tabs.searchEngines.setEngine(kagi.id, forProfile: home.profileID)
        try await mac.tabs.searchEngines.setShowsSuggestions(false, forProfile: home.profileID)
        try await mac.sync()
        try await iPad.sync()

        let engines = try await iPad.tabs.searchEngines.engines()
        let syncedKagi = try #require(engines.first { $0.id == kagi.id })
        #expect(syncedKagi == kagi)
        #expect(engines.first { $0.id == SearchEngine.bing.id }?.isHidden == true, "A removed built-in engine stays removed")
        #expect(engines.first { $0.id == SearchEngine.google.id }?.keyword == "goo")
        #expect(engines.first { $0.id == SearchEngine.google.id }?.urlTemplate == SearchEngine.google.urlTemplate)
        let profile = try #require(try await iPad.tabs.profiles().first)
        #expect(profile.searchEngineID == kagi.id)
        #expect(!profile.showsSearchSuggestions)
        #expect(try await iPad.sync.pendingChanges().isEmpty, "Changes from iCloud aren't sent back")
    }

    @Test func removingAnEngineOneDevicesProfileUsesSendsItBackToGoogle() async throws {
        let home = try await mac.tabs.bootstrap()
        let kagi = try await mac.tabs.searchEngines.add(name: "Kagi", urlTemplate: "https://kagi.com/search?q=%s")
        try await mac.sync()
        try await iPad.sync()
        try await iPad.tabs.searchEngines.setEngine(kagi.id, forProfile: home.profileID)
        try await iPad.sync()
        try await mac.sync()
        #expect(try await mac.tabs.profiles().first?.searchEngineID == kagi.id)

        try await mac.tabs.searchEngines.remove(id: kagi.id)
        try await mac.sync()
        try await iPad.sync()
        #expect(try await !iPad.tabs.searchEngines.engines().contains { $0.id == kagi.id })
        let profile = try #require(try await iPad.tabs.profiles().first)
        #expect(SearchEngine.engine(for: profile, in: try await iPad.tabs.searchEngines.engines()).id == SearchEngine.google.id)
        #expect(profile.searchEngineID == nil, "The profile's own change came along")
    }

    @Test func aProfileFromAnAxoBeforeSearchEnginesShowsSuggestions() async throws {
        let id = UUID()
        let record = SyncRecord(id: SyncRecordID(.profile, id), fields: ["name": "Old"], modifiedAt: Date())
        try await iPad.sync.applyRemoteChanges(saved: [StampedSyncRecord(record: record, systemFields: nil)], deleted: [])
        let profile = try #require(try await iPad.tabs.profiles().first { $0.id == id })
        #expect(profile.showsSearchSuggestions)
        #expect(profile.searchEngineID == nil)
    }

    @Test func stateFromAVersionThatSyncedLessIsDroppedSoEverythingIsFetchedAgain() async throws {
        try await mac.sync.saveEngineState(Data([1, 2, 3]))
        #expect(try await mac.sync.engineState() == Data([1, 2, 3]))
        // An older Axo saved its state without the schema version.
        try await mac.tabs.database.writer.write { db in
            try db.execute(sql: "DELETE FROM syncSetting WHERE key = 'schemaVersion'")
        }
        #expect(try await mac.sync.engineState() == nil, "A full fetch picks up search engines it skipped")
    }
}
