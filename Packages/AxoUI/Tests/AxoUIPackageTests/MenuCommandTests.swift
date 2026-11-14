#if os(macOS)
import AppKit
import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

/// The command bar finds and runs Axo's menu items (#123).
@MainActor
struct MenuCommandTests {
    /// Records the items it's asked to run.
    final class Recorder: NSObject {
        var ran: [String] = []
        @objc func run(_ sender: NSMenuItem) { ran.append(sender.title) }
    }

    /// A menu bar with a File menu, a nested Tabs menu, and a Testing menu.
    private func testMenu(_ recorder: Recorder) -> NSMenu {
        func item(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(Recorder.run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = recorder
            return item
        }
        let file = NSMenu(title: "File")
        file.autoenablesItems = false
        file.addItem(item("New Window", "n"))
        let disabled = item("Close All")
        disabled.isEnabled = false
        file.addItem(disabled)
        file.addItem(.separator())
        let hidden = item("Secret")
        hidden.isHidden = true
        file.addItem(hidden)
        let alternate = item("Close Everything", "w", [.command, .option])
        alternate.isAlternate = true
        file.addItem(alternate)
        file.addItem(item("Print Page", "p"))

        // Items are enabled by hand: automatic enabling needs a running app, which unit tests lack.
        let shortcuts = NSMenu(title: "Extension Shortcuts")
        shortcuts.autoenablesItems = false
        shortcuts.addItem(item("Save to Pocket", "S", .command))
        let tabs = NSMenu(title: "Tabs")
        tabs.autoenablesItems = false
        let shortcutsItem = NSMenuItem(title: "Extension Shortcuts", action: nil, keyEquivalent: "")
        shortcutsItem.submenu = shortcuts
        tabs.addItem(shortcutsItem)
        tabs.addItem(item("Show Web Inspector", "i", [.command, .option]))

        let testing = NSMenu(title: "Testing")
        testing.autoenablesItems = false
        testing.addItem(item("Open Link from Another App"))

        let bar = NSMenu(title: "Main")
        for menu in [file, tabs, testing] {
            let top = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            top.submenu = menu
            bar.addItem(top)
        }
        return bar
    }

    @Test func enabledLeafItemsAreIndexedWithTheirMenusAndShortcuts() {
        // Kept here: menu items hold their target weakly.
        let recorder = Recorder()
        let commands = MenuIndex.commands(in: testMenu(recorder))
        #expect(commands.map(\.id) == [
            "File › New Window", "File › Print Page",
            "Tabs › Extension Shortcuts › Save to Pocket", "Tabs › Show Web Inspector",
        ], "No disabled, hidden, or alternate items, separators, or the Testing menu")
        #expect(commands.first?.shortcut == "⌘N")
        #expect(commands.first { $0.title == "Save to Pocket" }?.shortcut == "⇧⌘S", "An uppercase key means Shift")
        #expect(commands.first { $0.title == "Show Web Inspector" }?.shortcut == "⌥⌘I")
        #expect(commands.first?.menuName == "File menu")
    }

    /// Running a command finds its item by its path (AppKit then performs it, which needs a
    /// running app; the UI test runs one in Axo).
    @Test func aCommandFindsItsItemByItsPath() throws {
        let recorder = Recorder()
        let menu = testMenu(recorder)
        let (submenu, index) = try #require(MenuIndex.location(of: MenuCommand(title: "Save to Pocket", path: ["Tabs", "Extension Shortcuts"]), in: menu))
        #expect(submenu.title == "Extension Shortcuts")
        #expect(submenu.items[index].title == "Save to Pocket")
        #expect(MenuIndex.location(of: MenuCommand(title: "Close All", path: ["File"]), in: menu) == nil, "A disabled item doesn't run")
        #expect(MenuIndex.location(of: MenuCommand(title: "Gone", path: ["File"]), in: menu) == nil)
        #expect(MenuIndex.location(of: MenuCommand(title: "New Window", path: ["Nowhere"]), in: menu) == nil)
    }

    @Test func resultsMatchTitleAndMenuRecentFirstWithoutActionsTwice() {
        let commands = [
            MenuCommand(title: "Translate Page", path: ["View"]),
            MenuCommand(title: "Show Sidebar", path: ["View"]),
            MenuCommand(title: "Hide Address Bar in Sidebar", path: ["View"]),
        ]
        let byMenu = CommandRanking.menuCommandResults(for: "view side", commands: commands, recent: [])
        #expect(byMenu.map(\.title) == ["Show Sidebar", "Hide Address Bar in Sidebar"], "Matched by menu name and title")
        let recentFirst = CommandRanking.menuCommandResults(for: "side", commands: commands, recent: ["View › Hide Address Bar in Sidebar"])
        #expect(recentFirst.map(\.title) == ["Hide Address Bar in Sidebar", "Show Sidebar"])
        #expect(CommandRanking.menuCommandResults(for: "translate", commands: commands, recent: []).isEmpty,
                "Translate Page is already an action")
        #expect(CommandRanking.menuCommandResults(for: "", commands: commands, recent: []).isEmpty)
    }

    /// A fake menu for the model.
    final class FakeMenus: MenuCommandProviding {
        var ran: [MenuCommand] = []
        let items = [MenuCommand(title: "Hide Address Bar in Sidebar", path: ["View"], shortcut: "⇧⌘A")]
        func commands() -> [MenuCommand] { items }
        func run(_ command: MenuCommand) { ran.append(command) }
    }

    @Test func theCommandBarRunsAMenuCommandAndRemembersIt() async throws {
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        await model.start()
        let menus = FakeMenus()
        model.menuCommands = menus
        model.showCommandBar()
        model.setCommandQuery("address bar")
        let index = try #require(model.commandResults.firstIndex { if case .menuCommand = $0 { true } else { false } })
        #expect(model.commandResults[index].hint == "Run")
        await model.runCommand(at: index)
        #expect(menus.ran.map(\.title) == ["Hide Address Bar in Sidebar"])
        #expect(model.recentMenuCommandIDs == ["View › Hide Address Bar in Sidebar"])
        #expect(!model.isCommandBarVisible)
    }
}
#endif
