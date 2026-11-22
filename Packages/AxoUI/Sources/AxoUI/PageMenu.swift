#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import AxoCore
import AxoWeb
import Foundation

/// One entry of Axo's menu for a right-click in a page.
public struct PageMenuEntry: Identifiable {
    public enum Kind {
        case action(PageMenuAction)
        case submenu([PageMenuEntry])
        /// macOS's Share menu for an item.
        case share(PageShareItem)
        case separator
    }

    public let id = UUID()
    public var kind: Kind
    public var title: String
    public var isEnabled: Bool
    public var isChecked: Bool
    /// The shortcut the same command has in the menu bar, shown beside the item.
    public var shortcut: PageMenuShortcut?

    static func action(_ title: String, _ action: PageMenuAction, enabled: Bool = true, checked: Bool = false,
                       shortcut: PageMenuShortcut? = nil) -> PageMenuEntry {
        PageMenuEntry(kind: .action(action), title: title, isEnabled: enabled, isChecked: checked, shortcut: shortcut)
    }

    static func share(_ item: PageShareItem) -> PageMenuEntry {
        PageMenuEntry(kind: .share(item), title: "Share", isEnabled: true, isChecked: false)
    }

    static var separator: PageMenuEntry {
        PageMenuEntry(kind: .separator, title: "", isEnabled: true, isChecked: false)
    }
}

/// A shortcut shown beside a page menu item: its key, with Command and any of Shift and Option.
public struct PageMenuShortcut: Equatable, Sendable {
    public var key: String
    public var shift = false
    public var option = false

    static func command(_ key: String, shift: Bool = false, option: Bool = false) -> PageMenuShortcut {
        PageMenuShortcut(key: key, shift: shift, option: option)
    }
}

/// What a page menu's Share item shares.
public enum PageShareItem: Equatable, Sendable {
    case url(URL)
    case text(String)
}

/// What a page menu entry does.
public enum PageMenuAction {
    case openLinkInNewTab(URL)
    case openLinkInPeek(URL)
    case openLinkInSplit(URL)
    case download(URL)
    case copyLink(URL)
    case openImageInNewTab(URL)
    case openImageInPeek(URL)
    case copyImage
    case copyAddress(URL)
    case lookUp
    case search(String)
    case startSpeaking(String)
    case stopSpeaking
    case edit(PageEdit)
    case replaceMisspelling(String)
    case back, forward, reload
    case translatePage, showOriginalPage, summarizePage
    case inspectElement
    case extensionItem(PageContextMenuItem)
}

/// What the page menu needs to know about the page and the browser, beyond what was clicked.
public struct PageMenuContext {
    /// The page's history.
    public var canGoBack = false
    public var canGoForward = false
    /// The page's address, for Copy Link and Share on the page itself.
    public var pageURL: URL?
    /// Whether Translate Page applies; `isTranslated` shows Show Original Page instead.
    public var canTranslate = false
    public var isTranslated = false
    /// Whether Summarize Page applies; `nil` leaves it out, for a Mac without the on-device model.
    public var canSummarize: Bool?
    /// The engine Search with names (the profile's).
    public var searchEngineName = "Google"
    /// Whether a link can open in a split with the clicked page (one of the Space's tabs, with
    /// room in its split).
    public var canOpenInSplit = false
    /// Whether Axo is speaking a selection now, for Speech's Stop Speaking.
    public var isSpeaking = false

    public init(canGoBack: Bool = false, canGoForward: Bool = false, pageURL: URL? = nil, canTranslate: Bool = false,
                isTranslated: Bool = false, canSummarize: Bool? = nil, searchEngineName: String = "Google",
                canOpenInSplit: Bool = false, isSpeaking: Bool = false) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.pageURL = pageURL
        self.canTranslate = canTranslate
        self.isTranslated = isTranslated
        self.canSummarize = canSummarize
        self.searchEngineName = searchEngineName
        self.canOpenInSplit = canOpenInSplit
        self.isSpeaking = isSpeaking
    }
}

