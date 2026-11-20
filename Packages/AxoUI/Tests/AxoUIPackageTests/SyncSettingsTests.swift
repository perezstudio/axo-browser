import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

/// The iCloud pane's states (#174) and Spaces arriving through sync.
@MainActor
struct SyncSettingsTests {
    @Test func everyStateHasATitleAndSaysWhatToDo() {
        let now = Date()
        #expect(SyncSettings.title(for: .unavailable) == "iCloud Isn’t Available")
        #expect(SyncSettings.message(for: .unavailable) == "This copy of Axo can't use iCloud. Official releases can.")
        #expect(SyncSettings.title(for: .off) == "Off")
        #expect(SyncSettings.message(for: .off).hasPrefix("Turn it on"))
        #expect(SyncSettings.title(for: .settingUp) == "Setting Up")
        #expect(SyncSettings.message(for: .settingUp).contains("nothing is replaced"))
        #expect(SyncSettings.title(for: .upToDate(lastSynced: now)) == "Up to Date")
        #expect(SyncSettings.message(for: .upToDate(lastSynced: nil)) == "Waiting for the first sync.")
        #expect(SyncSettings.message(for: .upToDate(lastSynced: now.addingTimeInterval(-120))).hasPrefix("Last synced"))
        #expect(SyncSettings.title(for: .paused(.signedOut)) == "Paused")
        #expect(SyncSettings.message(for: .paused(.signedOut)).contains("signed out of iCloud"))
        #expect(SyncSettings.message(for: .paused(.storageFull)).contains("storage is full"))
        #expect(SyncSettings.message(for: .paused(.restricted)).contains("Screen Time"))
        #expect(SyncSettings.title(for: .failed(details: "x")) == "Couldn’t Sync")
        #expect(SyncSettings.message(for: .failed(details: "x")).contains("tries again on its own"))
        // Problems stand out; the rest don't.
        #expect(SyncSettings.isProblem(.paused(.storageFull)) && SyncSettings.isProblem(.failed(details: "x")))
        #expect(!SyncSettings.isProblem(.upToDate(lastSynced: now)) && !SyncSettings.isProblem(.settingUp))
    }

    @Test func thePaneListsWhatSyncsAndWhatStays() {
        #expect(SyncSettings.syncedItems.contains("favorites"))
        #expect(SyncSettings.syncedItems.contains("themes"))
        #expect(SyncSettings.syncedItems.contains("search engines"))
        #expect(SyncSettings.localItems.contains("history") && SyncSettings.localItems.contains("extensions"))
        #expect(SyncSettings.localItems.contains("link rules") && SyncSettings.localItems.contains("settings"))
    }

    /// A Space arriving through iCloud is announced, with no notice (decision 2 in ui-plan.md).
    @Test func arrivingSpacesAreAnnouncedWithoutANotice() async throws {
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        var said: [String] = []
        model.announce = { said.append($0) }
        await model.start()

        model.spacesArrivedThroughSync(["Reading"])
        #expect(said == ["“Reading” arrived from iCloud"])
        model.spacesArrivedThroughSync(["Work", "Kids"])
        #expect(said.last == "2 Spaces arrived from iCloud")
        model.spacesArrivedThroughSync([])
        #expect(said.count == 2)
        #expect(model.notice == nil)
    }
}
