import AxoCore
import Foundation

/// Tab actions from a tab's context menu, the Tabs menu (for the selected tab), and the command
/// bar (#81): Duplicate, Copy Link, Move to Space, Close Other Tabs, and Close Tabs Below.
extension BrowserModel {
    /// The tab's current address: its live page's, or the saved one.
    func currentURL(of tab: AxoCore.Tab) -> URL {
        pool.state(for: tab.id)?.url ?? tab.url
    }

    /// Opens a copy of the tab below it (an unpinned tab; a pinned tab's copy goes first among
    /// the unpinned ones), with its back and forward history, and selects it.
    public func duplicateTab(_ id: AxoCore.Tab.ID) async {
        guard let space, let tab = tabs.first(where: { $0.id == id }) else { return }
        do {
            let copy = try await store.openTab(
                url: currentURL(of: tab), title: pool.state(for: id)?.title ?? tab.title,
                in: space.id, at: tab.isPinned ? .start : .after(id))
            // Before the page is made, so it restores the history instead of loading the URL.
            pool.copyHistory(from: id, to: copy.id)
            tabs = try await store.tabs(in: space.id)
            onTabEvent?(.opened(copy.id))
            select(copy.id)
            announce("Duplicated \(TabRow.displayTitle(for: tab))")
        } catch {
            report(error, "Axo couldn't duplicate the tab.")
        }
    }

    /// Copies the tab's address, as Copy Link does for the page showing.
    public func copyLink(of id: AxoCore.Tab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let url = currentURL(of: tab)
        if let copyLink { copyLink(url) } else { copyToPasteboard(url) }
        postNotice("Link copied", placement: id == selectedTabID ? .addressBar : .page)
    }

    /// The Spaces a tab of the shown Space can move to: the profile's others. Another profile's
    /// Space would need the page reloaded with its website data (#78), so it isn't offered.
    public var spacesToMoveTabsTo: [Space] {
        guard let space else { return [] }
        return spaces.filter { $0.profileID == space.profileID && $0.id != space.id }
    }

    /// Moves a tab to another of the profile's Spaces, keeping its live page; it leaves any
    /// folder or split. If it was selected, the tab next to it is selected.
    public func moveTab(_ id: AxoCore.Tab.ID, toSpace target: Space.ID) async {
        guard let space, let destination = spacesToMoveTabsTo.first(where: { $0.id == target }),
              let tab = tabs.first(where: { $0.id == id }) else { return }
        let order = visibleTabOrder
        do {
            try await store.moveTab(id: id, toSpace: destination.id)
            tabs = try await store.tabs(in: space.id)
            try await refreshSidebar()
        } catch {
            report(error, "Axo couldn't move the tab.")
            return
        }
        if selectedTabID == id {
            select(Self.neighbor(of: id, in: order, among: visibleTabOrder))
        }
        postNotice("Moved \(TabRow.displayTitle(for: tab)) to \(destination.name)")
    }

    /// The unpinned tabs that Close Other Tabs closes: all but `id` and the panes of its split.
    func otherUnpinnedTabs(than id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        let keep = Set(paneIDs(alongside: id))
        return unpinnedTabs.map(\.id).filter { !keep.contains($0) }
    }

    /// The unpinned tabs that Close Tabs Below closes: those after `id` (and its split) in the
    /// sidebar.
    func unpinnedTabs(below id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        let keep = Set(paneIDs(alongside: id))
        let order = unpinnedTabs.map(\.id)
        guard let last = order.lastIndex(where: { keep.contains($0) }) else { return [] }
        return order[(last + 1)...].filter { !keep.contains($0) }
    }

    /// `id` and, if it's in a split, the split's other panes.
    private func paneIDs(alongside id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        guard let split = split(of: id) else { return [id] }
        return panes(of: split.id).map(\.id)
    }

    /// Closes every unpinned tab but `id` (and its split). Pinned tabs stay; each closed tab
    /// can come back with Reopen Closed Tab or from the archive.
    public func closeOtherTabs(than id: AxoCore.Tab.ID) async {
        await closeTabs(otherUnpinnedTabs(than: id), keeping: id)
    }

    /// Closes the unpinned tabs below `id` (and its split) in the sidebar.
    public func closeTabs(below id: AxoCore.Tab.ID) async {
        await closeTabs(unpinnedTabs(below: id), keeping: id)
    }

    private func closeTabs(_ ids: [AxoCore.Tab.ID], keeping id: AxoCore.Tab.ID) async {
        guard !ids.isEmpty else { return }
        logger.notice("Closing \(ids.count, privacy: .public) tabs at the person's request")
        let selectionCloses = selectedTabID.map(ids.contains) ?? false
        if selectionCloses { select(id) }
        for closing in ids {
            await closeTab(closing)
        }
        postNotice(ids.count == 1 ? "Closed 1 tab" : "Closed \(ids.count) tabs")
    }
}
