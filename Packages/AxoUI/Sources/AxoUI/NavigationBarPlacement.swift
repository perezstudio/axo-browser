/// Where the Mac window's navigation bar (back, forward, reload, and the address field) goes,
/// chosen in Settings › General.
nonisolated public enum NavigationBarPlacement: String, CaseIterable, Identifiable, Sendable {
    /// At the top of the sidebar: the buttons beside the sidebar toggle, the address field
    /// below them.
    case sidebar
    /// Above the page: the buttons and the address field in the page's toolbar.
    case page

    /// The `@AppStorage` key. The app picks the store with `defaultAppStorage`, so UI tests
    /// never change the person's own setting.
    public static let storageKey = "navigationBarPlacement"

    public var id: Self { self }

    /// The name shown in Settings.
    public var title: String {
        switch self {
        case .sidebar: "In the sidebar"
        case .page: "Above the page"
        }
    }
}

/// Where the Mac window's tabs go, chosen in Settings › General (#136): in the sidebar, or in a
/// tab bar across the top of the window, which puts the navigation bar above the page.
nonisolated public enum TabsPlacement: String, CaseIterable, Identifiable, Sendable {
    /// In the sidebar, with Spaces, favorites, pinned tabs, and folders.
    case sidebar
    /// In a tab bar across the top of the window, with the page's control bar under it.
    case top

    /// The `@AppStorage` key, in the store the app picks (UI tests have their own).
    public static let storageKey = "tabsPlacement"

    public var id: Self { self }

    /// The name shown in Settings.
    public var title: String {
        switch self {
        case .sidebar: "In the sidebar"
        case .top: "At the top"
        }
    }

    /// Where the navigation bar goes: tabs at the top put it above the page, whatever the
    /// navigation bar setting says, since there's no sidebar to hold it.
    public func navigationBarPlacement(chosen: NavigationBarPlacement) -> NavigationBarPlacement {
        self == .top ? .page : chosen
    }
}

/// Where the address is edited when the navigation bar is in the sidebar (Settings › General):
/// in the command bar over the page, as in Arc, or right in the sidebar's address bar, with
/// suggestions below it, as in Dia.
nonisolated public enum AddressEditingPlacement: String, CaseIterable, Identifiable, Sendable {
    /// The command bar opens over the page with the address selected.
    case commandBar
    /// The sidebar's address bar becomes a field, with suggestions dropping down below it.
    case sidebar

    /// The `@AppStorage` key, in the store the app picks (UI tests have their own).
    public static let storageKey = "addressEditingPlacement"

    public var id: Self { self }

    /// The name shown in Settings.
    public var title: String {
        switch self {
        case .commandBar: "Command bar"
        case .sidebar: "Sidebar"
        }
    }
}
