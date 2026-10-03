import Foundation
import GRDB

/// A page or folder brought over from another browser, to add to a Space's sidebar.
public indirect enum ImportedItem: Hashable, Sendable {
    /// A page. An empty title shows the host until the page reports its own.
    case tab(title: String, url: URL)
    /// A folder and what's inside it, in order.
    case folder(name: String, children: [ImportedItem])

    /// The number of pages in this item, counting folders' contents.
    public var tabCount: Int {
        switch self {
        case .tab: 1
        case .folder(_, let children): children.reduce(0) { $0 + $1.tabCount }
        }
    }

    /// The pages in this item, in order, without their folders.
    public var flattenedTabs: [(title: String, url: URL)] {
        switch self {
        case .tab(let title, let url): [(title, url)]
        case .folder(_, let children): children.flatMap(\.flattenedTabs)
        }
    }
}

/// A Space to create from another browser's data.
public struct ImportedSpace: Hashable, Sendable {
    /// The Space's name.
    public var name: String
    /// The existing profile the Space uses.
    public var profileID: Profile.ID
    /// The pinned section: pinned tabs and folders, in order.
    public var pinned: [ImportedItem]
    /// The other tabs, in order. Folders here are flattened, since only pinned tabs go in folders.
    public var unpinned: [ImportedItem]

    /// Creates a Space to import.
    public init(name: String, profileID: Profile.ID, pinned: [ImportedItem], unpinned: [ImportedItem] = []) {
        self.name = name
        self.profileID = profileID
        self.pinned = pinned
        self.unpinned = unpinned
    }
}

extension TabStore {
    /// Creates Spaces from another browser's data, after the existing Spaces, in one
    /// transaction: if anything fails, nothing is added.
    ///
    /// Pinned pages keep their URL as their home URL. Unpinned tabs count as active at `date`,
    /// so they archive on the usual schedule from now rather than right away.
    ///
    /// - Returns: The new Spaces, in order.
    /// - Throws: ``TabStoreError/profileNotFound(_:)`` if a Space's profile doesn't exist.
    @discardableResult
    public func importSpaces(_ spaces: [ImportedSpace], at date: Date = Date()) async throws -> [Space] {
        try await database.writer.write { db in
            var lastKey = try Space.order(Space.Columns.sortKey.desc, Space.Columns.id.desc).fetchOne(db)?.sortKey
            var created: [Space] = []
            for imported in spaces {
                guard try Profile.exists(db, id: imported.profileID) else {
                    throw TabStoreError.profileNotFound(imported.profileID)
                }
                let key = try SortKey.between(lastKey, nil)
                lastKey = key
                let space = Space(profileID: imported.profileID, name: imported.name, sortKey: key)
                try space.insert(db)
                try Self.insertPinned(imported.pinned, in: space.id, parent: nil, after: nil, at: date, db)
                var tabKey: String?
                for page in imported.unpinned.flatMap(\.flattenedTabs) {
                    tabKey = try SortKey.between(tabKey, nil)
                    try Tab(spaceID: space.id, url: page.url, title: page.title, sortKey: tabKey!, lastActiveAt: date).insert(db)
                }
                created.append(space)
            }
            return created
        }
    }

    /// Adds pinned tabs and folders from another browser at the end of a Space's pinned
    /// section, in one transaction.
    ///
    /// - Throws: ``TabStoreError/spaceNotFound(_:)`` if the Space doesn't exist.
    public func importPinned(_ items: [ImportedItem], into spaceID: Space.ID, at date: Date = Date()) async throws {
        try await database.writer.write { db in
            guard try Space.exists(db, id: spaceID) else { throw TabStoreError.spaceNotFound(spaceID) }
            let last = try Self.pinnedLevelKeys(in: spaceID, parent: nil, excluding: nil, db).last
            try Self.insertPinned(items, in: spaceID, parent: nil, after: last, at: date, db)
        }
    }

    /// Inserts pinned tabs and folders at one level, after the key `after`, recursing into folders.
    private static func insertPinned(
        _ items: [ImportedItem],
        in spaceID: Space.ID,
        parent: Folder.ID?,
        after: String?,
        at date: Date,
        _ db: Database
    ) throws {
        var key = after
        for item in items {
            key = try SortKey.between(key, nil)
            switch item {
            case .tab(let title, let url):
                try Tab(
                    spaceID: spaceID, url: url, title: title, sortKey: key!,
                    isPinned: true, homeURL: url, lastActiveAt: date, folderID: parent
                ).insert(db)
            case .folder(let name, let children):
                let folder = Folder(spaceID: spaceID, parentID: parent, name: name, sortKey: key!)
                try folder.insert(db)
                try insertPinned(children, in: spaceID, parent: folder.id, after: nil, at: date, db)
            }
        }
    }
}
