import AxoPersistence
import Foundation
import GRDB

/// A site the person let open links of one scheme in another app (`mailto:`, `zoommtg:`) without
/// asking each time.
public struct ExternalAppPermission: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "externalAppPermission"

    /// The profile it belongs to. Profiles don't share them.
    public var profileID: Profile.ID
    /// The site's origin, such as `https://example.zoom.us` (with a port when it isn't the
    /// scheme's default).
    public var origin: String
    /// The links' scheme, lowercased, such as `zoommtg`.
    public var scheme: String
    /// When the person allowed it.
    public var updatedAt: Date

    /// Creates a saved permission. `scheme` is lowercased.
    public init(profileID: Profile.ID, origin: String, scheme: String, updatedAt: Date = Date()) {
        self.profileID = profileID
        self.origin = origin
        self.scheme = scheme.lowercased()
        self.updatedAt = updatedAt
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let profileID = Column(CodingKeys.profileID)
        public static let origin = Column(CodingKeys.origin)
        public static let scheme = Column(CodingKeys.scheme)
    }
}

/// Saves which sites may open which kinds of links in other apps without asking, per profile.
public final class ExternalAppPermissionStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over `database`. Usually reached through ``TabStore/externalAppPermissions``.
    public init(database: AppDatabase) {
        self.database = database
    }

    /// Whether `origin` may open `scheme` links without asking.
    public func isAllowed(scheme: String, origin: String, profileID: Profile.ID) async throws -> Bool {
        try await database.writer.read { db in
            try Self.matching(scheme: scheme, origin: origin, profileID: profileID).fetchCount(db) > 0
        }
    }

    /// The schemes `origin` may open without asking, sorted.
    public func schemes(origin: String, profileID: Profile.ID) async throws -> [String] {
        try await database.writer.read { db in
            try ExternalAppPermission
                .filter(ExternalAppPermission.Columns.profileID == profileID)
                .filter(ExternalAppPermission.Columns.origin == origin)
                .order(ExternalAppPermission.Columns.scheme)
                .fetchAll(db)
                .map(\.scheme)
        }
    }

    /// Lets `origin` open `scheme` links without asking.
    public func allow(scheme: String, origin: String, profileID: Profile.ID, at date: Date = Date()) async throws {
        try await database.writer.write { db in
            try ExternalAppPermission(profileID: profileID, origin: origin, scheme: scheme, updatedAt: date).save(db)
        }
    }

    /// Makes `origin` ask again before opening `scheme` links.
    public func forget(scheme: String, origin: String, profileID: Profile.ID) async throws {
        _ = try await database.writer.write { db in
            try Self.matching(scheme: scheme, origin: origin, profileID: profileID).deleteAll(db)
        }
    }

    /// Makes `origin` ask again before opening any app.
    public func reset(origin: String, profileID: Profile.ID) async throws {
        _ = try await database.writer.write { db in
            try ExternalAppPermission
                .filter(ExternalAppPermission.Columns.profileID == profileID)
                .filter(ExternalAppPermission.Columns.origin == origin)
                .deleteAll(db)
        }
    }

    private static func matching(scheme: String, origin: String, profileID: Profile.ID) -> QueryInterfaceRequest<ExternalAppPermission> {
        ExternalAppPermission
            .filter(ExternalAppPermission.Columns.profileID == profileID)
            .filter(ExternalAppPermission.Columns.origin == origin)
            .filter(ExternalAppPermission.Columns.scheme == scheme.lowercased())
    }
}

extension TabStore {
    /// Sites allowed to open other apps without asking, in the same database as the sidebar.
    public var externalAppPermissions: ExternalAppPermissionStore {
        ExternalAppPermissionStore(database: database)
    }
}
