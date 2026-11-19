//
//  ICloudSyncControllerTests.swift
//  AxoTests
//

import AxoPersistence
import AxoSync
import AxoUI
import CloudKit
import Foundation
import Testing
@testable import Axo

/// How the iCloud pane's state follows from what the controller knows (#174). These never reach
/// iCloud: the controller's inputs are given directly, as CloudKit and `SyncStore` would report
/// them (`SyncProblem.from` turns CloudKit's errors into problems, tested in AxoSync).
@MainActor
struct ICloudSyncControllerTests {
    private func status(
        available: Bool = true, enabled: Bool = true, signedIn: Bool? = true, firstSync: Bool = true,
        lastSynced: Date? = nil, problem: SyncProblem? = nil
    ) -> SyncStatus {
        ICloudSyncController.status(
            isAvailable: available, isEnabled: enabled, isSignedIn: signedIn,
            hasFinishedFirstSync: firstSync, lastSynced: lastSynced, problem: problem
        )
    }

    @Test func eachStateComesFromWhatSyncReports() {
        let synced = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(status(available: false) == .unavailable, "A build without the entitlement")
        #expect(status(enabled: false, problem: .storageFull) == .off, "Off wins over any problem")
        #expect(status(signedIn: nil, firstSync: false) == .settingUp, "Before the account is known")
        #expect(status(firstSync: false) == .settingUp, "Until the first sync with the account finishes")
        #expect(status(lastSynced: synced) == .upToDate(lastSynced: synced))
        #expect(status(signedIn: false) == .paused(.signedOut))
        #expect(status(problem: .signedOut) == .paused(.signedOut), "CloudKit saying so counts too")
        #expect(status(problem: .storageFull) == .paused(.storageFull))
        #expect(status(firstSync: false, problem: .storageFull) == .paused(.storageFull), "Even while setting up")
        let failed = status(problem: .other(code: CKError.Code.serverRejectedRequest.rawValue, description: "The server said no."))
        #expect(failed == .failed(details: "The server said no. (CloudKit error \(CKError.Code.serverRejectedRequest.rawValue))"))
    }

    @Test func aBuildThatCantSyncSaysSoAndNeverAsksICloud() throws {
        // An in-memory database, never the person's.
        let controller = ICloudSyncController(store: SyncStore(database: try AppDatabase.makeInMemory()), isAvailable: false)
        #expect(controller.status == .unavailable)
    }
}
