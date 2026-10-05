import AxoCore
import SwiftUI

/// The command bar (⌘T): type to open a page, search, switch tabs, find history, or run an
/// action. ↑ and ↓ move the highlight, Return runs it, Esc closes.
struct CommandBarView: View {
    let model: BrowserModel
    @FocusState private var isFocused: Bool
    /// The rows' height, so the list is only as tall as its rows (up to a limit).
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { model.hideCommandBar() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(model.pendingSplitAnchor == nil ? "Search, enter an address, or run a command" : "Choose a tab or enter an address to show in split view", text: Binding(
                        get: { model.commandQuery },
                        set: { model.setCommandQuery($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Command bar")
                    .accessibilityHint("Search, enter an address, or run a command. Use the up and down arrow keys to choose a result.")
                    .accessibilityIdentifier("commandField")
                    .onSubmit { Task { await model.runCommand() } }
                    .onExitCommandIfAvailable { model.hideCommandBar() }
                    .onKeyPress(.downArrow) { model.moveCommandSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { model.moveCommandSelection(by: -1); return .handled }
                }
                .padding(14)

                if !model.commandResults.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(model.commandResults.enumerated()), id: \.element.id) { index, result in
                                    CommandRow(model: model, result: result, isSelected: index == model.commandSelection)
                                        .id(result.id)
                                        .onTapGesture { Task { await model.runCommand(at: index) } }
                                        .accessibilityAction { Task { await model.runCommand(at: index) } }
                                }
                            }
                            .padding(6)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                        }
                        .frame(height: min(rowsHeight, 380))
                        .onChange(of: model.commandSelection) {
                            guard model.commandResults.indices.contains(model.commandSelection) else { return }
                            proxy.scrollTo(model.commandResults[model.commandSelection].id)
                        }
                    }
                }
            }
            .frame(width: 620)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            .padding(.top, 90)
            .accessibilityElement(children: .contain)
            // VoiceOver stays in the bar while it's open, like a sheet.
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("commandBar")
        }
        .defaultFocus($isFocused, true)
        // The sidebar list holds focus when the bar appears; take it once the field is on screen.
        .task { isFocused = true }
    }
}

/// One command bar row: an icon, a title, a detail line, and what Return will do.
private struct CommandRow: View {
    let model: BrowserModel
    let result: CommandResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(result.hint)
                .font(.caption)
                .foregroundStyle(isSelected ? .secondary : .tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // A soft tint keeps text readable with both the Raspberry and the lighter dark-mode accent.
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("commandResult")
    }

    @ViewBuilder
    private var icon: some View {
        switch result {
        case .open(_, let isSearch, _):
            Image(systemName: isSearch ? "magnifyingglass" : "globe")
        case .tab(let tab):
            if let favicon = model.favicon(for: tab) {
                Image(platformImage: favicon).resizable()
            } else {
                Image(systemName: tab.isPinned ? "pin" : "macwindow")
            }
        case .action(let action):
            Image(systemName: action.systemImage)
        case .history:
            Image(systemName: "clock")
        }
    }

    private var detail: String? {
        switch result {
        case .open: nil
        case .tab(let tab): tab.url.host() ?? tab.url.absoluteString
        case .action: nil
        case .history(let item): item.url.absoluteString
        }
    }
}
