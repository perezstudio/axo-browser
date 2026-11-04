import AxoCore
import Foundation

/// What Shortcuts actions do in the window. The app connects these to AxoIntegration's intents.
extension BrowserModel {
    /// Switches to a Space and brings the window forward. Returns whether the Space exists.
    public func showSpaceForIntent(_ spaceID: Space.ID) async -> Bool {
        guard spaces.contains(where: { $0.id == spaceID }) else { return false }
        await selectSpace(spaceID)
        showBrowserWindow?()
        return true
    }

    /// Opens a page in a new tab, in `spaceID` (switching to it) or the current Space, and brings
    /// the window forward.
    public func openForIntent(_ url: URL, in spaceID: Space.ID?) async {
        if let spaceID, spaces.contains(where: { $0.id == spaceID }) {
            await selectSpace(spaceID)
        }
        hideCommandBar()
        await openTab(url: url)
        showBrowserWindow?()
    }

    /// Shows a tab in its Space and brings the window forward. Returns whether the tab is in the
    /// sidebar.
    public func showTabForIntent(_ tabID: AxoCore.Tab.ID) async -> Bool {
        guard let tab = try? await store.tab(id: tabID), tab.archivedAt == nil,
              spaces.contains(where: { $0.id == tab.spaceID }) else { return false }
        await selectSpace(tab.spaceID)
        selectSidebarItem(.tab(sidebarRowTab(for: tabID)))
        if selectedTabID != tabID { select(tabID) }
        showBrowserWindow?()
        return true
    }

    /// Shows the tab whose page asked to be shown, as after a click on one of its notifications:
    /// selects it, in its Space if it's elsewhere, or the favorite, and brings the window forward.
    ///
    /// The engine also asks for reasons the person didn't start (a page entering full screen, an
    /// extension reloading a page that posted a form), so this only acts while Axo is the active
    /// app (a notification click makes it so first), never activates Axo itself, and leaves a tab
    /// that's already selected alone. Pages elsewhere (Peek, mini windows) are left as they are.
    func showTabForPage(_ tabID: AxoCore.Tab.ID) async {
        guard isAppActive(), selectedTabID != tabID else { return }
        if favorites.contains(where: { $0.id == tabID }) {
            select(tabID)
            showBrowserWindow?()
            return
        }
        _ = await showTabForIntent(tabID)
    }

    /// Copies the selected tab's page into a Space as a new tab, pinned or not, and returns it.
    /// The original tab stays where it is.
    public func saveCurrentTab(to spaceID: Space.ID, pinned: Bool) async throws -> AxoCore.Tab {
        guard let current = shownTab else { throw TabStoreError.tabNotFound(UUID()) }
        let url = selectedPage?.url ?? current.url
        let title = selectedPage?.title ?? current.title
        let saved = try await store.openTab(url: url, title: title, in: spaceID)
        if pinned { try await store.setPinned(true, tabID: saved.id) }
        try await refreshSidebar()
        return try await store.tab(id: saved.id) ?? saved
    }
}
