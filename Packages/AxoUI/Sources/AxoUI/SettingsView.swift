// Mac only for now; iPhone and iPad have their own chrome (#185).
#if os(macOS)
import SwiftUI

/// Axo's Settings window (⌘,), laid out like System Settings: a sidebar of panes with a search
/// field at its top, and the selected pane beside it (#85). The window resizes down to
/// ``minimumSize``, the sidebar can't be hidden, and it reopens on the last pane used.
public struct SettingsView: View {
    let model: BrowserModel

    /// The key under which the window remembers its last pane, in the window's settings store
    /// (UI tests have their own).
    public static let paneStorageKey = "settingsPane"
    /// The smallest the window gets: room for the sidebar and a pane's form.
    public static let minimumSize = CGSize(width: 720, height: 480)
    /// The size the window opens at the first time.
    public static let defaultSize = CGSize(width: 780, height: 560)

    @AppStorage(SettingsView.paneStorageKey) private var selection: SettingsPane = .general
    @State private var query = ""
    /// The split view's columns. View › Toggle Sidebar still reaches the split view with its
    /// toolbar button removed (a constant binding doesn't stop it), so a change is undone.
    @State private var columns = NavigationSplitViewVisibility.all
    @FocusState private var isSearchFocused: Bool

    /// Creates the Settings window's content.
    public init(model: BrowserModel) {
        self.model = model
    }

    /// The panes this Mac offers: iCloud only when sync is available.
    private var panes: [SettingsPane] {
        SettingsPane.allCases.filter { $0 != .iCloud || model.iCloudSync != nil }
    }

    /// The pane showing: the remembered one, unless it isn't offered (iCloud without sync).
    private var shownPane: SettingsPane {
        panes.contains(selection) ? selection : .general
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            pane(shownPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(shownPane.title)
        }
        .onChange(of: columns) {
            if columns != .all { columns = .all }
        }
        .frame(minWidth: Self.minimumSize.width, idealWidth: Self.defaultSize.width,
               minHeight: Self.minimumSize.height, idealHeight: Self.defaultSize.height)
        // The Settings scene opened taller than the screen on the hosted Mac (2168 pt) despite
        // its default size, so the window is fitted to its screen once it's shown.
        .background(WindowScreenFit(size: Self.defaultSize))
        // ⌘F searches the panes, as in System Settings. Browser windows' Find… is disabled here.
        .background {
            Button("Search Settings") { isSearchFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private var sidebar: some View {
        let matches = SettingsPane.filtered(panes, by: query)
        return List(selection: Binding(
            get: { shownPane },
            set: { pane in if let pane { selection = pane } }
        )) {
            ForEach(matches) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(pane)
                    .accessibilityIdentifier(pane.rowIdentifier)
            }
        }
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .accessibilityIdentifier("settingsPaneList")
        // A closed window starts its next opening with every pane listed.
        .onDisappear { query = "" }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .searchFocused($isSearchFocused)
        // The first match shows as soon as the pane showing no longer matches, and Return
        // goes to the first match, as in System Settings.
        .onChange(of: query) {
            if let first = matches.first, !matches.contains(shownPane) { selection = first }
        }
        .onSubmit(of: .search) {
            if let first = matches.first { selection = first }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        // The sidebar holds the only way between panes, so it can't be hidden.
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettings(softwareUpdate: model.softwareUpdate)
        case .profiles: ProfileSettings(model: model)
        case .spaces: SpaceSettings(model: model)
        case .search: SearchSettings(model: model)
        case .linkRouting: LinkRoutingSettings(model: model)
        case .siteCustomizations: SiteCustomizationSettings(model: model)
        case .iCloud:
            if let sync = model.iCloudSync {
                SyncSettings(sync: sync)
            }
        }
    }
}

/// Fits its window on its screen once the window is shown: a window larger than the screen's
/// visible area is resized to `size` (or the visible area, if smaller) and centered there.
/// It also makes the window resizable, which the Settings scene's window isn't on its own.
struct WindowScreenFit: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { FittingView(size: size) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// The frame `window` should take to fit `visible`, or `nil` when it already fits.
    nonisolated static func fittedFrame(for window: CGRect, contentFrame: (CGSize) -> CGRect, size: CGSize, in visible: CGRect) -> CGRect? {
        guard window.height > visible.height || window.width > visible.width
                || !visible.contains(window) else { return nil }
        var frame = window
        if window.height > visible.height || window.width > visible.width {
            frame.size = contentFrame(size).size
        }
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if window.height > visible.height || window.width > visible.width {
            frame.origin = CGPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        }
        return frame
    }

    final class FittingView: NSView {
        let size: CGSize
        init(size: CGSize) {
            self.size = size
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After SwiftUI's own sizing for this showing.
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }

        private func fit() {
            // SwiftUI's Settings scene makes its window fixed-size, even with
            // `.windowResizability(.contentMinSize)`; the content's minimum still applies.
            window?.styleMask.insert(.resizable)
            guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
                  let frame = WindowScreenFit.fittedFrame(for: window.frame, contentFrame: { size in
                      window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
                  }, size: size, in: visible) else { return }
            window.setFrame(frame, display: true)
        }
    }
}
#endif