/// Builds Axo's menu for a right-click, as the Page context menu board draws it (#173): the parts
/// that apply to what was clicked (spelling, link, image, selection, editing), or for the page
/// itself Back, Forward, Reload Page, its tools, Copy Link, and Share; then Inspect Element; then
/// extensions' items.
public enum PageMenu {
    /// The menu's entries for `menu`.
    @MainActor
    public static func entries(for menu: any PageContextMenu, context: PageMenuContext) -> [PageMenuEntry] {
        var sections: [[PageMenuEntry]] = []
        let link = menu.linkURL
        let image = menu.media == .image ? menu.sourceURL : nil
        let selection = menu.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)

        if menu.isEditable, !menu.misspelledWord.isEmpty {
            sections.append(menu.suggestions.isEmpty
                ? [.action("No Guesses Found", .replaceMisspelling(""), enabled: false)]
                : menu.suggestions.map { .action($0, .replaceMisspelling($0)) })
        }
        // Where to open what was clicked.
        var opens: [PageMenuEntry] = []
        if let link {
            opens += [
                .action("Open Link in New Tab", .openLinkInNewTab(link)),
                .action("Open Link in Peek", .openLinkInPeek(link)),
                .action("Open Link in Split View", .openLinkInSplit(link), enabled: context.canOpenInSplit),
            ]
        }
        if let image {
            opens += [
                .action("Open Image in New Tab", .openImageInNewTab(image)),
                .action("Open Image in Peek", .openImageInPeek(image)),
            ]
        }
        if !opens.isEmpty { sections.append(opens) }
        // Saving, copying, and sharing it.
        var keeps: [PageMenuEntry] = []
        if let link {
            keeps += [.action("Download Linked File", .download(link)), .action("Copy Link", .copyLink(link))]
        }
        if let image {
            keeps += [
                .action("Download Image", .download(image)),
                .action("Copy Image", .copyImage, enabled: menu.hasImageContents),
                .action("Copy Image Address", .copyAddress(image)),
            ]
        }
        if let shared = link ?? image {
            keeps.append(.share(.url(shared)))
        }
        if !keeps.isEmpty { sections.append(keeps) }

        if !selection.isEmpty {
            let shown = quoted(selection)
            sections.append([
                .action("Look Up \(shown)", .lookUp),
                .action("Search with \(context.searchEngineName)", .search(selection)),
            ])
        }
        if menu.isEditable {
            sections.append([
                .action("Cut", .edit(.cut), enabled: menu.edits.contains(.cut), shortcut: .command("x")),
                .action("Copy", .edit(.copy), enabled: menu.edits.contains(.copy), shortcut: .command("c")),
                .action("Paste", .edit(.paste), enabled: menu.edits.contains(.paste), shortcut: .command("v")),
                .action("Paste and Match Style", .edit(.pasteAndMatchStyle), enabled: menu.edits.contains(.paste),
                        shortcut: .command("v", shift: true, option: true)),
            ])
        } else if !selection.isEmpty {
            var copies: [PageMenuEntry] = [.action("Copy", .edit(.copy), shortcut: .command("c"))]
            // A link or image has its own Share; Speech is for selections outside them.
            if link == nil, image == nil {
                copies += [
                    .share(.text(selection)),
                    PageMenuEntry(kind: .submenu([
                        .action("Start Speaking", .startSpeaking(selection), enabled: !context.isSpeaking),
                        .action("Stop Speaking", .stopSpeaking, enabled: context.isSpeaking),
                    ]), title: "Speech", isEnabled: true, isChecked: false),
                ]
            }
            sections.append(copies)
        }
        if sections.isEmpty {
            sections.append([
                .action("Back", .back, enabled: context.canGoBack, shortcut: .command("[")),
                .action("Forward", .forward, enabled: context.canGoForward, shortcut: .command("]")),
                .action("Reload Page", .reload, shortcut: .command("r")),
            ])
            var tools: [PageMenuEntry] = [context.isTranslated
                ? .action("Show Original Page", .showOriginalPage)
                : .action("Translate Page", .translatePage, enabled: context.canTranslate)]
            if let canSummarize = context.canSummarize {
                tools.append(.action("Summarize Page", .summarizePage, enabled: canSummarize))
            }
            sections.append(tools)
            if let page = context.pageURL {
                sections.append([.action("Copy Link", .copyLink(page), shortcut: .command("c", shift: true)), .share(.url(page))])
            }
        }
        // No shortcut: ⌥⌘I is Show Web Inspector, which toggles DevTools rather than inspecting.
        sections.append([.action("Inspect Element", .inspectElement, enabled: menu.canInspectElement)])
        let extensions = menu.extensionItems.map(entry)
        if !extensions.isEmpty {
            sections.append(extensions)
        }
        return Array(sections.joined(separator: [.separator]))
    }

    private static func entry(_ item: PageContextMenuItem) -> PageMenuEntry {
        switch item.kind {
        case .separator:
            return .separator
        case .submenu:
            return PageMenuEntry(kind: .submenu(item.children.map(entry)), title: item.title, isEnabled: item.isEnabled, isChecked: false)
        default:
            return .action(item.title, .extensionItem(item), enabled: item.isEnabled, checked: item.isChecked)
        }
    }

    /// Selected text as a menu item shows it: quoted, and shortened when it's long.
    static func quoted(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let short = line.count > 30 ? line.prefix(30) + "…" : Substring(line)
        return "“\(short)”"
    }
}

