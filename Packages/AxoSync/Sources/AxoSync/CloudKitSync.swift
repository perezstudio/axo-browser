import CloudKit
import Foundation
import os
import Security
import Synchronization

/// Why sync stopped or failed, in terms the iCloud pane can act on.
public enum SyncProblem: Equatable, Sendable {
    /// No iCloud account is signed in (or it needs signing in again).
    case signedOut
    /// The person's iCloud storage is full.
    case storageFull
    /// Anything else, with CloudKit's error code and description for Show Details.
    case other(code: Int, description: String)

    /// The problem an error from CloudKit stands for. Partial failures count as storage full
    /// if any item failed for that, and as signed out if any failed for that.
    public static func from(_ error: any Error) -> SyncProblem {
        guard let error = error as? CKError else {
            return .other(code: (error as NSError).code, description: error.localizedDescription)
        }
        switch error.code {
        case .quotaExceeded: return .storageFull
        case .notAuthenticated: return .signedOut
        case .partialFailure:
            let codes = (error.partialErrorsByItemID ?? [:]).values.compactMap { ($0 as? CKError)?.code }
            if codes.contains(.quotaExceeded) { return .storageFull }
            if codes.contains(.notAuthenticated) { return .signedOut }
            return .other(code: error.errorCode, description: error.localizedDescription)
        default:
            return .other(code: error.errorCode, description: error.localizedDescription)
        }
    }

    /// Whether the sync engine retries this on its own (the network, the server being busy),
    /// so it's worth showing only if it lasts.
    public var isTransient: Bool {
        guard case .other(let code, _) = self, let ckCode = CKError.Code(rawValue: code) else { return false }
        return [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy].contains(ckCode)
    }
}

/// Syncs Axo's sidebar through the person's private iCloud database with `CKSyncEngine`.
///
/// Records live in one zone (``zoneName``). The engine decides when to send and fetch; this
/// class turns its events into ``SyncStore`` calls and hands it the store's pending changes.
/// Everything that decides what changes means lives in ``SyncStore``, which tests drive with a
/// fake cloud; this class is the thin part that needs a real iCloud account.
///
/// Create it only when ``isAvailable(containerIdentifier:)`` is true: CloudKit stops the app
/// if it's used without the iCloud entitlement.
public final class CloudKitSync: CKSyncEngineDelegate {
    /// The zone that holds Axo's records.
    public static let zoneName = "Axo"
    /// The zone's ID in the private database.
    public static let zoneID = CKRecordZone.ID(zoneName: zoneName)

    private let store: SyncStore
    private let database: CKDatabase
    private let engine = Mutex<CKSyncEngine?>(nil)
    private let observation = Mutex<Task<Void, Never>?>(nil)
    private let logger = Logger(subsystem: "com.perezstudio.Axo", category: "Sync")

    /// Called on the main actor after each fetch or send finishes, with the time, for showing
    /// when Axo last synced.
    private let onSynced: @MainActor @Sendable (Date) -> Void
    /// Called on the main actor when a send fails for a reason the person may need to act on
    /// (storage full, signed out), for the iCloud pane.
    private let onProblem: @MainActor @Sendable (SyncProblem) -> Void
    /// Called on the main actor with the names of Spaces that arrived from iCloud.
    private let onSpacesArrived: @MainActor @Sendable ([String]) -> Void

    /// Creates a sync over `database`, usually `CKContainer(identifier:).privateCloudDatabase`.
    /// Call ``start()`` to begin.
    public init(
        store: SyncStore,
        database: CKDatabase,
        onSynced: @escaping @MainActor @Sendable (Date) -> Void = { _ in },
        onProblem: @escaping @MainActor @Sendable (SyncProblem) -> Void = { _ in },
        onSpacesArrived: @escaping @MainActor @Sendable ([String]) -> Void = { _ in }
    ) {
        self.store = store
        self.database = database
        self.onSynced = onSynced
        self.onProblem = onProblem
        self.onSpacesArrived = onSpacesArrived
    }

    deinit {
        observation.withLock { $0?.cancel() }
    }

