import AxoWeb
import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The page column's toolbar: back, forward, reload, and the address field when the navigation
/// bar is above the page, and the extension, downloads, and summary buttons at the trailing edge.
struct NavigationToolbar: ToolbarContent {
    let model: BrowserModel
    let placement: NavigationBarPlacement

    var body: some ToolbarContent {
        if placement == .page {
            // Back and forward share one glass capsule; reload is its own circle (#67).
            ToolbarItemGroup(placement: .navigation) {
                BackForwardButtons(model: model)
            }
            // Without a spacer, macOS draws neighboring items in one glass group.
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItem(placement: .navigation) {
                ReloadButton(model: model)
            }
            ToolbarItem(placement: .principal) {
                AddressBar(model: model)
                    .frame(minWidth: 240, idealWidth: 520, maxWidth: 680)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("pageAddressBar")
            }
        }
        // The spacer pushes the page's tools (extensions, downloads, summary) to the trailing
        // edge; without it, they sit at the leading edge when there's no address field in the middle.
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
            ExtensionToolbarButtons(model: model)
        }
        if !model.pool.downloads.items.isEmpty || model.isShowingDownloads {
            ToolbarItem {
                DownloadsButton(model: model)
            }
        }
        if model.pageSummarizer != nil {
            ToolbarItem {
                SummaryButton(model: model)
            }
        }
    }
}

/// The sidebar's toolbar when the navigation bar is in the sidebar: back and forward in one glass
/// capsule and reload in its own circle (#67), beside the sidebar toggle.
struct SidebarNavigationToolbar: ToolbarContent {
    let model: BrowserModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            BackForwardButtons(model: model)
        }
        // Without a spacer, macOS draws neighboring items in one glass group.
        ToolbarSpacer(.fixed, placement: .navigation)
        ToolbarItem(placement: .navigation) {
            ReloadButton(model: model)
        }
    }
}

/// Back and forward.
struct BackForwardButtons: View {
    let model: BrowserModel

    var body: some View {
        Button("Back", systemImage: "chevron.backward") { model.goBack() }
            .disabled(model.selectedPage?.canGoBack != true)
            .help("Go back")
            .accessibilityIdentifier("backButton")
        Button("Forward", systemImage: "chevron.forward") { model.goForward() }
            .disabled(model.selectedPage?.canGoForward != true)
            .help("Go forward")
            .accessibilityIdentifier("forwardButton")
    }
}

/// Reload, or Stop while the page loads.
struct ReloadButton: View {
    let model: BrowserModel

    var body: some View {
        let isLoading = model.selectedPage?.isLoading == true
        Button(isLoading ? "Stop" : "Reload", systemImage: isLoading ? "xmark" : "arrow.clockwise") {
            model.reloadOrStop()
        }
        .disabled(model.selectedTabID == nil)
        .help(isLoading ? "Stop loading this page" : "Reload this page")
        .accessibilityIdentifier("reloadButton")
    }
}

/// The address field and Site Settings, at the top of the sidebar or above the page.
struct AddressBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            AddressField(model: model)
            SiteSettingsButton(model: model)
        }
        // Inside the toolbar's capsule, so the address and the Site Settings button sit in from
        // its rounded ends rather than against them.
        .padding(.horizontal, 10)
    }
}
#endif
