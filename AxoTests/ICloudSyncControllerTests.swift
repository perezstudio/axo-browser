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

/// The iCloud pane's state machine (#174), driven by event sequences as CloudKit and the sync
/// engine report them. Nothing here reaches iCloud; `SyncProblem.from` is tested in AxoSync.
@MainActor
struct ICloudSyncControllerTests {
    let synced = Date(timeIntervalSince1970: 1_800_000_000)
    let rejected = SyncProblem.other(domain: CKErrorDomain, code: CKError.Code.serverRejectedRequest.rawValue, description: "The server said no.")

    /// A state that's signed in and finished its first sync.
    private func syncing() -> ICloudSyncState {
        var state = ICloudSyncState(isAvailable: true, isEnabled: true)
        state.handle(.account(.available))
        state.handle(.firstSync(finished: true))
        return state
    }

    @Test func aBuildThatCantSyncAndSyncTurnedOff() throws {
        #expect(ICloudSyncState(isAvailable: false, isEnabled: true).status == .unavailable)
        var state = syncing()
        state.handle(.turnedOff)
        #expect(state.status == .off)
        // An in-memory database, never the person's.
        let controller = ICloudSyncController(store: SyncStore(database: try AppDatabase.makeInMemory()), isAvailable: false)
        #expect(controller.status == .unavailable)
    }

    @Test func settingUpUntilTheFirstSyncFinishesThenUpToDate() {
        var state = ICloudSyncState(isAvailable: true, isEnabled: true)
        #expect(state.status == .settingUp, "Before the account is known")
        state.handle(.account(.available))
        #expect(state.status == .settingUp)
        state.handle(.engine(.fetched(synced)))
        state.handle(.firstSync(finished: true))
        #expect(state.status == .upToDate(lastSynced: synced))
        // A switched account, or Axo's zone deleted elsewhere, sets up again.
        state.handle(.engine(.startedOver))
        #expect(state.status == .settingUp)
        state.handle(.firstSync(finished: true))
        state.handle(.accountChanged)
        #expect(state.status == .settingUp)
    }

    /// A send that fails for full storage still finishes; the pane must stay Paused, and a
    /// fetch after it mustn't clear it. Only a send that reaches iCloud does.
    @Test func storageFullLastsUntilASendGetsThrough() {
        var state = syncing()
        state.handle(.engine(.sent(synced, problem: .storageFull)))
        #expect(state.status == .paused(.storageFull))
        state.handle(.engine(.fetched(synced.addingTimeInterval(60))))
        #expect(state.status == .paused(.storageFull), "A fetch doesn't clear it")
        state.handle(.engine(.sent(synced.addingTimeInterval(120), problem: nil)))
        #expect(state.status == .upToDate(lastSynced: synced.addingTimeInterval(120)))
    }

    @Test func otherProblemsShowWithTheirCodeAndTransientOnesDont() {
        var state = syncing()
        state.handle(.failed(SyncProblem.from(CKError(.networkUnavailable))))
        #expect(state.status == .upToDate(lastSynced: nil), "The engine retries the network itself")
        state.handle(.failed(rejected))
        #expect(state.status == .failed(details: "The server said no. (CloudKit error \(CKError.Code.serverRejectedRequest.rawValue))"))
        // Another domain's error says which.
        state.handle(.failed(.other(domain: "SQLite", code: 6, description: "Locked.")))
        #expect(state.status == .failed(details: "Locked. (SQLite error 6)"))
        // Turning sync off and on starts clean.
        state.handle(.turnedOff)
        state.handle(.turnedOn)
        #expect(state.status == .upToDate(lastSynced: nil))
    }

    @Test func theAccountsStatesArentAllSignedOut() {
        var state = syncing()
        state.handle(.account(.noAccount))
        #expect(state.status == .paused(.signedOut))
        state.handle(.account(.temporarilyUnavailable))
        #expect(state.status == .paused(.signedOut), "Signed in but needs signing in again")
        state.handle(.account(.restricted))
        #expect(state.status == .paused(.restricted))
        state.handle(.account(.couldNotDetermine))
        #expect(state.status == .settingUp, "Not known yet; asked again")
        state.handle(.account(.available))
        #expect(state.status == .upToDate(lastSynced: nil))
        // CloudKit saying so mid-sync counts too, and signing back in clears it.
        state.handle(.engine(.sent(synced, problem: .signedOut)))
        #expect(state.status == .paused(.signedOut))
        state.handle(.account(.available))
        #expect(state.status == .upToDate(lastSynced: nil))
    }
}