    /// Whether this build can use iCloud: it's signed with the iCloud entitlement for
    /// `containerIdentifier`. Builds without it (such as contributors' unsigned builds) don't
    /// sync.
    ///
    /// On iOS there's no public way to read the app's entitlements, so this is `false` until
    /// the iOS app gets its own iCloud setup.
    public static func isAvailable(containerIdentifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let containers = value as? [String] else { return false }
        return containers.contains(containerIdentifier)
        #else
        return false
        #endif
    }

    /// Starts the engine from its saved state.
    ///
    /// Until the first sync with an account finishes, local changes wait: the engine first
    /// fetches what's in iCloud, then ``SyncStore/finishFirstSync()`` merges an untouched Home
    /// Space into it and queues everything else to send.
    public func start() async throws {
        guard engine.withLock({ $0 == nil }) else { return }
        let saved = try await store.engineState()
        let serialization = saved.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let syncEngine = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: self))
        engine.withLock { $0 = syncEngine }
        if serialization == nil {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        if try await store.hasFinishedFirstSync() {
            startSending(with: syncEngine)
        } else {
            // The engine fetches on its own too; this just doesn't wait for it.
            Task { try? await syncEngine.fetchChanges() }
        }
    }

    /// Stops syncing. Unsent changes keep collecting, and ``start()`` picks up where this left
    /// off.
    public func stop() {
        observation.withLock { task in
            task?.cancel()
            task = nil
        }
        engine.withLock { $0 = nil }
    }

    /// Sends pending changes and fetches new ones now, rather than when the engine would.
    public func syncNow() async throws {
        guard let syncEngine = engine.withLock({ $0 }) else { return }
        try await syncEngine.fetchChanges()
        try await syncEngine.sendChanges()
    }

    /// Hands the store's pending changes to the engine as they happen.
    private func startSending(with syncEngine: CKSyncEngine) {
        let changes = store.observePendingChanges()
        observation.withLock { task in
            guard task == nil else { return }
            task = Task { [weak self] in
                do {
                    for try await pending in changes {
                        self?.hand(pending, to: syncEngine)
                    }
                } catch {
                    self?.logger.error("Watching for changes stopped: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Starts over with the current account: forgets iCloud bookkeeping, makes sure the zone
    /// exists, and runs the first sync again after the next fetch.
    private func startOver(_ syncEngine: CKSyncEngine) async throws {
        observation.withLock { task in
            task?.cancel()
            task = nil
        }
        try await store.resetSyncMetadata()
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        Task { try? await syncEngine.fetchChanges() }
    }

    /// Tells the engine about pending changes. It ignores ones it already has.
    private func hand(_ pending: [PendingSyncChange], to syncEngine: CKSyncEngine) {
        syncEngine.state.add(pendingRecordZoneChanges: pending.map { change in
            let recordID = Self.recordID(for: change.id)
            return change.isDeletion ? .deleteRecord(recordID) : .saveRecord(recordID)
        })
    }

    private func handAllPendingChanges(to syncEngine: CKSyncEngine) async {
        guard let pending = try? await store.pendingChanges() else { return }
        hand(pending, to: syncEngine)
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .stateUpdate(let update):
                try await store.saveEngineState(JSONEncoder().encode(update.stateSerialization))
            case .accountChange(let change):
                try await handleAccountChange(change.changeType, syncEngine: syncEngine)
            case .fetchedDatabaseChanges(let changes):
                // The zone was deleted, from another device or in iCloud settings. This Mac's
                // sidebar stays and becomes the copy in iCloud.
                if changes.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                    try await startOver(syncEngine)
                }
            case .fetchedRecordZoneChanges(let changes):
                let saved = changes.modifications.compactMap { Self.stampedRecord(from: $0.record) }
                let deleted = changes.deletions.compactMap { Self.syncRecordID(recordID: $0.recordID) }
                let arrived = try await store.applyRemoteChanges(saved: saved, deleted: deleted)
                if !arrived.isEmpty { await onSpacesArrived(arrived) }
            case .sentRecordZoneChanges(let sent):
                try await handleSentChanges(sent, syncEngine: syncEngine)
            case .didFetchChanges:
                if try await !store.hasFinishedFirstSync() {
                    try await store.finishFirstSync()
                    startSending(with: syncEngine)
                }
                await onSynced(Date())
            case .didSendChanges:
                await onSynced(Date())
            default:
                break
            }
        } catch {
            logger.error("Couldn't handle \(event.description): \(error.localizedDescription)")
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        let store = store
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            guard let id = Self.syncRecordID(recordID: recordID),
                  let outgoing = try? await store.outgoingRecord(for: id) else {
                // The row is gone or unpinned; its deletion is pending separately.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                if let id = Self.syncRecordID(recordID: recordID) { try? await store.dropSaveIfRowIsGone(id) }
                return nil
            }
            return Self.ckRecord(from: outgoing)
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType, syncEngine: CKSyncEngine) async throws {
        switch change {
        case .signIn, .switchAccounts:
            try await startOver(syncEngine)
        case .signOut:
            // The sidebar stays on this Mac; it just stops syncing with that account.
            observation.withLock { task in
                task?.cancel()
                task = nil
            }
            try await store.resetSyncMetadata()
        @unknown default:
            break
        }
    }

    private func handleSentChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async throws {
        for record in sent.savedRecords {
            guard let id = Self.syncRecordID(recordID: record.recordID) else { continue }
            let sentChangeAt = record["modifiedAt"] as? Date ?? .distantPast
            try await store.didSave(id, systemFields: Self.systemFields(of: record), sentChangeAt: sentChangeAt)
        }
        for recordID in sent.deletedRecordIDs {
            if let id = Self.syncRecordID(recordID: recordID) { try await store.didDelete(id) }
        }
        for failure in sent.failedRecordSaves {
            let recordID = failure.record.recordID
            guard let id = Self.syncRecordID(recordID: recordID) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                if let server = failure.error.serverRecord.flatMap(Self.stampedRecord(from:)),
                   try await store.resolveConflict(with: server) {
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            case .unknownItem:
                try await store.recordWasMissingOnServer(id)
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            case .zoneNotFound:
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            default:
                // The engine retries network and account problems on its own; storage full and
                // signed out need the person, so the iCloud pane says so.
                logger.error("Couldn't save \(id): \(failure.error.localizedDescription)")
                let problem = SyncProblem.from(failure.error)
                if !problem.isTransient { await onProblem(problem) }
            }
        }
        // A row that changed again while its earlier change was being sent still needs sending.
        await handAllPendingChanges(to: syncEngine)
    }

    // MARK: Mapping

    static func recordID(for id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.recordName, zoneID: zoneID)
    }

    /// The sync ID for a CloudKit record ID in Axo's zone.
    static func syncRecordID(recordID: CKRecord.ID) -> SyncRecordID? {
        guard recordID.zoneID == zoneID else { return nil }
        return SyncRecordID(recordName: recordID.recordName)
    }

    /// A CloudKit record for an outgoing record, built on its last system fields so CloudKit
    /// can tell whether it's current.
    static func ckRecord(from stamped: StampedSyncRecord) -> CKRecord {
        let id = stamped.record.id
        let record = stamped.systemFields.flatMap(record(fromSystemFields:))
            ?? CKRecord(recordType: id.type.rawValue, recordID: recordID(for: id))
        for name in SyncRecord.fieldNames(for: id.type) {
            record[name] = stamped.record.fields[name] as NSString?
        }
        record["modifiedAt"] = stamped.record.modifiedAt as NSDate
        return record
    }

    /// The record a CloudKit record carries, with its system fields.
    static func stampedRecord(from record: CKRecord) -> StampedSyncRecord? {
        guard let id = syncRecordID(recordID: record.recordID), id.type.rawValue == record.recordType else { return nil }
        var fields: [String: String] = [:]
        for name in SyncRecord.fieldNames(for: id.type) {
            fields[name] = record[name] as? String
        }
        let modifiedAt = record["modifiedAt"] as? Date ?? record.modificationDate ?? .distantPast
        return StampedSyncRecord(record: SyncRecord(id: id, fields: fields, modifiedAt: modifiedAt), systemFields: systemFields(of: record))
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
