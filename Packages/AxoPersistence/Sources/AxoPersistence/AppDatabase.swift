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

        // Per-extension access the person chose: whether it can reach the sites it requested
        // ("all") or only the tab where it's clicked ("click"), and the optional permissions and
        // site patterns they approved later (a JSON array of strings).
        migrator.registerMigration("v7-extension-access") { db in
            try db.alter(table: "webExtension") { t in
                t.add(column: "siteAccess", .text).notNull().defaults(to: "all")
                t.add(column: "grantedOptional", .text).notNull().defaults(to: "[]")
            }
        }
        // The person's answers to sites asking for the camera, microphone, or location, per
        // profile, so pages don't ask again after Axo restarts. `origin` is the page's origin
        // ("https://meet.example.com", with a port when it isn't the default), `kind` is
        // "camera", "microphone", or "location", and `decision` is "allow" or "deny". No row
        // means Axo asks.
        migrator.registerMigration("v8-site-permissions") { db in
            try db.create(table: "sitePermission") { t in
                t.column("profileID", .blob).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("origin", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["profileID", "origin", "kind"])
            }
        }
        // Split views: two to four tabs shown side by side ("horizontal") or stacked
        // ("vertical"). A tab joins a split through `tab.splitID`, and `tab.splitSortKey` orders
        // the panes (a fractional sort key, like every other ordering). The split's tabs share
        // their section and folder, and the split shows as one sidebar row.
        migrator.registerMigration("v9-tab-splits") { db in
            try db.create(table: "tabSplit") { t in
                t.primaryKey("id", .blob)
                t.column("spaceID", .blob).notNull()
                    .references("space", onDelete: .cascade)
                t.column("orientation", .text).notNull().defaults(to: "horizontal")
            }
            try db.alter(table: "tab") { t in
                t.add(column: "splitID", .blob).references("tabSplit", onDelete: .setNull)
                t.add(column: "splitSortKey", .text)
            }
            try db.create(index: "tab_on_splitID", on: "tab", columns: ["splitID"])
        }
        // Link routing rules: links Axo receives from other apps open in a chosen Space when
        // they come from a given app (`kind` "app", `value` its bundle ID) or go to a given
        // domain and its subdomains (`kind` "domain", `value` the lowercased domain).
        // `displayName` is the app's name, for showing app rules.
        migrator.registerMigration("v10-link-routes") { db in
            try db.create(table: "linkRoute") { t in
                t.primaryKey("id", .blob)
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                t.column("displayName", .text).notNull().defaults(to: "")
                t.column("spaceID", .blob).notNull()
                    .references("space", onDelete: .cascade)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["kind", "value"])
            }
        }
        // Per-site custom CSS and JavaScript, for a domain and its subdomains, in every profile.
        // `css` is added before the page renders; `js` runs in the page once it loads.
        migrator.registerMigration("v11-site-customizations") { db in
            try db.create(table: "siteCustomization") { t in
                t.primaryKey("id", .blob)
                t.column("domain", .text).notNull().unique()
                t.column("css", .text).notNull().defaults(to: "")
                t.column("js", .text).notNull().defaults(to: "")
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("updatedAt", .datetime).notNull()
            }
        }
        // iCloud sync bookkeeping (AxoSync). Profiles, Spaces, folders, and pinned tabs sync.
        // - `syncChange`: one row per synced record changed here and not yet sent, kept by
        //   triggers so every write path is covered. A record's latest change replaces the
        //   earlier one. Unpinning or deleting a pinned tab is a deletion.
        // - `syncApplying`: holds a row while AxoSync writes changes from iCloud, inside that
        //   write's transaction, so the triggers don't send them back.
        // - `syncRecordMetadata`: each record's CloudKit system fields (change tag and so on).
        // - `syncParkedRecord`: records from iCloud waiting for a parent that hasn't arrived.
        // - `syncSetting`: small values by key, such as the sync engine's saved state.
        migrator.registerMigration("v12-sync") { db in
            try db.create(table: "syncChange") { t in
                t.column("recordType", .text).notNull()
                t.column("recordID", .blob).notNull()
                t.column("isDeletion", .boolean).notNull()
                t.column("changedAt", .datetime).notNull()
                t.primaryKey(["recordType", "recordID"])
            }
            try db.create(table: "syncApplying") { t in
                t.column("flag", .integer).notNull()
            }
            try db.create(table: "syncRecordMetadata") { t in
                t.column("recordType", .text).notNull()
                t.column("recordID", .blob).notNull()
                t.column("systemFields", .blob).notNull()
                t.primaryKey(["recordType", "recordID"])
            }
            try db.create(table: "syncParkedRecord") { t in
                t.column("recordType", .text).notNull()
                t.column("recordID", .blob).notNull()
                t.column("record", .blob).notNull()
                t.column("systemFields", .blob)
                t.primaryKey(["recordType", "recordID"])
            }
            try db.create(table: "syncSetting") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob).notNull()
            }

            // GRDB's date format, so `changedAt` reads back as a Date. (An upsert rather than INSERT OR
            // REPLACE: inside a trigger, the outer statement's conflict handling wins.)
            let now = "strftime('%Y-%m-%d %H:%M:%f', 'now')"
            let notApplying = "NOT EXISTS (SELECT 1 FROM syncApplying)"
            func record(_ type: String, _ id: String, deletion: Bool) -> String {
                """
                INSERT INTO syncChange (recordType, recordID, isDeletion, changedAt) VALUES ('\(type)', \(id), \(deletion ? 1 : 0), \(now))
                ON CONFLICT (recordType, recordID) DO UPDATE SET isDeletion = excluded.isDeletion, changedAt = excluded.changedAt;
                """
            }
            func changed(_ columns: [String]) -> String {
                columns.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
            }
            let tables: [(table: String, type: String, columns: [String])] = [
                ("profile", "Profile", ["name"]),
                ("space", "Space", ["profileID", "name", "sortKey"]),
                ("folder", "Folder", ["spaceID", "parentID", "name", "sortKey"]),
            ]
            for (table, type, columns) in tables {
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_sync_insert AFTER INSERT ON \(table) WHEN \(notApplying)
                    BEGIN \(record(type, "NEW.id", deletion: false)) END;
                    CREATE TRIGGER \(table)_sync_update AFTER UPDATE ON \(table)
                    WHEN \(notApplying) AND (\(changed(columns)))
                    BEGIN \(record(type, "NEW.id", deletion: false)) END;
                    CREATE TRIGGER \(table)_sync_delete AFTER DELETE ON \(table) WHEN \(notApplying)
                    BEGIN \(record(type, "OLD.id", deletion: true)) END;
                    """)
            }
            // Only pinned tabs sync. A page change in a pinned tab (url, title) isn't a change;
            // its home page, place, and pinned state are.
            let tabColumns = changed(["isPinned", "homeURL", "sortKey", "folderID", "spaceID"])
            try db.execute(sql: """
                CREATE TRIGGER tab_sync_insert AFTER INSERT ON tab WHEN \(notApplying) AND NEW.isPinned
                BEGIN \(record("Tab", "NEW.id", deletion: false)) END;
                CREATE TRIGGER tab_sync_update AFTER UPDATE ON tab
                WHEN \(notApplying) AND NEW.isPinned AND (\(tabColumns))
                BEGIN \(record("Tab", "NEW.id", deletion: false)) END;
                CREATE TRIGGER tab_sync_unpin AFTER UPDATE ON tab
                WHEN \(notApplying) AND OLD.isPinned AND NOT NEW.isPinned
                BEGIN \(record("Tab", "NEW.id", deletion: true)) END;
                CREATE TRIGGER tab_sync_delete AFTER DELETE ON tab WHEN \(notApplying) AND OLD.isPinned
                BEGIN \(record("Tab", "OLD.id", deletion: true)) END;
                """)
        }

        // A Space's color (a palette name, such as "blue") and icon (an SF Symbol name), both
        // optional. They sync, so the Space trigger from v12 is recreated to notice them.
        migrator.registerMigration("v13-space-appearance") { db in
            try db.alter(table: "space") { t in
                t.add(column: "color", .text)
                t.add(column: "icon", .text)
            }
            let now = "strftime('%Y-%m-%d %H:%M:%f', 'now')"
            let changed = ["profileID", "name", "sortKey", "color", "icon"]
                .map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
            try db.execute(sql: """
                DROP TRIGGER space_sync_update;
                CREATE TRIGGER space_sync_update AFTER UPDATE ON space
                WHEN NOT EXISTS (SELECT 1 FROM syncApplying) AND (\(changed))
                BEGIN
                INSERT INTO syncChange (recordType, recordID, isDeletion, changedAt) VALUES ('Space', NEW.id, 0, \(now))
                ON CONFLICT (recordType, recordID) DO UPDATE SET isDeletion = excluded.isDeletion, changedAt = excluded.changedAt;
                END;
                """)
        }

        // Favorites: pages kept in a grid above the pinned tabs and shared by every Space of a
        // profile. Each has a home URL and title; deleting a profile deletes its favorites.
        // They sync like pinned tabs.
        migrator.registerMigration("v14-favorites") { db in
            try db.create(table: "favorite") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull()
                    .references("profile", onDelete: .cascade)
                t.column("url", .text).notNull()
                t.column("title", .text).notNull().defaults(to: "")
                t.column("sortKey", .text).notNull()
            }
            try db.create(index: "favorite_on_profileID", on: "favorite", columns: ["profileID"])
            let now = "strftime('%Y-%m-%d %H:%M:%f', 'now')"
            let notApplying = "NOT EXISTS (SELECT 1 FROM syncApplying)"
            func record(_ id: String, deletion: Bool) -> String {
                """
                INSERT INTO syncChange (recordType, recordID, isDeletion, changedAt) VALUES ('Favorite', \(id), \(deletion ? 1 : 0), \(now))
                ON CONFLICT (recordType, recordID) DO UPDATE SET isDeletion = excluded.isDeletion, changedAt = excluded.changedAt;
                """
            }
            let changed = ["profileID", "url", "title", "sortKey"].map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
            try db.execute(sql: """
                CREATE TRIGGER favorite_sync_insert AFTER INSERT ON favorite WHEN \(notApplying)
                BEGIN \(record("NEW.id", deletion: false)) END;
                CREATE TRIGGER favorite_sync_update AFTER UPDATE ON favorite WHEN \(notApplying) AND (\(changed))
                BEGIN \(record("NEW.id", deletion: false)) END;
                CREATE TRIGGER favorite_sync_delete AFTER DELETE ON favorite WHEN \(notApplying)
                BEGIN \(record("OLD.id", deletion: true)) END;
                """)
        }

        return migrator
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }
}
