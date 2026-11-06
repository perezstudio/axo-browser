import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The General pane in Settings: where the navigation bar goes, and whether the sidebar's address
/// bar shows the full address.
struct GeneralSettings: View {
    @AppStorage(NavigationBarPlacement.storageKey) private var navigationBarPlacement = NavigationBarPlacement.sidebar
    @AppStorage(AddressBarSettings.showsFullAddressKey) private var showsFullAddress = false
    @AppStorage(AddressEditingPlacement.storageKey) private var addressEditingPlacement = AddressEditingPlacement.commandBar

    var body: some View {
        Form {
            Picker("Navigation bar", selection: $navigationBarPlacement) {
                ForEach(NavigationBarPlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("navigationBarPlacementPicker")
            Text("Back, forward, reload, and the address go at the top of the sidebar or above the page. In the sidebar, the address shows the site, and clicking it (or ⌘L) edits it in the command bar or in the sidebar, as chosen below. Above the page, it's a field you edit in place, as in Safari.")
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
