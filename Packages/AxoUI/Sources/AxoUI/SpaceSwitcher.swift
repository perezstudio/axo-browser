import AxoCore
import SwiftUI

/// The row of Spaces at the bottom of the sidebar, with a button to add one.
struct SpaceSwitcher: View {
    let model: BrowserModel
    @State private var isCreatingSpace = false
    @State private var renaming: Space?
    @State private var deleting: Space?

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                        SpaceButton(space: space, index: index, isSelected: space.id == model.space?.id) {
                            Task { await model.selectSpace(space.id) }
                        }
                        .contextMenu {
                            Button("Rename…") { renaming = space }
                            Button("Delete Space…", role: .destructive) { deleting = space }
                                .disabled(model.spaces.count < 2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)

            Button("New Space", systemImage: "plus") { isCreatingSpace = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("New Space")
                .accessibilityIdentifier("newSpaceButton")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
        .accessibilityIdentifier("spaceSwitcher")
        .sheet(isPresented: $isCreatingSpace) {
            NewSpaceSheet(model: model)
        }
        .sheet(item: $renaming) { space in
            RenameSpaceSheet(model: model, space: space)
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { space in
            Button("Delete Space", role: .destructive) {
                Task { await model.deleteSpace(space.id) }
            }
        } message: { _ in
            Text("Its tabs will be closed. Its profile and website data are kept.")
        }
    }
}

/// One Space in the switcher: the first letter of its name in a circle, filled when selected.
private struct SpaceButton: View {
    let space: Space
    let index: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(space.name.first.map { String($0).uppercased() } ?? "•")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background(Circle().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
        }
        .buttonStyle(.plain)
        .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
        .accessibilityLabel(space.name)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("spaceButton")
    }
}

/// Names a new Space and chooses whether it gets its own profile.
struct NewSpaceSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var usesNewProfile = false
    @State private var profileName = ""

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("Work"))
                .accessibilityIdentifier("spaceNameField")
            Toggle("Use a separate profile", isOn: $usesNewProfile)
                .accessibilityIdentifier("separateProfileToggle")
            if usesNewProfile {
                TextField("Profile name", text: $profileName, prompt: Text(trimmedName.isEmpty ? "Work" : trimmedName))
            }
            Text(usesNewProfile
                ? "A separate profile has its own cookies, logins, and website data."
                : "This Space shares cookies, logins, and website data with “\(model.space?.name ?? "the current Space")”.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    let profile = usesNewProfile ? (profileName.trimmed.isEmpty ? trimmedName : profileName.trimmed) : nil
                    let spaceName = trimmedName
                    dismiss()
                    Task { await model.createSpace(name: spaceName, newProfileName: profile) }
                }
                .disabled(trimmedName.isEmpty)
                .accessibilityIdentifier("createSpaceButton")
            }
        }
        .navigationTitle("New Space")
    }

    private var trimmedName: String { name.trimmed }
}

/// Renames a Space.
struct RenameSpaceSheet: View {
    let model: BrowserModel
    let space: Space
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(model: BrowserModel, space: Space) {
        self.model = model
        self.space = space
        _name = State(initialValue: space.name)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Rename") {
                    let newName = name.trimmed
                    dismiss()
                    Task { await model.renameSpace(space.id, to: newName) }
                }
                .disabled(name.trimmed.isEmpty)
            }
        }
        .navigationTitle("Rename Space")
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
