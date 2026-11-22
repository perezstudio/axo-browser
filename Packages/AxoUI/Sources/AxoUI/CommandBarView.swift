import AxoCore
import SwiftUI

/// The command bar (⌘T): type to open a page, search, switch tabs, find history, or run an
/// action. ↑ and ↓ move the highlight, Return runs it, Esc closes.
struct CommandBarView: View {
    let model: BrowserModel
    /// Whether it rises from the bottom (the iPhone's bar at the bottom, #182): the field nearest
    /// the thumb and the keyboard, results above it, nearest first.
    var risesFromBottom = false
    @FocusState private var isFocused: Bool
    /// The field's selection, so an address being edited starts selected and typing replaces it.
    @State private var selection: TextSelection?
    /// The rows' height, so the list is only as tall as its rows (up to a limit).
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: risesFromBottom ? .bottom : .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { model.hideCommandBar() }
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                if risesFromBottom { results(reversed: true); if !model.commandResults.isEmpty { Divider() } }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField(model.pendingSplitAnchor == nil ? "Search, enter an address, or run a command" : "Choose a tab or enter an address to show in split view", text: Binding(
                        get: { model.commandQuery },
                        set: { model.setCommandQuery($0) }
                    ), selection: $selection)
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
                    #if os(iOS)
                    // iOS has no Esc: × closes it.
                    Button("Cancel", systemImage: "xmark.circle.fill") { model.hideCommandBar() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("commandCancelButton")
                    #endif
                }
                .padding(14)

                if !risesFromBottom {
                    if !model.commandResults.isEmpty { Divider() }
                    results(reversed: false)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 16)
            .background(.regularMaterial, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            .padding(.top, risesFromBottom ? 0 : 90)
            .padding(.bottom, risesFromBottom ? 8 : 0)
            .padding(.horizontal, risesFromBottom ? 12 : 0)
            .transition(risesFromBottom ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
            .accessibilityElement(children: .contain)
            // VoiceOver stays in the bar while it's open, like a sheet.
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("commandBar")
        }
        .defaultFocus($isFocused, true)
        // The sidebar list holds focus when the bar appears; take it once the field is on screen.
        .task {
            isFocused = true
            selectAllIfEditingAddress()
        }
        .onChange(of: model.commandQuerySelectionRequest) { selectAllIfEditingAddress() }
    }

    /// The results, nearest the field first: top down under it, or bottom up above it.
    @ViewBuilder
    private func results(reversed: Bool) -> some View {
        if !model.commandResults.isEmpty {
            let rows = Array(model.commandResults.enumerated())
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        // By result, not position, so a row keeps its identity as rows arrive.
                        ForEach(reversed ? rows.reversed() : rows, id: \.element.id) { index, result in
                            CommandRow(model: model, result: result, isSelected: index == model.commandSelection)
                                .id(result.id)
                                .onTapGesture { Task { await model.runCommand(at: index) } }
                                .accessibilityAction { Task { await model.runCommand(at: index) } }
                        }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .defaultScrollAnchor(reversed ? .bottom : .top)
                // Shorter above the keyboard, so a small iPhone never runs them under the top.
                .frame(height: min(rowsHeight, reversed ? 240 : 380))
                .onChange(of: model.commandSelection) {
                    guard model.commandResults.indices.contains(model.commandSelection) else { return }
                    proxy.scrollTo(model.commandResults[model.commandSelection].id)
                }
            }
        }
    }
}

extension CommandBarView {
    /// Selects the whole address being edited, a turn later, once the field holds it and focus.
    fileprivate func selectAllIfEditingAddress() {
        guard model.commandBarEditedTabID != nil else { return }
        Task {
            let query = model.commandQuery
            selection = TextSelection(range: query.startIndex..<query.endIndex)
        }
    }
}

/// One command bar row: an icon, a title, a detail line, and what Return will do (left out
/// where there's no room, as in the sidebar's suggestions).
struct CommandRow: View {
    let model: BrowserModel
    let result: CommandResult
    let isSelected: Bool
    var showsHint = true

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
            if showsHint {
                Text(result.hint)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .secondary : .tertiary)
            }
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
        case .menuCommand:
            Image(systemName: "filemenu.and.selection")
        case .suggestion:
            Image(systemName: "magnifyingglass")
        }
    }

    private var detail: String? {
        switch result {
        case .open: nil
        case .tab(let tab): tab.url.host() ?? tab.url.absoluteString
        case .action: nil
        case .history(let item): item.url.absoluteString
        case .menuCommand(let command): [command.menuName, command.shortcut].filter { !$0.isEmpty }.joined(separator: ", ")
        case .suggestion: nil
        }
    }
}
