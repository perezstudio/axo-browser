import AxoPersistence
import Foundation
import GRDB

/// An installed web extension, as recorded for a profile.
public struct WebExtensionRecord: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "webExtension"

    /// The profile the extension is installed in.
    public var profileID: Profile.ID
    /// Chrome's extension ID.
    public var extensionID: String
    /// The name from the manifest (possibly a `__MSG_…__` placeholder).
    public var name: String
    /// The version from the manifest.
    public var version: String
    /// The folder with the extension's files.
    public var folderPath: String
    /// Whether the files are a developer's unpacked folder rather than Axo's own copy.
    public var isUnpacked: Bool
    /// Whether the extension runs.
    public var isEnabled: Bool
    /// When it was installed or last updated.
    public var installedAt: Date

    /// Creates a record.
    public init(
        profileID: Profile.ID, extensionID: String, name: String, version: String,
        folderPath: String, isUnpacked: Bool, isEnabled: Bool = true, installedAt: Date = Date()
    ) {
        self.profileID = profileID
        self.extensionID = extensionID
        self.name = name
        self.version = version
        self.folderPath = folderPath
        self.isUnpacked = isUnpacked
        self.isEnabled = isEnabled
        self.installedAt = installedAt
    }

    /// The extension's folder.
    public var folder: URL {
        URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let profileID = Column(CodingKeys.profileID)
        public static let extensionID = Column(CodingKeys.extensionID)
        public static let isEnabled = Column(CodingKeys.isEnabled)
    }
}

/// Records which extensions each profile has installed and enabled.
public final class ExtensionStore: Sendable {
    private let database: AppDatabase

    /// Creates a store over `database`. Usually reached through ``TabStore/extensions``.
    public init(database: AppDatabase) {
        self.database = database
    }

    /// Saves an install or update. An update keeps the extension's enabled state.
    public func save(_ record: WebExtensionRecord) async throws {
        try await database.writer.write { db in
            var record = record
            if let existing = try Self.find(record.extensionID, profileID: record.profileID, db) {
                record.isEnabled = existing.isEnabled
            }
            try record.save(db)
        }
    }

    /// A profile's extensions, by name.
    public func extensions(for profileID: Profile.ID) async throws -> [WebExtensionRecord] {
        try await database.writer.read { db in
            try WebExtensionRecord
                .filter(WebExtensionRecord.Columns.profileID == profileID)
                .fetchAll(db)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// One extension's record, if installed.
    public func record(_ extensionID: String, profileID: Profile.ID) async throws -> WebExtensionRecord? {
        try await database.writer.read { db in try Self.find(extensionID, profileID: profileID, db) }
    }

    /// Turns an extension on or off.
    public func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async throws {
        _ = try await database.writer.write { db in
            try WebExtensionRecord
                .filter(WebExtensionRecord.Columns.profileID == profileID)
                .filter(WebExtensionRecord.Columns.extensionID == extensionID)
                .updateAll(db, WebExtensionRecord.Columns.isEnabled.set(to: enabled))
        }
    }

    /// Forgets an extension. Removing its files is the caller's job.
    public func remove(_ extensionID: String, profileID: Profile.ID) async throws {
        _ = try await database.writer.write { db in
            try WebExtensionRecord
                .filter(WebExtensionRecord.Columns.profileID == profileID)
                .filter(WebExtensionRecord.Columns.extensionID == extensionID)
                .deleteAll(db)
        }
    }

    private static func find(_ extensionID: String, profileID: Profile.ID, _ db: Database) throws -> WebExtensionRecord? {
        try WebExtensionRecord
            .filter(WebExtensionRecord.Columns.profileID == profileID)
            .filter(WebExtensionRecord.Columns.extensionID == extensionID)
            .fetchOne(db)
    }
}

extension TabStore {
    /// Installed extensions, in the same database as the sidebar.
    public var extensions: ExtensionStore {
        ExtensionStore(database: database)
    }
}