extension BrowserModel {
    /// Runs a page menu entry's action for the page in `tabID`.
    func perform(_ action: PageMenuAction, menu: any PageContextMenu, tabID: AxoCore.Tab.ID) {
        switch action {
        case .openLinkInNewTab(let url), .openImageInNewTab(let url):
            Task { await openTab(url: url, at: newTabPosition(after: tabID)) }
        case .openLinkInPeek(let url), .openImageInPeek(let url):
            openPeek(url, from: tabID)
        case .openLinkInSplit(let url):
            Task { await openLinkInSplit(url, from: tabID) }
        case .download(let url):
            menu.download(url)
        case .copyLink(let url), .copyAddress(let url):
            if let copyLink { copyLink(url) } else { copyToPasteboard(url) }
        case .copyImage:
            menu.copyImage()
        case .lookUp:
            menu.lookUpSelection()
        case .search(let text):
            Task { await openTab(url: searchContext.engine.searchURL(for: text), at: newTabPosition(after: tabID)) }
        case .startSpeaking(let text):
            selectionSpeech.speak(text)
        case .stopSpeaking:
            selectionSpeech.stop()
        case .edit(let edit):
            menu.perform(edit)
        case .replaceMisspelling(let word):
            menu.replaceMisspelling(with: word)
        case .back:
            pool.goBack(in: tabID)
        case .forward:
            pool.goForward(in: tabID)
        case .reload:
            pool.reload(tabID)
        case .translatePage:
            Task { await translateSelectedPage() }
        case .showOriginalPage:
            Task { await showOriginalPage() }
        case .summarizePage:
            Task { await summarizeSelectedPage() }
        case .inspectElement:
            menu.inspectElement()
        case .extensionItem(let item):
            menu.perform(item)
        }
    }

    /// The page menu's context for the page in `tabID`: its history and address, the page tools
    /// (for the selected page, which a right-click shows), the profile's search engine, whether a
    /// link can join it in a split, and whether a selection is being spoken.
    func pageMenuContext(for tabID: AxoCore.Tab.ID) -> PageMenuContext {
        let state = pool.state(for: tabID)
        let isSelected = tabID == selectedTabID
        return PageMenuContext(
            canGoBack: state?.canGoBack ?? false,
            canGoForward: state?.canGoForward ?? false,
            pageURL: (state?.url).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
            canTranslate: isSelected && canTranslatePage,
            isTranslated: isSelected && selectedTranslation != nil,
            canSummarize: pageSummarizer == nil ? nil : isSelected && canSummarizePage,
            searchEngineName: searchContext.engine.name,
            canOpenInSplit: canOpenInSplit(from: tabID),
            isSpeaking: selectionSpeech.isSpeaking
        )
    }

