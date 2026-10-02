import SwiftUI

/// The address field: shows the selected page's URL and loads what's typed into it.
struct AddressField: View {
    let model: BrowserModel
    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Search or enter address", text: $text, selection: $selection)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .autocorrectionDisabled()
            .accessibilityLabel("Address")
            .accessibilityIdentifier("addressField")
            .onSubmit {
                let submitted = text
                Task {
                    // Submit before giving up focus: losing focus cancels a new tab in progress.
                    await model.submitAddress(submitted)
                    isFocused = false
                }
            }
            .onExitCommand {
                model.cancelNewTab()
                isFocused = false
                text = currentAddress
            }
            .onChange(of: model.addressFocusRequest) {
                text = model.isComposingNewTab ? "" : currentAddress
                // Select the whole address so typing replaces it, like Safari.
                selection = TextSelection(range: text.startIndex..<text.endIndex)
                isFocused = true
            }
            .onChange(of: currentAddress) {
                if !isFocused { text = currentAddress }
            }
            .onChange(of: isFocused) {
                if !isFocused, model.isComposingNewTab {
                    model.cancelNewTab()
                    text = currentAddress
                }
            }
            .onAppear { text = currentAddress }
    }

    /// The selected page's URL, falling back to the saved URL of a tab that hasn't loaded yet.
    private var currentAddress: String {
        (model.selectedPage?.url ?? model.selectedTab?.url)?.absoluteString ?? ""
    }
}
