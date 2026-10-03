import Foundation
import GRDB

/// Axo's single SQLite database.
///
/// Everything Axo stores lives here: the sidebar model, history, bookmarks, and the FTS5 index
/// the command bar searches. Writes go through the database's single writer; reads can run
/// concurrently when the database is backed by a `DatabasePool`.
public final class AppDatabase: Sendable {
    /// The underlying GRDB connection: a `DatabasePool` on disk, or a `DatabaseQueue` in memory.
    public let writer: any DatabaseWriter

    /// Wraps a GRDB writer and runs every pending migration.
    ///
    /// - Parameter writer: The connection to use. Prefer ``openOnDisk(at:)`` or ``makeInMemory()``.
    /// - Throws: Any error raised while migrating.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens or creates the database file at `url`, backed by a `DatabasePool` (WAL mode).
    ///
    /// Creates the parent directory if it does not exist.
    public static func openOnDisk(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return try AppDatabase(DatabasePool(path: url.path, configuration: makeConfiguration()))
    }

    /// Creates an empty, migrated database in memory. Intended for tests and previews.
    public static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    /// The versioned schema migrations, applied in order.
    ///
    /// Add new migrations at the end. Never edit a migration that has shipped.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        // Rebuild the schema when a migration's definition changes during development.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        // Profiles, Spaces, and tabs. Every ID is a UUID stored as a 16-byte blob (GRDB's
        // default), and ordering uses fractional `sortKey` strings compared bytewise.
        migrator.registerMigration("v1-profiles-spaces-tabs") { db in
            try db.create(table: "profile") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
            }
            try db.create(table: "space") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("sortKey", .text).notNull()
            }
            try db.create(index: "space_on_profileID_sortKey", on: "space", columns: ["profileID", "sortKey"])
            try db.create(table: "tab") { t in
                t.primaryKey("id", .blob)
                t.column("spaceID", .blob).notNull()
                    .references("space", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("sortKey", .text).notNull()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("archivedAt", .datetime)
            }
            try db.create(index: "tab_on_spaceID_sortKey", on: "tab", columns: ["spaceID", "sortKey"])
        }

        // Site icons, keyed by host so every tab on a site shares one icon. Stored as small
        // normalized PNGs, so the sidebar can show them without network access after a relaunch.
        migrator.registerMigration("v2-favicons") { db in
            try db.create(table: "favicon") { t in
                t.primaryKey("host", .text)
                t.column("data", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // Pinned tabs remember a home page, and every tab records when it was last shown so
        // unpinned tabs can archive after a period of inactivity. Existing tabs count as active
        // now, so none archive the moment this migration runs.
        migrator.registerMigration("v3-pinned-home-and-activity") { db in
            try db.alter(table: "tab") { t in
                t.add(column: "homeURL", .text)
                t.add(column: "lastActiveAt", .datetime)
            }
            try db.execute(sql: "UPDATE tab SET lastActiveAt = CURRENT_TIMESTAMP")
            try db.create(index: "tab_on_archivedAt", on: "tab", columns: ["archivedAt"])
        }

        // Folders: a tree inside a Space's pinned section. Folders and pinned tabs at the same
        // level share one fractional order. Deleting a Space deletes its folders; deleting a
        // folder leaves its tabs (AxoCore moves them up a level first; SET NULL is a backstop).
        migrator.registerMigration("v4-folders") { db in
            try db.create(table: "folder") { t in
                t.primaryKey("id", .blob)
                t.column("spaceID", .blob).notNull()
                    .references("space", onDelete: .cascade)
                t.column("parentID", .blob)
                    .references("folder", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("sortKey", .text).notNull()
                t.column("isExpanded", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "folder_on_spaceID_parentID", on: "folder", columns: ["spaceID", "parentID"])
            try db.alter(table: "tab") { t in
                t.add(column: "folderID", .blob).references("folder", onDelete: .setNull)
            }
            try db.create(index: "tab_on_folderID", on: "tab", columns: ["folderID"])
        }

        // Browsing history, one row per profile and URL, with an FTS5 index over title and
        // URL that SQLite keeps in sync through triggers. The command bar searches it on every
        // keystroke.
        migrator.registerMigration("v5-history") { db in
            try db.create(table: "historyItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .blob).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("visitCount", .integer).notNull().defaults(to: 0)
                t.column("lastVisitedAt", .datetime).notNull()
                t.uniqueKey(["profileID", "url"])
            }
            try db.create(index: "historyItem_on_profileID_lastVisitedAt", on: "historyItem", columns: ["profileID", "lastVisitedAt"])
            try db.create(virtualTable: "historyItem_ft", using: FTS5()) { t in
                t.synchronize(withTable: "historyItem")
                t.tokenizer = .unicode61()
                t.column("title")
                t.column("url")
            }
        }

        // Installed web extensions, per profile. Files live on disk (Axo's extensions folder,
        // or a developer's folder for unpacked extensions); this table records which are
        // installed and whether each is enabled.
        migrator.registerMigration("v6-extensions") { db in
            try db.create(table: "webExtension") { t in
                t.column("profileID", .blob).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("extensionID", .text).notNull()
                t.column("name", .text).notNull()
                t.column("version", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("isUnpacked", .boolean).notNull().defaults(to: false)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("installedAt", .datetime).notNull()
                t.primaryKey(["profileID", "extensionID"])
            }
        }

        return migrator
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }
}
