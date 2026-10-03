import AxoPersistence
import Foundation
import GRDB

/// Where to place a tab within its section (pinned or unpinned) of its Space's list.
public enum TabPosition: Hashable, Sendable {
    /// Before every other tab in the section.
    case start
    /// After every other tab in the section.
    case end
    /// Directly after the tab with this ID, which must be in the same section.
    case after(Tab.ID)
}

/// Errors thrown by ``TabStore``.
public enum TabStoreError: Error, Equatable {
    /// No tab with this ID exists.
    case tabNotFound(Tab.ID)
    /// The tab used as a position anchor is in a different Space.
    case anchorInDifferentSpace(Tab.ID)
    /// The tab used as a position anchor is pinned and the moving tab isn't, or the reverse.
    case anchorInDifferentSection(Tab.ID)
    /// No Space with this ID exists.
    case spaceNotFound(Space.ID)
    /// The last Space can't be deleted; a window always shows one.
    case cannotDeleteLastSpace
    /// No folder with this ID exists.
    case folderNotFound(Folder.ID)
    /// The folder belongs to another Space.
    case folderInDifferentSpace(Folder.ID)
    /// The move would put a folder inside itself.
    case folderCycle(Folder.ID)
    /// No profile with this ID exists.
    case profileNotFound(Profile.ID)
    /// A profile can't be deleted while Spaces still use it.
    case profileInUse(Profile.ID)
    /// The split already has ``TabSplit/maximumPanes`` tabs.
    case splitFull(TabSplit.ID)
}

/// Reads and writes the sidebar model: profiles, Spaces, and tabs.
///
/// Writes run off the main actor through the database's single writer, each in its own
/// transaction. To keep SwiftUI in sync, observe ``tabsRequest(in:)`` with `ValueObservation`
/// or GRDBQuery instead of re-fetching.
public final class TabStore: Sendable {
    /// The name of the profile created on first launch.
    public static let defaultProfileName = "Default"
    /// The name of the Space created on first launch.
    public static let defaultSpaceName = "Home"

    let database: AppDatabase

    /// Creates a store over `database`.
    public init(database: AppDatabase) {
        self.database = database
    }

    /// Opens or creates Axo's database file at `url` and returns a store over it.
    public static func openOnDisk(at url: URL) throws -> TabStore {
        TabStore(database: try AppDatabase.openOnDisk(at: url))
    }

    /// Returns a store over an empty in-memory database, for tests, previews, and UI testing.
    public static func makeInMemory() throws -> TabStore {
        TabStore(database: try AppDatabase.makeInMemory())
    }

    // MARK: Spaces

    /// Returns the first Space, creating a default profile and Space if none exist yet.
    ///
    /// Call this on launch before showing a window.
    @discardableResult
    public func bootstrap() async throws -> Space {
        try await database.writer.write { db in
            if let space = try Space.order(Space.Columns.sortKey, Space.Columns.id).fetchOne(db) {
                return space
            }
            let profile = try Profile.fetchOne(db) ?? Profile(name: Self.defaultProfileName)
            try profile.save(db)
            let space = Space(profileID: profile.id, name: Self.defaultSpaceName, sortKey: SortKey.initial)
            try space.insert(db)
            return space
        }
    }

    /// Returns every Space in sidebar order.
    public func spaces() async throws -> [Space] {
        try await database.writer.read { db in
            try Space.order(Space.Columns.sortKey, Space.Columns.id).fetchAll(db)
        }
    }

    /// Streams every Space in sidebar order: the current list first, then a new list after
    /// every change.
    public func observeSpaces() -> AsyncValueObservation<[Space]> {
        ValueObservation
            .tracking { db in try Space.order(Space.Columns.sortKey, Space.Columns.id).fetchAll(db) }
            .values(in: database.writer)
    }

