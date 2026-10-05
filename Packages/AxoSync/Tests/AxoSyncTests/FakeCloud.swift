import AxoCore
import AxoPersistence
import Foundation
@testable import AxoSync

/// An in-memory stand-in for a CloudKit zone, with CloudKit's rules for change tags: saving
/// needs the record's current tag (or no tag for a new record), and a stale tag is a conflict.
actor FakeCloud {
    enum SaveResult {
        case saved(systemFields: Data)
        case conflict(server: StampedSyncRecord)
        case missing
    }

    private var records: [SyncRecordID: (record: SyncRecord, tag: Int)] = [:]
    /// Every save and deletion, in order, for fetching changes since a point.
    private var log: [(id: SyncRecordID, isDeletion: Bool)] = []
    private var nextTag = 1

    private static func systemFields(_ tag: Int) -> Data { Data(String(tag).utf8) }
    private static func tag(from systemFields: Data?) -> Int? { systemFields.flatMap { Int(String(decoding: $0, as: UTF8.self)) } }

    func save(_ stamped: StampedSyncRecord) -> SaveResult {
        let id = stamped.record.id
        let sentTag = Self.tag(from: stamped.systemFields)
        if let existing = records[id] {
            guard sentTag == existing.tag else {
                return .conflict(server: StampedSyncRecord(record: existing.record, systemFields: Self.systemFields(existing.tag)))
            }
        } else if sentTag != nil {
            return .missing
        }
        defer { nextTag += 1 }
        records[id] = (stamped.record, nextTag)
        log.append((id, false))
        return .saved(systemFields: Self.systemFields(nextTag))
    }

    func delete(_ id: SyncRecordID) {
        records[id] = nil
        log.append((id, true))
    }

    /// Changes after `position` in the log, with the new position.
    func changes(since position: Int) -> (saved: [StampedSyncRecord], deleted: [SyncRecordID], position: Int) {
        var saved: [SyncRecordID: StampedSyncRecord] = [:]
        var deleted: Set<SyncRecordID> = []
        for entry in log[position...] {
            if entry.isDeletion {
                saved[entry.id] = nil
                deleted.insert(entry.id)
            } else if let current = records[entry.id] {
                deleted.remove(entry.id)
                saved[entry.id] = StampedSyncRecord(record: current.record, systemFields: Self.systemFields(current.tag))
            }
        }
        return (Array(saved.values), Array(deleted), log.count)
    }

    func record(_ id: SyncRecordID) -> SyncRecord? { records[id]?.record }
    var recordCount: Int { records.count }
}

/// One device: its own database, the sidebar store the app uses, and the sync store.
final class Device {
    let database: AppDatabase
    let tabs: TabStore
    let sync: SyncStore
    let cloud: FakeCloud
    /// How far into the cloud's change log this device has fetched.
    private var position = 0

    init(cloud: FakeCloud) throws {
        database = try AppDatabase.makeInMemory()
        tabs = TabStore(database: database)
        sync = SyncStore(database: database)
        self.cloud = cloud
    }

    /// Sends local changes, then fetches everyone else's, like one round of the sync engine.
    func sync(sendOnly: Bool = false) async throws {
        for change in try await sync.pendingChanges() {
            if change.isDeletion {
                await cloud.delete(change.id)
                try await sync.didDelete(change.id)
                continue
            }
            guard let outgoing = try await sync.outgoingRecord(for: change.id) else {
                try await sync.dropSaveIfRowIsGone(change.id)
                continue
            }
            switch await cloud.save(outgoing) {
            case .saved(let systemFields):
                try await sync.didSave(change.id, systemFields: systemFields, sentChangeAt: change.changedAt)
            case .conflict(let server):
                if try await sync.resolveConflict(with: server), let retry = try await sync.outgoingRecord(for: change.id),
                   case .saved(let systemFields) = await cloud.save(retry) {
                    try await sync.didSave(change.id, systemFields: systemFields, sentChangeAt: change.changedAt)
                }
            case .missing:
                try await sync.recordWasMissingOnServer(change.id)
                if let retry = try await sync.outgoingRecord(for: change.id), case .saved(let systemFields) = await cloud.save(retry) {
                    try await sync.didSave(change.id, systemFields: systemFields, sentChangeAt: change.changedAt)
                }
            }
        }
        guard !sendOnly else { return }
        try await fetch()
    }

    /// Fetches changes from the cloud since the last fetch.
    func fetch() async throws {
        let changes = await cloud.changes(since: position)
        position = changes.position
        try await sync.applyRemoteChanges(saved: changes.saved, deleted: changes.deleted)
    }
}
