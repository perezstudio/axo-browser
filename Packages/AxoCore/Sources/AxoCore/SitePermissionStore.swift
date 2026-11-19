import AxoPersistence
import Foundation
import GRDB

/// The person's saved answer to a site asking to use a device or capability.
public struct SitePermission: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sitePermission"

    /// What a site can ask to use. Requests for the camera and microphone together are saved
    /// as one answer for each.
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case camera
        case microphone
        case location
        case notifications
        case clipboard
    }

    /// The saved answer. Without one, Axo asks.
    public enum Decision: String, Codable, Hashable, Sendable {
        case allow
        case deny
    }

    /// The profile the answer belongs to. Profiles don't share answers.
    public var profileID: Profile.ID
    /// The site's origin, such as `https://meet.example.com` (with a port when it isn't the
    /// scheme's default).
    public var origin: String
    public var kind: Kind
    public var decision: Decision
    /// When the answer was given or last changed.
    public var updatedAt: Date

    /// Creates a saved answer.
    public init(profileID: Profile.ID, origin: String, kind: Kind, decision: Decision, updatedAt: Date = Date()) {
        self.profileID = profileID
        self.origin = origin
        self.kind = kind
        self.decision = decision
        self.updatedAt = updatedAt
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let profileID = Column(CodingKeys.profileID)
        public static let origin = Column(CodingKeys.origin)
        public static let kind = Column(CodingKeys.kind)
    }
}

/// A profile's saved answers and defaults at one moment.
public struct SitePermissionSnapshot: Equatable, Sendable {
    /// Every site's answers, by origin.
    public var answers: [SitePermission]
    /// What sites without an answer get, by kind; a kind with none asks.
    public var defaults: [SitePermission.Kind: SitePermission.Decision]

    public init(answers: [SitePermission], defaults: [SitePermission.Kind: SitePermission.Decision]) {
        self.answers = answers
        self.defaults = defaults
    }
}

