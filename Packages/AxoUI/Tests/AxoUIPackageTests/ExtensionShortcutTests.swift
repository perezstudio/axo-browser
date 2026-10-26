#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import AxoUI

/// Extensions' shortcuts never take keys Axo's own menu items use.
@MainActor
struct ExtensionShortcutTests {
    private func menu() -> NSMenu {
        let main = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(NSMenuItem(title: "New Tab", action: nil, keyEquivalent: "t"))
        // Shift as AppKit writes it: an uppercase letter.
        file.submenu?.addItem(NSMenuItem(title: "Reopen Closed Tab", action: nil, keyEquivalent: "T"))
        let tabs = NSMenuItem(title: "Tabs", action: nil, keyEquivalent: "")
        tabs.submenu = NSMenu(title: "Tabs")
        let extensions = NSMenuItem(title: ExtensionShortcut.menuTitle, action: nil, keyEquivalent: "")
        extensions.submenu = NSMenu(title: ExtensionShortcut.menuTitle)
        extensions.submenu?.addItem(NSMenuItem(title: "Notes", action: nil, keyEquivalent: "y"))
        tabs.submenu?.addItem(extensions)
        main.addItem(file)
        main.addItem(tabs)
        return main
    }

    private func shortcut(_ key: Character, _ modifiers: EventModifiers) -> ExtensionShortcut {
        ExtensionShortcut(extensionID: "notes", name: "run", title: "Notes", key: key, modifiers: modifiers)
    }

    @Test func axosOwnShortcutsWin() {
        let menu = menu()
        #expect(shortcut("t", .command).clashes(with: menu))
        #expect(shortcut("t", [.command, .shift]).clashes(with: menu), "⇧⌘T is Axo's too")
        #expect(!shortcut("t", [.command, .option]).clashes(with: menu))
        #expect(!shortcut("y", .command).clashes(with: menu), "Extensions' own items don't count")
        #expect(!shortcut("t", .command).clashes(with: nil))
    }
}
#endif
