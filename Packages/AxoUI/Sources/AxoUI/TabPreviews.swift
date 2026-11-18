import AxoCore
import AxoWeb
import SwiftUI

/// The card a tab's row shows while the pointer rests on it (#76), as in Arc: the page's title,
/// its address with the host stressed, and a picture of the page, beside the sidebar (below the
/// tab with tabs at the top). A split's card shows each pane.
public struct TabPreview: Equatable {
    /// Which side of the row the card sits on.
    public enum Edge: Equatable, Sendable {
        /// Beside it, to the right: sidebar rows.
        case trailing
        /// Below it: the top tab bar's tabs.
        case bottom
    }

    /// One page of the card.
    public struct Page: Equatable, Identifiable {
        public let id: AxoCore.Tab.ID
        public var title: String
        public var url: URL
        /// "Pinned page: site" for a pinned tab away from its pinned page (#73).
        public var pinnedPageNote: String?
        /// Whether a picture is coming: the tab has a live page, or a hibernated one with a
        /// snapshot. A tab with no page gets none, rather than loading one for it.
        public var expectsPicture: Bool
        /// The picture once it's here, decoded once.
        public var picture: PlatformImage?
    }

    /// The row's tabs.
    public let tabIDs: [AxoCore.Tab.ID]
    /// The row's frame in the window, from SwiftUI's global coordinate space.
    public var anchor: CGRect
    public var edge: Edge
    public var pages: [Page]
}

extension BrowserModel {
    /// The pointer came to rest on a row: its card shows after ``tabPreviewDelay``, or at once
    /// when another row's card was showing a moment ago, as moving down the sidebar does.
    /// Nothing shows while the sidebar scrolls.
    public func beginTabPreview(_ tabIDs: [AxoCore.Tab.ID], anchor: CGRect, edge: TabPreview.Edge) {
        guard !tabIDs.isEmpty, !isSidebarScrolling, firstRun == nil else { return }
        tabPreviewTask?.cancel()
        tabPreviewRequest = tabIDs
        let recent = tabPreviewHiddenAt.map { ContinuousClock.now - $0 < Self.tabPreviewSwitchWindow } ?? false
        let immediate = tabPreview != nil || recent
        let delay = tabPreviewDelay
        tabPreviewTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: delay)
            }
            guard let self, !Task.isCancelled, !self.isSidebarScrolling, self.tabPreviewRequest == tabIDs else { return }
            let pages = tabIDs.compactMap(self.tabPreviewPage(for:))
            guard !pages.isEmpty else { return }
            self.tabPreview = TabPreview(tabIDs: tabIDs, anchor: anchor, edge: edge, pages: pages)
            // Pictures afterwards, one at a time: the card shows its words at once.
            for page in pages where page.expectsPicture {
                let picture = await self.pool.previewSnapshot(for: page.id).flatMap(PlatformImage.init(data:))
                guard !Task.isCancelled, self.tabPreview?.tabIDs == tabIDs,
                      let index = self.tabPreview?.pages.firstIndex(where: { $0.id == page.id }) else { return }
                self.tabPreview?.pages[index].picture = picture
                if picture == nil { self.tabPreview?.pages[index].expectsPicture = false }
            }
        }
    }

    /// The pointer left a row: its card goes, if it's that row's.
    public func endTabPreview(_ tabIDs: [AxoCore.Tab.ID]) {
        guard tabPreviewRequest == tabIDs else { return }
        hideTabPreview()
    }

    /// Hides the card now: selecting a tab, switching Spaces, or scrolling.
    public func hideTabPreview() {
        tabPreviewTask?.cancel()
        tabPreviewTask = nil
        tabPreviewRequest = nil
        if tabPreview != nil {
            tabPreviewHiddenAt = .now
            tabPreview = nil
        }
    }

    /// The sidebar (or the tab bar) started or stopped scrolling: no card shows meanwhile, and
    /// no picture is taken for one.
    public func setSidebarScrolling(_ scrolling: Bool) {
        isSidebarScrolling = scrolling
        if scrolling { hideTabPreview() }
    }

    /// How long after the card goes another row's still shows at once.
    static let tabPreviewSwitchWindow: Duration = .milliseconds(400)

    /// What the card says about a tab: its live page's title and address when it has one, its
    /// record's otherwise.
    private func tabPreviewPage(for id: AxoCore.Tab.ID) -> TabPreview.Page? {
        guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
        let state = pool.state(for: id)
        let title = state.flatMap { $0.title.isEmpty ? nil : $0.title } ?? TabRow.displayTitle(for: tab)
        let expectsPicture = pool.isHibernated(id) ? pool.snapshot(for: id) != nil : pool.liveTabIDs.contains(id)
        return TabPreview.Page(id: id, title: title, url: state?.url ?? tab.url,
                               pinnedPageNote: TabRow.pinnedPageNote(for: tab), expectsPicture: expectsPicture)
    }
}

