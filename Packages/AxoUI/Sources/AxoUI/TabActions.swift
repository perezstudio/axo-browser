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
        // Below the tab's whole sidebar row: after a split's last pane, so the split's tabs stay
        // together.
        let anchor = split(of: id).flatMap { split in panes(of: split.id).last?.id } ?? id
        do {
            let copy = try await store.openTab(
                url: currentURL(of: tab), title: pool.state(for: id)?.title ?? tab.title,
                in: space.id, at: tab.isPinned ? .start : .after(anchor))
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

    /// Whether Move to Space is offered for the tab: not for a tab in a split, whose row stands
    /// for the whole split (moving one pane would break it up), and not without another Space.
    public func canMoveToSpace(_ id: AxoCore.Tab.ID) -> Bool {
        split(of: id) == nil && !spacesToMoveTabsTo.isEmpty && tabs.contains { $0.id == id }
    }

    /// Moves a tab to another of the profile's Spaces, keeping its live page; it leaves any
    /// folder. If it was selected, the tab next to it is selected.
    public func moveTab(_ id: AxoCore.Tab.ID, toSpace target: Space.ID) async {
        guard let space, canMoveToSpace(id), let destination = spacesToMoveTabsTo.first(where: { $0.id == target }),
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
        // Its new Space's page in the sidebar shows it, for a swipe there (#84).
        await refreshPreview(of: destination.id)
        // Gone from this Space's window, as for a closed tab (the WebKit extension bridge).
        onTabEvent?(.closed(id))
        if selectedTabID == id {
            select(Self.neighbor(of: id, in: order, among: visibleTabOrder))
        }
        postNotice("Moved \(TabRow.displayTitle(for: tab)) to \(destination.name)")
    }

    /// The unpinned sidebar rows, in order, each as its tabs: one tab, or a split's panes.
    private var unpinnedRows: [[AxoCore.Tab.ID]] {
        unpinnedTabs.filter { !isSplitFollower($0) }.map { paneIDs(alongside: $0.id) }
    }

    /// The unpinned tabs that Close Other Tabs closes: every other unpinned row's. None for a
    /// pinned tab or a favorite, which these actions aren't for.
    func otherUnpinnedTabs(than id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        let rows = unpinnedRows
        guard rows.contains(where: { $0.contains(id) }) else { return [] }
        return rows.filter { !$0.contains(id) }.flatMap(\.self)
    }

    /// The unpinned tabs that Close Tabs Below closes: the rows after `id`'s in the sidebar.
    func unpinnedTabs(below id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        let rows = unpinnedRows
        guard let row = rows.firstIndex(where: { $0.contains(id) }) else { return [] }
        return rows[(row + 1)...].flatMap(\.self)
    }

    /// `id` and, if it's in a split, the split's other panes.
    private func paneIDs(alongside id: AxoCore.Tab.ID) -> [AxoCore.Tab.ID] {
        guard let split = split(of: id) else { return [id] }
        return panes(of: split.id).map(\.id)
    }

    /// Closes every other unpinned row (`id`'s split stays together). Pinned tabs stay; each
    /// closed tab can come back with Reopen Closed Tab or from the archive.
    public func closeOtherTabs(than id: AxoCore.Tab.ID) async {
        await closeTabs(otherUnpinnedTabs(than: id), keeping: id)
    }

    /// Closes the unpinned rows below `id`'s in the sidebar.
    public func closeTabs(below id: AxoCore.Tab.ID) async {
        await closeTabs(unpinnedTabs(below: id), keeping: id)
    }

    /// Closes several unpinned tabs at once: one write, one announcement.
    private func closeTabs(_ ids: [AxoCore.Tab.ID], keeping id: AxoCore.Tab.ID) async {
        guard let space, !ids.isEmpty else { return }
        logger.notice("Closing \(ids.count, privacy: .public) tabs at the person's request")
        if selectedTabID.map(ids.contains) ?? false { select(id) }
        for closing in ids {
            prompts.dismissAll(from: closing)
            pool.discard(closing)
        }
        do {
            try await store.archiveTabs(ids: ids, at: now())
            tabs = try await store.tabs(in: space.id)
        } catch {
            report(error, "Axo couldn't close the tabs.")
            return
        }
        ids.forEach { onTabEvent?(.closed($0)) }
        postNotice(ids.count == 1 ? "Closed 1 tab" : "Closed \(ids.count) tabs")
    }
}
