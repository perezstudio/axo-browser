import AxoCore
import SwiftUI

// The Mac sidebar's footer; iPhone and iPad switch Spaces from a menu.
#if os(macOS)
/// The sidebar's footer: Settings on the left, a dot for each Space in a glass capsule in the
/// middle, and New Space on the right.
struct SpaceSwitcher: View {
    @Bindable var model: BrowserModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .modifier(FooterButtonStyle())
                .help("Settings")
                .accessibilityIdentifier("settingsButton")

                Spacer(minLength: 0)
                SpaceDots(model: model)
                Spacer(minLength: 0)

                Button("New Space", systemImage: "plus") { model.isCreatingSpace = true }
                    .modifier(FooterButtonStyle())
                    .help("New Space")
                    .accessibilityIdentifier("newSpaceButton")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
        .accessibilityIdentifier("spaceSwitcher")
        .sheet(isPresented: $model.isCreatingSpace) {
            NewSpaceSheet(model: model)
        }
        .confirmationDialog(
            "Delete “\(model.spaceToDelete?.name ?? "")”?",
            isPresented: Binding(get: { model.spaceToDelete != nil }, set: { if !$0 { model.spaceToDelete = nil } }),
            presenting: model.spaceToDelete
        ) { space in
            Button("Delete Space", role: .destructive) {
                Task { await model.deleteSpace(space.id) }
            }
        } message: { _ in
            Text("Its tabs will be closed. Its profile and website data are kept.")
        }
    }
}

/// The footer's round glass buttons, styled like toolbar buttons.
private struct FooterButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
    }
}

/// A dot for each Space in a glass capsule, the current one filled. Many Spaces scroll.
private struct SpaceDots: View {
    let model: BrowserModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            dots
            ScrollView(.horizontal) { dots }
                .scrollIndicators(.never)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }

    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                SpaceDot(space: space, index: index, isSelected: space.id == model.space?.id) {
                    Task { await model.selectSpace(space.id) }
                }
                .contextMenu {
                    Button("Rename…") { model.spaceToRename = space }
                    Button("Delete Space…", role: .destructive) { model.spaceToDelete = space }
                        .disabled(model.spaces.count < 2)
                }
            }
        }
    }
}

/// One Space in the switcher: a dot, larger and filled when it's the current Space.
private struct SpaceDot: View {
    let space: Space
    let index: Int
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: isSelected ? 8 : 6, height: isSelected ? 8 : 6)
                // Not only color: a ring marks the current Space when the person asks for it.
                .overlay {
                    if isSelected && differentiateWithoutColor {
                        Circle().strokeBorder(.primary, lineWidth: 1.5).padding(-3)
                    }
                }
                .frame(width: 18, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
        .accessibilityLabel(space.name)
        .accessibilityHint(index < 9 ? "Control-\(index + 1)" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("spaceButton")
    }
}
#endif

/// Names a new Space and chooses whether it gets its own profile.
struct NewSpaceSheet: View {
    let model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var usesNewProfile = false
    @State private var profileName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            // Sheets don't show their navigation title, so the sheet names itself.
            Text("New Space")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextField("Name", text: $name, prompt: Text("Work"))
                .focused($isNameFocused)
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
        .defaultFocus($isNameFocused, true)
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

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