    /// Creates a Space after the existing ones.
    ///
    /// - Throws: ``TabStoreError/profileNotFound(_:)`` if the profile doesn't exist.
    @discardableResult
    public func createSpace(name: String, profileID: Profile.ID) async throws -> Space {
        try await database.writer.write { db in
            guard try Profile.exists(db, id: profileID) else { throw TabStoreError.profileNotFound(profileID) }
            let last = try Space.order(Space.Columns.sortKey.desc, Space.Columns.id.desc).fetchOne(db)
            let space = Space(profileID: profileID, name: name, sortKey: try SortKey.between(last?.sortKey, nil))
            try space.insert(db)
            return space
        }
    }

    /// Renames a Space.
    public func renameSpace(id: Space.ID, to name: String) async throws {
        try await database.writer.write { db in
            guard var space = try Space.fetchOne(db, id: id) else { throw TabStoreError.spaceNotFound(id) }
            space.name = name
            try space.update(db)
        }
    }

    /// Deletes a Space and all its tabs. The Space's profile and its website data are kept.
    ///
    /// - Returns: The IDs of the deleted tabs, so their web views can be discarded.
    /// - Throws: ``TabStoreError/cannotDeleteLastSpace`` for the only Space, or
    ///   ``TabStoreError/spaceNotFound(_:)``.
    @discardableResult
    public func deleteSpace(id: Space.ID) async throws -> [Tab.ID] {
        try await database.writer.write { db in
            guard try Space.exists(db, id: id) else { throw TabStoreError.spaceNotFound(id) }
            guard try Space.fetchCount(db) > 1 else { throw TabStoreError.cannotDeleteLastSpace }
            let tabIDs = try Tab.filter(Tab.Columns.spaceID == id).fetchAll(db).map(\.id)
            try Space.deleteOne(db, id: id)
            return tabIDs
        }
    }

    // MARK: Profiles

