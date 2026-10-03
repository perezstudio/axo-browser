import AxoCore
import SwiftUI

/// The sidebar: the address field, the Space's pinned tabs, and its other tabs.
struct SidebarView: View {
    let model: BrowserModel
    @State private var isShowingArchive = false

    var body: some View {
        List(selection: Binding(get: { model.selectedTabID }, set: { model.select($0) })) {
            if !model.pinnedTabs.isEmpty {
                Section("Pinned") {
                    rows(for: model.pinnedTabs, pinned: true)
                }
                .accessibilityIdentifier("pinnedSection")
            }
            Section(model.space?.name ?? "Tabs") {
                rows(for: model.unpinnedTabs, pinned: false)
            }
        }
        .sheet(isPresented: $isShowingArchive) {
            ArchivedTabsView(model: model)
        }
        .onChange(of: model.isShowingArchive) { isShowingArchive = model.isShowingArchive }
        .onChange(of: isShowingArchive) { if !isShowingArchive { model.isShowingArchive = false } }
        .accessibilityIdentifier("sidebar")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SpaceSwitcher(model: model)
        }
        .safeAreaInset(edge: .top) {
            // Like Arc, the address field sits at the top of the sidebar.
            AddressField(model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .toolbar {
            ToolbarItem {
                Button("New Tab", systemImage: "plus") { model.beginNewTab() }
                    .help("New Tab")
                    .accessibilityIdentifier("newTabButton")
            }
        }
    }
}

extension SidebarView {
    /// The rows of one section, reorderable within it.
    @ViewBuilder
    private func rows(for tabs: [AxoCore.Tab], pinned: Bool) -> some View {
        ForEach(tabs) { tab in
            TabRow(tab: tab, favicon: model.favicon(for: tab))
                .tag(tab.id)
                .contextMenu { menu(for: tab) }
        }
        .onMove { source, destination in
            Task { await model.moveTabs(fromOffsets: source, toOffset: destination, pinned: pinned) }
        }
    }

    @ViewBuilder
    private func menu(for tab: AxoCore.Tab) -> some View {
        if tab.isPinned {
            Button("Go to Pinned Page") { Task { await model.goToPinnedHome(tab.id) } }
                .disabled(!tab.hasLeftHome)
            Button("Pin This Page Instead") { Task { await model.makeCurrentPagePinnedHome(tab.id) } }
                .disabled(!tab.hasLeftHome)
            Button("Unpin Tab") { Task { await model.setPinned(false, tabID: tab.id) } }
            Divider()
            Button("Unload Tab") { Task { await model.closeTab(tab.id) } }
        } else {
            Button("Pin Tab") { Task { await model.setPinned(true, tabID: tab.id) } }
            Divider()
            Button("Close Tab") { Task { await model.closeTab(tab.id) } }
        }
    }
}

/// One tab in the sidebar: the site's icon (or a globe) and the page title.
struct TabRow: View {
    let tab: AxoCore.Tab
    let favicon: NSImage?

    var body: some View {
        Label {
            Text(Self.displayTitle(for: tab))
        } icon: {
            if let favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(.rect(cornerRadius: 3))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "globe")
            }
        }
        .lineLimit(1)
        .accessibilityIdentifier("tabRow")
    }

    /// The page title, or the host (or full URL) for pages without one.
    static func displayTitle(for tab: AxoCore.Tab) -> String {
        if !tab.title.isEmpty { return tab.title }
        return tab.url.host() ?? tab.url.absoluteString
    }
}
