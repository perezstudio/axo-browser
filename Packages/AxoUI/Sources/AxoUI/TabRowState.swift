import AxoCore
import Foundation

/// What a sidebar row shows about its tab's page beyond the record: whether it's loading (#70)
/// and whether it's dimmed for having no live page (#72). Rows read these in their bodies, so
/// they redraw only when their own tab starts or stops loading, or becomes live or not.
extension BrowserModel {
    /// Whether the tab has a live page (not hibernated, unloaded, or not loaded since launch).
    public func isTabLive(_ id: AxoCore.Tab.ID) -> Bool {
        pool.liveness.isLive(id)
    }

    /// Whether the tab's page is loading. Reads only the loading flag, never progress, so rows
    /// don't redraw on every progress tick.
    public func isTabLoading(_ id: AxoCore.Tab.ID) -> Bool {
        guard isTabLive(id) else { return false }
        return pool.state(for: id)?.isLoading ?? false
    }

    /// Whether the tab's row is dimmed: it has no live page and isn't the one selected.
    public func isTabDimmed(_ id: AxoCore.Tab.ID) -> Bool {
        id != selectedTabID && !isTabLive(id)
    }
}