    /// Whether a link from the page in `tabID` can open beside it: the page is one of the shown
    /// Space's tabs, and its split (if any) has room.
    func canOpenInSplit(from tabID: AxoCore.Tab.ID) -> Bool {
        guard tabs.contains(where: { $0.id == tabID }) else { return false }
        guard let split = split(of: tabID) else { return true }
        return panes(of: split.id).count < TabSplit.maximumPanes
    }

    /// Opens a link in a new tab beside the page in `tabID`, in a split with it (#173). A pinned
    /// page's split pins the new tab when it joins.
    func openLinkInSplit(_ url: URL, from tabID: AxoCore.Tab.ID) async {
        guard canOpenInSplit(from: tabID),
              let opened = await openTab(url: url, at: newTabPosition(after: tabID)) else { return }
        await addToSplit(opened, with: tabID)
    }

    /// Where a tab opened from the page in `tabID` goes: right after it, or for a pinned tab,
    /// whose section new tabs can't join, at the top of the tabs section.
    func newTabPosition(after tabID: AxoCore.Tab.ID) -> TabPosition {
        tabs.first { $0.id == tabID }?.isPinned == true ? .start : .after(tabID)
    }

    /// Puts a URL on the pasteboard, as its address and as a URL.
    func copyToPasteboard(_ url: URL) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.url = url
        #endif
    }

    #if os(macOS)
    /// Shows Axo's menu for a right-click in the page in `tabID`, where it was clicked.
    func showPageMenu(_ menu: any PageContextMenu, tabID: AxoCore.Tab.ID) -> Bool {
        guard let view = pool.livePage(for: tabID)?.view, view.window != nil else { return false }
        let entries = PageMenu.entries(for: menu, context: pageMenuContext(for: tabID))
        let nsMenu = PageMenuPresenter.menu(for: entries) { [weak self] action in
            self?.perform(action, menu: menu, tabID: tabID)
        }
        // The location's origin is the view's top left.
        let point = view.isFlipped ? menu.location : CGPoint(x: menu.location.x, y: view.bounds.height - menu.location.y)
        // Shown asynchronously, so the engine's right-click handling finishes first.
        DispatchQueue.main.async {
            nsMenu.popUp(positioning: nil, at: point, in: view)
            menu.closed(followingLink: nil)
        }
        return true
    }
    #endif
}

#if os(macOS)
/// Builds the `NSMenu` for page menu entries.
@MainActor
enum PageMenuPresenter {
    static func menu(for entries: [PageMenuEntry], run: @escaping (PageMenuAction) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            menu.addItem(item(for: entry, run: run))
        }
        return menu
    }

    private static func item(for entry: PageMenuEntry, run: @escaping (PageMenuAction) -> Void) -> NSMenuItem {
        switch entry.kind {
        case .separator:
            return .separator()
        case .submenu(let children):
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.submenu = menu(for: children, run: run)
            item.isEnabled = entry.isEnabled
            return item
        case .share(let shared):
            // macOS's own Share menu: AirDrop, Messages, Mail, and the rest.
            let object: Any = switch shared {
            case .url(let url): url as NSURL
            case .text(let text): text as NSString
            }
            let picker = NSSharingServicePicker(items: [object])
            let item = picker.standardShareMenuItem
            // Kept with the item while the menu is open, as its services need it.
            item.representedObject = picker
            return item
        case .action(let action):
            let target = MenuAction { run(action) }
            let item = NSMenuItem(title: entry.title, action: #selector(MenuAction.run), keyEquivalent: entry.shortcut?.key ?? "")
            if let shortcut = entry.shortcut {
                var modifiers: NSEvent.ModifierFlags = [.command]
                if shortcut.shift { modifiers.insert(.shift) }
                if shortcut.option { modifiers.insert(.option) }
                item.keyEquivalentModifierMask = modifiers
            }
            item.target = target
            // The item keeps its target alive while the menu is open.
            item.representedObject = target
            item.isEnabled = entry.isEnabled
            item.state = entry.isChecked ? .on : .off
            return item
        }
    }
}

/// An `NSMenuItem` target that runs a closure.
@MainActor
final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}
#endif
