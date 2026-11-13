import AxoCore
import SwiftUI

#if os(macOS)
/// Edits the Space theme in ``BrowserModel/themeEditing`` (#137): presets (System, the
/// system's material, first), up to three colors, the appearance, transparency, and grain. The
/// window shows each change at once; Done keeps it and Cancel (or Esc) puts the old theme back.
struct SpaceThemeEditor: View {
    let model: BrowserModel

    private var draft: SpaceTheme? { model.themeEditing?.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ThemePresetGrid(selection: draft) { model.previewTheme($0) }
            if let draft {
                Divider()
                colorControls(draft)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Appearance")
                        .accessibilityHidden(true)
                    Picker("Appearance", selection: Binding(get: { draft.mode }, set: { mode in update { $0.mode = mode } })) {
                        Text("Automatic").tag(SpaceTheme.Mode.automatic)
                        Text("Light").tag(SpaceTheme.Mode.light)
                        Text("Dark").tag(SpaceTheme.Mode.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("themeModePicker")
                }
                slider("Transparency", value: Binding(get: { draft.transparency }, set: { value in update { $0.transparency = value } }),
                       identifier: "themeTransparencySlider", low: "Solid", high: "See-through")
                slider("Grain", value: Binding(get: { draft.grain }, set: { value in update { $0.grain = value } }),
                       identifier: "themeGrainSlider", low: "None", high: "Most")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(save: false) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("themeCancelButton")
                Button("Done") { finish(save: true) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("themeDoneButton")
            }
        }
        .padding(16)
        .frame(width: 300)
        .onExitCommand { finish(save: false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spaceThemeEditor")
    }

    private var title: String {
        let name = model.spaces.first { $0.id == model.themeEditing?.spaceID }?.name
        return name.map { "Theme for \($0)" } ?? "Space Theme"
    }

    private func update(_ change: (inout SpaceTheme) -> Void) {
        guard var theme = draft else { return }
        change(&theme)
        model.previewTheme(theme)
    }

    private func finish(save: Bool) {
        model.closeThemeEditor(save: save)
    }

    /// The colors, each with the system's color picker, and buttons to add and remove one.
    private func colorControls(_ theme: SpaceTheme) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Colors")
                .accessibilityHidden(true)
            colorRow(theme)
        }
    }

    private func colorRow(_ theme: SpaceTheme) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(theme.colors.enumerated()), id: \.offset) { index, color in
                ColorPicker("Theme color \(index + 1)", selection: Binding(
                    get: { Color(themeColor: color) },
                    set: { picked in
                        update { theme in
                            var colors = theme.colors
                            colors[index] = ThemeColor(color: picked)
                            theme.setColors(colors)
                        }
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel("Theme color \(index + 1)")
                .accessibilityValue(color.spokenName)
                .accessibilityIdentifier("themeColor\(index + 1)")
            }
            Spacer()
            Button {
                update { theme in theme.setColors(theme.colors + [theme.colors.last ?? .white]) }
            } label: {
                Image(systemName: "plus")
            }
            .disabled(theme.colors.count >= SpaceTheme.maxColors)
            .help("Add Color")
            .accessibilityLabel("Add Color")
            .accessibilityIdentifier("themeAddColorButton")
            Button {
                update { theme in theme.setColors(Array(theme.colors.dropLast())) }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(theme.colors.count <= 1)
            .help("Remove Color")
            .accessibilityLabel("Remove Color")
            .accessibilityIdentifier("themeRemoveColorButton")
        }
    }

    /// A labeled slider from 0 to 1 that VoiceOver reads as a percentage.
    private func slider(_ title: String, value: Binding<Double>, identifier: String, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                // The ends' names are for sight; VoiceOver reads the value as a percentage.
                Text(low).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                // The slider's own label is its accessibility label (another would be read twice).
                Slider(value: value, in: 0...1) { Text(title) }
                    .labelsHidden()
                    .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
                    .accessibilityIdentifier(identifier)
                Text(high).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }
}

/// System and the presets as round swatches; the chosen one has a ring. Choosing a preset
/// keeps the draft's transparency and grain.
private struct ThemePresetGrid: View {
    let selection: SpaceTheme?
    let choose: (SpaceTheme?) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 6), alignment: .leading, spacing: 8) {
            swatch(title: "System", isSelected: selection == nil, fill: AnyShapeStyle(.quaternary)) { choose(nil) }
                .accessibilityIdentifier("themePresetSystem")
            ForEach(ThemePreset.allCases) { preset in
                let theme = preset.theme
                let isSelected = selection?.colors == theme.colors
                swatch(title: preset.title, isSelected: isSelected, fill: fill(for: theme)) {
                    var chosen = theme
                    if let selection {
                        chosen.transparency = selection.transparency
                        chosen.grain = selection.grain
                    }
                    choose(chosen)
                }
                .accessibilityIdentifier("themePreset\(preset.title)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Presets")
    }

    private func fill(for theme: SpaceTheme) -> AnyShapeStyle {
        let colors = theme.colors.map(Color.init(themeColor:))
        return colors.count == 1 ? AnyShapeStyle(colors[0]) : AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
    }

    private func swatch(title: String, isSelected: Bool, fill: AnyShapeStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                .frame(width: 22, height: 22)
                .overlay {
                    if isSelected { Circle().strokeBorder(.primary, lineWidth: 2).padding(-3) }
                }
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif

#if os(macOS)
/// A small round picture of a theme: its colors, or the system's material for none.
struct ThemeSwatch: View {
    let theme: SpaceTheme?

    var body: some View {
        Circle()
            .fill(fill)
            .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        guard let theme else { return AnyShapeStyle(.quaternary) }
        let colors = theme.colors.map(Color.init(themeColor:))
        return colors.count == 1 ? AnyShapeStyle(colors[0]) : AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
    }
}
#endif
