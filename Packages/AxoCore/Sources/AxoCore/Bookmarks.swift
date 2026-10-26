import AxoPersistence
import Foundation
import GRDB

/// A bookmark or folder in a profile's bookmark tree, the view of Axo's sidebar that extensions
/// see through `chrome.bookmarks`. Its ID is the ID of the favorite, pinned tab, folder, or Space
/// it stands for.
public struct BookmarkItem: Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// The bookmark's page, or `nil` for a folder.
    public var url: URL?
    /// A folder's contents, in order.
    public var children: [BookmarkItem]

    /// Creates a bookmark, or a folder when `url` is `nil`.
    public init(id: UUID, title: String, url: URL? = nil, children: [BookmarkItem] = []) {
        self.id = id
        self.title = title
        self.url = url
        self.children = children
    }
}

/// A profile's bookmark tree: the favorites are the bookmarks bar, and each Space is a folder
/// in the other bookmarks, holding its pinned section (pinned tabs and folders) in sidebar order.
public struct BookmarkTree: Hashable, Sendable {
    /// The bookmarks bar: the profile's favorites, in grid order.
    public var bar: [BookmarkItem]
    /// The other bookmarks: one folder per Space of the profile, in order.
    public var other: [BookmarkItem]

    public init(bar: [BookmarkItem], other: [BookmarkItem]) {
        self.bar = bar
        self.other = other
    }
}

/// Where a bookmark is in a ``BookmarkTree``.
public enum BookmarkPlace: Hashable, Sendable {
    /// At the top of the bookmarks bar.
    case bar
    /// At the top of the other bookmarks.
    case other
    /// In the folder with this ID: a Space or a pinned-section folder.
    case inside(UUID)
}

/// A change an extension made to the bookmark tree, for ``TabStore/applyBookmarkChange(_:profileID:currentSpaceID:)``.
public struct BookmarkChange: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case created, updated, moved, removed
    }

    public var kind: Kind
    /// The bookmark's ID. A new bookmark's item gets this ID.
    public var id: UUID
    /// Where it is now (where it was, for a removal), and its position there.
    public var place: BookmarkPlace
    public var index: Int
    public var title: String
    /// The bookmark's page, or `nil` for a folder.
    public var url: URL?

    public init(kind: Kind, id: UUID, place: BookmarkPlace, index: Int, title: String, url: URL?) {
        self.kind = kind
        self.id = id
        self.place = place
        self.index = index
        self.title = title
        self.url = url
    }
}

extension TabStore {
    /// A profile's bookmark tree. See ``BookmarkTree``.
    public func bookmarkTree(profileID: Profile.ID) async throws -> BookmarkTree {
        try await database.writer.read { db in try Self.bookmarkTree(profileID: profileID, db) }
    }

    /// Streams a profile's bookmark tree: the current tree first, then a new one whenever it
    /// changes.
    public func observeBookmarkTree(profileID: Profile.ID) -> AsyncValueObservation<BookmarkTree> {
        ValueObservation
            .tracking { db in try Self.bookmarkTree(profileID: profileID, db) }
            .removeDuplicates()
            .values(in: database.writer)
    }

    private static func bookmarkTree(profileID: Profile.ID, _ db: Database) throws -> BookmarkTree {
        let favorites = try Favorite
            .filter(Favorite.Columns.profileID == profileID)
            .order(Favorite.Columns.sortKey, Favorite.Columns.id)
            .fetchAll(db)
        let spaces = try Space
            .filter(Space.Columns.profileID == profileID)
            .order(Space.Columns.sortKey, Space.Columns.id)
            .fetchAll(db)
        let spaceIDs = spaces.map(\.id)
        let tabs = try Tab
            .filter(spaceIDs.contains(Tab.Columns.spaceID))
            .filter(Tab.Columns.isPinned == true)
            .filter(Tab.Columns.archivedAt == nil)
            .fetchAll(db)
        let folders = try Folder.filter(spaceIDs.contains(Folder.Columns.spaceID)).fetchAll(db)

        // Each level of a pinned section: its tabs and folders, by their shared sort key.
        var levels: [LevelKey: [(key: String, item: BookmarkItem)]] = [:]
        for tab in tabs {
            let item = BookmarkItem(id: tab.id, title: tab.title, url: tab.homeURL ?? tab.url)
            levels[LevelKey(spaceID: tab.spaceID, folderID: tab.folderID), default: []].append((tab.sortKey, item))
        }
        func children(of spaceID: Space.ID, _ folderID: Folder.ID?) -> [BookmarkItem] {
            var level = levels[LevelKey(spaceID: spaceID, folderID: folderID)] ?? []
            for folder in folders where folder.spaceID == spaceID && folder.parentID == folderID {
                level.append((folder.sortKey, BookmarkItem(id: folder.id, title: folder.name, children: children(of: spaceID, folder.id))))
            }
            return level.sorted { ($0.key, $0.item.id.uuidString) < ($1.key, $1.item.id.uuidString) }.map(\.item)
        }
        return BookmarkTree(
            bar: favorites.map { BookmarkItem(id: $0.id, title: $0.title, url: $0.url) },
            other: spaces.map { BookmarkItem(id: $0.id, title: $0.name, children: children(of: $0.id, nil)) }
        )
    }

