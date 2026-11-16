import SwiftUI

// Mac only; iPhone and iPad have their own chrome.
#if os(macOS)
/// The sidebar's top row with the navigation bar in the sidebar (#67): beside the window's
/// controls, back and forward in one glass capsule, reload in its own glass circle, and the
/// button that hides the sidebar. It replaces the window toolbar, so the page beside it reaches
/// the window's top edge, and dragging its empty space moves the window.
struct SidebarTopRow: View {
    let model: BrowserModel
    let hideSidebar: () -> Void

    /// As tall as the window's title bar area, so the 36 pt buttons are centered with the
    /// window's controls, 26 pt from the top, as the toolbar's were.
    static let height: CGFloat = 52
    /// Room for the window's controls (close, minimize, zoom), which end 79 pt from the left.
    static let windowControlsWidth: CGFloat = 86
    /// The narrowest the sidebar gets with this row: the window's controls, the back and forward
    /// capsule, reload, the sidebar button, and the gaps between them.
    static let minimumSidebarWidth: CGFloat = 250

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 6) {
                Spacer(minLength: Self.windowControlsWidth)
                HStack(spacing: 0) {
                    BackForwardButtons(model: model)
                        .labelStyle(SidebarGlassLabelStyle())
                        .buttonStyle(.borderless)
                        .frame(width: 30, height: 30)
                }
                .padding(.horizontal, 3)
                .frame(height: SidebarGlassButtonStyle.side)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Back and Forward")
                ReloadButton(model: model)
                    .modifier(SidebarGlassButtonStyle())
                Button("Hide Sidebar", systemImage: "sidebar.left", action: hideSidebar)
                    .modifier(SidebarGlassButtonStyle())
                    .help("Hide Sidebar")
                    .accessibilityIdentifier("hideSidebarButton")
            }
            .padding(.trailing, 8)
        }
        .frame(height: Self.height)
        // The row's empty space moves the window, as the title bar it replaces did.
        .background {
            Color.clear
                .contentShape(.rect)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebarTopRow")
    }
}
#endif
