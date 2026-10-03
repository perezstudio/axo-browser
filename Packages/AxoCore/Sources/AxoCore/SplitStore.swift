import AxoPersistence
import Foundation
import GRDB

/// A split view: two to four tabs shown together, side by side or stacked.
///
/// A split's tabs share their section (pinned or not) and folder, and show as one row in the
/// sidebar, where the first of them in sidebar order sits. Their `splitSortKey`s order the panes.
public struct TabSplit: Codable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tabSplit"

    /// How the panes are arranged.
    public enum Orientation: String, Codable, Hashable, Sendable {
        /// Side by side, left to right.
        case horizontal
        /// Stacked, top to bottom.
        case vertical
    }

    /// The most tabs a split can hold.
    public static let maximumPanes = 4

    public var id: UUID
    /// The Space the split belongs to.
    public var spaceID: Space.ID
    public var orientation: Orientation

    /// Creates a split.
    public init(id: UUID = UUID(), spaceID: Space.ID, orientation: Orientation = .horizontal) {
        self.id = id
        self.spaceID = spaceID
        self.orientation = orientation
    }

    /// Column names, for building queries.
    public enum Columns {
        public static let spaceID = Column(CodingKeys.spaceID)
    }
}

extension TabStore {
    /// A Space's splits.
    public func splits(in spaceID: Space.ID) async throws -> [TabSplit] {
        try await database.writer.read { db in
            try TabSplit.filter(TabSplit.Columns.spaceID == spaceID).fetchAll(db)
        }
    }

    /// Streams a Space's splits: the current list first, then a new list after every change.
    public func observeSplits(in spaceID: Space.ID) -> AsyncValueObservation<[TabSplit]> {
        ValueObservation
            .tracking { db in try TabSplit.filter(TabSplit.Columns.spaceID == spaceID).fetchAll(db) }
            .values(in: database.writer)
    }

    /// Adds a tab to `anchor`'s split as its last pane, creating a split of the two if `anchor`
    /// isn't in one. The tab leaves any split it was in, and moves next to `anchor` in its
    /// section and folder; joining a pinned split pins it, with its page as its home URL.
    ///
    /// - Returns: The split.
    /// - Throws: ``TabStoreError/splitFull(_:)`` if the split has ``TabSplit/maximumPanes`` tabs,
    ///   ``TabStoreError/anchorInDifferentSpace(_:)``, or ``TabStoreError/tabNotFound(_:)``.
    @discardableResult
    public func addToSplit(_ tabID: Tab.ID, with anchorID: Tab.ID) async throws -> TabSplit {
        try await database.writer.write { db in
            guard tabID != anchorID else { throw TabStoreError.anchorInDifferentSection(anchorID) }
            guard let anchor = try Tab.fetchOne(db, id: anchorID) else { throw TabStoreError.tabNotFound(anchorID) }
            guard var tab = try Tab.fetchOne(db, id: tabID) else { throw TabStoreError.tabNotFound(tabID) }
            guard tab.spaceID == anchor.spaceID else { throw TabStoreError.anchorInDifferentSpace(anchorID) }

            let split: TabSplit
            if let existingID = anchor.splitID, let existing = try TabSplit.fetchOne(db, id: existingID) {
                if tab.splitID == existingID { return existing }
                guard try Self.members(of: existingID, db).count < TabSplit.maximumPanes else {
                    throw TabStoreError.splitFull(existingID)
                }
                split = existing
            } else {
                split = TabSplit(spaceID: anchor.spaceID)
                try split.insert(db)
                var first = anchor
                first.splitID = split.id
                first.splitSortKey = SortKey.initial
                try first.update(db)
            }

            if tab.splitID != nil {
                try Self.leaveSplit(tabID, db)
                tab = try Tab.fetchOne(db, id: tabID) ?? tab
            }
            let lastPane = try Self.members(of: split.id, db).last?.splitSortKey
            tab.splitID = split.id
            tab.splitSortKey = try SortKey.between(lastPane, nil)
            try tab.update(db)
            // The split stays where its row is: at its first tab in sidebar order.
            let row = try Self.members(of: split.id, db).filter { $0.id != tabID }.min { $0.sortKey < $1.sortKey }
            try Self.alignSplit(split.id, with: row?.id ?? anchorID, db)
            return split
        }
    }