    private struct LevelKey: Hashable {
        var spaceID: Space.ID
        var folderID: Folder.ID?
    }

    /// Applies a change an extension made to a profile's bookmark tree to the sidebar.
    ///
    /// Bookmarks in the bar are favorites, and bookmarks and folders in a Space's folder are its
    /// pinned tabs and folders. What the sidebar can't hold is left out: folders in the bar,
    /// bookmarks among the Spaces (they go to the end of `currentSpaceID`'s pinned section
    /// instead), moves between Spaces, and new or removed Spaces. Show the tree again afterwards,
    /// so the extension sees what the sidebar did. Removing a folder keeps what's inside it, as
    /// deleting one in the sidebar does.
    public func applyBookmarkChange(_ change: BookmarkChange, profileID: Profile.ID, currentSpaceID: Space.ID) async throws {
        let target = try await bookmarkTarget(of: change.place, currentSpaceID: currentSpaceID)
        let thing = try await bookmarkThing(change.id, profileID: profileID)
        switch change.kind {
        case .created:
            guard case .none = thing else { return }
            // The sidebar has no place among the Spaces, so those go to the current Space.
            let target: BookmarkTarget? = if case .spaces = target { .pinned(currentSpaceID, nil) } else { target }
            let index = if case .other = change.place { Int.max } else { change.index }
            switch target {
            case .bar:
                guard let url = change.url else { return }
                try await favorites.add(url: url, title: change.title, profileID: profileID, id: change.id)
                try await moveFavorite(change.id, to: index, profileID: profileID)
            case .pinned(let spaceID, let folderID):
                if let url = change.url {
                    try await openTab(id: change.id, url: url, title: change.title, in: spaceID)
                    try await setPinned(true, tabID: change.id)
                    try await moveToPinnedLevel(.tab(change.id), spaceID: spaceID, folderID: folderID, index: index)
                } else {
                    try await createFolder(named: change.title, in: spaceID, parent: folderID, id: change.id)
                    try await moveToPinnedLevel(.folder(change.id), spaceID: spaceID, folderID: folderID, index: index)
                }
            default:
                return
            }

        case .updated:
            switch thing {
            case .favorite(let favorite):
                try await favorites.setHome(change.url ?? favorite.url, title: change.title, for: favorite.id)
            case .tab(let tab):
                try await updateTab(id: tab.id, url: tab.url, title: change.title)
                if let url = change.url { try await setHomeURL(url, tabID: tab.id) }
            case .folder(let folder):
                try await renameFolder(id: folder.id, to: change.title)
            case .space(let space):
                try await renameSpace(id: space.id, to: change.title)
            case nil:
                return
            }

        case .moved:
            switch (thing, target) {
            case (.favorite(let favorite), .bar):
                try await moveFavorite(favorite.id, to: change.index, profileID: profileID)
            case (.tab(let tab), .bar):
                try await favorites.add(fromTab: tab.id)
                try await moveFavorite(tab.id, to: change.index, profileID: profileID)
            case (.favorite(let favorite), .pinned(let spaceID, let folderID)):
                try await favorites.moveToPinned(favorite.id, in: spaceID)
                try await moveToPinnedLevel(.tab(favorite.id), spaceID: spaceID, folderID: folderID, index: change.index)
            case (.tab(let tab), .pinned(let spaceID, let folderID)) where tab.spaceID == spaceID:
                try await moveToPinnedLevel(.tab(tab.id), spaceID: spaceID, folderID: folderID, index: change.index)
            case (.folder(let folder), .pinned(let spaceID, let folderID)) where folder.spaceID == spaceID:
                try await moveToPinnedLevel(.folder(folder.id), spaceID: spaceID, folderID: folderID, index: change.index)
            case (.space(let space), .spaces):
                let others = try await spaces().filter { $0.profileID == profileID && $0.id != space.id }
                try await moveSpace(id: space.id, after: Self.anchor(at: change.index, in: others)?.id)
            default:
                return
            }

        case .removed:
            switch thing {
            case .favorite(let favorite): try await favorites.remove(favorite.id)
            case .tab(let tab): try await deleteTab(id: tab.id)
            case .folder(let folder): try await deleteFolder(id: folder.id)
            case .space, nil: return
            }
        }
    }

