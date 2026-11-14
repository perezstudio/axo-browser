import Foundation
#if os(macOS)
import AppKit
#endif

/// An item in Axo's menus that the command bar can run (#123), such as "Translate Page" in the
/// View menu.
public struct MenuCommand: Hashable, Sendable, Identifiable {
    /// The item's title.
    public let title: String
    /// The menus above it, top first ("View", or "Tabs", "Extension Shortcuts").
    public let path: [String]
    /// Its keyboard shortcut as menus show it ("⇧⌘T"), or empty.
    public let shortcut: String

    public init(title: String, path: [String], shortcut: String = "") {
        self.title = title
        self.path = path
        self.shortcut = shortcut
    }

    public var id: String { (path + [title]).joined(separator: " › ") }

    /// The menu it's in, as the command bar names it ("View menu").
    public var menuName: String { path.first.map { "\($0) menu" } ?? "" }
}

/// Lists the menus' commands and runs one. The app sets the Mac's main menu
/// (``MainMenuCommands``); tests use their own.
@MainActor
public protocol MenuCommandProviding: AnyObject {
    /// The enabled items, as they are now.
    func commands() -> [MenuCommand]
    /// Runs `command` as if it were chosen from its menu.
    func run(_ command: MenuCommand)
}

#if os(macOS)
/// The Mac's main menu as command bar results.
@MainActor
public final class MainMenuCommands: MenuCommandProviding {
    private let menu: () -> NSMenu?

    /// Commands from `menu`, the app's main menu by default.
    public init(menu: @escaping () -> NSMenu? = { NSApp.mainMenu }) {
        self.menu = menu
    }

    public func commands() -> [MenuCommand] {
        guard let menu = menu() else { return [] }
        return MenuIndex.commands(in: menu)
    }

    public func run(_ command: MenuCommand) {
        guard let menu = menu() else { return }
        MenuIndex.perform(command, in: menu)
    }
}

/// Reads and runs menu items for the command bar.
@MainActor
enum MenuIndex {
    /// Top-level menus never offered: the Testing menu of UI testing mode, and the system's
    /// Services menu.
    static let excludedMenus: Set<String> = ["Testing", "Services"]

    /// The enabled, visible leaf items of `menu`, after it validates them, with their paths.
    /// Separators, hidden and alternate items, and items without a title are left out.
    static func commands(in menu: NSMenu, path: [String] = []) -> [MenuCommand] {
        menu.update()
        var commands: [MenuCommand] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {
            if let submenu = item.submenu {
                // The top level's items are the menu bar's titles; the app menu's title is the
                // app's name.
                let title = item.title.isEmpty ? submenu.title : item.title
                guard !excludedMenus.contains(title) else { continue }
                commands += Self.commands(in: submenu, path: path + [title])
            } else if item.isEnabled, !item.title.isEmpty, !path.isEmpty {
                commands.append(MenuCommand(title: item.title, path: path, shortcut: shortcut(of: item)))
            }
        }
        return commands
    }

    /// Runs the item at `command`'s path, as choosing it from its menu would.
    static func perform(_ command: MenuCommand, in menu: NSMenu) {
        guard let (submenu, index) = location(of: command, in: menu) else { return }
        submenu.performActionForItem(at: index)
    }

    /// The menu holding `command`'s item and the item's index, while the item is there and
    /// enabled.
    static func location(of command: MenuCommand, in menu: NSMenu) -> (NSMenu, Int)? {
        var current = menu
        for title in command.path {
            guard let item = current.items.first(where: { ($0.title.isEmpty ? $0.submenu?.title : $0.title) == title }),
                  let submenu = item.submenu else { return nil }
            current = submenu
        }
        current.update()
        guard let index = current.items.firstIndex(where: { $0.title == command.title && $0.submenu == nil }),
              current.items[index].isEnabled else { return nil }
        return (current, index)
    }

    /// A menu item's shortcut as menus show it, such as "⇧⌘T".
    static func shortcut(of item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        // An uppercase key equivalent implies Shift.
        let key = item.keyEquivalent
        if flags.contains(.shift) || (key.uppercased() == key && key.lowercased() != key) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let names: [String: String] = ["\u{1b}": "⎋", "\r": "↩", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{7f}": "⌫",
                                       String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
                                       String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
                                       String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
                                       String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"]
        return text + (names[key] ?? key.uppercased())
    }
}
#endif
