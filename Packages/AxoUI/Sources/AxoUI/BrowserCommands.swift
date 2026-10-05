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
            Button(model?.selectedFolder == nil ? "New Folder" : "New Folder Inside") { model?.beginNewFolder() }
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
            Button(model?.isShowingDownloads == true ? "Hide Downloads" : "Show Downloads") { model?.isShowingDownloads.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Customize This Site…") { model?.customizeCurrentSite() }
                .disabled(model?.selectedHost == nil)
            Button("Site Settings…") {
                guard let model else { return }
                Task { await model.showSiteSettings() }
            }
            .disabled(model?.siteSettingsOrigin == nil)
            Divider()
            if model?.selectedTranslation != nil {
                Button("Show Original Page") {
                    guard let model else { return }
                    Task { await model.showOriginalPage() }
                }
            } else {
                Button("Translate Page") {
                    guard let model else { return }
                    Task { await model.translateSelectedPage() }
                }
                .disabled(model?.canTranslatePage != true)
            }
            if model?.pageSummarizer != nil {
                Button("Summarize Page") {
                    guard let model else { return }
                    Task { await model.summarizeSelectedPage() }
                }
                .disabled(model?.canSummarizePage != true)
            }
            Divider()
        }
        CommandMenu("Tabs") {
            Button("Next Tab") { model?.selectTab(offsetBy: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model?.tabs.isEmpty != false)
            Button("Previous Tab") { model?.selectTab(offsetBy: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(model?.tabs.isEmpty != false)
            Divider()
            Button(model?.selectedTab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                guard let model else { return }
                Task { await model.togglePinSelectedTab() }
            }
            .keyboardShortcut("p", modifiers: [.command, .control])
            .disabled(model?.selectedTab == nil || model?.selectedFolderID != nil)
            Button("Go to Pinned Page") {
                guard let model, let id = model.selectedTabID else { return }
                Task { await model.goToPinnedHome(id) }
            }
            .disabled(model?.selectedTab?.hasLeftHome != true || model?.selectedFolderID != nil)
            Button("Pin This Page Instead") {
                guard let model, let id = model.selectedTabID else { return }
                Task { await model.makeCurrentPagePinnedHome(id) }
            }
            .disabled(model?.selectedTab?.hasLeftHome != true || model?.selectedFolderID != nil)
            if let model, let item = model.selectedSidebarItem {
                MoveToFolderMenu(
                    model: model,
                    item: item,
                    current: model.parentFolder(of: item),
                    excluding: model.selectedFolderID.map { PinnedNode.folderAndDescendants($0, in: model.pinnedTree) } ?? []
                )
            }
            Divider()
            Button("Move Up") {
                guard let model else { return }
                Task { await model.moveSelectedItem(by: -1) }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
            .disabled(model?.canMoveSelectedItem(by: -1) != true)
            Button("Move Down") {
                guard let model else { return }
                Task { await model.moveSelectedItem(by: 1) }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
            .disabled(model?.canMoveSelectedItem(by: 1) != true)
            Divider()
            Button("Open Peek as Tab") {
                guard let model else { return }
                Task { await model.promotePeek() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model?.peek == nil)
            Button("Open Peek in Split View") {
                guard let model else { return }
                Task { await model.promotePeek(inSplit: true) }
            }
            .disabled(model?.peek == nil)
            // A menu shortcut, so Esc works even while the page in Peek has keyboard focus.
            // Off while the command bar is open, so Esc still closes the bar first.
            Button("Close Peek") { model?.closePeek() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(model?.peek == nil || model?.isCommandBarVisible == true)
            Divider()
            Button("Add Split View") { model?.beginSplitWithNewTab() }
                .keyboardShortcut("=", modifiers: [.control, .shift])
                .disabled(model?.canAddToSplit != true)
            Button("Remove Tab from Split View") {
                guard let model else { return }
                Task { await model.removeSelectedTabFromSplit() }
            }
            .disabled(model?.selectedSplit == nil)
            Button("Separate Split View") {
                guard let model else { return }
                Task { await model.separateSelectedSplit() }
            }
            .disabled(model?.selectedSplit == nil)
            Button(model?.selectedSplit?.orientation == .vertical ? "Show Panes Side by Side" : "Stack Panes") {
                guard let model else { return }
                Task { await model.toggleSplitOrientation() }
            }
            .disabled(model?.selectedSplit == nil)
            Divider()
            Button("Rename Folder…") { model?.renameSelectedFolder() }
                .disabled(model?.selectedFolder == nil)
            Button("Delete Folder") {
                guard let model else { return }
                Task { await model.deleteSelectedFolder() }
            }
            .disabled(model?.selectedFolder == nil)
            if let model, let profileID = model.space?.profileID,
               let items = model.extensionToolbar?.toolbarItems(profileID: profileID, tabID: model.selectedTabID), !items.isEmpty {
                Divider()
                Menu("Extension Buttons") {
                    ForEach(items) { item in
                        Button(item.label) {
                            model.extensionToolbar?.performAction(extensionID: item.id, profileID: profileID, tabID: model.selectedTabID)
                        }
                        .disabled(!item.isEnabled)
                    }
                }
            }
        }
        CommandMenu("Spaces") {
            Button("New Space…") { model?.isCreatingSpace = true }
                .disabled(model == nil)
            Button("Rename Space…") { model?.beginRenameSpace() }
                .disabled(model?.space == nil)
            Button("Delete Space…") { model?.beginDeleteSpace() }
                .disabled((model?.spaces.count ?? 0) < 2)
            Divider()
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