    /// What a bookmark's ID stands for in a profile.
    private enum BookmarkThing {
        case favorite(Favorite), tab(Tab), folder(Folder), space(Space)
    }

    private func bookmarkThing(_ id: UUID, profileID: Profile.ID) async throws -> BookmarkThing? {
        try await database.writer.read { db in
            if let favorite = try Favorite.fetchOne(db, id: id) {
                return favorite.profileID == profileID ? .favorite(favorite) : nil
            }
            if let space = try Space.fetchOne(db, id: id) {
                return space.profileID == profileID ? .space(space) : nil
            }
            let spaceID: Space.ID
            let thing: BookmarkThing
            if let tab = try Tab.fetchOne(db, id: id), tab.isPinned {
                (spaceID, thing) = (tab.spaceID, .tab(tab))
            } else if let folder = try Folder.fetchOne(db, id: id) {
                (spaceID, thing) = (folder.spaceID, .folder(folder))
            } else {
                return nil
            }
            return try Space.fetchOne(db, id: spaceID)?.profileID == profileID ? thing : nil
        }
    }

    /// Where a bookmark goes in the sidebar.
    private enum BookmarkTarget {
        /// The favorites.
        case bar
        /// Among the Spaces.
        case spaces
        /// A level of a Space's pinned section.
        case pinned(Space.ID, Folder.ID?)
    }

    private func bookmarkTarget(of place: BookmarkPlace, currentSpaceID: Space.ID) async throws -> BookmarkTarget? {
        switch place {
        case .bar:
            return .bar
        case .other:
            return .spaces
        case .inside(let id):
            return try await database.writer.read { db in
                if try Space.exists(db, id: id) { return .pinned(id, nil) }
                if let folder = try Folder.fetchOne(db, id: id) { return .pinned(folder.spaceID, folder.id) }
                return nil
            }
        }
    }

    /// Moves a favorite to `index` in its profile's grid.
    private func moveFavorite(_ id: Favorite.ID, to index: Int, profileID: Profile.ID) async throws {
        let others = try await favorites.favorites(for: profileID).filter { $0.id != id }
        try await favorites.move(id, after: Self.anchor(at: index, in: others)?.id)
    }

    /// Moves a tab or folder to `index` in a level of a Space's pinned section.
    private func moveToPinnedLevel(_ item: PinnedItem, spaceID: Space.ID, folderID: Folder.ID?, index: Int) async throws {
        let others = try await database.writer.read { db in
            let tabs = try Tab
                .filter(Tab.Columns.spaceID == spaceID)
                .filter(Tab.Columns.isPinned == true)
                .filter(Tab.Columns.folderID == folderID)
                .fetchAll(db)
                .map { ($0.sortKey, PinnedItem.tab($0.id)) }
            let folders = try Folder
                .filter(Folder.Columns.spaceID == spaceID)
                .filter(Folder.Columns.parentID == folderID)
                .fetchAll(db)
                .map { ($0.sortKey, PinnedItem.folder($0.id)) }
            return (tabs + folders).sorted { $0.0 < $1.0 }.map(\.1).filter { $0 != item }
        }
        try await movePinnedItem(item, into: folderID, after: Self.anchor(at: index, in: others))
    }

    /// The item to place something after so it ends up at `index` among `others`.
    private static func anchor<Item>(at index: Int, in others: [Item]) -> Item? {
        let index = min(index, others.count)
        return index > 0 ? others[index - 1] : nil
    }
}
