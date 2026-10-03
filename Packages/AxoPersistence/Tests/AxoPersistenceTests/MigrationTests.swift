import Foundation
import GRDB
import Testing
@testable import AxoPersistence

struct MigrationTests {
    @Test func v1CreatesProfileSpaceAndTabTables() throws {
        let database = try AppDatabase.makeInMemory()
        try database.writer.read { db in
            #expect(try db.tableExists("profile"))
            #expect(try db.tableExists("space"))
            #expect(try db.tableExists("tab"))
            let tabColumns = try db.columns(in: "tab").map(\.name)
            #expect(tabColumns == ["id", "spaceID", "url", "title", "sortKey", "isPinned", "archivedAt", "homeURL", "lastActiveAt", "folderID"])
        }
    }

    @Test func deletingAProfileCascadesToItsSpacesAndTabs() throws {
        let database = try AppDatabase.makeInMemory()
        let profileID = UUID(), spaceID = UUID()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(
                sql: "INSERT INTO space (id, profileID, name, sortKey) VALUES (?, ?, 'Home', 'a0')",
                arguments: [spaceID, profileID]
            )
            try db.execute(
                sql: "INSERT INTO tab (id, spaceID, url, sortKey) VALUES (?, ?, 'https://example.com', 'a0')",
                arguments: [UUID(), spaceID]
            )

            try db.execute(sql: "DELETE FROM profile WHERE id = ?", arguments: [profileID])

            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM space") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tab") == 0)
        }
    }

    @Test func aTabMustBelongToAnExistingSpace() throws {
        let database = try AppDatabase.makeInMemory()
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO tab (id, spaceID, url, sortKey) VALUES (?, ?, 'https://example.com', 'a0')",
                    arguments: [UUID(), UUID()]
                )
            }
        }
    }

    @Test func newTabsDefaultToUntitledUnpinnedAndActive() throws {
        let database = try AppDatabase.makeInMemory()
        let profileID = UUID(), spaceID = UUID(), tabID = UUID()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(
                sql: "INSERT INTO space (id, profileID, name, sortKey) VALUES (?, ?, 'Home', 'a0')",
                arguments: [spaceID, profileID]
            )
            try db.execute(
                sql: "INSERT INTO tab (id, spaceID, url, sortKey) VALUES (?, ?, 'https://example.com', 'a0')",
                arguments: [tabID, spaceID]
            )
            let row = try #require(try Row.fetchOne(db, sql: "SELECT title, isPinned, archivedAt FROM tab"))
            #expect(row["title"] as String == "")
            #expect(row["isPinned"] as Bool == false)
            #expect(row["archivedAt"] as Date? == nil)
        }
    }

    @Test func v2CreatesTheFaviconTableKeyedByHost() throws {
        let database = try AppDatabase.makeInMemory()
        try database.writer.write { db in
            #expect(try db.columns(in: "favicon").map(\.name) == ["host", "data", "updatedAt"])
            #expect(try db.primaryKey("favicon").columns == ["host"])
            try db.execute(
                sql: "INSERT INTO favicon (host, data, updatedAt) VALUES ('example.com', x'00', CURRENT_TIMESTAMP)"
            )
            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: "INSERT INTO favicon (host, data, updatedAt) VALUES ('example.com', x'01', CURRENT_TIMESTAMP)"
                )
            }
        }
    }

    @Test func v3MarksExistingTabsActiveAtMigrationTime() throws {
        // Migrate to v2, add a tab, then run v3 and check the tab got an activity date.
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v2-favicons")
        let profileID = UUID(), spaceID = UUID()
        try queue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(sql: "INSERT INTO space (id, profileID, name, sortKey) VALUES (?, ?, 'Home', 'a0')", arguments: [spaceID, profileID])
            try db.execute(sql: "INSERT INTO tab (id, spaceID, url, sortKey) VALUES (?, ?, 'https://example.com', 'a0')", arguments: [UUID(), spaceID])
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT homeURL, lastActiveAt FROM tab"))
            #expect(row["homeURL"] as String? == nil)
            let lastActive = try #require(row["lastActiveAt"] as Date?)
            #expect(abs(lastActive.timeIntervalSinceNow) < 60)
        }
    }

    @Test func v4FoldersNestAndCleanUpWithTheirSpace() throws {
        let database = try AppDatabase.makeInMemory()
        let profileID = UUID(), spaceID = UUID(), outer = UUID(), inner = UUID(), tabID = UUID()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(sql: "INSERT INTO space (id, profileID, name, sortKey) VALUES (?, ?, 'Home', 'a0')", arguments: [spaceID, profileID])
            try db.execute(sql: "INSERT INTO folder (id, spaceID, name, sortKey) VALUES (?, ?, 'Outer', 'a0')", arguments: [outer, spaceID])
            try db.execute(sql: "INSERT INTO folder (id, spaceID, parentID, name, sortKey) VALUES (?, ?, ?, 'Inner', 'a0')", arguments: [inner, spaceID, outer])
            try db.execute(sql: "INSERT INTO tab (id, spaceID, url, sortKey, isPinned, folderID, lastActiveAt) VALUES (?, ?, 'https://a.com', 'a0', 1, ?, CURRENT_TIMESTAMP)", arguments: [tabID, spaceID, inner])

            #expect(try Bool.fetchOne(db, sql: "SELECT isExpanded FROM folder WHERE id = ?", arguments: [outer]) == true)

            // Deleting a folder deletes its subfolders, and their tabs lose the folder.
            try db.execute(sql: "DELETE FROM folder WHERE id = ?", arguments: [outer])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folder") == 0)
            #expect(try Row.fetchOne(db, sql: "SELECT folderID FROM tab")?["folderID"] as Data? == nil)

            // Deleting the Space deletes its folders.
            try db.execute(sql: "INSERT INTO folder (id, spaceID, name, sortKey) VALUES (?, ?, 'Again', 'a0')", arguments: [UUID(), spaceID])
            try db.execute(sql: "DELETE FROM space WHERE id = ?", arguments: [spaceID])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM folder") == 0)
        }
    }
}