/// The card's address: the site's host stressed, on a line of its own cut at the start like the
/// address pill's, so a long lookalike host (`www.bank.example.attacker.example`) keeps its real
/// domain in view; the rest of the address below it. A page with no host (a `data:` page holds a
/// whole file) shows the start of its address.
enum TabPreviewAddress {
    static func parts(of url: URL) -> (host: String, rest: String) {
        guard let host = url.host(percentEncoded: true), !host.isEmpty else {
            return ("", String(url.absoluteString.prefix(80)))
        }
        var rest = url.path(percentEncoded: true)
        if let query = url.query(percentEncoded: true) { rest += "?" + query }
        if rest == "/" { rest = "" }
        return (host, String(rest.prefix(200)))
    }
}

/// Draws the card for ``BrowserModel/tabPreview`` over the whole window, beside its row. It never
/// takes the pointer or focus, so the row and page keep theirs.
struct TabPreviewLayer: View {
    let model: BrowserModel
    /// The coordinate space top tabs measure themselves in for the card: the browser window's
    /// root view, which holds this layer (sidebar rows use `.global`).
    static let space = "tabPreviewWindow"
    @State private var cardSize = CGSize(width: TabPreviewCard.width, height: 220)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // Only while a card shows: nothing lies over the pages otherwise (Chromium's hover
        // tracking ignores pages under another view).
        ZStack {
            if let preview = model.tabPreview {
                GeometryReader { geometry in
                    // Sidebar rows (edge `.trailing`) report their frames in `.global`: the
                    // sidebar is its own split view column, outside the window root's named
                    // space. Top tabs (edge `.bottom`) report them in that named space, since
                    // `.global` inside the tab bar's scroll view came out 40 pt up and put the
                    // card over the tab. This layer converts from the anchor's space.
                    let space: CoordinateSpace = preview.edge == .bottom ? .named(Self.space) : .global
                    let origin = geometry.frame(in: space).origin
                    let anchor = preview.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                    TabPreviewCard(preview: preview)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .offset(Self.offset(for: anchor, edge: preview.edge, card: cardSize, in: geometry.size))
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.tabPreview?.tabIDs)
        // Switching to another app (⌘Tab) with the pointer still on a row hides it.
        .onChange(of: appearsActive) { if !appearsActive { model.hideTabPreview() } }
    }

    /// Where the card's top-left corner goes: beside the row (or below the tab), never over it,
    /// and kept inside the window.
    static func offset(for anchor: CGRect, edge: TabPreview.Edge, card: CGSize, in window: CGSize) -> CGSize {
        let margin: CGFloat = 8
        switch edge {
        case .trailing:
            let top = min(max(anchor.midY - card.height / 2, margin), max(margin, window.height - card.height - margin))
            return CGSize(width: anchor.maxX + 10, height: top)
        case .bottom:
            let leading = min(max(anchor.minX, margin), max(margin, window.width - card.width - margin))
            return CGSize(width: leading, height: anchor.maxY + 8)
        }
    }
}

/// The card itself.
struct TabPreviewCard: View {
    let preview: TabPreview
    static let width: CGFloat = 264

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if preview.pages.contains(where: \.expectsPicture) {
                HStack(spacing: 1) {
                    ForEach(preview.pages) { page in picture(of: page) }
                }
                .frame(height: 150)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(preview.pages) { page in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                        address(of: page.url)
                        if let note = page.pinnedPageNote {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabPreviewCard")
    }

    @ViewBuilder
    private func picture(of page: TabPreview.Page) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.quaternary)
            if let image = page.picture {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    private func address(of url: URL) -> some View {
        let parts = TabPreviewAddress.parts(of: url)
        return VStack(alignment: .leading, spacing: 0) {
            if !parts.host.isEmpty {
                Text(verbatim: parts.host)
                    .foregroundStyle(.primary)
                    .truncationMode(.head)
            }
            if !parts.rest.isEmpty {
                Text(verbatim: parts.rest)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(url.absoluteString)
        .accessibilityIdentifier("tabPreviewAddress")
    }
}

/// A row's frame, held by reference so updating it (every frame while the sidebar scrolls)
/// doesn't redraw the row.
@MainActor
final class TabPreviewFrame {
    var rect = CGRect.zero
}

/// A pinned tab's pinned page for VoiceOver (#73), when it's away from it.
struct PinnedPageContent: ViewModifier {
    let tab: AxoCore.Tab

    func body(content: Content) -> some View {
        if let note = TabRow.pinnedPageNote(for: tab) {
            content.accessibilityCustomContent(Text("Pinned page"), Text(verbatim: note))
        } else {
            content
        }
    }
}
