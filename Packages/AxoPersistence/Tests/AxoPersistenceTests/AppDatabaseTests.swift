import Foundation
import GRDB
import Testing
@testable import AxoPersistence

struct AppDatabaseTests {
    @Test func inMemoryDatabaseAppliesAllMigrations() throws {
        let database = try AppDatabase.makeInMemory()
        let applied = try database.writer.read { db in
            try AppDatabase.migrator.appliedIdentifiers(db)
        }
        #expect(applied == Set(AppDatabase.migrator.migrations))
    }

    @Test func foreignKeysAreEnforced() throws {
        let database = try AppDatabase.makeInMemory()
        let enabled = try database.writer.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(enabled == true)
    }

    @Test func onDiskDatabaseCreatesItsDirectoryAndUsesWAL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nested/Axo.sqlite")

        let database = try AppDatabase.openOnDisk(at: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(database.writer is DatabasePool)
        let journalMode = try database.writer.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(journalMode == "wal")
    }
}
