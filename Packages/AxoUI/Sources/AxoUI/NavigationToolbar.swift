import AxoWeb
import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The page column's toolbar: back, forward, reload, and the address field when the navigation
/// bar is above the page, and the extension, downloads, and summary buttons at the trailing edge.
struct NavigationToolbar: ToolbarContent {
    let model: BrowserModel
    let placement: NavigationBarPlacement
    /// Whether the page's tools (extensions, downloads, summary) are here. With the navigation
    /// bar in the sidebar they're in the sidebar while it shows (#67), and here while it's hidden.
    let showsPageTools: Bool

    var body: some ToolbarContent {
        // Above the page, only while the toolbar shows (window full screen): otherwise the page's
        // control bar has them, and a hidden copy would answer ⌘L and Site Settings too (#170).
        if placement == .page, showsPageTools {
            // Back and forward share one glass capsule; reload is its own circle (#67).
            ToolbarItemGroup(placement: .navigation) {
                BackForwardButtons(model: model)
            }
            ToolbarSpacer(.fixed, placement: .navigation)
            ToolbarItem(placement: .navigation) {
                ReloadButton(model: model).ownGlassCircle()
            }
            // macOS draws neighboring navigation items in one glass group, a spacer or not; reload
            // leaves it and draws its own circle.
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) {
                AddressBar(model: model, drawsFocusRing: true)
                    .frame(minWidth: 240, idealWidth: 520, maxWidth: 680)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("pageAddressBar")
            }
        }
        if showsPageTools {
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
}

/// The sidebar's toolbar when the navigation bar is in the sidebar: back and forward in one glass
/// capsule and reload in its own circle (#67), beside the sidebar toggle.
struct SidebarNavigationToolbar: ToolbarContent {
    let model: BrowserModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            BackForwardButtons(model: model)
        }
        ToolbarSpacer(.fixed, placement: .navigation)
        ToolbarItem(placement: .navigation) {
            ReloadButton(model: model).ownGlassCircle()
        }
        // macOS draws neighboring navigation items in one glass group, a spacer or not; reload
        // leaves it and draws its own circle.
        .sharedBackgroundVisibility(.hidden)
    }
}

extension View {
    /// A toolbar button in a glass circle of its own, the size of the toolbar's glass.
    func ownGlassCircle() -> some View {
        buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
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
    /// Whether it draws the focus ring around itself while the field has focus.
    var drawsFocusRing = false
    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 6) {
            AddressField(model: model)
            SiteSettingsButton(model: model)
        }
        // Inside the toolbar's capsule, so the address and the Site Settings button sit in from
        // its rounded ends rather than against them.
        .padding(.horizontal, 10)
        #if os(macOS)
        // In the window toolbar (window full screen), where nothing around it draws the focus
        // ring for the plain field; the control bar's capsule draws its own.
        .overlay {
            if drawsFocusRing, isFocused {
                Capsule()
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(AddressFieldFocus.self) { isFocused = $0 }
        #endif
    }
}
#endif
