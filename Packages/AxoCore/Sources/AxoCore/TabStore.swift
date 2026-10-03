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
    /// No profile with this ID exists.
    case profileNotFound(Profile.ID)
    /// A profile can't be deleted while Spaces still use it.
    case profileInUse(Profile.ID)
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

    private let database: AppDatabase

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
    /// - Returns: The new tab.
    @discardableResult
    public func openTab(
        url: URL,
        title: String = "",
        in spaceID: Space.ID,
        at position: TabPosition = .end
    ) async throws -> Tab {
        try await database.writer.write { db in
            let sortKey = try Self.sortKey(for: position, in: spaceID, pinned: false, excluding: nil, db)
            let tab = Tab(spaceID: spaceID, url: url, title: title, sortKey: sortKey)
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
            tab.sortKey = try Self.sortKey(for: position, in: tab.spaceID, pinned: tab.isPinned, excluding: id, db)
            try tab.update(db)
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
            try Tab.deleteOne(db, id: id)
        }
    }

    // MARK: Pinning

    /// Pins or unpins a tab, moving it to the end of its new section. Pinning remembers the
    /// current page as the tab's home URL; unpinning forgets it.
    public func setPinned(_ pinned: Bool, tabID: Tab.ID) async throws {
        try await database.writer.write { db in
            guard var tab = try Tab.fetchOne(db, id: tabID) else { throw TabStoreError.tabNotFound(tabID) }
            guard tab.isPinned != pinned else { return }
            tab.sortKey = try Self.sortKey(for: .end, in: tab.spaceID, pinned: pinned, excluding: tabID, db)
            tab.isPinned = pinned
            tab.homeURL = pinned ? tab.url : nil
            try tab.update(db)
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
            tab.sortKey = try Self.sortKey(for: .end, in: tab.spaceID, pinned: tab.isPinned, excluding: id, db)
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

    // MARK: Ordering

    /// Computes a sort key for `position` among the tabs in one section (pinned or not) of a
    /// Space, ignoring the tab being moved.
    private static func sortKey(
        for position: TabPosition,
        in spaceID: Space.ID,
        pinned: Bool,
        excluding excludedID: Tab.ID?,
        _ db: Database
    ) throws -> String {
        var siblings = Tab
            .filter(Tab.Columns.spaceID == spaceID)
            .filter(Tab.Columns.isPinned == pinned)
        if let excludedID {
            siblings = siblings.filter(Tab.Columns.id != excludedID)
        }
        switch position {
        case .start:
            let first = try siblings.order(Tab.Columns.sortKey, Tab.Columns.id).fetchOne(db)
            return try SortKey.between(nil, first?.sortKey)
        case .end:
            let last = try siblings.order(Tab.Columns.sortKey.desc, Tab.Columns.id.desc).fetchOne(db)
            return try SortKey.between(last?.sortKey, nil)
        case .after(let anchorID):
            guard let anchor = try Tab.fetchOne(db, id: anchorID) else {
                throw TabStoreError.tabNotFound(anchorID)
            }
            guard anchor.spaceID == spaceID else { throw TabStoreError.anchorInDifferentSpace(anchorID) }
            guard anchor.isPinned == pinned else { throw TabStoreError.anchorInDifferentSection(anchorID) }
            // The next distinct key, so ties left by a sync merge can't produce an invalid range.
            let next = try siblings
                .filter(Tab.Columns.sortKey > anchor.sortKey)
                .order(Tab.Columns.sortKey)
                .fetchOne(db)
            return try SortKey.between(anchor.sortKey, next?.sortKey)
        }
    }
}