    /// Takes a tab out of its split, leaving it as its own row in the same place. A split left
    /// with one tab ends.
    public func removeFromSplit(_ tabID: Tab.ID) async throws {
        try await database.writer.write { db in
            guard try Tab.fetchOne(db, id: tabID) != nil else { throw TabStoreError.tabNotFound(tabID) }
            try Self.leaveSplit(tabID, db)
        }
    }

    /// Ends a split. Its tabs stay where they are, as separate rows.
    public func separateSplit(_ id: TabSplit.ID) async throws {
        _ = try await database.writer.write { db in
            try TabSplit.deleteOne(db, id: id)
        }
    }

    /// Arranges a split's panes side by side or stacked.
    public func setSplitOrientation(_ orientation: TabSplit.Orientation, id: TabSplit.ID) async throws {
        try await database.writer.write { db in
            guard var split = try TabSplit.fetchOne(db, id: id) else { return }
            split.orientation = orientation
            try split.update(db)
        }
    }

    // MARK: Keeping splits together

    /// A split's tabs that are in the sidebar, in pane order.
    static func members(of splitID: TabSplit.ID, _ db: Database) throws -> [Tab] {
        try Tab
            .filter(Tab.Columns.splitID == splitID)
            .filter(Tab.Columns.archivedAt == nil)
            .order(Tab.Columns.splitSortKey, Tab.Columns.id)
            .fetchAll(db)
    }

    /// Takes a tab out of its split, ending the split if fewer than two tabs remain.
    static func leaveSplit(_ tabID: Tab.ID, _ db: Database) throws {
        guard var tab = try Tab.fetchOne(db, id: tabID), let splitID = tab.splitID else { return }
        tab.splitID = nil
        tab.splitSortKey = nil
        try tab.update(db)
        if try members(of: splitID, db).count < 2 {
            // Deleting the split clears the last tab's splitID (ON DELETE SET NULL).
            try TabSplit.deleteOne(db, id: splitID)
            try Tab.filter(Tab.Columns.splitID == nil).filter(Tab.Columns.splitSortKey != nil)
                .updateAll(db, Tab.Columns.splitSortKey.set(to: nil))
        }
    }

    /// Gives the rest of a split the section and folder of `leaderID` (a tab of the split that
    /// just moved or changed), and places them right after it, so the split stays one row.
    static func alignSplit(_ splitID: TabSplit.ID, with leaderID: Tab.ID, _ db: Database) throws {
        guard let leader = try Tab.fetchOne(db, id: leaderID) else { return }
        let others = try members(of: splitID, db).filter { $0.id != leaderID }
        guard !others.isEmpty else { return }
        let memberIDs = Set(others.map(\.id) + [leaderID])
        let levelKeys: [String]
        if leader.isPinned {
            levelKeys = try pinnedLevelKeys(in: leader.spaceID, parent: leader.folderID, excluding: nil, db)
        } else {
            levelKeys = try String.fetchAll(db, Tab
                .filter(Tab.Columns.spaceID == leader.spaceID)
                .filter(Tab.Columns.isPinned == false)
                .filter(Tab.Columns.archivedAt == nil)
                .filter(!memberIDs.contains(Tab.Columns.id))
                .select(Tab.Columns.sortKey)
                .order(Tab.Columns.sortKey))
        }
        // The member keys themselves don't count as neighbors.
        let otherKeys = Set(others.map(\.sortKey))
        let upper = levelKeys.first { $0 > leader.sortKey && !otherKeys.contains($0) }
        var previous = leader.sortKey
        for var member in others {
            member.isPinned = leader.isPinned
            member.folderID = leader.folderID
            member.homeURL = leader.isPinned ? (member.homeURL ?? member.url) : nil
            member.sortKey = try SortKey.between(previous, upper)
            previous = member.sortKey
            try member.update(db)
        }
    }

    /// Keeps `tabID`'s split together after the tab moved or changed section.
    static func alignSplit(containing tabID: Tab.ID, _ db: Database) throws {
        guard let splitID = try Tab.fetchOne(db, id: tabID)?.splitID else { return }
        try alignSplit(splitID, with: tabID, db)
    }
}
