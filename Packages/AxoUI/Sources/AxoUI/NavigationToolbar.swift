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
        HistoryButton(model: model, direction: .back)
        HistoryButton(model: model, direction: .forward)
    }
}

/// Back or Forward (#112): a click goes one page; a right-click shows the tab's earlier (or
/// later) pages as a menu, and a long press (or VoiceOver's Show History) shows them in a
/// popover, the nearest first; choosing one goes there directly.
private struct HistoryButton: View {
    let model: BrowserModel
    let direction: HistoryDirection
    @State private var isShowingHistory = false
    /// Set by a long press, so the click its release ends doesn't also go one page.
    @State private var pressShowedHistory = false

    var body: some View {
        let isBack = direction == .back
        Button(isBack ? "Back" : "Forward", systemImage: isBack ? "chevron.backward" : "chevron.forward") {
            if pressShowedHistory {
                pressShowedHistory = false
            } else if isBack {
                model.goBack()
            } else {
                model.goForward()
            }
        }
        .disabled(isBack ? model.selectedPage?.canGoBack != true : model.selectedPage?.canGoForward != true)
        .help(isBack ? "Go back (hold for history)" : "Go forward (hold for history)")
        .accessibilityIdentifier(isBack ? "backButton" : "forwardButton")
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
            guard !model.history(direction).isEmpty else { return }
            pressShowedHistory = true
            isShowingHistory = true
        })
        .contextMenu {
            ForEach(Array(model.history(direction).enumerated()), id: \.offset) { index, entry in
                Button {
                    model.goToHistory(direction, index: index)
                } label: {
                    HistoryEntryLabel(model: model, entry: entry)
                }
            }
        }
        .accessibilityAction(named: "Show History") {
            if !model.history(direction).isEmpty { isShowingHistory = true }
        }
        .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
            HistoryList(model: model, direction: direction) { isShowingHistory = false }
                .windowAppearance()
        }
    }
}

/// A page in a history menu: its site's icon and its title, or its address without one.
private struct HistoryEntryLabel: View {
    let model: BrowserModel
    let entry: HistoryEntry

    var body: some View {
        Label {
            Text(HistoryList.title(of: entry))
        } icon: {
            if let icon = model.favicon(for: entry.url) {
                Image(platformImage: icon)
            } else {
                Image(systemName: "globe")
            }
        }
    }
}

/// The history popover's list (#112), the nearest page first.
struct HistoryList: View {
    let model: BrowserModel
    let direction: HistoryDirection
    let close: () -> Void

    /// What a history entry shows: its title, or its address when it has none.
    static func title(of entry: HistoryEntry) -> String {
        entry.title.isEmpty ? entry.url.absoluteString : entry.title
    }

    var body: some View {
        let entries = model.history(direction)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                Button {
                    close()
                    model.goToHistory(direction, index: index)
                } label: {
                    HistoryEntryLabel(model: model, entry: entry)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .help(entry.url.absoluteString)
                .accessibilityIdentifier("historyEntry")
            }
        }
        .padding(.vertical, 6)
        .frame(width: 280)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(direction == .back ? "Back History" : "Forward History")
        .accessibilityIdentifier("historyList")
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
            if let indicator = model.connectionIndicator {
                ConnectionButton(model: model, indicator: indicator)
            }
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
