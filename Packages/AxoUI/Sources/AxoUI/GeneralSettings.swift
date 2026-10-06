import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The General pane in Settings: where the navigation bar goes.
struct GeneralSettings: View {
    @AppStorage(NavigationBarPlacement.storageKey) private var navigationBarPlacement = NavigationBarPlacement.sidebar

    var body: some View {
        Form {
            Picker("Navigation bar", selection: $navigationBarPlacement) {
                ForEach(NavigationBarPlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("navigationBarPlacementPicker")
            Text("Back, forward, reload, and the address field go at the top of the sidebar or above the page.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
#endif
