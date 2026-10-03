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

/// Saves the person's answers to sites asking for the camera, microphone, or location, per
/// profile and origin, so pages don't ask again after Axo restarts.
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
            let saved = try SitePermission
                .filter(SitePermission.Columns.profileID == profileID)
                .filter(SitePermission.Columns.origin == origin)
                .fetchAll(db)
            return Dictionary(saved.map { ($0.kind, $0.decision) }, uniquingKeysWith: { _, last in last })
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
