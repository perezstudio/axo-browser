import SwiftUI

// Mac only; iPhone and iPad have their own chrome.
#if os(macOS)
/// The sidebar's top row with the navigation bar in the sidebar (#67): beside the window's
/// controls, back and forward in one glass capsule, reload in its own glass circle, and the
/// button that hides the sidebar. It replaces the window toolbar, so the page beside it reaches
/// the window's top edge, and dragging its empty space moves the window. In the floating sidebar
/// (`isFloating`, while the sidebar is hidden) that button keeps the sidebar shown instead.
struct SidebarTopRow: View {
    let model: BrowserModel
    /// Whether this is the floating sidebar's row.
    var isFloating = false
    /// Hides the sidebar, or, in the floating sidebar, keeps it shown.
    let toggleSidebar: () -> Void

    /// As tall as the window's title bar area, so the 36 pt buttons are centered with the
    /// window's controls, 26 pt from the top, as the toolbar's were.
    static let height: CGFloat = 52
    /// Where the window's controls (close, minimize, zoom) end, 79 pt from the left, as macOS
    /// places them in a window with a toolbar.
    static let windowControlsWidth: CGFloat = WindowControls.leading + WindowControls.size.width
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
        // Four gaps: after the window's controls, before the capsule, and between the buttons.
        return windowControlsWidth + spacing * 4 + capsule + SidebarGlassButtonStyle.side * 2 + trailingPadding
    }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: Self.spacing) {
                // The window's own controls, which hide with the title bar (#67).
                WindowControls()
                    .frame(width: WindowControls.size.width, height: WindowControls.size.height)
                    .padding(.leading, WindowControls.leading)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    BackForwardButtons(model: model)
                        .buttonStyle(CapsuleIconButtonStyle(side: Self.capsuleButtonSide))
                }
                .padding(.horizontal, Self.capsulePadding)
                .frame(height: SidebarGlassButtonStyle.side)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Back and Forward")
                ReloadButton(model: model)
                    .modifier(SidebarGlassButtonStyle())
                let title = isFloating ? "Keep Sidebar Shown" : "Hide Sidebar"
                Button(title, systemImage: "sidebar.left", action: toggleSidebar)
                    .modifier(SidebarGlassButtonStyle())
                    .help(title)
                    .accessibilityIdentifier(isFloating ? "keepSidebarShownButton" : "hideSidebarButton")
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

/// An icon-only button filling a square of `side`, so its whole square takes clicks, dimmed while
/// disabled and while pressed.
private struct CapsuleIconButtonStyle: ButtonStyle {
    let side: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, side: side)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let side: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(SidebarGlassLabelStyle())
                .frame(width: side, height: side)
                .contentShape(.rect)
                .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.35)
        }
    }
}

/// The window's close, minimize, and zoom buttons, made with AppKit's
/// `NSWindow.standardWindowButton(_:for:)` for a window whose title bar is hidden: SwiftUI hides
/// the title bar with the toolbar, controls and all (#67). AppKit makes them with no target, so
/// the view points each at the window it's in (as the real title bar's are), never the key one.
/// Their × − + glyphs show on hover only through private API, so they don't here.
struct WindowControls: NSViewRepresentable {
    /// The three buttons' span: 14 pt buttons, 23 pt apart, as macOS 27 places them.
    static let size = CGSize(width: 60, height: 14)
    /// Where the close button starts, from the window's leading edge.
    static let leading: CGFloat = 19
    /// The window style the buttons are made for.
    private static let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    /// The distance from one button's start to the next's.
    static let pitch: CGFloat = 23

    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) {}

    /// Holds the three buttons and aims them at its window.
    final class ControlsView: NSView {
        /// The buttons, close first.
        private(set) var buttons: [NSButton] = []

        init() {
            super.init(frame: CGRect(origin: .zero, size: WindowControls.size))
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = NSWindow.standardWindowButton(type, for: WindowControls.style) else { continue }
                button.setFrameOrigin(CGPoint(x: CGFloat(index) * WindowControls.pitch, y: 0))
                addSubview(button)
                buttons.append(button)
            }
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for button in buttons { button.target = window }
        }
    }
}

extension EnvironmentValues {
    /// Whether the page's tools (extensions, Downloads, the summary) are in the sidebar rather
    /// than the toolbar (#67), so only one of each is on screen and presents popovers.
    @Entry var pageToolsInSidebar = false
}

/// Reports whether the window's split view has its sidebar collapsed, from the split view's
/// own sidebar item, so every way of hiding or showing it counts.
/// Also reports whether the window is in full screen, and hands over the split view
/// controller so Hide Sidebar can collapse it as View › Toggle Sidebar does.
struct SidebarCollapseObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    var onFullScreenChange: (Bool) -> Void = { _ in }
    var onController: (NSSplitViewController?) -> Void = { _ in }

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onChange: onChange, onFullScreenChange: onFullScreenChange, onController: onController)
    }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
        view.onFullScreenChange = onFullScreenChange
        view.onController = onController
    }

    final class ObserverView: NSView {
        var onChange: (Bool) -> Void
        var onFullScreenChange: (Bool) -> Void
        var onController: (NSSplitViewController?) -> Void
        private var observation: NSKeyValueObservation?
        private var fullScreenObservers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void, onFullScreenChange: @escaping (Bool) -> Void,
             onController: @escaping (NSSplitViewController?) -> Void) {
            self.onChange = onChange
            self.onFullScreenChange = onFullScreenChange
            self.onController = onController
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
            fullScreenObservers = []
            guard let window else { return }
            onFullScreenChange(window.styleMask.contains(.fullScreen))
            for (name, isFullScreen) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
                fullScreenObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onFullScreenChange(isFullScreen) }
                })
            }
            let controller = Self.splitController(above: self)
            onController(controller)
            guard let item = controller?.splitViewItems.first(where: { $0.behavior == .sidebar }) else { return }
            observation = item.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
                let isCollapsed = item.isCollapsed
                Task { @MainActor in self?.onChange(isCollapsed) }
            }
        }

        /// The nearest split view controller above `view` with a sidebar.
        static func splitController(above view: NSView) -> NSSplitViewController? {
            var next = view.superview
            while let current = next {
                if let split = current as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                   controller.splitViewItems.contains(where: { $0.behavior == .sidebar }) {
                    return controller
                }
                next = current.superview
            }
            return nil
        }
    }
}
#endif
