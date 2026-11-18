import SwiftUI

// Mac only; iPhone and iPad have their own chrome.
#if os(macOS)
/// The sidebar while it's hidden (#67): in the sidebar layout the page fills the window with no
/// toolbar or window controls (above the page, the control bar keeps them, #170), and the pointer reaching the window's left
/// edge floats the sidebar in over the page as the board's card: the Space's theme as tinted glass
/// over the page (`FloatingThemeGlass`). Its top row has the
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

    /// The card's width, the board's 268 pt.
    static let width: CGFloat = 268
    /// How far the card sits in from the window's edges.
    static let inset: CGFloat = 8
    /// The card's corners, the window's own radius on macOS 27.
    static let cornerRadius: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            // Above the page, the control bar beside it keeps the window's controls.
            SidebarTopRow(model: model, isFloating: true, showsNavigation: showsNavigation,
                          showsWindowControls: showsNavigation, toggleSidebar: keepShown)
            SidebarView(model: model)
        }
        // The card holds the page's tools while it shows, as the sidebar does.
        .environment(\.pageToolsInSidebar, true)
        // Outside the split view's column, the list doesn't get the sidebar's style on its own,
        // and drew a plain, opaque list over the card.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .modifier(SpaceThemeModifier(model: model, isFloating: true))
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        // The board's panel: a hairline light edge and a deep, soft shadow.
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.35), radius: 25, y: 18)
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
        model.isShowingDownloads || model.isShowingSiteSettings || model.isShowingSummary || model.isShowingConnectionInfo
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
/// The page as a card on the Space's theme while the sidebar is hidden (#67): inset by
/// ``inset`` with rounded corners and a soft shadow, as the board draws it. The margin around
/// it is the window's to drag, and a double click there zooms it, as on a title bar, since
/// nothing else on screen can move the window then. The card takes the page column's whole
/// place again once the sidebar shows.
///
/// It comes in two parts around the page column's `ignoresSafeArea` (the title bar's 52 pt
/// area): ``PageCard`` (the card's shape and its top margin) goes before it, so the margin is
/// measured from the window's top, and ``PageCardMargin`` (the other margins and the theme
/// behind) after it. Padding the column after it left the card under the title bar's area, and
/// before it, 8 pt below that area.
struct PageCard: ViewModifier {
    let isCard: Bool

    /// The margin around the card.
    static let inset: CGFloat = 8
    /// The card's corners.
    static let cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .clipShape(.rect(cornerRadius: isCard ? Self.cornerRadius : 0))
            .overlay {
                if isCard {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(.black.opacity(0.2), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(isCard ? 0.25 : 0), radius: 10, y: 6)
            .padding(.top, isCard ? Self.inset : 0)
    }
}

/// The card's side and bottom margins and the Space's theme behind it, whose margin moves the
/// window; see ``PageCard``.
struct PageCardMargin: ViewModifier {
    let model: BrowserModel
    let isCard: Bool

    func body(content: Content) -> some View {
        content
            .padding([.leading, .trailing, .bottom], isCard ? PageCard.inset : 0)
            .background {
                if isCard {
                    ZStack {
                        Rectangle().fill(.background)
                        Color.clear.modifier(SpaceThemeModifier(model: model))
                        // The margin moves the window, and a double click zooms it.
                        Color.clear
                            .contentShape(.rect)
                            .gesture(WindowDragGesture())
                            .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
                            .allowsWindowActivationEvents(true)
                    }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                }
            }
    }
}

extension EnvironmentValues {
    /// Whether this is the floating sidebar's copy of the sidebar (#67).
    @Entry var isFloatingSidebar = false
}
#endif
