import AxoCore
import SwiftUI

/// The sidebar: the address field and the current Space's tabs, in order.
struct SidebarView: View {
    let model: BrowserModel

    var body: some View {
        List(selection: Binding(get: { model.selectedTabID }, set: { model.select($0) })) {
            Section(model.space?.name ?? "Tabs") {
                ForEach(model.tabs) { tab in
                    TabRow(tab: tab, favicon: model.favicon(for: tab))
                        .tag(tab.id)
                        .contextMenu {
                            Button("Close Tab") {
                                Task { await model.closeTab(tab.id) }
                            }
                        }
                }
                .onMove { source, destination in
                    Task { await model.moveTabs(fromOffsets: source, toOffset: destination) }
                }
            }
        }
        .accessibilityIdentifier("sidebar")
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
