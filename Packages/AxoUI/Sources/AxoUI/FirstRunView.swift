import AxoCore
import SwiftUI

#if os(macOS)
/// First run (#175): one glass card on Blush that stays in place while its contents change, from
/// the welcome to importing to setting up the first Space. Setting up tints the glass with the
/// Space's color. Blush is one of the few places Axo's brand colors appear; the rest of the app
/// uses the Space's color.
struct FirstRunView: View {
    let model: BrowserModel
    let firstRun: FirstRun
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Axo's Blush, and Ink for dark mode, behind the card.
    private var backdrop: Color {
        colorScheme == .dark ? Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x1F / 255) : Color(red: 1, green: 0xEE / 255, blue: 0xF3 / 255)
    }

    /// The glass's tint: clear until setting up, then a light wash of the Space's color.
    private var tint: Color {
        guard firstRun.step == .setUpSpace, let color = firstRun.preset?.theme.colors.first else { return .clear }
        return Color(themeColor: color).opacity(0.2)
    }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            VStack(spacing: 0) {
                content
                    .id(firstRun.step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(width: 440)
            .padding(32)
            .clipped()
            .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: 28))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: tint)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5), value: firstRun.step)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("firstRun")
    }

    @ViewBuilder
    private var content: some View {
        switch firstRun.step {
        case .welcome: welcome
        case .importing: importing
        case .setUpSpace: setUpSpace
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(Color(red: 0x9B / 255, green: 0x2A / 255, blue: 0x5C / 255))
                .accessibilityHidden(true)
            Text("Welcome to Axo")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("A calm, fast browser that keeps your tabs organized in Spaces. Let's get you set up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Get Started") { model.continueFirstRun() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("firstRunGetStarted")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunWelcome")
    }

    @ViewBuilder
    private var importing: some View {
        VStack(spacing: 16) {
            if let session = firstRun.importSession {
                let name = session.sources.first { $0.id == session.sourceID }?.name ?? "another browser"
                Text(firstRun.hasImported ? "You're all set" : "Bring your things from \(name)?")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                importStatus(session)
                HStack(spacing: 12) {
                    if firstRun.hasImported {
                        Button("Continue") { model.finishFirstRun() }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("firstRunContinue")
                    } else {
                        Button("Start Fresh") { model.startFresh() }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("firstRunStartFresh")
                        Button("Import") { Task { await model.importInFirstRun() } }
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!session.canImport)
                            .accessibilityIdentifier("firstRunImport")
                    }
                }
                .controlSize(.large)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunImportStep")
    }

    @ViewBuilder
    private func importStatus(_ session: ImportSession) -> some View {
        switch session.phase {
        case .loading:
            ProgressView().controlSize(.small).accessibilityLabel("Reading the browser's data")
        case .choosing(let counts):
            Text(counts.parts.isEmpty ? "There's nothing to import from this browser." : counts.summary.prefix(1).uppercased() + counts.summary.dropFirst() + ".")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("firstRunImportCounts")
            Text("Logins, passwords, and cookies stay in the other browser.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .importing:
            ProgressView("Importing…").controlSize(.small)
        case .finished(let counts):
            Text("Imported \(counts.summary).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("firstRunImportResult")
        case .unreadable(let message), .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("firstRunImportError")
        }
    }

    private var setUpSpace: some View {
        @Bindable var firstRun = firstRun
        return VStack(alignment: .leading, spacing: 18) {
            Text("Set up your first Space")
                .font(.title.bold())
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Text("Spaces keep your tabs apart, like one for work and one for home. You can add more anytime.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $firstRun.spaceName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .accessibilityIdentifier("firstRunSpaceName")
            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.headline)
                HStack(spacing: 8) {
                    ForEach(FirstRun.icons, id: \.self) { icon in
                        Button { firstRun.spaceIcon = icon } label: {
                            Image(systemName: icon)
                                .frame(width: 34, height: 34)
                                .background(firstRun.spaceIcon == icon ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                                            in: .rect(cornerRadius: 8))
                                .contentShape(.rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help(FirstRun.iconNames[icon] ?? icon)
                        .accessibilityLabel(FirstRun.iconNames[icon] ?? icon)
                        .accessibilityAddTraits(firstRun.spaceIcon == icon ? .isSelected : [])
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.headline)
                HStack(spacing: 6) {
                    swatch(title: "System", fill: AnyShapeStyle(.background), isSelected: firstRun.preset == nil) { firstRun.preset = nil }
                    ForEach(ThemePreset.allCases) { preset in
                        let colors = preset.theme.colors.map(Color.init(themeColor:))
                        swatch(title: preset.title,
                               fill: colors.count == 1 ? AnyShapeStyle(colors[0]) : AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)),
                               isSelected: firstRun.preset == preset) { firstRun.preset = preset }
                    }
                }
            }
            Button("Create Space") { Task { await model.createFirstSpace() } }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("firstRunCreateSpace")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunSetUpStep")
    }

    private func swatch(title: String, fill: AnyShapeStyle, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                .frame(width: 22, height: 22)
                .overlay { if isSelected { Circle().strokeBorder(.primary, lineWidth: 2).padding(-3) } }
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("firstRunColor\(title)")
    }
}
#endif