/// Saves the person's answers to sites asking for the camera, microphone, location,
/// notifications, or the clipboard, per profile and origin, so pages don't ask again after Axo
/// restarts.
public final class SitePermissionStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over `database`. Usually reached through ``TabStore/sitePermissions``.
    public init(database: AppDatabase) {
        self.database = database
    }

    /// The saved answer for a kind on a site, or `nil` if Axo should ask.
    public func decision(_ kind: SitePermission.Kind, origin: String, profileID: Profile.ID) async throws -> SitePermission.Decision? {
        try await database.writer.read { db in
            try SitePermission
                .filter(SitePermission.Columns.profileID == profileID)
                .filter(SitePermission.Columns.origin == origin)
                .filter(SitePermission.Columns.kind == kind.rawValue)
                .fetchOne(db)?
                .decision
        }
    }

    /// Every saved answer for a site, by kind.
    public func decisions(origin: String, profileID: Profile.ID) async throws -> [SitePermission.Kind: SitePermission.Decision] {
        try await database.writer.read { db in
            // Only kinds this version knows, so a newer version's rows don't break the rest.
            let saved = try SitePermission
                .filter(SitePermission.Columns.profileID == profileID)
                .filter(SitePermission.Columns.origin == origin)
                .filter(SitePermission.Kind.allCases.map(\.rawValue).contains(SitePermission.Columns.kind))
                .fetchAll(db)
            return Dictionary(saved.map { ($0.kind, $0.decision) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// Every saved answer for some kinds, in every profile and site, so the engine's own copy of
    /// them can be brought in step at launch.
    public func all(_ kinds: Set<SitePermission.Kind>) async throws -> [SitePermission] {
        try await database.writer.read { db in
            try SitePermission
                .filter(kinds.map(\.rawValue).contains(SitePermission.Columns.kind))
                .fetchAll(db)
        }
    }

    /// Saves an answer for some kinds on a site, or forgets them when `decision` is `nil`, so
    /// Axo asks again.
    public func setDecision(
        _ decision: SitePermission.Decision?,
        for kinds: Set<SitePermission.Kind>,
        origin: String,
        profileID: Profile.ID,
        at date: Date = Date()
    ) async throws {
        try await database.writer.write { db in
            for kind in kinds {
                if let decision {
                    try SitePermission(profileID: profileID, origin: origin, kind: kind, decision: decision, updatedAt: date).save(db)
                } else {
                    _ = try SitePermission
                        .filter(SitePermission.Columns.profileID == profileID)
                        .filter(SitePermission.Columns.origin == origin)
                        .filter(SitePermission.Columns.kind == kind.rawValue)
                        .deleteAll(db)
                }
            }
        }
    }

    /// Every site's saved answer for a kind in a profile, by origin, for Settings' Website
    /// Permissions pane.
    public func permissions(_ kind: SitePermission.Kind, profileID: Profile.ID) async throws -> [SitePermission] {
        try await database.writer.read { db in
            try SitePermission
                .filter(SitePermission.Columns.profileID == profileID)
                .filter(SitePermission.Columns.kind == kind.rawValue)
                .order(SitePermission.Columns.origin)
                .fetchAll(db)
        }
    }

    /// Forgets every site's answer for a kind in a profile, so they all ask again. Returns the
    /// origins forgotten.
    @discardableResult
    public func removeAll(_ kind: SitePermission.Kind, profileID: Profile.ID) async throws -> [String] {
        try await database.writer.write { db in
            let request = SitePermission
                .filter(SitePermission.Columns.profileID == profileID)
                .filter(SitePermission.Columns.kind == kind.rawValue)
            let origins = try request.fetchAll(db).map(\.origin)
            _ = try request.deleteAll(db)
            return origins
        }
    }

    /// What sites without an answer get, by kind, in a profile. A kind with no default asks.
    public func defaults(profileID: Profile.ID) async throws -> [SitePermission.Kind: SitePermission.Decision] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT kind, decision FROM sitePermissionDefault WHERE profileID = ?", arguments: [profileID])
            // Only kinds and decisions this version knows.
            return Dictionary(rows.compactMap { row -> (SitePermission.Kind, SitePermission.Decision)? in
                guard let kind = SitePermission.Kind(rawValue: row["kind"]),
                      let decision = SitePermission.Decision(rawValue: row["decision"]) else { return nil }
                return (kind, decision)
            }, uniquingKeysWith: { _, last in last })
        }
    }

    /// Every profile's defaults for some kinds, so the engine's copy can be brought in step at
    /// launch.
    public func allDefaults(_ kinds: Set<SitePermission.Kind>) async throws -> [(profileID: Profile.ID, kind: SitePermission.Kind, decision: SitePermission.Decision)] {
        try await database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT profileID, kind, decision FROM sitePermissionDefault").compactMap { row in
                guard let kind = SitePermission.Kind(rawValue: row["kind"]), kinds.contains(kind),
                      let decision = SitePermission.Decision(rawValue: row["decision"]) else { return nil }
                return (row["profileID"] as UUID, kind, decision)
            }
        }
    }

    /// Sets what sites without an answer get for a kind, or `nil` for Ask.
    public func setDefault(_ decision: SitePermission.Decision?, for kind: SitePermission.Kind, profileID: Profile.ID) async throws {
        try await database.writer.write { db in
            if let decision {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sitePermissionDefault (profileID, kind, decision) VALUES (?, ?, ?)",
                    arguments: [profileID, kind.rawValue, decision.rawValue]
                )
            } else {
                try db.execute(sql: "DELETE FROM sitePermissionDefault WHERE profileID = ? AND kind = ?", arguments: [profileID, kind.rawValue])
            }
        }
    }

    /// Streams a profile's answers and defaults: the current ones first, then again after every
    /// change, for Settings' Website Permissions pane.
    public func observe(profileID: Profile.ID) -> AsyncValueObservation<SitePermissionSnapshot> {
        ValueObservation
            .tracking { db in
                let answers = try SitePermission
                    .filter(SitePermission.Columns.profileID == profileID)
                    .filter(SitePermission.Kind.allCases.map(\.rawValue).contains(SitePermission.Columns.kind))
                    .order(SitePermission.Columns.origin)
                    .fetchAll(db)
                let rows = try Row.fetchAll(db, sql: "SELECT kind, decision FROM sitePermissionDefault WHERE profileID = ?", arguments: [profileID])
                let defaults = Dictionary(rows.compactMap { row -> (SitePermission.Kind, SitePermission.Decision)? in
                    guard let kind = SitePermission.Kind(rawValue: row["kind"]),
                          let decision = SitePermission.Decision(rawValue: row["decision"]) else { return nil }
                    return (kind, decision)
                }, uniquingKeysWith: { _, last in last })
                return SitePermissionSnapshot(answers: answers, defaults: defaults)
            }
            .values(in: database.writer)
    }

    /// Forgets every answer for a site, so it asks again.
    public func reset(origin: String, profileID: Profile.ID) async throws {
        _ = try await database.writer.write { db in
            try SitePermission
                .filter(SitePermission.Columns.profileID == profileID)
                .filter(SitePermission.Columns.origin == origin)
                .deleteAll(db)
        }
    }
}

extension TabStore {
    /// Saved answers to sites' permission requests, in the same database as the sidebar.
    public var sitePermissions: SitePermissionStore {
        SitePermissionStore(database: database)
    }
}
