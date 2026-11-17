import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The General pane in Settings: where the navigation bar goes, whether the toolbar above the page
/// takes the page's color, and how the sidebar's address bar shows and edits the address.
struct GeneralSettings: View {
    @AppStorage(NavigationBarPlacement.storageKey) private var chosenNavigationBarPlacement = NavigationBarPlacement.sidebar
    @AppStorage(TabsPlacement.storageKey) private var tabsPlacement = TabsPlacement.sidebar
    @AppStorage(AddressBarSettings.showsFullAddressKey) private var showsFullAddress = false
    @AppStorage(AddressEditingPlacement.storageKey) private var addressEditingPlacement = AddressEditingPlacement.commandBar
    @AppStorage(ToolbarTintSettings.storageKey) private var tintsToolbar = true

    /// The navigation bar's place, above the page while tabs are at the top.
    private var navigationBarPlacement: NavigationBarPlacement {
        tabsPlacement.navigationBarPlacement(chosen: chosenNavigationBarPlacement)
    }

    var body: some View {
        Form {
            Picker("Show tabs", selection: $tabsPlacement) {
                ForEach(TabsPlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("tabsPlacementPicker")
            Text("In the sidebar, with your Spaces, favorites, and pinned tabs, or in a tab bar across the top of the window. With tabs at the top, the navigation bar is above the page.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Navigation bar", selection: Binding(
                get: { navigationBarPlacement },
                set: { chosenNavigationBarPlacement = $0 }
            )) {
                ForEach(NavigationBarPlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .pickerStyle(.radioGroup)
            // Tabs at the top hold it above the page.
            .disabled(tabsPlacement == .top)
            .accessibilityIdentifier("navigationBarPlacementPicker")
            Text("Back, forward, reload, and the address go at the top of the sidebar or above the page. In the sidebar, the address shows the site, and clicking it (or ⌘L) edits it in the command bar or in the sidebar, as chosen below. Above the page, it's a field you edit in place, as in Safari.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Tint the toolbar to match the page", isOn: $tintsToolbar)
                .toggleStyle(.checkbox)
                .disabled(navigationBarPlacement != .page)
                .accessibilityIdentifier("tintsToolbarToggle")
            Text("Above the page, the toolbar takes the color the website asks for, or the color at its top.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Show full website address", isOn: $showsFullAddress)
                // A checkbox, as in Safari's settings (a grouped form would make it a switch).
                .toggleStyle(.checkbox)
                .disabled(navigationBarPlacement != .sidebar)
                .accessibilityIdentifier("showsFullAddressToggle")
            Picker("Edit the address in", selection: $addressEditingPlacement) {
                ForEach(AddressEditingPlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(navigationBarPlacement != .sidebar)
            .accessibilityIdentifier("addressEditingPlacementPicker")
            Text("Clicking the address bar or pressing ⌘L opens the command bar over the page, or edits the address right in the sidebar, with suggestions below it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
#endif
