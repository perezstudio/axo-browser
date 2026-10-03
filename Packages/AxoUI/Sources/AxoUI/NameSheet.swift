import SwiftUI

/// A small sheet that asks for a name, used for folders and Spaces.
struct NameSheet: View {
    let title: String
    let confirmTitle: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialName: String, confirmTitle: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .accessibilityIdentifier("nameField")
                .onSubmit(save)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmTitle, action: save)
                    .disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("nameConfirmButton")
            }
        }
        .navigationTitle(title)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
