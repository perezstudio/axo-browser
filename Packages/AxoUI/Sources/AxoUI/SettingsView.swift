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

    @AppStorage(SettingsView.paneStorageKey) private var selection: SettingsPane = .general
    @State private var query = ""
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
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
        } detail: {
            pane(shownPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(shownPane.title)
        }
        .frame(minWidth: Self.minimumSize.width, idealWidth: 780,
               minHeight: Self.minimumSize.height, idealHeight: 560)
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
        // Return goes to the first match, as in System Settings.
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
        case .general: GeneralSettings()
        case .profiles: ProfileSettings(model: model)
        case .spaces: SpaceSettings(model: model)
        case .linkRouting: LinkRoutingSettings(model: model)
        case .siteCustomizations: SiteCustomizationSettings(model: model)
        case .iCloud:
            if let sync = model.iCloudSync {
                SyncSettings(sync: sync)
            }
        }
    }
}
#endif
