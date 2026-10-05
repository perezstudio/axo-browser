import SwiftUI

/// The bar above the page for finding text in it.
///
/// Searching starts as you type. Return or ⌘G finds the next match, ⇧⌘G the previous one,
/// and Esc or Done closes the bar and clears the highlight.
struct FindBar: View {
    @Bindable var model: BrowserModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Find on Page", text: $model.findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($isFocused)
                .autocorrectionDisabled()
                .accessibilityLabel("Find on page")
                .accessibilityIdentifier("findField")
                .onSubmit { Task { await model.findNext() } }
                .onChange(of: model.findText) { Task { await model.findNext() } }

            if model.findHasNoMatches {
                Text("No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("findNoMatches")
            }

            ControlGroup {
                Button("Previous Match", systemImage: "chevron.up") { Task { await model.findPrevious() } }
                    .help("Previous match")
                    .accessibilityIdentifier("findPreviousButton")
                Button("Next Match", systemImage: "chevron.down") { Task { await model.findNext() } }
                    .help("Next match")
                    .accessibilityIdentifier("findNextButton")
            }
            .disabled(model.findText.isEmpty)
            .fixedSize()

            Spacer()

            Button("Done") { model.closeFindBar() }
                .accessibilityIdentifier("findDoneButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        // Esc closes the bar from the field or any of its buttons.
        .onExitCommandIfAvailable { model.closeFindBar() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find on Page")
        .onAppear { isFocused = true }
        .onChange(of: model.findFocusRequest) { isFocused = true }
    }
}
