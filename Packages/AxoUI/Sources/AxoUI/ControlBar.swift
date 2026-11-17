import AxoWeb
import SwiftUI

// Mac only; iPhone and iPad have their own chrome.
#if os(macOS)
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
    /// Shows the sidebar again.
    let showSidebar: () -> Void
    @AppStorage(ToolbarTintSettings.storageKey) private var tintsFromPage = true
    @Environment(\.colorScheme) private var colorScheme

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
                BackForwardCapsule(model: model)
                ReloadButton(model: model)
                    .modifier(SidebarGlassButtonStyle())
                AddressBar(model: model)
                    .frame(minWidth: 200, maxWidth: Self.addressMaxWidth)
                    .frame(height: SidebarGlassButtonStyle.side)
                    .glassEffect(.regular, in: .capsule)
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
                // The bar's empty space moves the window.
                Color.clear
                    .contentShape(.rect)
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents(true)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Controls")
        .accessibilityIdentifier("controlBar")
    }

    /// The gap at the bar's ends.
    static let horizontalPadding: CGFloat = 12

    /// The page's color with the tint on (Settings › General), or the window's background.
    private var background: Color {
        let tint = ToolbarTint.tint(for: model.selectedPage?.pageColors, isDark: colorScheme == .dark,
                                    isEnabled: tintsFromPage, placement: .page)
        return tint.map { Color(pageColor: $0.color) } ?? Color(nsColor: .windowBackgroundColor)
    }

    /// Extensions, Downloads (once there's a download), and Summarize Page.
    @ViewBuilder
    private var pageTools: some View {
        HStack(spacing: 2) {
            ExtensionToolbarButtons(model: model)
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
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
