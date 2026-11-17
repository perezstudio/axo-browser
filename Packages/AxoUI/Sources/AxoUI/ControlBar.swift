import AxoWeb
import SwiftUI

// Mac only; iPhone and iPad have their own chrome.
#if os(macOS)
/// The control bar's button for the tab bar, with tabs at the top (#136).
struct TabBarToggle {
    /// Whether the tab bar is hidden.
    let isHidden: Bool
    /// Hides or shows it.
    let toggle: () -> Void
}

/// The page's control bar with the navigation bar above the page (#170): back and forward,
/// reload, the address field in the middle, and the page's tools (extensions, Downloads, the
/// summary) at the right, in a bar at the top of the page's area, on the page's own color
/// (#107's tint) rather than across the window, so the sidebar keeps the Space's theme to the
/// top. With the sidebar hidden it also holds the window's controls and Show Sidebar. Dragging
/// its empty space moves the window, as the title bar it replaces did.
struct ControlBar: View {
    let model: BrowserModel
    /// Whether the sidebar is hidden; the bar then also holds the window's controls and Show
    /// Sidebar.
    let isSidebarHidden: Bool
    /// With tabs at the top (#136), the button that hides or shows the tab bar.
    var tabBar: TabBarToggle?
    /// Shows the sidebar again.
    let showSidebar: () -> Void
    @AppStorage(ToolbarTintSettings.storageKey) private var tintsFromPage = true
    @Environment(\.colorScheme) private var colorScheme
    /// Whether the address field has focus, for the focus ring around its capsule.
    @State private var isAddressFocused = false

    /// As tall as the title bar's area it sits in, so its 36 pt buttons are centered with the
    /// window's controls, 26 pt down.
    static let height: CGFloat = SidebarTopRow.height
    /// The widest the address gets.
    static let addressMaxWidth: CGFloat = 640

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: SidebarTopRow.spacing) {
                if isSidebarHidden {
                    WindowControls()
                        .frame(width: WindowControls.size.width, height: WindowControls.size.height)
                        .padding(.leading, WindowControls.leading - Self.horizontalPadding)
                        .padding(.trailing, 6)
                    Button("Show Sidebar", systemImage: "sidebar.left", action: showSidebar)
                        .modifier(SidebarGlassButtonStyle())
                        .help("Show Sidebar")
                        .accessibilityIdentifier("showSidebarButton")
                }
                if let tabBar {
                    let title = tabBar.isHidden ? "Keep Tab Bar Shown" : "Hide Tab Bar"
                    Button(title, systemImage: "rectangle.topthird.inset.filled", action: tabBar.toggle)
                        .modifier(SidebarGlassButtonStyle())
                        .help(title)
                        .accessibilityIdentifier("tabBarToggleButton")
                }
                BackForwardCapsule(model: model)
                ReloadButton(model: model)
                    .modifier(SidebarGlassButtonStyle())
                AddressBar(model: model)
                    // It gives way first in a narrow window, so the buttons at the ends stay.
                    .frame(minWidth: 120, maxWidth: Self.addressMaxWidth)
                    .layoutPriority(-1)
                    .frame(height: SidebarGlassButtonStyle.side)
                    .glassEffect(.regular, in: .capsule)
                    // The field is plain; while it has focus, the capsule shows the focus ring.
                    .overlay {
                        if isAddressFocused {
                            Capsule()
                                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                                .allowsHitTesting(false)
                        }
                    }
                    .onPreferenceChange(AddressFieldFocus.self) { isAddressFocused = $0 }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("pageAddressBar")
                    .frame(maxWidth: .infinity)
                pageTools
            }
            .padding(.horizontal, Self.horizontalPadding)
        }
        .frame(height: Self.height)
        .background {
            ZStack {
                Rectangle().fill(background)
                    // Under the tab bar, the page's top edge casts the board's shadow up onto it,
                    // with a hairline (#136).
                    .shadow(color: .black.opacity(castsShadowUp ? 0.28 : 0), radius: 9, y: -6)
                    .overlay(alignment: .top) {
                        if castsShadowUp {
                            Rectangle().fill(.black.opacity(0.18)).frame(height: 0.5)
                        }
                    }
                // The bar's empty space moves the window, and a double click zooms it, as the
                // title bar's did.
                Color.clear
                    .contentShape(.rect)
                    .gesture(WindowDragGesture())
                    .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
                    .allowsWindowActivationEvents(true)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Controls")
        .accessibilityIdentifier("controlBar")
    }

    /// Whether the tab bar sits above the bar, which the page's top edge casts a shadow on.
    private var castsShadowUp: Bool { tabBar.map { !$0.isHidden } ?? false }

    /// The gap at the bar's ends.
    static let horizontalPadding: CGFloat = 12

    /// The page's color with the tint on (Settings › General), or the window's background.
    private var background: Color {
        let tint = ToolbarTint.tint(for: model.selectedPage?.pageColors, isDark: colorScheme == .dark,
                                    isEnabled: tintsFromPage, placement: .page)
        return tint.map { Color(pageColor: $0.color) } ?? Color(nsColor: .windowBackgroundColor)
    }

    /// Whether any extension has a button.
    private var hasExtensions: Bool {
        guard let provider = model.extensionToolbar, let profileID = model.space?.profileID else { return false }
        return !provider.toolbarItems(profileID: profileID, tabID: model.selectedTabID).isEmpty
    }

    /// Extensions (the first few, and a menu with the rest), Downloads (once there's a download),
    /// and Summarize Page.
    @ViewBuilder
    private var pageTools: some View {
        HStack(spacing: 2) {
            if hasExtensions {
                ExtensionToolbarButtons(model: model, limit: ExtensionToolbarButtons.addressBarLimit)
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            if !model.pool.downloads.items.isEmpty || model.isShowingDownloads {
                DownloadsButton(model: model)
                    .modifier(SidebarGlassButtonStyle())
            }
            if model.pageSummarizer != nil {
                SummaryButton(model: model)
                    .modifier(SidebarGlassButtonStyle())
            }
        }
    }
}
#endif
