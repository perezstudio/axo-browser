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
    /// Which of the menu's items with this title it is, from 0: titles can repeat, since some
    /// come from the person's data (two Spaces or favorites with the same name).
    public let occurrence: Int

    public init(title: String, path: [String], shortcut: String = "", occurrence: Int = 0) {
        self.title = title
        self.path = path
        self.shortcut = shortcut
        self.occurrence = occurrence
    }

    public var id: String {
        let id = (path + [title]).joined(separator: " › ")
        return occurrence == 0 ? id : "\(id) #\(occurrence + 1)"
    }

    /// Where it is, as the command bar names it ("View menu", or "Tabs › Move to Space menu"),
    /// so items with the same title in different submenus can be told apart.
    public var menuName: String { path.isEmpty ? "" : "\(path.joined(separator: " › ")) menu" }
}

/// Lists the menus' commands and runs one. The app sets the Mac's main menu
/// (``MainMenuCommands``); tests use their own.
@MainActor
public protocol MenuCommandProviding: AnyObject {
    /// The enabled items, as they are now.
    func commands() -> [MenuCommand]
    /// Runs `command` as if it were chosen from its menu.
    ///
    /// - Returns: Whether it ran: `false` if the item is gone or disabled now.
    @discardableResult
    func run(_ command: MenuCommand) -> Bool
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

    @discardableResult
    public func run(_ command: MenuCommand) -> Bool {
        guard let menu = menu() else { return false }
        return MenuIndex.perform(command, in: menu)
    }
}

/// Reads and runs menu items for the command bar.
@MainActor
enum MenuIndex {
    /// Top-level menus never offered: the Testing menu of UI testing mode. The system's
    /// Services menu is left out by identity (its title is localized; ``isServicesMenu(_:)``).
    static let excludedMenus: Set<String> = ["Testing"]

    /// Whether `menu` is the app's Services menu, whose items act on the selection in whatever
    /// has focus.
    static func isServicesMenu(_ menu: NSMenu) -> Bool {
        if let services = NSApplication.shared.servicesMenu, services === menu { return true }
        return false
    }

    /// Whether `item` is offered: not a separator, hidden, or an alternate.
    private static func isListed(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && !item.isHidden && !item.isAlternate
    }

    /// The enabled, visible leaf items of `menu`, after it validates them, with their paths.
    /// Separators, hidden and alternate items, and items without a title are left out.
    static func commands(in menu: NSMenu, path: [String] = []) -> [MenuCommand] {
        menu.update()
        var commands: [MenuCommand] = []
        var occurrences: [String: Int] = [:]
        for item in menu.items where isListed(item) {
            if let submenu = item.submenu {
                // The top level's items are the menu bar's titles; the app menu's title is the
                // app's name.
                let title = item.title.isEmpty ? submenu.title : item.title
                guard !excludedMenus.contains(title), !isServicesMenu(submenu) else { continue }
                commands += Self.commands(in: submenu, path: path + [title])
            } else if !item.title.isEmpty, !path.isEmpty {
                // Counted before the enabled check, so `location` finds the same item by index.
                let occurrence = occurrences[item.title, default: 0]
                occurrences[item.title] = occurrence + 1
                guard item.isEnabled else { continue }
                commands.append(MenuCommand(title: item.title, path: path, shortcut: shortcut(of: item), occurrence: occurrence))
            }
        }
        return commands
    }

    /// Runs the item at `command`'s path, as choosing it from its menu would.
    @discardableResult
    static func perform(_ command: MenuCommand, in menu: NSMenu) -> Bool {
        guard let (submenu, index) = location(of: command, in: menu) else { return false }
        submenu.performActionForItem(at: index)
        return true
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
        let matches = current.items.indices.filter { index in
            let item = current.items[index]
            return isListed(item) && item.submenu == nil && item.title == command.title
        }
        guard matches.indices.contains(command.occurrence) else { return nil }
        let index = matches[command.occurrence]
        guard current.items[index].isEnabled else { return nil }
        return (current, index)
    }

    /// A menu item's shortcut as menus show it, such as "⇧⌘T".
    static func shortcut(of item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        // The Globe (fn) key, as in Window › Full Screen's fn-F.
        var text = flags.contains(.function) ? "fn " : ""
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
                                       String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
                                       String(UnicodeScalar(NSDeleteFunctionKey)!): "⌦",
                                       String(UnicodeScalar(NSHomeFunctionKey)!): "↖",
                                       String(UnicodeScalar(NSEndFunctionKey)!): "↘",
                                       String(UnicodeScalar(NSPageUpFunctionKey)!): "⇞",
                                       String(UnicodeScalar(NSPageDownFunctionKey)!): "⇟"]
        // F1 to F12.
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
           (NSF1FunctionKey...NSF12FunctionKey).contains(Int(scalar.value)) {
            return text + "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        }
        return text + (names[key] ?? key.uppercased())
    }
}
#endif
