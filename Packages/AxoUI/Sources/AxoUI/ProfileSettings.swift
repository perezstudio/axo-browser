import AxoCore
import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The Profiles pane in Settings: every profile, with + and − to add and delete them, and the
/// selected profile's name, Spaces, extensions, and website data.
struct ProfileSettings: View {
    let model: BrowserModel
    @State private var selection: Profile.ID?
    @State private var isAdding = false
    @State private var profileToDelete: Profile?

    private var selected: Profile? {
        model.allProfiles.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(model.allProfiles, selection: $selection) { profile in
                    Text(profile.name)
                        .tag(profile.id)
                }
                .accessibilityLabel("Profiles")
                .accessibilityIdentifier("profileList")
                Divider()
                HStack(spacing: 0) {
                    Button("Add Profile", systemImage: "plus") { isAdding = true }
                        .accessibilityIdentifier("addProfileButton")
                    Button("Delete Profile", systemImage: "minus") { profileToDelete = selected }
                        .disabled(selected == nil || model.allProfiles.count < 2)
                        .accessibilityIdentifier("deleteProfileButton")
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 180)
            Divider()
            if let profile = selected {
                ProfileDetail(model: model, profile: profile)
                    .id(profile.id)
            } else {
                ContentUnavailableView("No Profile Selected", systemImage: "person.crop.circle", description: Text("Choose a profile to see its settings."))
            }
        }
        .onAppear { if selection == nil { selection = model.space?.profileID } }
        .sheet(isPresented: $isAdding) {
            NameSheet(title: "New Profile", initialName: "", confirmTitle: "Create") { name in
                Task {
                    if let profile = await model.addProfile(named: name) { selection = profile.id }
                }
            }
        }
        .sheet(item: $profileToDelete) { profile in
            DeleteProfileSheet(model: model, profile: profile) {
                selection = model.space?.profileID
            }
        }
    }
}

/// One profile's settings.
private struct ProfileDetail: View {
    let model: BrowserModel
    let profile: Profile
    @State private var name: String
    @State private var extensionCount: Int?
    @State private var isConfirmingClear = false

    init(model: BrowserModel, profile: Profile) {
        self.model = model
        self.profile = profile
        _name = State(initialValue: profile.name)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .accessibilityIdentifier("profileNameField")
                .onSubmit(rename)
                .onDisappear(perform: rename)
            Section("Spaces") {
                let spaces = model.spaces(using: profile.id)
                if spaces.isEmpty {
                    Text("No Spaces use this profile.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(spaces) { space in
                        Text(space.name)
                    }
                }
            }
            if let extensionCount {
                Section("Extensions") {
                    Text(extensionCount == 1 ? "1 extension installed" : "\(extensionCount) extensions installed")
                }
            }
            Section("Website Data") {
                Text("Cookies, logins, and site data for this profile's Spaces. Other profiles keep their own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Clear Website Data…") { isConfirmingClear = true }
                    .accessibilityIdentifier("clearWebsiteDataButton")
            }
        }
        .formStyle(.grouped)
        .task {
            extensionCount = await model.extensionManagement?.installedExtensions(profileID: profile.id).count
        }
        .confirmationDialog("Clear website data for “\(profile.name)”?", isPresented: $isConfirmingClear) {
            Button("Clear Website Data", role: .destructive) {
                Task { await model.clearWebsiteData(for: profile.id) }
            }
        } message: {
            Text("You'll be signed out of sites in this profile's Spaces.")
        }
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        Task { await model.renameProfile(profile.id, to: trimmed) }
    }
}

/// Confirms deleting a profile and, if Spaces use it, which profile they move to.
private struct DeleteProfileSheet: View {
    let model: BrowserModel
    let profile: Profile
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var replacement: Profile.ID?

    private var others: [Profile] {
        model.allProfiles.filter { $0.id != profile.id }
    }

    var body: some View {
        let spaces = model.spaces(using: profile.id)
        Form {
            Text("Delete “\(profile.name)”?")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Its cookies, logins, and website data are deleted. This can't be undone.")
                .foregroundStyle(.secondary)
            if !spaces.isEmpty {
                Picker(spaces.count == 1 ? "Move “\(spaces[0].name)” to" : "Move its \(spaces.count) Spaces to", selection: $replacement) {
                    ForEach(others) { other in
                        Text(other.name).tag(Profile.ID?.some(other.id))
                    }
                }
                .accessibilityIdentifier("replacementProfilePicker")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { replacement = others.first?.id }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete Profile", role: .destructive) {
                    let replacement = spaces.isEmpty ? nil : replacement
                    dismiss()
                    onDelete()
                    Task { await model.deleteProfile(profile.id, movingSpacesTo: replacement) }
                }
                .disabled(!spaces.isEmpty && replacement == nil)
                .accessibilityIdentifier("confirmDeleteProfileButton")
            }
        }
    }
}
#endif
