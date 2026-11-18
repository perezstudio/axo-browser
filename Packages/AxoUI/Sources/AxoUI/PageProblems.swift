import AxoCore
import AxoWeb
import SwiftUI

/// Crashed and unresponsive pages (#75): a row with a page that stopped working dims and shows a
/// warning that reloads it, and the page's place shows "This Page Stopped" (or "This Page Isn't
/// Responding") with Reload, as the error pages and Tab row states boards draw them. Rows read it
/// through the pool's per-tab liveness, so a row redraws only when its own tab changes.
extension BrowserModel {
    /// Why the tab's page stopped working; nil while it works or has no live page.
    public func tabProblem(_ id: AxoCore.Tab.ID) -> PageProblem? {
        pool.liveness(for: id).state?.problem
    }

    /// The first problem among several tabs (a split's panes), for their row.
    public func tabProblem(_ ids: [AxoCore.Tab.ID]) -> PageProblem? {
        ids.lazy.compactMap(tabProblem).first
    }

    /// Reloads the tabs' pages that stopped working: the row's warning, and Reload on the page.
    /// An engine ends a page that stopped responding before loading it again. A page that crashed
    /// before anything loaded has nothing to reload, so it loads its tab's address again.
    public func reloadStoppedPages(_ ids: [AxoCore.Tab.ID]) {
        for id in ids where tabProblem(id) != nil {
            if pool.state(for: id)?.url == nil, let url = tabRecordURL(id) {
                pool.load(url, in: id)
            } else {
                pool.reload(id)
            }
        }
    }

    /// The address a tab's record has: a sidebar tab's, a favorite's, Peek's, or a mini window's.
    private func tabRecordURL(_ id: AxoCore.Tab.ID) -> URL? {
        if let tab = tabs.first(where: { $0.id == id }) { return tab.url }
        if let favorite = favorites.first(where: { $0.id == id }) { return favorite.url }
        if let peek, peek.tab.id == id { return peek.tab.url }
        return miniWindows.first { $0.tab.id == id }?.tab.url
    }

    /// Whether the page showing (or its split's) stopped responding: View › Wait for Page.
    public var shownPageIsUnresponsive: Bool {
        shownTab.map { muteTargets(for: $0.id).contains { tabProblem($0) == .unresponsive } } ?? false
    }

    /// Gives the page showing (or its split's pane) that stopped responding more time.
    public func waitForShownPage() {
        guard let shownTab else { return }
        for id in muteTargets(for: shownTab.id) where tabProblem(id) == .unresponsive {
            waitForResponse(id)
        }
    }

    /// Gives a page that stopped responding more time: Wait on the page.
    public func waitForResponse(_ id: AxoCore.Tab.ID) {
        pool.livePage(for: id)?.waitForResponse()
    }

    /// Tells VoiceOver when a page on screen stops working (the page showing, a pane of its split,
    /// Peek, or a mini window), which may happen with nothing the person did; a background tab's
    /// row says so in its value instead. The page loses keyboard focus, so the menus' shortcuts
    /// (⌘R) work again: a page that crashed or hangs never hands key presses back.
    func pageProblemChanged(_ tabID: AxoCore.Tab.ID, _ problem: PageProblem?) {
        guard let problem else { return }
        let onScreen = (shownTab.map { muteTargets(for: $0.id) } ?? [])
            + [peek?.tab.id].compactMap(\.self) + miniWindows.map(\.tab.id)
        guard onScreen.contains(tabID) else { return }
        announce(problem.title)
        #if os(macOS)
        if let view = pool.livePage(for: tabID)?.view, let window = view.window,
           let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) {
            window.makeFirstResponder(nil)
        }
        #endif
    }
}

extension PageProblem {
    /// The page's heading, also what VoiceOver hears when it happens.
    var title: String {
        switch self {
        case .crashed, .outOfMemory: "This Page Stopped"
        case .unresponsive: "This Page Isn’t Responding"
        }
    }

    /// What happened and what to do, plainly.
    var message: String {
        switch self {
        case .crashed:
            "Something went wrong while showing it. Reloading usually brings it back, and your other tabs are fine."
        case .outOfMemory:
            "It ran out of memory. Closing tabs you aren’t using may help. Your other tabs are fine."
        case .unresponsive:
            "It may be busy, or stuck. Wait gives it more time; reloading starts it again, and loses anything on it that isn’t saved."
        }
    }

    /// The engine's code for it, under Show Details; nil when the engine gave none (WebKit).
    var details: String? {
        switch self {
        case .crashed(let code): code.map { "Error code: \($0)" }
        case .outOfMemory: "Error code: Out of Memory"
        case .unresponsive: nil
        }
    }

    /// The row's state for VoiceOver and its warning's tooltip.
    var rowDescription: String {
        switch self {
        case .crashed, .outOfMemory: "Page stopped working"
        case .unresponsive: "Page isn’t responding"
        }
    }
}

/// The warning a row with a stopped page shows at its trailing edge; a click reloads the page, as
/// the Tab row states board has it.
struct TabProblemButton: View {
    let problem: PageProblem
    let reload: () -> Void

    var body: some View {
        Button(action: reload) {
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help("\(problem.rowDescription). Click to reload.")
        .accessibilityLabel("Reload Page")
        .accessibilityIdentifier("tabProblemButton")
    }
}

/// What the page's place shows while the page stopped working: Axo, surprised, on the page's
/// background, with Reload (and Wait for a page that isn't responding) in the Space's color.
struct PageProblemView: View {
    let problem: PageProblem
    /// The Space's color, for Axo and the main button.
    let tint: Color
    let reload: () -> Void
    let wait: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 12) {
            SurprisedAxo(tint: tint)
            Text(problem.title)
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            Text(problem.message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 8) {
                if problem == .unresponsive {
                    Button("Wait", action: wait)
                        .buttonStyle(.glassProminent)
                        .tint(tint)
                        .accessibilityIdentifier("pageProblemWait")
                    Button("Reload", action: reload)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("pageProblemReload")
                } else {
                    Button("Reload", action: reload)
                        .buttonStyle(.glassProminent)
                        .tint(tint)
                        .accessibilityIdentifier("pageProblemReload")
                }
                if problem.details != nil {
                    Button {
                        withAnimation(.snappy) { showsDetails.toggle() }
                    } label: {
                        Label(showsDetails ? "Hide Details" : "Show Details",
                              systemImage: showsDetails ? "chevron.up" : "chevron.down")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("pageProblemDetails")
                }
            }
            .controlSize(.large)
            .padding(.top, 8)
            if showsDetails, let details = problem.details {
                Text(details)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Over the page, which drew nothing (a crash) or is frozen (a hang); it takes the
        // page's clicks, since the page can't use them anyway.
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pageProblem")
        // Its details stay with the problem they belong to.
        .onChange(of: problem) { showsDetails = false }
    }
}

extension View {
    /// Covers a tab's page with ``PageProblemView`` while the page stopped working (#75).
    func pageProblem(for tabID: AxoCore.Tab.ID?, model: BrowserModel) -> some View {
        modifier(PageProblemCover(tabID: tabID, model: model))
    }
}

private struct PageProblemCover: ViewModifier {
    let tabID: AxoCore.Tab.ID?
    let model: BrowserModel

    func body(content: Content) -> some View {
        content.overlay {
            if let tabID, let problem = model.tabProblem(tabID) {
                PageProblemView(
                    problem: problem,
                    tint: model.space?.markerColor ?? .accentColor,
                    reload: { model.reloadStoppedPages([tabID]) },
                    wait: { model.waitForResponse(tabID) }
                )
            }
        }
    }
}
