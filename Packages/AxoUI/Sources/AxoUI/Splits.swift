#if os(macOS)
import AppKit
#endif
import AxoCore
import AxoWeb
import Foundation

/// Split views: two to four tabs on screen together, shown as one sidebar row.
extension BrowserModel {
    // MARK: Reading splits

    /// The split a tab is a pane of, if it has at least one other pane in the sidebar.
    public func split(of tabID: AxoCore.Tab.ID) -> TabSplit? {
        guard let splitID = tabs.first(where: { $0.id == tabID })?.splitID,
              panes(of: splitID).count > 1 else { return nil }
        return splits.first { $0.id == splitID }
    }

    /// A split's tabs, in pane order.
    public func panes(of splitID: TabSplit.ID) -> [AxoCore.Tab] {
        tabs.filter { $0.splitID == splitID }
            .sorted { ($0.splitSortKey ?? "", $0.id.uuidString) < ($1.splitSortKey ?? "", $1.id.uuidString) }
    }

    /// The split on screen, if the selected tab is in one.
    public var selectedSplit: TabSplit? {
        selectedTabID.flatMap(split(of:))
    }

    /// The tab whose row stands for a split in the sidebar: its first tab in sidebar order.
    /// For a tab outside a split, the tab itself.
    public func sidebarRowTab(for tabID: AxoCore.Tab.ID) -> AxoCore.Tab.ID {
        guard let split = split(of: tabID) else { return tabID }
        return tabs.first { $0.splitID == split.id }?.id ?? tabID
    }

    /// Whether a tab is hidden in the sidebar because its split's row stands for it.
    func isSplitFollower(_ tab: AxoCore.Tab) -> Bool {
        sidebarRowTab(for: tab.id) != tab.id
    }

    // MARK: Focus

    /// Called when a web view takes focus. Clicking a pane of the split on screen selects that
    /// pane's tab, so the toolbar and address field follow it.
    func paneDidTakeFocus(_ tabID: AxoCore.Tab.ID) {
        guard tabID != selectedTabID, let split = selectedSplit, split.id == self.split(of: tabID)?.id else { return }
        select(tabID)
    }

    /// Selects a split's row: shows the split with the pane it last had focused.
    func selectSplitRow(_ rowTabID: AxoCore.Tab.ID) {
        guard let split = split(of: rowTabID) else {
            select(rowTabID)
            return
        }
        let panes = panes(of: split.id).map(\.id)
        let remembered = focusedPaneBySplit[split.id].flatMap { panes.contains($0) ? $0 : nil }
        select(remembered ?? rowTabID)
    }

    /// Remembers which pane of a split is focused.
    func rememberFocusedPane() {
        if let split = selectedSplit, let selectedTabID { focusedPaneBySplit[split.id] = selectedTabID }
    }

    // MARK: Changing splits

    /// Whether another tab can join the selected tab in a split view.
    public var canAddToSplit: Bool {
        guard let selectedTabID else { return false }
        guard let split = split(of: selectedTabID) else { return true }
        return panes(of: split.id).count < TabSplit.maximumPanes
    }

    /// Shows a tab next to the selected one: makes a split of the two, or adds it to the
    /// selected tab's split.
    public func addToSplit(_ tabID: AxoCore.Tab.ID) async {
        guard let anchor = selectedTabID, anchor != tabID else { return }
        await addToSplit(tabID, with: anchor)
    }

    private func addToSplit(_ tabID: AxoCore.Tab.ID, with anchor: AxoCore.Tab.ID) async {
        do {
            try await store.addToSplit(tabID, with: anchor)
            try await refreshSidebar()
            select(tabID)
            if let tab = selectedTab { announce("Added \(TabRow.displayTitle(for: tab)) to split view") }
        } catch TabStoreError.splitFull {
            alertMessage = "A split view can show up to \(TabSplit.maximumPanes) tabs."
        } catch {
            report(error, "Axo couldn't make the split view.")
        }
    }

    /// Opens the command bar to choose what to show next to the selected tab: a page to open in
    /// a new tab, or an open tab (Add Split View).
    public func beginSplitWithNewTab() {
        guard canAddToSplit else { return }
        let anchor = selectedTabID
        showCommandBar()
        pendingSplitAnchor = anchor
    }

    /// Finishes Add Split View with the tab the command bar opened or chose.
    func completePendingSplit(with tabID: AxoCore.Tab.ID?, anchor: AxoCore.Tab.ID?) async {
        guard let anchor, let tabID, anchor != tabID else { return }
        await addToSplit(tabID, with: anchor)
    }

    /// Takes the focused pane out of its split. It stays in the sidebar as its own row.
    public func removeSelectedTabFromSplit() async {
        guard let tabID = selectedTabID, split(of: tabID) != nil else { return }
        do {
            try await store.removeFromSplit(tabID)
            try await refreshSidebar()
            announce("Removed from split view")
        } catch {
            report(error, "Axo couldn't change the split view.")
        }
    }

    /// Ends the split on screen. Its tabs stay in the sidebar as separate rows.
    public func separateSelectedSplit() async {
        guard let split = selectedSplit else { return }
        do {
            try await store.separateSplit(split.id)
            try await refreshSidebar()
            announce("Separated split view")
        } catch {
            report(error, "Axo couldn't separate the split view.")
        }
    }

    /// Switches the split on screen between side by side and stacked.
    public func toggleSplitOrientation() async {
        guard let split = selectedSplit else { return }
        let orientation: TabSplit.Orientation = split.orientation == .horizontal ? .vertical : .horizontal
        do {
            try await store.setSplitOrientation(orientation, id: split.id)
            try await refreshSidebar()
            announce(orientation == .horizontal ? "Side by side" : "Stacked")
        } catch {
            report(error, "Axo couldn't rearrange the split view.")
        }
    }
}
