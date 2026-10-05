import Foundation
import Testing
@testable import AxoUI

@MainActor
struct SyncSettingsTests {
    @Test func statusesAreDescribedPlainly() {
        let now = Date()
        #expect(SyncSettings.message(for: .unavailable) == "This copy of Axo can't use iCloud. Official releases can.")
        #expect(SyncSettings.message(for: .off) == "Off")
        #expect(SyncSettings.message(for: .noAccount) == "Sign in to iCloud in System Settings to sync.")
        #expect(SyncSettings.message(for: .on(lastSynced: nil)) == "Waiting for the first sync")
        #expect(SyncSettings.message(for: .on(lastSynced: now.addingTimeInterval(-120))).hasPrefix("Last synced"))
        #expect(SyncSettings.message(for: .failed("iCloud is full.")) == "iCloud is full.")
    }
}
