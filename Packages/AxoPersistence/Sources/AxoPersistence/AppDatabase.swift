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
        return migrator
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }
}