    /// Returns every profile, by name.
    public func profiles() async throws -> [Profile] {
        try await database.writer.read { db in
            try Profile.order(Column("name").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        }
    }

    /// Creates a profile. AxoWeb gives it its own website data store the first time a tab uses it.
    @discardableResult
    public func createProfile(name: String) async throws -> Profile {
        try await database.writer.write { db in
            let profile = Profile(name: name)
            try profile.insert(db)
            return profile
        }
    }

    /// Renames a profile.
    public func renameProfile(id: Profile.ID, to name: String) async throws {
        try await database.writer.write { db in
            guard var profile = try Profile.fetchOne(db, id: id) else { throw TabStoreError.profileNotFound(id) }
            profile.name = name
            try profile.update(db)
        }
    }

    /// Deletes a profile that no Space uses. Removing its website data is the caller's job
    /// (`WKWebsiteDataStore.remove(forIdentifier:)` in AxoWeb).
    ///
    /// - Throws: ``TabStoreError/profileInUse(_:)`` while a Space uses it.
    public func deleteProfile(id: Profile.ID) async throws {
        try await database.writer.write { db in
            guard try Profile.exists(db, id: id) else { throw TabStoreError.profileNotFound(id) }
            guard try Space.filter(Space.Columns.profileID == id).fetchCount(db) == 0 else {
                throw TabStoreError.profileInUse(id)
            }
            try Profile.deleteOne(db, id: id)
        }
    }

    // MARK: Tabs

    /// The request for a Space's tabs that are not archived, in sidebar order: pinned tabs
    /// first, then the others, each by sort key.
    ///
    /// Use it with `ValueObservation` or GRDBQuery to keep a view up to date.
    public static func tabsRequest(in spaceID: Space.ID) -> QueryInterfaceRequest<Tab> {
        Tab
            .filter(Tab.Columns.spaceID == spaceID)
            .filter(Tab.Columns.archivedAt == nil)
            .order(Tab.Columns.isPinned.desc, Tab.Columns.sortKey, Tab.Columns.id)
    }

    /// Streams a Space's tabs that are not archived, in sidebar order: the current list first,
    /// then a new list after every change.
    public func observeTabs(in spaceID: Space.ID) -> AsyncValueObservation<[Tab]> {
        ValueObservation
            .tracking(Self.tabsRequest(in: spaceID).fetchAll)
            .values(in: database.writer)
    }

    /// Returns a Space's tabs that are not archived, in sidebar order.
    public func tabs(in spaceID: Space.ID) async throws -> [Tab] {
        try await database.writer.read { db in
            try Self.tabsRequest(in: spaceID).fetchAll(db)
        }
    }

    /// Returns the tab with `id`, or `nil` if it doesn't exist.
    public func tab(id: Tab.ID) async throws -> Tab? {
        try await database.writer.read { db in
            try Tab.fetchOne(db, id: id)
        }
    }

    /// Creates an unpinned tab for `url` in a Space.
    ///
    /// - Parameters:
    ///   - url: The page to open.
    ///   - title: The page title if already known.
    ///   - spaceID: The Space to add the tab to.
    ///   - position: Where to place the tab. Defaults to the end of the list.
    ///   - id: The new tab's ID. Pass one to keep a page that was already showing under that ID
    ///     (such as a Peek being promoted to a tab), so its web view carries over.
    /// - Returns: The new tab.
    @discardableResult
    public func openTab(
        id: Tab.ID = UUID(),
        url: URL,
        title: String = "",
        in spaceID: Space.ID,
        at position: TabPosition = .end
    ) async throws -> Tab {
        try await database.writer.write { db in
            let sortKey = try Self.sortKey(for: position, in: spaceID, pinned: false, folder: nil, excluding: nil, db)
            let tab = Tab(id: id, spaceID: spaceID, url: url, title: title, sortKey: sortKey)
            try tab.insert(db)
            // Return the stored record: the database keeps dates to the millisecond.
            return try Tab.fetchOne(db, id: tab.id) ?? tab
        }
    }

    /// Moves a tab within its section of its Space. Only the moved tab's row changes.
    ///
    /// - Throws: ``TabStoreError`` if the tab or the anchor tab doesn't exist, or the anchor is
    ///   in another Space or section.
    public func moveTab(id: Tab.ID, to position: TabPosition) async throws {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: id) else { throw TabStoreError.tabNotFound(id) }
            if case .after(let anchorID) = position, anchorID == id { return }
            tab.sortKey = try Self.sortKey(for: position, in: tab.spaceID, pinned: tab.isPinned, folder: tab.folderID, excluding: id, db)
            try tab.update(db)
            try Self.alignSplit(containing: id, db)
        }
    }

    /// Updates a tab's page and title, for example after a navigation.
    ///
    /// - Throws: ``TabStoreError/tabNotFound(_:)`` if the tab doesn't exist.
    public func updateTab(id: Tab.ID, url: URL, title: String) async throws {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: id) else { throw TabStoreError.tabNotFound(id) }
            tab.url = url
            tab.title = title
            try tab.update(db)
        }
    }

    /// Deletes a tab for good. Closing a tab in the sidebar archives it instead; see
    /// ``archiveTab(id:at:)``.
    ///
    /// Deleting a tab that doesn't exist does nothing.
    public func deleteTab(id: Tab.ID) async throws {
        _ = try await database.writer.write { db in
            try Self.leaveSplit(id, db)
            return try Tab.deleteOne(db, id: id)
        }
    }

    // MARK: Pinning

    /// Pins or unpins a tab, moving it to the end of its new section (the top level of the
    /// pinned section, outside any folder). Pinning remembers the current page as the tab's home
    /// URL; unpinning forgets it.
    public func setPinned(_ pinned: Bool, tabID: Tab.ID) async throws {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: tabID) else { throw TabStoreError.tabNotFound(tabID) }
            guard tab.isPinned != pinned else { return }
            tab.sortKey = try Self.sortKey(for: .end, in: tab.spaceID, pinned: pinned, folder: nil, excluding: tabID, db)
            tab.isPinned = pinned
            tab.folderID = nil
            tab.homeURL = pinned ? tab.url : nil
            try tab.update(db)
            // A split is pinned or not as a whole.
            try Self.alignSplit(containing: tabID, db)
        }
    }

    /// Makes a pinned tab's current page its home URL.
    public func setHomeURL(_ url: URL, tabID: Tab.ID) async throws {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: tabID) else { throw TabStoreError.tabNotFound(tabID) }
            guard tab.isPinned else { return }
            tab.homeURL = url
            try tab.update(db)
        }
    }

    /// Points a pinned tab back at its home URL, for example when it's closed. The page title
    /// updates when the page loads.
    ///
    /// - Returns: The home URL, or `nil` if the tab isn't pinned.
    @discardableResult
    public func resetPinnedTab(id: Tab.ID) async throws -> URL? {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: id) else { throw TabStoreError.tabNotFound(id) }
            guard tab.isPinned, let homeURL = tab.homeURL else { return nil }
            if tab.url != homeURL {
                tab.url = homeURL
                tab.title = ""
                try tab.update(db)
            }
            return homeURL
        }
    }

    // MARK: Activity and archiving

    /// Records that a tab was shown at `date`, which delays its auto-archiving.
    public func markActive(id: Tab.ID, at date: Date = Date()) async throws {
        _ = try await database.writer.write { db in
            try Tab.filter(id: id).updateAll(db, Tab.Columns.lastActiveAt.set(to: date))
        }
    }

    /// Archives a tab: it leaves the sidebar but can be restored. Pinned tabs can be archived too
    /// (when unpinned first is preferred); archiving an archived tab does nothing.
    public func archiveTab(id: Tab.ID, at date: Date = Date()) async throws {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: id) else { throw TabStoreError.tabNotFound(id) }
            guard tab.archivedAt == nil else { return }
            try Self.leaveSplit(id, db)
            tab = try Tab.fetchOne(db, id: id) ?? tab
            tab.archivedAt = date
            try tab.update(db)
        }
    }

    /// Archives every unpinned tab, in every Space, that hasn't been shown since `cutoff`.
    ///
    /// - Parameter keeping: Tabs to leave alone even if they're idle, such as the ones on screen.
    /// - Returns: The IDs of the tabs that were archived.
    @discardableResult
    public func archiveInactiveTabs(
        lastActiveBefore cutoff: Date,
        keeping: Set<Tab.ID> = [],
        at date: Date = Date()
    ) async throws -> [Tab.ID] {
        try await database.writer.write { db in
            let idle = try Tab
                .filter(Tab.Columns.archivedAt == nil)
                .filter(Tab.Columns.isPinned == false)
                .filter(Tab.Columns.lastActiveAt < cutoff)
                .fetchAll(db)
                .map(\.id)
                .filter { !keeping.contains($0) }
            for id in idle { try Self.leaveSplit(id, db) }
            try Tab.filter(keys: idle).updateAll(db, Tab.Columns.archivedAt.set(to: date))
            return idle
        }
    }

    /// A Space's archived tabs, most recently archived first.
    public func archivedTabs(in spaceID: Space.ID) async throws -> [Tab] {
        try await database.writer.read { db in
            try Tab
                .filter(Tab.Columns.spaceID == spaceID)
                .filter(Tab.Columns.archivedAt != nil)
                .order(Tab.Columns.archivedAt.desc, Tab.Columns.id)
                .fetchAll(db)
        }
    }

    /// Puts an archived tab back at the end of its section and marks it active.
    ///
    /// - Returns: The restored tab.
    @discardableResult
    public func restoreTab(id: Tab.ID, at date: Date = Date()) async throws -> Tab {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: id) else { throw TabStoreError.tabNotFound(id) }
            guard tab.archivedAt != nil else { return tab }
            tab.sortKey = try Self.sortKey(for: .end, in: tab.spaceID, pinned: tab.isPinned, folder: tab.folderID, excluding: id, db)
            tab.archivedAt = nil
            tab.lastActiveAt = date
            try tab.update(db)
            return try Tab.fetchOne(db, id: id) ?? tab
        }
    }

    // MARK: Favicons

    /// Saves the icon for `url`'s host, replacing any older one. Does nothing for URLs without a
    /// host, such as `about:blank`.
    public func saveFavicon(_ data: Data, for url: URL) async throws {
        guard let host = Favicon.key(for: url) else { return }
        try await database.writer.write { db in
            try Favicon(host: host, data: data).save(db)
        }
    }

    /// Returns the saved icons for these hosts, keyed by host. Hosts without an icon are omitted.
    public func favicons(forHosts hosts: some Collection<String>) async throws -> [String: Data] {
        let keys = Set(hosts.map { $0.lowercased() })
        guard !keys.isEmpty else { return [:] }
        return try await database.writer.read { db in
            let records = try Favicon.filter(keys: keys).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: records.map { ($0.host, $0.data) })
        }
    }

    // MARK: Folders

    /// A Space's folders, in no particular order. Build the tree from `parentID` and order each
    /// level by `sortKey` together with its pinned tabs.
    public func folders(in spaceID: Space.ID) async throws -> [Folder] {
        try await database.writer.read { db in
            try Folder.filter(Folder.Columns.spaceID == spaceID).order(Folder.Columns.sortKey).fetchAll(db)
        }
    }

    /// Streams a Space's folders after every change.
    public func observeFolders(in spaceID: Space.ID) -> AsyncValueObservation<[Folder]> {
        ValueObservation
            .tracking { db in try Folder.filter(Folder.Columns.spaceID == spaceID).order(Folder.Columns.sortKey).fetchAll(db) }
            .values(in: database.writer)
    }

    /// Creates a folder at the end of a level of a Space's pinned section.
    ///
    /// - Parameter parent: The folder to create it in, or `nil` for the top level.
    @discardableResult
    public func createFolder(named name: String, in spaceID: Space.ID, parent: Folder.ID? = nil) async throws -> Folder {
        try await database.writer.write { db in
            guard try Space.exists(db, id: spaceID) else { throw TabStoreError.spaceNotFound(spaceID) }
            if let parent {
                guard let parentFolder = try Folder.fetchOne(db, id: parent) else { throw TabStoreError.folderNotFound(parent) }
                guard parentFolder.spaceID == spaceID else { throw TabStoreError.folderInDifferentSpace(parent) }
            }
            let keys = try Self.pinnedLevelKeys(in: spaceID, parent: parent, excluding: nil, db)
            let folder = Folder(spaceID: spaceID, parentID: parent, name: name, sortKey: try SortKey.between(keys.last, nil))
            try folder.insert(db)
            return folder
        }
    }

    /// Renames a folder.
    public func renameFolder(id: Folder.ID, to name: String) async throws {
        try await updateFolder(id) { $0.name = name }
    }

    /// Expands or collapses a folder in the sidebar.
    public func setFolderExpanded(_ expanded: Bool, id: Folder.ID) async throws {
        try await updateFolder(id) { $0.isExpanded = expanded }
    }

    private func updateFolder(_ id: Folder.ID, _ change: @escaping @Sendable (inout Folder) -> Void) async throws {
        try await database.writer.write { db in
            guard var folder = try Folder.fetchOne(db, id: id) else { throw TabStoreError.folderNotFound(id) }
            change(&folder)
            try folder.update(db)
        }
    }

    /// Deletes a folder. Its tabs and subfolders move up to the folder's parent, after the
    /// items already there, in their current order. Nothing inside is deleted.
    public func deleteFolder(id: Folder.ID) async throws {
        try await database.writer.write { db in
            guard let folder = try Folder.fetchOne(db, id: id) else { throw TabStoreError.folderNotFound(id) }
            var keys = try Self.pinnedLevelKeys(in: folder.spaceID, parent: folder.parentID, excluding: .folder(id), db)
            let tabs = try Tab.filter(Tab.Columns.folderID == id).fetchAll(db)
            let subfolders = try Folder.filter(Folder.Columns.parentID == id).fetchAll(db)
            let children: [(key: String, item: PinnedItem)] =
                (tabs.map { ($0.sortKey, PinnedItem.tab($0.id)) } + subfolders.map { ($0.sortKey, PinnedItem.folder($0.id)) })
                .sorted { $0.0 < $1.0 }
            for child in children {
                let key = try SortKey.between(keys.last, nil)
                keys.append(key)
                switch child.item {
                case .tab(let tabID):
                    try Tab.filter(id: tabID).updateAll(db, Tab.Columns.folderID.set(to: folder.parentID), Tab.Columns.sortKey.set(to: key))
                case .folder(let folderID):
                    try Folder.filter(id: folderID).updateAll(db, Folder.Columns.parentID.set(to: folder.parentID), Folder.Columns.sortKey.set(to: key))
                }
            }
            try Folder.deleteOne(db, id: id)
        }
    }

    /// Moves a pinned tab or a folder to a level of the pinned section. Moving an unpinned tab
    /// pins it. Only the moved item's row changes.
    ///
    /// - Parameters:
    ///   - item: The tab or folder to move.
    ///   - parent: The folder to move it into, or `nil` for the top level.
    ///   - anchor: The item to place it after, which must be at that level, or `nil` to place it
    ///     first.
    /// - Throws: ``TabStoreError`` if anything doesn't exist, is in another Space, the anchor is
    ///   at another level, or a folder would end up inside itself.
    public func movePinnedItem(_ item: PinnedItem, into parent: Folder.ID?, after anchor: PinnedItem?) async throws {
        try await database.writer.write { db in
            let spaceID: Space.ID
            switch item {
            case .tab(let id):
                guard let tab = try Tab.fetchOne(db, id: id) else { throw TabStoreError.tabNotFound(id) }
                spaceID = tab.spaceID
            case .folder(let id):
                guard let folder = try Folder.fetchOne(db, id: id) else { throw TabStoreError.folderNotFound(id) }
                spaceID = folder.spaceID
            }
            if let parent {
                guard let parentFolder = try Folder.fetchOne(db, id: parent) else { throw TabStoreError.folderNotFound(parent) }
                guard parentFolder.spaceID == spaceID else { throw TabStoreError.folderInDifferentSpace(parent) }
                if case .folder(let movingID) = item, try Self.folder(parent, isInside: movingID, db) {
                    throw TabStoreError.folderCycle(movingID)
                }
            }
            if anchor == item { return }

            let keys = try Self.pinnedLevelKeys(in: spaceID, parent: parent, excluding: item, db)
            let key: String
            switch anchor {
            case nil:
                key = try SortKey.between(nil, keys.first)
            case .tab(let anchorID):
                guard let anchorTab = try Tab.fetchOne(db, id: anchorID),
                      anchorTab.isPinned, anchorTab.folderID == parent, anchorTab.spaceID == spaceID else {
                    throw TabStoreError.anchorInDifferentSection(anchorID)
                }
                key = try Self.key(after: anchorTab.sortKey, among: keys)
            case .folder(let anchorID):
                guard let anchorFolder = try Folder.fetchOne(db, id: anchorID),
                      anchorFolder.parentID == parent, anchorFolder.spaceID == spaceID else {
                    throw TabStoreError.anchorInDifferentSection(anchorID)
                }
                key = try Self.key(after: anchorFolder.sortKey, among: keys)
            }

            switch item {
            case .tab(let id):
                guard var tab = try Tab.fetchOne(db, id: id) else { return }
                if !tab.isPinned {
                    tab.isPinned = true
                    tab.homeURL = tab.url
                }
                tab.folderID = parent
                tab.sortKey = key
                try tab.update(db)
                try Self.alignSplit(containing: id, db)
            case .folder(let id):
                guard var folder = try Folder.fetchOne(db, id: id) else { return }
                folder.parentID = parent
                folder.sortKey = key
                try folder.update(db)
            }
        }
    }

    /// Whether `candidate` is `ancestor` or inside it.
    private static func folder(_ candidate: Folder.ID, isInside ancestor: Folder.ID, _ db: Database) throws -> Bool {
        var current: Folder.ID? = candidate
        var seen: Set<Folder.ID> = []
        while let id = current, seen.insert(id).inserted {
            if id == ancestor { return true }
            current = try Folder.fetchOne(db, id: id)?.parentID
        }
        return false
    }

    // MARK: Ordering

    /// Computes a sort key for `position` within one section of a Space, ignoring the tab being
    /// moved. For pinned tabs, the section is one level of the pinned tree (`folder`), where
    /// folders and tabs share an order.
    private static func sortKey(
        for position: TabPosition,
        in spaceID: Space.ID,
        pinned: Bool,
        folder: Folder.ID?,
        excluding excludedID: Tab.ID?,
        _ db: Database
    ) throws -> String {
        let keys: [String]
        if pinned {
            keys = try pinnedLevelKeys(in: spaceID, parent: folder, excluding: excludedID.map(PinnedItem.tab), db)
        } else {
            var siblings = Tab.filter(Tab.Columns.spaceID == spaceID).filter(Tab.Columns.isPinned == false)
            if let excludedID {
                siblings = siblings.filter(Tab.Columns.id != excludedID)
            }
            keys = try String.fetchAll(db, siblings.select(Tab.Columns.sortKey).order(Tab.Columns.sortKey))
        }
        switch position {
        case .start:
            return try SortKey.between(nil, keys.first)
        case .end:
            return try SortKey.between(keys.last, nil)
        case .after(let anchorID):
            guard let anchor = try Tab.fetchOne(db, id: anchorID) else {
                throw TabStoreError.tabNotFound(anchorID)
            }
            guard anchor.spaceID == spaceID else { throw TabStoreError.anchorInDifferentSpace(anchorID) }
            guard anchor.isPinned == pinned, !pinned || anchor.folderID == folder else {
                throw TabStoreError.anchorInDifferentSection(anchorID)
            }
            return try key(after: anchor.sortKey, among: keys)
        }
    }

    /// A key after `anchorKey` and before the next distinct key, so ties left by a sync merge
    /// can't produce an invalid range.
    private static func key(after anchorKey: String, among sortedKeys: [String]) throws -> String {
        try SortKey.between(anchorKey, sortedKeys.first { $0 > anchorKey })
    }

    /// The sorted keys of the pinned tabs and folders at one level of a Space's pinned tree.
    static func pinnedLevelKeys(
        in spaceID: Space.ID,
        parent: Folder.ID?,
        excluding excluded: PinnedItem?,
        _ db: Database
    ) throws -> [String] {
        var tabs = Tab
            .filter(Tab.Columns.spaceID == spaceID)
            .filter(Tab.Columns.isPinned == true)
            .filter(Tab.Columns.folderID == parent)
        var folders = Folder
            .filter(Folder.Columns.spaceID == spaceID)
            .filter(Folder.Columns.parentID == parent)
        switch excluded {
        case .tab(let id): tabs = tabs.filter(Tab.Columns.id != id)
        case .folder(let id): folders = folders.filter(Folder.Columns.id != id)
        case nil: break
        }
        let keys = try String.fetchAll(db, tabs.select(Tab.Columns.sortKey))
            + String.fetchAll(db, folders.select(Folder.Columns.sortKey))
        return keys.sorted()
    }
}
