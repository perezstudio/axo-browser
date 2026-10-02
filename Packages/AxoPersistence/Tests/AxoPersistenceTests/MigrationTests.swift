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
            #expect(tabColumns == ["id", "spaceID", "url", "title", "sortKey", "isPinned", "archivedAt"])
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
}
