import AxoCore
import AxoWeb
import Foundation

extension BrowserModel {
    /// Shows a page another page opened, already loading and connected to its opener
    /// (`window.open`, `target="_blank"`): a popup becomes a mini window, sized as it asked, and a
    /// tab goes right after the tab that opened it. From Peek, a mini window, or a pinned tab, the
    /// link opens there or in Peek as other new-window links do, without the connection.
    func showOpenedPage(_ opened: OpenedPage, from sourceID: AxoCore.Tab.ID) {
        guard let space else {
            opened.page.close()
            return
        }
        switch opened.kind {
        case .popup(let size):
            showEnginePopupWindow(EnginePopupWindow(page: opened.page, profileID: space.profileID, size: size))
        case .tab(let inBackground):
            let source = tabs.first { $0.id == sourceID }
            guard let source, !source.isPinned, peek?.tab.id != sourceID else {
                opened.page.close()
                pool.onOpenInNewTab?(opened.url, sourceID)
                return
            }
            Task { await adoptOpenedPage(opened, after: source, selecting: !inBackground, in: space) }
        }
    }

    private func adoptOpenedPage(_ opened: OpenedPage, after source: AxoCore.Tab, selecting: Bool, in space: Space) async {
        let position: TabPosition = source.folderID == nil ? .after(source.id) : .end
        do {
            let tab = try await store.openTab(url: opened.url, title: opened.page.title, in: space.id, at: position)
            pool.adopt(opened.page, as: tab, profileID: space.profileID)
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
