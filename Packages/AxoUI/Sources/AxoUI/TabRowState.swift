import AxoCore
import Foundation

/// What a sidebar row shows about its tab's page beyond the record: whether it's loading (#70)
/// and whether it's dimmed for having no live page (#72). These read the pool's per-tab
/// liveness, so a row redraws only when its own tab changes; rows get whether they're selected
/// from their parent rather than reading the selection.
extension BrowserModel {
    /// Whether the tab has a live page (not hibernated, unloaded, or not loaded since launch).
    public func isTabLive(_ id: AxoCore.Tab.ID) -> Bool {
        pool.liveness(for: id).isLive
    }

    /// Whether the tab's page is loading (never its progress).
    public func isTabLoading(_ id: AxoCore.Tab.ID) -> Bool {
        pool.liveness(for: id).isLoading
    }

    /// Whether a row for the tab is dimmed: it has no live page and the row isn't selected.
    public func isTabDimmed(_ id: AxoCore.Tab.ID, isSelected: Bool) -> Bool {
        !isSelected && !isTabLive(id)
    }

    /// Whether the sidebar row standing for `tab` holds the selection: the tab, or for a split,
    /// any of its panes.
    func rowHoldsSelection(_ tab: AxoCore.Tab) -> Bool {
        guard let selectedTabID else { return false }
        if tab.id == selectedTabID { return true }
        guard let split = split(of: tab.id) else { return false }
        return panes(of: split.id).contains { $0.id == selectedTabID }
    }
}
