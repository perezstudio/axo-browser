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

        return migrator
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }
}
