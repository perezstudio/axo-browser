import SwiftUI

// Mac only; iPhone and iPad have their own chrome.
#if os(macOS)
/// The sidebar while it's hidden, with the navigation bar in the sidebar (#67): the page fills
/// the window with no toolbar or window controls, and the pointer reaching the window's left
/// edge floats the sidebar in over the page as a card in the Space's theme. Its top row has the
/// window's controls and Keep Sidebar Shown; the pointer leaving it lets it go, unless one of
/// its popovers or sheets is open. ⌃⌘S (View › Show Sidebar) shows the sidebar from the
/// keyboard, and with VoiceOver.
struct FloatingSidebar: View {
    let model: BrowserModel
    /// Whether its top row holds back, forward, and reload (not above the page, where the
    /// control bar has them).
    var showsNavigation = true
    /// Shows the sidebar in the window again.
    let keepShown: () -> Void
    /// Reports the pointer entering and leaving the card.
    let onHover: (Bool) -> Void

    /// The card's width: as wide as the narrowest sidebar with its top row.
    static let width: CGFloat = SidebarTopRow.minimumSidebarWidth + 18
    /// How far the card sits in from the window's edges.
    static let inset: CGFloat = 8
    /// The card's corners, the window's own radius on macOS 27.
    static let cornerRadius: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            SidebarTopRow(model: model, isFloating: true, showsNavigation: showsNavigation, toggleSidebar: keepShown)
            SidebarView(model: model)
        }
        // The card holds the page's tools while it shows, as the sidebar does.
        .environment(\.pageToolsInSidebar, true)
        .modifier(SpaceThemeModifier(model: model))
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(.separator, lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floatingSidebar")
        // The card's sidebar adds no toolbar items: the window has no toolbar while it shows.
        .environment(\.isFloatingSidebar, true)
        // The inset around the card counts as the card, so the pointer moving between the card
        // and the window's edge never lets it go.
        .padding(Self.inset)
        .contentShape(.rect)
        .onHover(perform: onHover)
    }

    /// Whether something the sidebar shows is open, so the card stays while it is (and comes in
    /// for it, when it opened from a menu): its popovers and sheets, or editing the address in it.
    static func isHolding(_ model: BrowserModel) -> Bool {
        model.isShowingDownloads || model.isShowingSiteSettings || model.isShowingSummary
            || model.isCreatingSpace || model.themeEditing != nil || model.spaceToRename != nil
            || model.namingRequest != nil || model.isShowingArchive || model.pendingExtensionInstall != nil
            || model.isShowingExtensions || model.importSession != nil || model.customizationDraft != nil
            || (model.isCommandBarVisible && model.isAddressEditedInSidebar)
    }

    /// Whether `window` shows something the card may have opened that the model doesn't know of:
    /// a sheet, or a child window such as an extension's popup (popovers are child windows).
    static func isHolding(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.attachedSheet != nil || !(window.childWindows ?? []).isEmpty
    }
}

/// Reports the pointer entering and leaving its area through a tracking area, without taking
/// any clicks or mouse moves: its hit test finds nothing, so the page beneath gets them (Chromium
/// ignores mouse moves over a page whose window's hit test lands on another view).
struct EdgeHoverDetector: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> DetectorView { DetectorView(onHover: onHover) }
    func updateNSView(_ view: DetectorView, context: Context) { view.onHover = onHover }

    final class DetectorView: NSView {
        var onHover: (Bool) -> Void

        init(onHover: @escaping (Bool) -> Void) {
            self.onHover = onHover
            super.init(frame: .zero)
            // While Axo is the active app, key window or not.
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}
/// A slim bar along the page's top edge that moves the window while the sidebar is hidden (#67),
/// when nothing else on screen can: it shows once the pointer reaches the top edge and goes when
/// the pointer leaves, as the floating sidebar does. Dragging it moves the window and a double
/// click zooms it, as the title bar would. It takes the pointer only while it shows.
struct WindowDragBar: View {
    /// Reports the pointer entering and leaving the bar.
    let onHover: (Bool) -> Void

    /// The bar's height, its grabber included.
    static let height: CGFloat = 14

    var body: some View {
        Capsule()
            .fill(.secondary)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(.bar)
            .contentShape(.rect)
            .gesture(WindowDragGesture())
            .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
            .allowsWindowActivationEvents(true)
            .onHover(perform: onHover)
            .help("Drag to move the window")
            // The window moves with the pointer; VoiceOver users move it with its own commands.
            .accessibilityElement()
            .accessibilityLabel("Window")
            .accessibilityHint("Drag to move the window")
            .accessibilityIdentifier("windowDragBar")
    }
}

extension EnvironmentValues {
    /// Whether this is the floating sidebar's copy of the sidebar (#67).
    @Entry var isFloatingSidebar = false
}
#endif
