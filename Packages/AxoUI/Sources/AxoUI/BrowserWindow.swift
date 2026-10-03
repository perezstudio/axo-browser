import AxoCore
import AxoWeb
import SwiftUI

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
                .toolbar { NavigationToolbar(model: model) }
                // The sidebar's address field already shows where you are.
                .toolbar(removing: .title)
        }
        .focusedSceneValue(\.browserModel, model)
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
        if let tab = model.selectedTab, let space = model.space {
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

/// The picture of a page taken when its tab hibernated, shown until the page reloads, so waking
/// a tab feels instant.
private struct RestoringSnapshot: View {
    let page: WebTabState?

    var body: some View {
        if let snapshot = page?.restoringSnapshot {
            Image(nsImage: snapshot)
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
