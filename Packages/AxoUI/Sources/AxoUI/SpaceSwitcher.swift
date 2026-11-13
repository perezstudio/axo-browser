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
        // The toolbar's buttons are centered 26 pt from the window's top on macOS 27 (their
        // 36 pt glass in a 52 pt slot); 8 pt here centers the footer's 26 pt from the bottom
        // and leading edges. `testSidebarFooterMatchesTheToolbar` checks the centers.
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
        .accessibilityIdentifier("spaceSwitcher")
        .sheet(isPresented: $model.isCreatingSpace) {
            NewSpaceSheet(model: model).windowAppearance()
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

/// The footer's round glass buttons, sized like the window toolbar's (#135): an extra large
/// glass circle around a 15 pt icon is 36 pt, the toolbar's glass on macOS 27 (measured from
/// window screenshots; accessibility reports only the toolbar item's 52 pt slot).
/// `testSidebarFooterMatchesTheToolbar` checks the footer is 36 pt and the slot still 52 pt.
/// It can't see the toolbar's glass itself, so check the screenshots it attaches when macOS
/// changes the toolbar.
private struct FooterButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(FooterIconLabelStyle())
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.extraLarge)
    }
}

/// Only the icon, in a square of one size for every symbol: the glass circle sizes itself from
/// its content, and a plus is smaller than a gear, which left New Space a few points smaller
/// than Settings. The title stays, as `.iconOnly` keeps it, so VoiceOver still names the button.
private struct FooterIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .frame(width: Self.iconSide, height: Self.iconSide)
        }
        .labelStyle(.iconOnly)
    }

    /// The square each footer icon sits in.
    static let iconSide: CGFloat = 15
}

/// A dot for each Space in a glass capsule, the current one filled. Many Spaces scroll. The
/// capsule is as tall as the footer's buttons: each dot's target is ``SpaceDot/height`` tall,
/// plus the capsule's padding.
private struct SpaceDots: View {
    let model: BrowserModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            dots
            ScrollView(.horizontal) { dots }
                .scrollIndicators(.never)
                // As tall as the dots, so the capsule is the buttons' height either way.
                .frame(height: SpaceDot.height)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, (Self.buttonHeight - SpaceDot.height) / 2)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space list")
        .accessibilityIdentifier("spaceDots")
        // The theme editor (#137) hangs from the Space dots, beside the sidebar it changes.
        .popover(isPresented: Binding(
            get: { model.themeEditing.map { $0.isOpen && $0.placement == .sidebar } ?? false },
            // Clicking outside keeps what the window shows, as other Mac popovers do; Esc and
            // Cancel restore the old theme first.
            // Only this popover's own closing: another editor replacing it isn't a Done.
            set: { if !$0, model.themeEditing?.placement == .sidebar { model.closeThemeEditor(save: true) } }
        ), arrowEdge: .top) {
            SpaceThemeEditor(model: model)
                // The popover follows the window's appearance; the sidebar has the theme's.
                .windowAppearance()
        }
    }

    /// The footer's buttons' height (``FooterButtonStyle``), which the capsule matches.
    static let buttonHeight: CGFloat = 36

    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.spaces.enumerated()), id: \.element.id) { index, space in
                SpaceDot(space: space, index: index, isSelected: space.id == model.space?.id) {
                    Task { await model.selectSpace(space.id) }
                }
                .contextMenu {
                    Button("Rename…") { model.spaceToRename = space }
                    Button("Edit Theme…") { model.beginEditingTheme(for: space.id, in: .sidebar) }
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

    /// The height of a dot's click target.
    static let height: CGFloat = 28

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: isSelected ? 8 : 6, height: isSelected ? 8 : 6)
                // Not only color: a ring marks the current Space when the person asks for it.
                .overlay {
                    if isSelected && differentiateWithoutColor {
                        Circle().strokeBorder(.primary, lineWidth: 1.5).padding(-3)
                    }
                }
                .frame(width: 18, height: Self.height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
        .accessibilityLabel(space.name)
        .accessibilityHint(index < 9 ? "Control-\(index + 1)" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("spaceButton")
    }

    /// The Space's color when it has one (faded when it isn't the current Space), otherwise
    /// the primary color.
    private var fill: AnyShapeStyle {
        // Palette colors only: a theme's own color would vanish on its own background, where the
        // shown Space's dot sits.
        if let color = space.spaceColor?.color {
            return AnyShapeStyle(isSelected ? color : color.opacity(0.5))
        }
        return isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
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
