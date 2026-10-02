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
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model?.beginNewTab() }
                .keyboardShortcut("t")
                .disabled(model == nil)
            Button("Open Location…") { model?.focusAddressField() }
                .keyboardShortcut("l")
                .disabled(model == nil)
            Divider()
            Button("Close Tab") {
                guard let model else { return }
                Task { await model.closeSelectedTab() }
            }
            .keyboardShortcut("w")
            .disabled(model?.selectedTabID == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Reload Page") { model?.reloadOrStop() }
                .keyboardShortcut("r")
                .disabled(model?.selectedTabID == nil)
            Divider()
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
