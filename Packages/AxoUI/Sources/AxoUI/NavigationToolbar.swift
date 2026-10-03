import AxoWeb
import SwiftUI

/// Back, forward, and reload. The address field lives at the top of the sidebar.
struct NavigationToolbar: ToolbarContent {
    let model: BrowserModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.backward") { model.goBack() }
                .disabled(model.selectedPage?.canGoBack != true)
                .help("Go back")
                .accessibilityIdentifier("backButton")
            Button("Forward", systemImage: "chevron.forward") { model.goForward() }
                .disabled(model.selectedPage?.canGoForward != true)
                .help("Go forward")
                .accessibilityIdentifier("forwardButton")
        }
        if !model.pool.downloads.items.isEmpty || model.isShowingDownloads {
            ToolbarItem(placement: .primaryAction) {
                DownloadsButton(model: model)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            let isLoading = model.selectedPage?.isLoading == true
            Button(isLoading ? "Stop" : "Reload", systemImage: isLoading ? "xmark" : "arrow.clockwise") {
                model.reloadOrStop()
            }
            .disabled(model.selectedTabID == nil)
            .help(isLoading ? "Stop loading this page" : "Reload this page")
            .accessibilityIdentifier("reloadButton")
        }
    }
}
