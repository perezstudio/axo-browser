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
    /// The narrowest the sidebar gets with this row.
    static let minimumSidebarWidth: CGFloat = 250
    /// Back's and Forward's buttons in their capsule.
    static let capsuleButtonSide: CGFloat = 30
    /// The capsule's padding on either side of the buttons.
    static let capsulePadding: CGFloat = 3
    /// The gap between the row's controls.
    static let spacing: CGFloat = 6
    /// The gap after the last button, before the page's edge.
    static let trailingPadding: CGFloat = 8
    /// The width the row's contents need: the window's controls, the capsule, reload, Hide
    /// Sidebar, and the gaps between them.
    static var requiredWidth: CGFloat {
        let capsule = capsuleButtonSide * 2 + capsulePadding * 2
        return windowControlsWidth + capsule + SidebarGlassButtonStyle.side * 2 + spacing * 3 + trailingPadding
    }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: Self.spacing) {
                Spacer(minLength: Self.windowControlsWidth)
                HStack(spacing: 0) {
                    BackForwardButtons(model: model)
                        .labelStyle(SidebarGlassLabelStyle())
                        .buttonStyle(.borderless)
                        .frame(width: Self.capsuleButtonSide, height: Self.capsuleButtonSide)
                }
                .padding(.horizontal, Self.capsulePadding)
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
            .padding(.trailing, Self.trailingPadding)
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

extension EnvironmentValues {
    /// Whether the page's tools (extensions, Downloads, the summary) are in the sidebar rather
    /// than the toolbar (#67), so only one of each is on screen and presents popovers.
    @Entry var pageToolsInSidebar = false
}

/// Reports whether the window's split view has its sidebar collapsed, from the split view's
/// own sidebar item, so every way of hiding or showing it counts.
struct SidebarCollapseObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(onChange: onChange) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: (Bool) -> Void
        private var observation: NSKeyValueObservation?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard window != nil, let item = Self.sidebarItem(above: self) else { return }
            observation = item.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
                let isCollapsed = item.isCollapsed
                Task { @MainActor in self?.onChange(isCollapsed) }
            }
        }

        /// The sidebar item of the nearest split view controller above `view`.
        static func sidebarItem(above view: NSView) -> NSSplitViewItem? {
            var next = view.superview
            while let current = next {
                if let split = current as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                   let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) {
                    return sidebar
                }
                next = current.superview
            }
            return nil
        }
    }
}
#endif
