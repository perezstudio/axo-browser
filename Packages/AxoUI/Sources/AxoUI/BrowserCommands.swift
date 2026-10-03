import SwiftUI

extension FocusedValues {
    /// The model of the focused browser window, for menu commands.
    @Entry var browserModel: BrowserModel?
}

/// Menu bar commands and keyboard shortcuts for browsing.
public struct BrowserCommands: Commands {
    @FocusedValue(\.browserModel) private var model

    /// Creates the browser commands.
    public init() {}

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            if model?.isDefaultBrowser == true {
                Button("Axo Is Your Default Browser") {}
                    .disabled(true)
            } else {
                Button("Make Axo Your Default Browser…") {
                    guard let model else { return }
                    Task { await model.makeDefaultBrowser() }
                }
                .disabled(model?.isDefaultBrowser == nil)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model?.beginNewTab() }
                .keyboardShortcut("t")
                .disabled(model == nil)
            Button("New Folder") { model?.namingRequest = .newFolder(parent: nil, moving: nil) }
                // Not ⌥⌘N: ⌥N is a dead key on US layouts, so that shortcut never fires.
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(model == nil)
            Button("Install Extension…") { model?.chooseExtensionToInstall() }
                .disabled(model?.extensionManagement == nil)
            Button("Open Location…") { model?.focusAddressField() }
                .keyboardShortcut("l")
                .disabled(model == nil)
            Divider()
            Button("Reopen Closed Tab") {
                guard let model else { return }
                Task { await model.reopenLastClosedTab() }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model == nil)
            Button("Close Tab") {
                // With no tab open, ⌘W closes the window instead, since this item owns ⌘W.
                guard let model, model.selectedTabID != nil else {
                    NSApp.keyWindow?.performClose(nil)
                    return
                }
                Task { await model.closeSelectedTab() }
            }
            .keyboardShortcut("w")
        }
        CommandGroup(replacing: .importExport) {
            Button("Import from Another Browser…") { model?.beginImport() }
                .disabled(model?.browserImporter == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model?.printSelectedTab() }
                .keyboardShortcut("p")
                .disabled(model?.selectedTabID == nil)
        }
        CommandGroup(after: .textEditing) {
            Section {
                Button("Find…") { model?.showFindBar() }
                    .keyboardShortcut("f")
                    .disabled(model?.selectedTabID == nil)
                Button("Find Next") {
                    guard let model else { return }
                    Task { await model.findNext() }
                }
                .keyboardShortcut("g")
                .disabled(model?.findText.isEmpty != false)
                Button("Find Previous") {
                    guard let model else { return }
                    Task { await model.findPrevious() }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model?.findText.isEmpty != false)
            }
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Page") { model?.reloadOrStop() }
                .keyboardShortcut("r")
                .disabled(model?.selectedTabID == nil)
            Button("Show Extensions") { model?.isShowingExtensions = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.extensionManagement == nil)
            Button("Show Archived Tabs") { model?.isShowingArchive = true }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Show Downloads") { model?.isShowingDownloads.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model == nil)
            Divider()
        }
        CommandMenu("Spaces") {
            Button("Next Space") {
                guard let model else { return }
                Task { await model.selectNextSpace() }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled((model?.spaces.count ?? 0) < 2)
            Button("Previous Space") {
                guard let model else { return }
                Task { await model.selectPreviousSpace() }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled((model?.spaces.count ?? 0) < 2)
            Divider()
            ForEach(Array((model?.spaces ?? []).prefix(9).enumerated()), id: \.element.id) { index, space in
                Button(space.name) {
                    guard let model else { return }
                    Task { await model.selectSpace(at: index) }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control)
            }
        }
        CommandMenu("Develop") {
            Button("Show Web Inspector") { model?.toggleWebInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model?.selectedTabID == nil || model?.developerTools == nil)
            Button("Show JavaScript Console") { model?.showJavaScriptConsole() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model?.selectedTabID == nil || model?.developerTools == nil)
        }
        CommandMenu("History") {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.selectedPage?.canGoBack != true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.selectedPage?.canGoForward != true)
        }
    }
}
