import AxoCore
import SwiftUI

// Mac only for now; iPhone and iPad have their own chrome.
#if os(macOS)
/// The Spaces pane in Settings: every Space in order (drag to reorder), with + and − to add and
/// delete them, and the selected Space's name, profile, color, and icon.
struct SpaceSettings: View {
    let model: BrowserModel
    @State private var selection: Space.ID?
    @State private var isAdding = false
    @State private var spaceToDelete: Space?

    private var selected: Space? {
        model.spaces.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.spaces) { space in
                        SpaceLabel(space: space)
                            .tag(space.id)
                    }
                    .onMove { source, destination in
                        move(from: source, to: destination)
                    }
                }
                .accessibilityLabel("Spaces")
                .accessibilityIdentifier("spaceList")
                Divider()
                HStack(spacing: 0) {
                    Button("Add Space", systemImage: "plus") { isAdding = true }
                        .accessibilityIdentifier("addSpaceButton")
                    Button("Delete Space", systemImage: "minus") { spaceToDelete = selected }
                        .disabled(selected == nil || model.spaces.count < 2)
                        .accessibilityIdentifier("deleteSpaceButton")
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 180)
            Divider()
            if let space = selected {
                SpaceDetail(model: model, space: space)
                    .id(space.id)
            } else {
                ContentUnavailableView("No Space Selected", systemImage: "square.stack", description: Text("Choose a Space to see its settings."))
            }
        }
        .onAppear { if selection == nil { selection = model.space?.id } }
        // A Space added here becomes the window's Space; show its settings.
        .onChange(of: model.space?.id) { selection = model.space?.id }
        .sheet(isPresented: $isAdding) {
            NewSpaceSheet(model: model)
        }
        .confirmationDialog(
            "Delete “\(spaceToDelete?.name ?? "")”?",
            isPresented: Binding(get: { spaceToDelete != nil }, set: { if !$0 { spaceToDelete = nil } }),
            presenting: spaceToDelete
        ) { space in
            Button("Delete Space", role: .destructive) {
                selection = model.spaces.first { $0.id != space.id }?.id
                Task { await model.deleteSpace(space.id) }
            }
        } message: { _ in
            Text("Its tabs will be closed. Its profile and website data are kept.")
        }
    }

    /// Moves one Space after a drag in the list.
    private func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first else { return }
        var order = model.spaces
        let moved = order.remove(at: from)
        let index = from < destination ? destination - 1 : destination
        let anchor = index > 0 ? order[index - 1].id : nil
        Task { await model.moveSpace(moved.id, after: anchor) }
    }
}

/// A Space's icon (or a dot in its color) and name.
private struct SpaceLabel: View {
    let space: Space

    var body: some View {
        Label {
            Text(space.name)
        } icon: {
            if let icon = space.icon {
                Image(systemName: icon)
                    .foregroundStyle(space.spaceColor?.color ?? .accentColor)
            } else {
                Circle()
                    .fill(space.spaceColor?.color ?? .accentColor)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// One Space's settings.
private struct SpaceDetail: View {
    let model: BrowserModel
    let space: Space
    @State private var name: String

    init(model: BrowserModel, space: Space) {
        self.model = model
        self.space = space
        _name = State(initialValue: space.name)
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .accessibilityIdentifier("spaceNameSettingsField")
                .onSubmit(rename)
                .onDisappear(perform: rename)
            if model.allProfiles.count > 1 {
                Picker("Profile", selection: Binding(
                    get: { space.profileID },
                    set: { profileID in Task { await model.moveSpace(space.id, toProfile: profileID) } }
                )) {
                    ForEach(model.allProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .accessibilityIdentifier("spaceProfilePicker")
            } else {
                // With one profile there's nothing to choose.
                LabeledContent("Profile", value: model.allProfiles.first?.name ?? "")
                    .accessibilityIdentifier("spaceProfilePicker")
            }
            Section {
                ColorSwatches(selection: space.spaceColor) { color in
                    Task { await model.setSpaceAppearance(space.id, color: color, icon: space.icon) }
                }
            } header: {
                Text("Color")
            }
            Section {
                IconGrid(selection: space.icon, tint: space.spaceColor?.color ?? .accentColor) { icon in
                    Task { await model.setSpaceAppearance(space.id, color: space.spaceColor, icon: icon) }
                }
            } header: {
                Text("Icon")
            }
            Text("Moving a Space to another profile reloads its pages with that profile's cookies and logins.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func rename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        Task { await model.renameSpace(space.id, to: trimmed) }
    }
}

/// The palette, plus None, as round swatches. The chosen one has a ring.
private struct ColorSwatches: View {
    let selection: SpaceColor?
    let choose: (SpaceColor?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            swatch(nil, title: "None", fill: AnyShapeStyle(.quaternary))
            ForEach(SpaceColor.allCases) { color in
                swatch(color, title: color.title, fill: AnyShapeStyle(color.color))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color")
        .accessibilityIdentifier("spaceColorSwatches")
    }

    private func swatch(_ color: SpaceColor?, title: String, fill: AnyShapeStyle) -> some View {
        let isSelected = color == selection
        return Button { choose(color) } label: {
            Circle()
                .fill(fill)
                .frame(width: 18, height: 18)
                .overlay {
                    if isSelected { Circle().strokeBorder(.primary, lineWidth: 2).padding(-3) }
                }
                .padding(3)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The icons, plus None, in a grid. The chosen one is highlighted.
private struct IconGrid: View {
    let selection: String?
    let tint: Color
    let choose: (String?) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
            cell(nil, title: "None") { Image(systemName: "nosign") }
            ForEach(SpaceIcon.all, id: \.symbol) { icon in
                cell(icon.symbol, title: icon.title) { Image(systemName: icon.symbol) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Icon")
        .accessibilityIdentifier("spaceIconGrid")
    }

    private func cell(_ symbol: String?, title: String, @ViewBuilder image: () -> Image) -> some View {
        let isSelected = symbol == selection
        return Button { choose(symbol) } label: {
            image()
                .frame(width: 28, height: 28)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.5))))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
