import AppKit
import AxoCore
import AxoWeb
import Foundation

/// A page open in Peek: a temporary card over a pinned tab, for links that leave the pinned
/// tab's site. It isn't in the sidebar until it's promoted to a tab.
public struct Peek: Identifiable, Equatable {
    /// The page's tab. It isn't saved; its ID carries over if the Peek becomes a tab.
    public var tab: AxoCore.Tab
    /// The pinned tab whose link opened it.
    public var sourceTabID: AxoCore.Tab.ID

    public var id: AxoCore.Tab.ID { tab.id }
}

extension BrowserModel {
    /// Decides what a link click in a page does. In a pinned tab, a plain click on a link to
    /// another site opens Peek instead of leaving the pinned page. Returns whether it was taken.
    func handleLinkClick(_ click: LinkClick) -> Bool {
        guard click.modifiers.intersection([.command, .shift, .option, .control]).isEmpty,
              let scheme = click.url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              tabs.first(where: { $0.id == click.tabID })?.isPinned == true,
              click.leavesSite else { return false }
        openPeek(click.url, from: click.tabID)
        return true
    }

    /// Opens `url` in Peek over the pinned tab `sourceID`, replacing any Peek already open.
    public func openPeek(_ url: URL, from sourceID: AxoCore.Tab.ID) {
        guard let space else { return }
        if peek != nil { closePeek(focusingPage: false) }
        let tab = AxoCore.Tab(spaceID: space.id, url: url, sortKey: SortKey.initial)
        peek = Peek(tab: tab, sourceTabID: sourceID)
        announce("Opened \(url.host() ?? url.absoluteString) in Peek")
    }

    /// The Peek's live page state, for its title and loading bar.
    public var peekPage: WebTabState? {
        peek.flatMap { pool.state(for: $0.tab.id) }
    }

    /// Closes Peek and lets its page go.
    public func closePeek() {
        closePeek(focusingPage: true)
    }

    private func closePeek(focusingPage: Bool) {
        guard let peek else { return }
        self.peek = nil
        pool.discard(peek.tab.id)
        if focusingPage { focusPage() }
    }

    /// Makes the Peek a regular tab at the end of the sidebar, or, with `inSplit`, a split view
    /// next to the pinned tab it came from. The page keeps its state.
    public func promotePeek(inSplit: Bool = false) async {
        guard let peek, let space else { return }
        let page = pool.state(for: peek.tab.id)
        let url = page?.url ?? peek.tab.url
        let title = page?.title ?? ""
        self.peek = nil
        do {
            let tab = try await store.openTab(id: peek.tab.id, url: url, title: title, in: space.id)
            try await refreshSidebar()
            onTabEvent?(.opened(tab.id))
            if inSplit, tabs.contains(where: { $0.id == peek.sourceTabID }) {
                select(peek.sourceTabID)
                await addToSplit(tab.id)
            } else {
                select(tab.id)
                announce("Opened \(TabRow.displayTitle(for: tab)) as a tab")
            }
        } catch {
            pool.discard(peek.tab.id)
            report(error, "Axo couldn't open the page as a tab.")
        }
    }
}
