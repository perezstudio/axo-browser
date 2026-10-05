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
            #expect(tabColumns == ["id", "spaceID", "url", "title", "sortKey", "isPinned", "archivedAt", "homeURL", "lastActiveAt", "folderID", "splitID", "splitSortKey"])
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

    @Test func v5HistoryIsSearchableAndStaysInSync() throws {
        let database = try AppDatabase.makeInMemory()
        let profileID = UUID()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(sql: """
                INSERT INTO historyItem (profileID, url, title, visitCount, lastVisitedAt)
                VALUES (?, 'https://swift.org/documentation', 'Swift Documentation', 1, CURRENT_TIMESTAMP)
                """, arguments: [profileID])

            func matches(_ query: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyItem_ft WHERE historyItem_ft MATCH ?", arguments: [query]) ?? 0
            }
            #expect(try matches("docum*") == 1, "Titles are indexed")
            #expect(try matches("swift") == 1, "URLs are indexed")

            try db.execute(sql: "UPDATE historyItem SET title = 'Language Guide'")
            #expect(try matches("guide") == 1, "Updates reach the index")
            #expect(try matches("docum*") == 1, "The URL still matches")

            try db.execute(sql: "DELETE FROM profile")
            #expect(try matches("swift") == 0, "Deleting a profile removes its history from the index")
        }
    }

    @Test func v6ExtensionsAreUniquePerProfileAndGoWithIt() throws {
        let database = try AppDatabase.makeInMemory()
        let profileID = UUID()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            let insert = """
                INSERT INTO webExtension (profileID, extensionID, name, version, folderPath, installedAt)
                VALUES (?, 'abcdefghijklmnopabcdefghijklmnop', 'Ext', '1.0', '/tmp/x', CURRENT_TIMESTAMP)
                """
            try db.execute(sql: insert, arguments: [profileID])
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: [profileID]) }
            #expect(try Bool.fetchOne(db, sql: "SELECT isEnabled FROM webExtension") == true)

            try db.execute(sql: "DELETE FROM profile")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM webExtension") == 0)
        }
    }

    @Test func v7DefaultsToFullRequestedAccessAndNoExtras() throws {
        let database = try AppDatabase.makeInMemory()
        let profileID = UUID()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(sql: """
                INSERT INTO webExtension (profileID, extensionID, name, version, folderPath, installedAt)
                VALUES (?, 'id', 'Ext', '1.0', '/tmp/x', CURRENT_TIMESTAMP)
                """, arguments: [profileID])
            let row = try #require(try Row.fetchOne(db, sql: "SELECT siteAccess, grantedOptional FROM webExtension"))
            #expect(row["siteAccess"] as String == "all")
            #expect(row["grantedOptional"] as String == "[]")
        }
    }

    @Test func v8SitePermissionsAreOnePerKindAndGoWithTheirProfile() throws {
        let database = try AppDatabase.makeInMemory()
        let profileID = UUID()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            let insert = """
                INSERT INTO sitePermission (profileID, origin, kind, decision, updatedAt)
                VALUES (?, 'https://meet.example.com', ?, 'allow', CURRENT_TIMESTAMP)
                """
            try db.execute(sql: insert, arguments: [profileID, "camera"])
            try db.execute(sql: insert, arguments: [profileID, "microphone"])
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: [profileID, "camera"]) }

            try db.execute(sql: "DELETE FROM profile")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sitePermission") == 0)
        }
    }

    @Test func v9TabsJoinSplitsThatGoWithTheirSpace() throws {
        let database = try AppDatabase.makeInMemory()
        let (profileID, spaceID, splitID, tabID) = (UUID(), UUID(), UUID(), UUID())
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(sql: "INSERT INTO space (id, profileID, name, sortKey) VALUES (?, ?, 'Home', 'a0')", arguments: [spaceID, profileID])
            try db.execute(sql: "INSERT INTO tabSplit (id, spaceID) VALUES (?, ?)", arguments: [splitID, spaceID])
            #expect(try String.fetchOne(db, sql: "SELECT orientation FROM tabSplit") == "horizontal")
            try db.execute(sql: """
                INSERT INTO tab (id, spaceID, url, sortKey, splitID, splitSortKey) VALUES (?, ?, 'https://a.example', 'a0', ?, 'a0')
                """, arguments: [tabID, spaceID, splitID])

            // Deleting the split frees its tabs; deleting the Space removes the split.
            try db.execute(sql: "DELETE FROM tabSplit")
            #expect(try Row.fetchOne(db, sql: "SELECT splitID FROM tab")?["splitID"] as Data? == nil)
            try db.execute(sql: "INSERT INTO tabSplit (id, spaceID) VALUES (?, ?)", arguments: [splitID, spaceID])
            try db.execute(sql: "DELETE FROM space")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tabSplit") == 0)
        }
    }

    @Test func v10LinkRoutesAreUniqueAndGoWithTheirSpace() throws {
        let database = try AppDatabase.makeInMemory()
        let (profileID, spaceID) = (UUID(), UUID())
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(sql: "INSERT INTO space (id, profileID, name, sortKey) VALUES (?, ?, 'Work', 'a0')", arguments: [spaceID, profileID])
            let insert = "INSERT INTO linkRoute (id, kind, value, spaceID, createdAt) VALUES (?, 'domain', 'github.com', ?, CURRENT_TIMESTAMP)"
            try db.execute(sql: insert, arguments: [UUID(), spaceID])
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: [UUID(), spaceID]) }
            try db.execute(sql: "DELETE FROM space")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM linkRoute") == 0)
        }
    }

    @Test func v11SiteCustomizationsAreOnePerDomainAndOnByDefault() throws {
        let database = try AppDatabase.makeInMemory()
        try database.writer.write { db in
            let insert = "INSERT INTO siteCustomization (id, domain, updatedAt) VALUES (?, 'example.com', CURRENT_TIMESTAMP)"
            try db.execute(sql: insert, arguments: [UUID()])
            #expect(throws: DatabaseError.self) { try db.execute(sql: insert, arguments: [UUID()]) }
            let row = try #require(try Row.fetchOne(db, sql: "SELECT css, js, isEnabled FROM siteCustomization"))
            #expect(row["css"] as String == "" && row["js"] as String == "" && row["isEnabled"] as Bool == true)
        }
    }

    @Test func v12RecordsChangesToSyncedRowsOnly() throws {
        let database = try AppDatabase.makeInMemory()
        let profileID = UUID(), spaceID = UUID(), pinnedID = UUID(), unpinnedID = UUID()
        try database.writer.write { db in
            func changes() throws -> [String: Bool] {
                let rows = try Row.fetchAll(db, sql: "SELECT recordType, isDeletion FROM syncChange")
                return Dictionary(rows.map { ($0["recordType"] as String, $0["isDeletion"] as Bool) }, uniquingKeysWith: { $1 })
            }
            try db.execute(sql: "INSERT INTO profile (id, name) VALUES (?, 'Default')", arguments: [profileID])
            try db.execute(sql: "INSERT INTO space (id, profileID, name, sortKey) VALUES (?, ?, 'Home', 'a0')", arguments: [spaceID, profileID])
            try db.execute(sql: "INSERT INTO tab (id, spaceID, url, sortKey, isPinned) VALUES (?, ?, 'https://a.example', 'a0', 1)", arguments: [pinnedID, spaceID])
            try db.execute(sql: "INSERT INTO tab (id, spaceID, url, sortKey) VALUES (?, ?, 'https://b.example', 'a1')", arguments: [unpinnedID, spaceID])
            #expect(try changes() == ["Profile": false, "Space": false, "Tab": false])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncChange WHERE recordType = 'Tab'") == 1, "Unpinned tabs don't sync")
            let changedAt = try #require(try Date.fetchOne(db, sql: "SELECT changedAt FROM syncChange WHERE recordType = 'Profile'"))
            #expect(abs(changedAt.timeIntervalSinceNow) < 60)

            // Page changes and unchanged writes aren't changes; moves are.
            try db.execute(sql: "DELETE FROM syncChange")
            try db.execute(sql: "UPDATE tab SET url = 'https://a.example/next', title = 'Next', lastActiveAt = CURRENT_TIMESTAMP")
            try db.execute(sql: "UPDATE space SET name = 'Home'")
            #expect(try changes().isEmpty)
            try db.execute(sql: "UPDATE tab SET sortKey = 'b0' WHERE id = ?", arguments: [pinnedID])
            #expect(try changes() == ["Tab": false])

            // Unpinning or deleting a pinned tab is a deletion, which replaces the earlier change.
            try db.execute(sql: "UPDATE tab SET isPinned = 0 WHERE id = ?", arguments: [pinnedID])
            #expect(try changes() == ["Tab": true])
            try db.execute(sql: "DELETE FROM syncChange")
            try db.execute(sql: "DELETE FROM tab WHERE id = ?", arguments: [unpinnedID])
            #expect(try changes().isEmpty)

            // Writes from iCloud aren't recorded.
            try db.execute(sql: "INSERT INTO syncApplying (flag) VALUES (1)")
            try db.execute(sql: "UPDATE space SET name = 'From iCloud'")
            try db.execute(sql: "DELETE FROM syncApplying")
            #expect(try changes().isEmpty)

            // Deleting a profile records its Space as deleted too.
            try db.execute(sql: "DELETE FROM profile")
            #expect(try changes() == ["Profile": true, "Space": true])
        }
    }
}
