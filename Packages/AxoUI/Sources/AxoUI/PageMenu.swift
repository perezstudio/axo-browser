#if os(macOS)
import AppKit
#endif
import AxoCore
import AxoWeb
import Foundation

/// One entry of Axo's menu for a right-click in a page.
public struct PageMenuEntry: Identifiable {
    public enum Kind {
        case action(PageMenuAction)
        case submenu([PageMenuEntry])
        case separator
    }

    public let id = UUID()
    public var kind: Kind
    public var title: String
    public var isEnabled: Bool
    public var isChecked: Bool

    static func action(_ title: String, _ action: PageMenuAction, enabled: Bool = true, checked: Bool = false) -> PageMenuEntry {
        PageMenuEntry(kind: .action(action), title: title, isEnabled: enabled, isChecked: checked)
    }

    static var separator: PageMenuEntry {
        PageMenuEntry(kind: .separator, title: "", isEnabled: true, isChecked: false)
    }
}

/// What a page menu entry does.
public enum PageMenuAction {
    case openLinkInNewTab(URL)
    case openLinkInPeek(URL)
    case download(URL)
    case copyLink(URL)
    case openImageInNewTab(URL)
    case copyImage
    case copyAddress(URL)
    case lookUp
    case search(String)
    case edit(PageEdit)
    case replaceMisspelling(String)
    case back, forward, reload
    case extensionItem(PageContextMenuItem)
}

/// Builds Axo's menu for a right-click, like Safari's: the parts that apply to what was clicked
/// (spelling, link, image, selection, editing), or Back, Forward, and Reload for the page itself,
/// then extensions' items.
public enum PageMenu {
    /// The menu's entries for `menu`; `canGoBack` and `canGoForward` are the page's.
    @MainActor
    public static func entries(for menu: any PageContextMenu, canGoBack: Bool, canGoForward: Bool) -> [PageMenuEntry] {
        var sections: [[PageMenuEntry]] = []

        if menu.isEditable, !menu.misspelledWord.isEmpty {
            sections.append(menu.suggestions.isEmpty
                ? [.action("No Guesses Found", .replaceMisspelling(""), enabled: false)]
                : menu.suggestions.map { .action($0, .replaceMisspelling($0)) })
        }
        if let link = menu.linkURL {
            sections.append([
                .action("Open Link in New Tab", .openLinkInNewTab(link)),
                .action("Open Link in Peek", .openLinkInPeek(link)),
                .action("Download Linked File", .download(link)),
                .action("Copy Link", .copyLink(link)),
            ])
        }
        if menu.media == .image, let image = menu.sourceURL {
            sections.append([
                .action("Open Image in New Tab", .openImageInNewTab(image)),
                .action("Download Image", .download(image)),
                .action("Copy Image", .copyImage, enabled: menu.hasImageContents),
                .action("Copy Image Address", .copyAddress(image)),
            ])
        }
        let selection = menu.selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            let shown = quoted(selection)
            sections.append([
                .action("Look Up \(shown)", .lookUp),
                .action("Search the Web for \(shown)", .search(selection)),
            ])
        }
        if menu.isEditable {
            sections.append([
                .action("Cut", .edit(.cut), enabled: menu.edits.contains(.cut)),
                .action("Copy", .edit(.copy), enabled: menu.edits.contains(.copy)),
                .action("Paste", .edit(.paste), enabled: menu.edits.contains(.paste)),
                .action("Paste and Match Style", .edit(.pasteAndMatchStyle), enabled: menu.edits.contains(.paste)),
                .action("Select All", .edit(.selectAll), enabled: menu.edits.contains(.selectAll)),
            ])
        } else if !selection.isEmpty {
            sections.append([.action("Copy", .edit(.copy))])
        }
        if sections.isEmpty {
            sections.append([
                .action("Back", .back, enabled: canGoBack),
                .action("Forward", .forward, enabled: canGoForward),
                .action("Reload", .reload),
            ])
        }
        let extensions = menu.extensionItems.map(entry)
        if !extensions.isEmpty {
            sections.append(extensions)
        }
        return Array(sections.map { $0 }.joined(separator: [.separator]))
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
            Task { await openTab(url: url, at: .after(tabID)) }
        case .openLinkInPeek(let url):
            openPeek(url, from: tabID)
        case .download(let url):
            menu.download(url)
        case .copyLink(let url), .copyAddress(let url):
            copyToPasteboard(url)
        case .copyImage:
            menu.copyImage()
        case .lookUp:
            menu.lookUpSelection()
        case .search(let text):
            Task { await openTab(url: AddressInput.searchURL(for: text), at: .after(tabID)) }
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
        case .extensionItem(let item):
            menu.perform(item)
        }
    }

    /// Puts a URL on the pasteboard, as its address and as a URL.
    func copyToPasteboard(_ url: URL) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
        #endif
    }

    #if os(macOS)
    /// Shows Axo's menu for a right-click in the page in `tabID`, where it was clicked.
    func showPageMenu(_ menu: any PageContextMenu, tabID: AxoCore.Tab.ID) -> Bool {
        guard let view = pool.livePage(for: tabID)?.view, view.window != nil else { return false }
        let state = pool.state(for: tabID)
        let entries = PageMenu.entries(for: menu, canGoBack: state?.canGoBack ?? false, canGoForward: state?.canGoForward ?? false)
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
        case .action(let action):
            let target = MenuAction { run(action) }
            let item = NSMenuItem(title: entry.title, action: #selector(MenuAction.run), keyEquivalent: "")
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
