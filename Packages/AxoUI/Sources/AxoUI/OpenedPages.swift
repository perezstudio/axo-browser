import AxoCore
import AxoWeb
import Foundation

extension BrowserModel {
    /// Shows a page another page opened, already loading and connected to its opener
    /// (`window.open`, `target="_blank"`): a popup becomes a mini window, sized as it asked, and a
    /// tab goes right after the tab that opened it, or after the Space's tabs when a favorite's
    /// page opened it (#234). From Peek, a mini window, or a pinned tab, the link opens there or
    /// in Peek as other new-window links do, without the connection. A page made with another
    /// profile than the shown Space's (its Space moved meanwhile) is closed: it would carry that
    /// profile's website data into this Space.
    func showOpenedPage(_ opened: OpenedPage, from sourceID: AxoCore.Tab.ID) {
        guard let space, pool.liveProfileID(for: sourceID) == space.profileID else {
            opened.page.close()
            return
        }
        switch opened.kind {
        case .popup(let size):
            showEnginePopupWindow(EnginePopupWindow(page: opened.page, profileID: space.profileID, size: size))
        case .tab(let inBackground):
            if let source = tabs.first(where: { $0.id == sourceID }), !source.isPinned, peek?.tab.id != sourceID {
                let position: TabPosition = source.folderID == nil ? .after(source.id) : .end
                Task { await adoptOpenedPage(opened, at: position, selecting: !inBackground, in: space) }
            } else if isShownFavorite(sourceID) {
                // A favorite's page (#234): favorites aren't the Space's tabs, so the new tab goes
                // at the end of them, as New Tab does, keeping its opener.
                Task { await adoptOpenedPage(opened, at: .end, selecting: !inBackground, in: space) }
            } else {
                // A pinned tab's link goes to Peek; Peek's and a mini window's stay in them.
                opened.page.close()
                pool.onOpenInNewTab?(opened.url, sourceID)
            }
        }
    }

    /// Whether `id` is a favorite of the shown Space's profile whose page belongs to that profile
    /// (#234). While the shown Space moves to another profile, the old favorites can still be
    /// listed; their pages mustn't open tabs here.
    func isShownFavorite(_ id: AxoCore.Tab.ID) -> Bool {
        guard let space, favoritesProfileID == space.profileID else { return false }
        return favorites.contains { $0.id == id } && pool.liveProfileID(for: id) == space.profileID
    }

    private func adoptOpenedPage(_ opened: OpenedPage, at position: TabPosition, selecting: Bool, in space: Space) async {
        do {
            let tab = try await store.openTab(url: opened.url, title: opened.page.title, in: space.id, at: position)
            pool.adopt(opened.page, as: tab, profileID: space.profileID)
            // Switched Spaces meanwhile: the tab is in its Space, but the shown sidebar isn't it.
            guard self.space?.id == space.id else { return }
            tabs = try await store.tabs(in: space.id)
            onTabEvent?(.opened(tab.id))
            if selecting { select(tab.id) }
        } catch {
            opened.page.close()
            report(error, "Axo couldn't open the page.")
        }
    }

    // MARK: Page full screen

    /// A page asked to fill the screen, or to stop. Only the page showing can; the window then
    /// shows only it, filling the screen.
    func pageSetsFullscreen(_ tabID: AxoCore.Tab.ID, _ fullscreen: Bool) {
        if fullscreen {
            guard tabID == selectedTabID || tabID == shownTab?.id else {
                pool.exitFullscreen(tabID)
                return
            }
            fullscreenTabID = tabID
            announce("Full screen. Press Escape to exit.")
        } else if fullscreenTabID == tabID {
            fullscreenTabID = nil
        }
    }

    /// Takes the page out of full screen, when the person leaves it some other way than the page
    /// (the window's full-screen button, or switching tabs).
    public func exitPageFullscreen() {
        guard let tabID = fullscreenTabID else { return }
        fullscreenTabID = nil
        pool.exitFullscreen(tabID)
    }
}
