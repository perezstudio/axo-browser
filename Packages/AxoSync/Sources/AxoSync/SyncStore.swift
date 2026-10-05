import AxoPersistence
import Foundation
import GRDB

/// The database side of sync: what changed here, what each synced row looks like as a
/// ``SyncRecord``, and applying records from iCloud. It knows nothing about CloudKit, so the
/// CloudKit adapter and tests (with a fake cloud) share it.
///
/// Local changes are recorded by triggers (migration `v12-sync`), so every write path counts.
/// Conflicts are settled per record: the later change wins (``SyncRecord/modifiedAt`` against
/// the pending local change's time). A record from iCloud whose parent hasn't arrived yet, such
/// as a tab before its Space, waits until it does.
public final class SyncStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over Axo's database.
    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Local changes

    /// Every local change not yet sent, oldest first.
    public func pendingChanges() async throws -> [PendingSyncChange] {
        try await database.writer.read { db in try Self.pendingChanges(db) }
    }

    /// Streams the local changes not yet sent: the current list first, then a new list after
    /// every change.
    public func observePendingChanges() -> AsyncValueObservation<[PendingSyncChange]> {
        ValueObservation
            .tracking { db in try Self.pendingChanges(db) }
            .values(in: database.writer)
    }

    private static func pendingChanges(_ db: Database) throws -> [PendingSyncChange] {
        try Row.fetchAll(db, sql: "SELECT recordType, recordID, isDeletion, changedAt FROM syncChange ORDER BY changedAt").compactMap { row in
            guard let type = SyncRecordType(rawValue: row["recordType"]) else { return nil }
            return PendingSyncChange(id: SyncRecordID(type, row["recordID"]), isDeletion: row["isDeletion"], changedAt: row["changedAt"])
        }
    }

    private static func pendingChange(for id: SyncRecordID, _ db: Database) throws -> PendingSyncChange? {
        try Row.fetchOne(db, sql: "SELECT isDeletion, changedAt FROM syncChange WHERE recordType = ? AND recordID = ?", arguments: [id.type.rawValue, id.id])
            .map { PendingSyncChange(id: id, isDeletion: $0["isDeletion"], changedAt: $0["changedAt"]) }
    }

    /// Marks every synced row as changed, so it's all sent. Used for the first sync and after
    /// signing in to a different iCloud account.
    public func markEverythingChanged() async throws {
        try await database.writer.write { db in
            let now = Date()
            for type in SyncRecordType.allCases {
                let filter = type == .tab ? " WHERE isPinned" : ""
                let ids = try UUID.fetchAll(db, sql: "SELECT id FROM \(type.table)\(filter)")
                for id in ids {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO syncChange (recordType, recordID, isDeletion, changedAt) VALUES (?, ?, 0, ?)",
                        arguments: [type.rawValue, id, now]
                    )
                }
            }
        }
    }

    /// The record to send for a local change: the row's current values, stamped with the
    /// change's time and the system fields last seen. `nil` when the row is gone (or, for a
    /// tab, no longer pinned), which means it should be deleted instead.
    public func outgoingRecord(for id: SyncRecordID) async throws -> StampedSyncRecord? {
        try await database.writer.read { db in
            let modifiedAt = try Self.pendingChange(for: id, db)?.changedAt ?? Date()
            guard let record = try Self.localRecord(for: id, modifiedAt: modifiedAt, db) else { return nil }
            return StampedSyncRecord(record: record, systemFields: try Self.systemFields(for: id, db))
        }
    }

    /// Drops a queued save whose row no longer exists here. (Its deletion, if it was ever sent,
    /// is queued separately.)
    public func dropSaveIfRowIsGone(_ id: SyncRecordID) async throws {
        try await database.writer.write { db in
            guard try Self.localRecord(for: id, modifiedAt: Date(), db) == nil else { return }
            try db.execute(sql: "DELETE FROM syncChange WHERE recordType = ? AND recordID = ? AND NOT isDeletion", arguments: [id.type.rawValue, id.id])
        }
    }

    /// Notes that a record was saved in iCloud. The change is done unless the row changed
    /// again after `sentChangeAt`.
    public func didSave(_ id: SyncRecordID, systemFields: Data, sentChangeAt: Date) async throws {
        try await database.writer.write { db in
            try Self.setSystemFields(systemFields, for: id, db)
            try db.execute(
                sql: "DELETE FROM syncChange WHERE recordType = ? AND recordID = ? AND NOT isDeletion AND changedAt <= ?",
                arguments: [id.type.rawValue, id.id, sentChangeAt]
            )
        }
    }

    /// Notes that a record was deleted in iCloud.
    public func didDelete(_ id: SyncRecordID) async throws {
        try await database.writer.write { db in
            try Self.setSystemFields(nil, for: id, db)
            try db.execute(sql: "DELETE FROM syncChange WHERE recordType = ? AND recordID = ? AND isDeletion", arguments: [id.type.rawValue, id.id])
        }
    }

    /// Notes that iCloud no longer has a record this Mac tried to update, because another
    /// device deleted it. The local change is newer than anything known about the deletion, so
    /// it stays pending and the next send creates the record again.
    public func recordWasMissingOnServer(_ id: SyncRecordID) async throws {
        try await database.writer.write { db in try Self.setSystemFields(nil, for: id, db) }
    }

    // MARK: Changes from iCloud

    /// Applies records saved and deleted on other devices.
    ///
    /// A saved record replaces the local row unless the row has a later pending change; then
    /// the local change wins and will be sent, carrying the new system fields. Deletions always
    /// apply and drop any pending change to the row. Records whose parent is missing wait, and
    /// are tried again each time changes arrive.
    public func applyRemoteChanges(saved: [StampedSyncRecord], deleted: [SyncRecordID]) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "INSERT INTO syncApplying (flag) VALUES (1)")
            for id in deleted.sorted(by: { $0.type > $1.type }) {
                try Self.applyDeletion(of: id, db)
            }
            for stamped in saved.sorted(by: { $0.record.id.type < $1.record.id.type }) {
                let id = stamped.record.id
                if let pending = try Self.pendingChange(for: id, db), pending.changedAt > stamped.record.modifiedAt {
                    if let systemFields = stamped.systemFields { try Self.setSystemFields(systemFields, for: id, db) }
                    continue
                }
                try db.execute(sql: "DELETE FROM syncChange WHERE recordType = ? AND recordID = ?", arguments: [id.type.rawValue, id.id])
                if try !Self.apply(stamped, db) { try Self.park(stamped, db) }
            }
            try Self.retryParkedRecords(db)
            try db.execute(sql: "DELETE FROM syncApplying")
        }
    }

    /// Settles a conflict iCloud reported for a local change, given the server's record.
    ///
    /// - Returns: `true` when the local change is later and should be sent again (with the
    ///   server's system fields); `false` when the server's record won and was applied here.
    public func resolveConflict(with server: StampedSyncRecord) async throws -> Bool {
        try await applyRemoteChanges(saved: [server], deleted: [])
        return try await database.writer.read { db in
            try Self.pendingChange(for: server.record.id, db) != nil
        }
    }

    // MARK: Engine state and resets

    /// The sync engine's saved state, if any.
    public func engineState() async throws -> Data? {
        try await database.writer.read { db in try Self.setting("engineState", db) }
    }

    /// Saves the sync engine's state.
    public func saveEngineState(_ data: Data) async throws {
        try await database.writer.write { db in try Self.setSetting("engineState", data, db) }
    }

    /// Whether this Mac has finished its first sync with the current iCloud account: fetched
    /// what's in iCloud, merged an untouched Home Space into it, and queued the rest to send.
    /// Until then, local changes wait, so a new device doesn't upload its empty Home Space.
    public func hasFinishedFirstSync() async throws -> Bool {
        try await database.writer.read { db in try Self.setting("firstSyncDone", db) != nil }
    }

    /// Finishes the first sync, after the first fetch from iCloud.
    ///
    /// If this Mac's only Space is untouched (it hasn't come from iCloud and has no pinned tabs
    /// or folders) and iCloud brought other Spaces, the untouched Space's open tabs, splits, and
    /// link rules move to the first synced Space, and the untouched Space and its profile (if
    /// nothing else uses it) are removed. Then every local row is queued to send.
    ///
    /// - Returns: The removed Space's ID and the Space its tabs moved to, if it merged.
    @discardableResult
    public func finishFirstSync() async throws -> (removed: UUID, mergedInto: UUID)? {
        let merge = try await database.writer.write { db -> (removed: UUID, mergedInto: UUID)? in
            try db.execute(sql: "INSERT INTO syncApplying (flag) VALUES (1)")
            defer { try? db.execute(sql: "DELETE FROM syncApplying") }
            let synced = "SELECT recordID FROM syncRecordMetadata WHERE recordType = 'Space'"
            let local = try Row.fetchAll(db, sql: "SELECT id, profileID FROM space WHERE id NOT IN (\(synced))")
            guard local.count == 1, let localSpace = local.first,
                  let target = try UUID.fetchOne(db, sql: "SELECT id FROM space WHERE id IN (\(synced)) ORDER BY sortKey, id")
            else { return nil }
            let spaceID: UUID = localSpace["id"], profileID: UUID = localSpace["profileID"]
            let isUntouched = try Bool.fetchOne(db, sql: """
                SELECT NOT EXISTS (SELECT 1 FROM tab WHERE spaceID = ? AND isPinned)
                   AND NOT EXISTS (SELECT 1 FROM folder WHERE spaceID = ?)
                """, arguments: [spaceID, spaceID]) ?? false
            guard isUntouched else { return nil }
            // Spaces from iCloud hold only pinned tabs here, so open tabs keep their sort keys.
            for table in ["tab", "tabSplit", "linkRoute"] {
                try db.execute(sql: "UPDATE \(table) SET spaceID = ? WHERE spaceID = ?", arguments: [target, spaceID])
            }
            try db.execute(sql: "DELETE FROM space WHERE id = ?", arguments: [spaceID])
            // It was never sent, so its queued changes go with it.
            try db.execute(sql: "DELETE FROM syncChange WHERE recordID = ?", arguments: [spaceID])
            let profileSynced = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncRecordMetadata WHERE recordType = 'Profile' AND recordID = ?)", arguments: [profileID]) ?? false
            let profileUsed = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM space WHERE profileID = ?)", arguments: [profileID]) ?? false
            if !profileSynced && !profileUsed {
                // Its website data stays on disk, unused; nothing here deletes browsing data.
                try db.execute(sql: "DELETE FROM profile WHERE id = ?", arguments: [profileID])
                try db.execute(sql: "DELETE FROM syncChange WHERE recordID = ?", arguments: [profileID])
            }
            return (spaceID, target)
        }
        try await markEverythingChanged()
        try await database.writer.write { db in try Self.setSetting("firstSyncDone", Data([1]), db) }
        return merge
    }

    /// Forgets everything iCloud-specific (system fields, waiting records, engine state, unsent
    /// changes, and the first sync), keeping the sidebar itself. Used when the iCloud account
    /// changes.
    public func resetSyncMetadata() async throws {
        try await database.writer.write { db in
            for table in ["syncRecordMetadata", "syncParkedRecord", "syncSetting", "syncChange"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    private static func setting(_ key: String, _ db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT value FROM syncSetting WHERE key = ?", arguments: [key])
    }

    private static func setSetting(_ key: String, _ value: Data, _ db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO syncSetting (key, value) VALUES (?, ?)", arguments: [key, value])
    }

    /// The number of records from iCloud waiting for their parent.
    func parkedRecordCount() async throws -> Int {
        try await database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncParkedRecord") ?? 0 }
    }

    // MARK: Rows and records

    static func localRecord(for id: SyncRecordID, modifiedAt: Date, _ db: Database) throws -> SyncRecord? {
        let sql = switch id.type {
        case .profile: "SELECT name FROM profile WHERE id = ?"
        case .space: "SELECT profileID, name, sortKey, color, icon FROM space WHERE id = ?"
        case .folder: "SELECT spaceID, parentID, name, sortKey FROM folder WHERE id = ?"
        case .tab: "SELECT spaceID, folderID, COALESCE(homeURL, url) AS url, title, sortKey FROM tab WHERE id = ? AND isPinned"
        }
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [id.id]) else { return nil }
        var fields: [String: String] = [:]
        for name in SyncRecord.fieldNames(for: id.type) {
            if name.hasSuffix("ID") {
                fields[name] = (row[name] as UUID?)?.uuidString.lowercased()
            } else {
                fields[name] = row[name] as String?
            }
        }
        return SyncRecord(id: id, fields: fields, modifiedAt: modifiedAt)
    }

    /// Writes a record from iCloud into its table.
    ///
    /// - Returns: `false` if its parent isn't here yet (or it's missing a required field, which
    ///   leaves it waiting harmlessly).
    private static func apply(_ stamped: SyncRecord.Stamped, _ db: Database) throws -> Bool {
        let record = stamped.record
        let id = record.id.id
        func exists(_ table: String, _ id: UUID?) throws -> Bool {
            guard let id else { return false }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE id = ?)", arguments: [id]) ?? false
        }
        func optionalParentExists(_ field: String, in table: String) throws -> Bool {
            record.fields[field] == nil ? true : try exists(table, record.uuid(field))
        }
        switch record.id.type {
        case .profile:
            guard let name = record.fields["name"] else { return false }
            try db.execute(
                sql: "INSERT INTO profile (id, name) VALUES (?, ?) ON CONFLICT (id) DO UPDATE SET name = excluded.name",
                arguments: [id, name]
            )
        case .space:
            guard let name = record.fields["name"], let sortKey = record.fields["sortKey"],
                  try exists("profile", record.uuid("profileID")) else { return false }
            try db.execute(sql: """
                INSERT INTO space (id, profileID, name, sortKey, color, icon) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET profileID = excluded.profileID, name = excluded.name,
                    sortKey = excluded.sortKey, color = excluded.color, icon = excluded.icon
                """, arguments: [id, record.uuid("profileID"), name, sortKey, record.fields["color"], record.fields["icon"]])
        case .folder:
            guard let name = record.fields["name"], let sortKey = record.fields["sortKey"],
                  try exists("space", record.uuid("spaceID")),
                  try optionalParentExists("parentID", in: "folder") else { return false }
            try db.execute(sql: """
                INSERT INTO folder (id, spaceID, parentID, name, sortKey) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET spaceID = excluded.spaceID, parentID = excluded.parentID,
                    name = excluded.name, sortKey = excluded.sortKey
                """, arguments: [id, record.uuid("spaceID"), record.uuid("parentID"), name, sortKey])
        case .tab:
            guard let url = record.fields["url"], let sortKey = record.fields["sortKey"],
                  try exists("space", record.uuid("spaceID")),
                  try optionalParentExists("folderID", in: "folder") else { return false }
            // A pinned tab here keeps its current page and title; only its home page and place
            // change. A tab that leaves its Space leaves its split there.
            try db.execute(sql: """
                INSERT INTO tab (id, spaceID, folderID, url, homeURL, title, sortKey, isPinned, lastActiveAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT (id) DO UPDATE SET
                    splitID = CASE WHEN spaceID IS excluded.spaceID THEN splitID END,
                    splitSortKey = CASE WHEN spaceID IS excluded.spaceID THEN splitSortKey END,
                    url = CASE WHEN isPinned THEN url ELSE excluded.url END,
                    title = CASE WHEN isPinned THEN title ELSE excluded.title END,
                    spaceID = excluded.spaceID, folderID = excluded.folderID, homeURL = excluded.homeURL,
                    sortKey = excluded.sortKey, isPinned = 1, archivedAt = NULL
                """, arguments: [id, record.uuid("spaceID"), record.uuid("folderID"), url, url, record.fields["title"] ?? "", sortKey, Date()])
        }
        try db.execute(sql: "DELETE FROM syncParkedRecord WHERE recordType = ? AND recordID = ?", arguments: [record.id.type.rawValue, id])
        if let systemFields = stamped.systemFields { try setSystemFields(systemFields, for: record.id, db) }
        return true
    }

    private static func applyDeletion(of id: SyncRecordID, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM \(id.type.table) WHERE id = ?", arguments: [id.id])
        try db.execute(sql: "DELETE FROM syncChange WHERE recordType = ? AND recordID = ?", arguments: [id.type.rawValue, id.id])
        try db.execute(sql: "DELETE FROM syncParkedRecord WHERE recordType = ? AND recordID = ?", arguments: [id.type.rawValue, id.id])
        try setSystemFields(nil, for: id, db)
    }

    private static func park(_ stamped: SyncRecord.Stamped, _ db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO syncParkedRecord (recordType, recordID, record, systemFields) VALUES (?, ?, ?, ?)",
            arguments: [stamped.record.id.type.rawValue, stamped.record.id.id, try JSONEncoder().encode(stamped.record), stamped.systemFields]
        )
    }

    /// Applies waiting records whose parents have arrived, repeating while that helps (a
    /// folder inside a folder that was itself waiting, for example).
    private static func retryParkedRecords(_ db: Database) throws {
        var progressed = true
        while progressed {
            progressed = false
            let parked = try Row.fetchAll(db, sql: "SELECT record, systemFields FROM syncParkedRecord").compactMap { row -> SyncRecord.Stamped? in
                guard let record = try? JSONDecoder().decode(SyncRecord.self, from: row["record"] as Data) else { return nil }
                return SyncRecord.Stamped(record: record, systemFields: row["systemFields"])
            }
            for stamped in parked.sorted(by: { $0.record.id.type < $1.record.id.type }) {
                if try apply(stamped, db) { progressed = true }
            }
        }
    }

    private static func systemFields(for id: SyncRecordID, _ db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT systemFields FROM syncRecordMetadata WHERE recordType = ? AND recordID = ?", arguments: [id.type.rawValue, id.id])
    }

    private static func setSystemFields(_ data: Data?, for id: SyncRecordID, _ db: Database) throws {
        if let data {
            try db.execute(
                sql: "INSERT OR REPLACE INTO syncRecordMetadata (recordType, recordID, systemFields) VALUES (?, ?, ?)",
                arguments: [id.type.rawValue, id.id, data]
            )
        } else {
            try db.execute(sql: "DELETE FROM syncRecordMetadata WHERE recordType = ? AND recordID = ?", arguments: [id.type.rawValue, id.id])
        }
    }
}

extension SyncRecord {
    /// Shorthand inside the store.
    typealias Stamped = StampedSyncRecord
}
