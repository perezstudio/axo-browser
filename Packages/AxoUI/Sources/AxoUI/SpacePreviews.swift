import AxoCore
import Foundation

/// A Space's sidebar rows as they'd show, kept for every Space so a swipe between Spaces (#84)
/// can slide the neighboring Space in under the fingers before switching to it. Plain records,
/// no pages: a Space's pages load only once it's shown.
public struct SpaceSidebarPreview: Equatable, Sendable {
    /// One unpinned row: a tab, or a split, which stands for its first tab in sidebar order
    /// (`leader`, the row's identity, as in the real list) and shows its panes in pane order.
    public enum Row: Identifiable, Equatable, Sendable {
        case tab(AxoCore.Tab)
        case split(leader: AxoCore.Tab.ID, panes: [AxoCore.Tab])

        public var id: AxoCore.Tab.ID {
            switch self {
            case .tab(let tab): tab.id
            case .split(let leader, _): leader
            }
        }
    }

    public let space: Space
    /// The pinned section, with split followers left out as in the sidebar.
    public let pinnedTree: [PinnedNode]
    /// The unpinned rows, in order.
    public let rows: [Row]
    /// Each split's panes, by the tab whose row stands for it, for pinned splits.
    public let splitPanes: [AxoCore.Tab.ID: [AxoCore.Tab]]
    /// The tab the Space shows when switched to.
    public let selectedTabID: AxoCore.Tab.ID?
    /// The favorites of the Space's profile, shown above its rows.
    public var favorites: [Favorite] = []

    /// Builds a Space's rows from its records, as ``BrowserModel`` builds the shown Space's: a
    /// split of two or more panes is one row, standing for its first tab in sidebar order.
    static func make(
        space: Space, tabs: [AxoCore.Tab], folders: [Folder], splits: [TabSplit], selectedTabID: AxoCore.Tab.ID?,
        favorites: [Favorite] = []
    ) -> SpaceSidebarPreview {
        let knownSplits = Set(splits.map(\.id))
        var panesBySplit: [TabSplit.ID: [AxoCore.Tab]] = [:]
        for tab in tabs {
            if let splitID = tab.splitID, knownSplits.contains(splitID) { panesBySplit[splitID, default: []].append(tab) }
        }
        var splitPanes: [AxoCore.Tab.ID: [AxoCore.Tab]] = [:]
        var followers: Set<AxoCore.Tab.ID> = []
        for (_, members) in panesBySplit where members.count > 1 {
            // The row stands for the split's first tab in sidebar order; panes show in pane order.
            guard let leader = members.first else { continue }
            splitPanes[leader.id] = members.sorted {
                ($0.splitSortKey ?? "", $0.id.uuidString) < ($1.splitSortKey ?? "", $1.id.uuidString)
            }
            followers.formUnion(members.dropFirst().map(\.id))
        }
        let shown = tabs.filter { !followers.contains($0.id) }
        let rows: [Row] = shown.filter { !$0.isPinned }.map { tab in
            splitPanes[tab.id].map { Row.split(leader: tab.id, panes: $0) } ?? .tab(tab)
        }
        return SpaceSidebarPreview(
            space: space,
            pinnedTree: PinnedNode.tree(folders: folders, pinnedTabs: shown.filter(\.isPinned)),
            rows: rows,
            splitPanes: splitPanes,
            selectedTabID: selectedTabID.flatMap { id in
                tabs.contains { $0.id == id } || favorites.contains { $0.id == id } ? id : nil
            } ?? tabs.first?.id,
            favorites: favorites
        )
    }
}

extension BrowserModel {
    /// The shown Space's rows, built the same way as every other Space's kept rows, so its page
    /// draws them the same way.
    var shownSpaceRows: SpaceSidebarPreview? {
        space.map { space in
            SpaceSidebarPreview.make(
                space: space, tabs: tabs, folders: folders, splits: splits, selectedTabID: selectedTabID,
                favorites: favorites)
        }
    }

    /// The Spaces just before and after the shown one, for a swipe.
    public var neighboringSpaces: (previous: Space?, next: Space?) {
        guard let index = spaces.firstIndex(where: { $0.id == space?.id }) else { return (nil, nil) }
        return (index > 0 ? spaces[index - 1] : nil, index < spaces.count - 1 ? spaces[index + 1] : nil)
    }

    /// Reads every Space's rows again, a turn later and once for however many changes come first.
    func scheduleSpacePreviewLoad() {
        spacePreviewLoad?.cancel()
        spacePreviewLoad = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self?.loadSpacePreviews()
        }
    }

    /// Reads every Space's rows but the shown one's (whose rows are live), keeping them ready
    /// for a swipe. Cheap: records only, a few small reads per Space.
    func loadSpacePreviews() async {
        var fresh: [Space.ID: SpaceSidebarPreview] = [:]
        for other in spaces {
            if let preview = await readPreview(of: other) { fresh[other.id] = preview }
        }
        guard !Task.isCancelled else { return }
        // The shown Space's rows are live; it gets a copy only as it's left.
        if let shown = space?.id { fresh[shown] = nil }
        spacePreviews = fresh
        await loadSavedFavicons()
    }

    /// Reads the Spaces next to the shown one again, as a swipe starts, in case something
    /// changed them meanwhile (an extension, iCloud).
    public func refreshNeighborPreviews() async {
        for neighbor in [neighboringSpaces.previous, neighboringSpaces.next].compactMap(\.self) {
            if let preview = await readPreview(of: neighbor) { spacePreviews[neighbor.id] = preview }
        }
    }

    /// The shown Space's rows as they are now, kept as it's left, so swiping back is instant.
    func keepPreviewOfShownSpace() {
        guard let space else { return }
        spacePreviews[space.id] = SpaceSidebarPreview.make(
            space: space, tabs: tabs, folders: folders, splits: splits, selectedTabID: selectedTabID,
            favorites: favorites)
    }

    private func readPreview(of target: Space) async -> SpaceSidebarPreview? {
        do {
            async let tabs = store.tabs(in: target.id)
            async let folders = store.folders(in: target.id)
            async let splits = store.splits(in: target.id)
            async let favorites = store.favorites.favorites(for: target.profileID)
            return try await SpaceSidebarPreview.make(
                space: target, tabs: tabs, folders: folders, splits: splits,
                selectedTabID: rememberedSelection(in: target.id), favorites: favorites)
        } catch {
            logger.error("Couldn't read a Space's sidebar: \(error)")
            return nil
        }
    }
}
