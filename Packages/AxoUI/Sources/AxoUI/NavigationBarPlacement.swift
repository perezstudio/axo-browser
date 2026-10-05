/// Where the Mac window's navigation bar (back, forward, reload, and the address field) goes,
/// chosen in Settings › General.
public enum NavigationBarPlacement: String, CaseIterable, Identifiable, Sendable {
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
