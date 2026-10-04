import AppKit
import AxoCore
import AxoWeb
import Foundation

/// A link from another app, open in its own small window. It isn't in the sidebar until it's
/// opened in Axo's main window as a tab.
public struct MiniWindow: Identifiable, Equatable {
    /// The page's tab. It isn't saved; its ID carries over if the page becomes a tab.
    public var tab: AxoCore.Tab
    /// The profile whose cookies and website data the page uses.
    public var profileID: Profile.ID

    public var id: AxoCore.Tab.ID { tab.id }
}

extension BrowserModel {
    /// Whether a tab ID belongs to a page that isn't in the sidebar: Peek or a mini window.
    func isTemporaryPage(_ tabID: AxoCore.Tab.ID) -> Bool {
        peek?.tab.id == tabID || miniWindows.contains { $0.id == tabID }
    }

    /// Opens `url` in a new mini window, using the current Space's profile.
    public func openMiniWindow(_ url: URL) {
        guard let space else { return }
        let mini = MiniWindow(tab: AxoCore.Tab(spaceID: space.id, url: url, sortKey: SortKey.initial), profileID: space.profileID)
        miniWindows.append(mini)
        presentMiniWindow?(mini)
    }

    /// A mini window's live page state, for its title and loading bar.
    public func miniWindowPage(_ id: MiniWindow.ID) -> WebTabState? {
        pool.state(for: id)
    }

    /// Forgets a mini window that closed and lets its page go.
    public func closeMiniWindow(_ id: MiniWindow.ID) {
        guard miniWindows.contains(where: { $0.id == id }) else { return }
        miniWindows.removeAll { $0.id == id }
        pool.discard(id)
    }

    /// Moves a mini window's page into the current Space as a tab, selects it, and closes the
    /// mini window. The page keeps its state.
    public func openMiniWindowInAxo(_ id: MiniWindow.ID) async {
        guard let mini = miniWindows.first(where: { $0.id == id }), let space else { return }
        let page = pool.state(for: id)
        let url = page?.url ?? mini.tab.url
        let title = page?.title ?? ""
        miniWindows.removeAll { $0.id == id }
        dismissMiniWindow?(id)
        do {
            let tab = try await store.openTab(id: id, url: url, title: title, in: space.id)
            try await refreshSidebar()
            onTabEvent?(.opened(tab.id))
            select(tab.id)
        } catch {
            pool.discard(id)
            report(error, "Axo couldn't open the page as a tab.")
        }
    }
}
