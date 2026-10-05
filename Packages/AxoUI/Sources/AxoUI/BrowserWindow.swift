import AxoCore
import AxoWeb
import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The root view of a browser window: the sidebar on the left and web content on the right.
public struct BrowserWindow: View {
    @Bindable private var model: BrowserModel

    /// Creates a window showing `model`.
    public init(model: BrowserModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            content
                // In the page column: an overlay on the split view itself couldn't take focus.
                .overlay {
                    if let peek = model.peek, let space = model.space {
                        PeekOverlay(model: model, peek: peek, profileID: space.profileID)
                    }
                }
                .overlay {
                    if model.isCommandBarVisible {
                        CommandBarView(model: model)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let translation = model.selectedTranslation {
                        TranslationBar(model: model, translation: translation)
                    }
                }
                .modifier(PageTranslationTask(model: model))
                .toolbar { NavigationToolbar(model: model) }
                // The sidebar's address field already shows where you are.
                .toolbar(removing: .title)
        }
        .focusedSceneValue(\.browserModel, model)
        .modifier(HandoffActivity(model: model))
        .pagePrompts(model: model)
        .task { await model.start() }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            presenting: model.alertMessage
        ) { _ in
            Button("OK") { model.alertMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let split = model.selectedSplit, let space = model.space {
            SplitPanesView(model: model, split: split, panes: model.panes(of: split.id), profileID: space.profileID)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isFindBarVisible { FindBar(model: model) }
                }
        } else if let tab = model.selectedTab, let space = model.space {
            WebViewHost(tab: tab, profileID: space.profileID, pool: model.pool)
                .accessibilityIdentifier("webContent")
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isFindBarVisible { FindBar(model: model) }
                }
                .overlay(alignment: .top) { RestoringSnapshot(page: model.selectedPage) }
                .overlay(alignment: .top) { LoadingBar(page: model.selectedPage) }
        } else {
            ContentUnavailableView {
                Label("No Tab Open", systemImage: "safari")
            } description: {
                Text("Open a tab to start browsing.")
            } actions: {
                Button("New Tab") { model.beginNewTab() }
                    .accessibilityIdentifier("emptyStateNewTabButton")
            }
            .accessibilityIdentifier("emptyState")
        }
    }
}

/// A split view's panes, side by side or stacked, with resizable dividers. The focused pane has
/// an accent outline; clicking a pane focuses it.
private struct SplitPanesView: View {
    let model: BrowserModel
    let split: TabSplit
    let panes: [AxoCore.Tab]
    let profileID: Profile.ID

    var body: some View {
        Group {
            if split.orientation == .horizontal {
                HSplitView { paneViews }
            } else {
                VSplitView { paneViews }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split view")
        .accessibilityIdentifier("splitView")
    }

    private var paneViews: some View {
        ForEach(Array(panes.enumerated()), id: \.element.id) { index, tab in
            let page = model.pool.state(for: tab.id)
            WebViewHost(tab: tab, profileID: profileID, pool: model.pool)
                .frame(minWidth: 200, minHeight: 150)
                .overlay(alignment: .top) { RestoringSnapshot(page: page) }
                .overlay(alignment: .top) { LoadingBar(page: page) }
                .overlay {
                    if tab.id == model.selectedTabID {
                        Rectangle()
                            .strokeBorder(.tint, lineWidth: 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Pane \(index + 1) of \(panes.count), \(TabRow.displayTitle(for: tab))")
                .accessibilityAddTraits(tab.id == model.selectedTabID ? .isSelected : [])
                .accessibilityIdentifier("splitPane")
        }
    }
}

/// The picture of a page taken when its tab hibernated, shown until the page reloads, so waking
/// a tab feels instant.
private struct RestoringSnapshot: View {
    let page: WebTabState?

    var body: some View {
        if let snapshot = page?.restoringSnapshot {
            Image(platformImage: snapshot)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.background)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }
}

/// A thin progress bar along the top of the page while it loads.
private struct LoadingBar: View {
    let page: WebTabState?

    var body: some View {
        if let page, page.isLoading {
            ProgressView(value: page.estimatedProgress)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel("Loading")
        }
    }
}

#Preview {
    BrowserWindow(model: BrowserModel(
        store: try! TabStore.makeInMemory(),
        pool: WebViewPool(makeDataStore: { _ in .nonPersistent() })
    ))
}
#endif
