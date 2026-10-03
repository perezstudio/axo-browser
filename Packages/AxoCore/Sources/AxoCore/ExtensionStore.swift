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
    /// Which sites the extension can reach.
    public var siteAccess: SiteAccess
    /// Optional permissions and site patterns the person approved after install, as WebKit names
    /// them (for example `cookies` or `*://*.example.com/*`).
    public var grantedOptional: [String]

    /// Which sites an extension can reach.
    public enum SiteAccess: String, Codable, Sendable, CaseIterable {
        /// Every site it asked for.
        case all
        /// Only the tab where the person clicks its toolbar button.
        case click
    }

    /// Creates a record.
    public init(
        profileID: Profile.ID, extensionID: String, name: String, version: String,
        folderPath: String, isUnpacked: Bool, isEnabled: Bool = true, installedAt: Date = Date(),
        siteAccess: SiteAccess = .all, grantedOptional: [String] = []
    ) {
        self.profileID = profileID
        self.extensionID = extensionID
        self.name = name
        self.version = version
        self.folderPath = folderPath
        self.isUnpacked = isUnpacked
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.siteAccess = siteAccess
        self.grantedOptional = grantedOptional
    }

    // Stored as text: the access as its raw value and approvals as a JSON array.
    enum CodingKeys: String, CodingKey {
        case profileID, extensionID, name, version, folderPath, isUnpacked, isEnabled, installedAt, siteAccess, grantedOptional
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        extensionID = try container.decode(String.self, forKey: .extensionID)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        folderPath = try container.decode(String.self, forKey: .folderPath)
        isUnpacked = try container.decode(Bool.self, forKey: .isUnpacked)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        siteAccess = (try? container.decode(SiteAccess.self, forKey: .siteAccess)) ?? .all
        let approvals = (try? container.decode(String.self, forKey: .grantedOptional)) ?? "[]"
        grantedOptional = (try? JSONDecoder().decode([String].self, from: Data(approvals.utf8))) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(extensionID, forKey: .extensionID)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(isUnpacked, forKey: .isUnpacked)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(installedAt, forKey: .installedAt)
        try container.encode(siteAccess, forKey: .siteAccess)
        let approvals = String(decoding: try JSONEncoder().encode(grantedOptional), as: UTF8.self)
        try container.encode(approvals, forKey: .grantedOptional)
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

    /// Saves an install or update. An update keeps the extension's enabled state, site access,
    /// and approvals.
    public func save(_ record: WebExtensionRecord) async throws {
        try await database.writer.write { db in
            var record = record
            if let existing = try Self.find(record.extensionID, profileID: record.profileID, db) {
                record.isEnabled = existing.isEnabled
                record.siteAccess = existing.siteAccess
                record.grantedOptional = existing.grantedOptional
            }
            try record.save(db)
        }
    }

    /// Sets which sites an extension can reach.
    public func setSiteAccess(_ access: WebExtensionRecord.SiteAccess, extensionID: String, profileID: Profile.ID) async throws {
        try await update(extensionID, profileID: profileID) { $0.siteAccess = access }
    }

    /// Records optional permissions or site patterns the person approved.
    public func addGrantedOptional(_ approvals: [String], extensionID: String, profileID: Profile.ID) async throws {
        try await update(extensionID, profileID: profileID) { record in
            record.grantedOptional = Array(Set(record.grantedOptional).union(approvals)).sorted()
        }
    }

    private func update(_ extensionID: String, profileID: Profile.ID, _ change: @escaping @Sendable (inout WebExtensionRecord) -> Void) async throws {
        try await database.writer.write { db in
            guard var record = try Self.find(extensionID, profileID: profileID, db) else { return }
            change(&record)
            try record.update(db)
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
