import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI
#if os(macOS)
import AppKit

/// The command bar finds and runs Axo's menu items (#123).
@MainActor
struct MenuIndexTests {
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

    @Test func repeatedTitlesAreToldApartAndRunTheRightItem() throws {
        let recorder = Recorder()
        let spaces = NSMenu(title: "Spaces")
        spaces.autoenablesItems = false
        for title in ["Work", "Work", "Home"] {
            let item = NSMenuItem(title: title, action: #selector(Recorder.run(_:)), keyEquivalent: "")
            item.target = recorder
            spaces.addItem(item)
        }
        let bar = NSMenu(title: "Main")
        let top = NSMenuItem(title: "Spaces", action: nil, keyEquivalent: "")
        top.submenu = spaces
        bar.addItem(top)
        let commands = MenuIndex.commands(in: bar)
        #expect(commands.map(\.id) == ["Spaces › Work", "Spaces › Work #2", "Spaces › Home"])
        let (_, index) = try #require(MenuIndex.location(of: commands[1], in: bar))
        #expect(index == 1, "The second Work, not the first")
        #expect(commands[1].menuName == "Spaces menu")
        #expect(MenuCommand(title: "Work", path: ["Tabs", "Move to Space"]).menuName == "Tabs › Move to Space menu",
                "Submenus are named, so the same title in two submenus reads differently")
    }

    @Test func theServicesMenuIsLeftOutWhateverItsTitle() {
        let recorder = Recorder()
        let services = NSMenu(title: "Dienste")
        services.autoenablesItems = false
        let service = NSMenuItem(title: "Look Up", action: #selector(Recorder.run(_:)), keyEquivalent: "")
        service.target = recorder
        services.addItem(service)
        let app = NSMenu(title: "Axo")
        app.autoenablesItems = false
        let servicesItem = NSMenuItem(title: "Dienste", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        let bar = NSMenu(title: "Main")
        let top = NSMenuItem(title: "Axo", action: nil, keyEquivalent: "")
        top.submenu = app
        bar.addItem(top)
        let previous = NSApplication.shared.servicesMenu
        NSApplication.shared.servicesMenu = services
        defer { NSApplication.shared.servicesMenu = previous }
        #expect(MenuIndex.commands(in: bar).isEmpty)
    }

    @Test func shortcutsNameFunctionKeys() {
        let f5 = NSMenuItem(title: "F", action: nil, keyEquivalent: String(UnicodeScalar(NSF5FunctionKey)!))
        f5.keyEquivalentModifierMask = .command
        #expect(MenuIndex.shortcut(of: f5) == "⌘F5")
        // The Globe (fn) modifier can't be set here: AppKit allows it only on its own items.
    }
}
#endif

/// The command bar's menu command results and running them (#123).
@MainActor
struct MenuCommandTests {
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

    /// Menu items that do what an action does aren't offered twice, whatever their ellipsis or
    /// wording.
    @Test func menuItemsForActionsAreLeftOut() {
        let commands = ["New Space…", "Find…", "Print…", "Stack Panes", "Show Panes Side by Side", "New Folder Inside",
                        "Hide Downloads", "Rename Space…", "Import from Another Browser…"]
            .map { MenuCommand(title: $0, path: ["File"]) } + [MenuCommand(title: "Find Next", path: ["Edit"])]
        let titles = commands.flatMap { command in
            CommandRanking.menuCommandResults(for: command.title, commands: commands, recent: []).map(\.title)
        }
        #expect(Set(titles) == ["Find Next"], "Only Find Next isn't an action")
    }

    /// A fake menu for the model.
    final class FakeMenus: MenuCommandProviding {
        var ran: [MenuCommand] = []
        var indexed = 0
        var isAvailable = true
        let items = [MenuCommand(title: "Hide Address Bar in Sidebar", path: ["View"], shortcut: "⇧⌘A")]
        func commands() -> [MenuCommand] { indexed += 1; return items }
        func run(_ command: MenuCommand) -> Bool {
            guard isAvailable else { return false }
            ran.append(command)
            return true
        }
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

    /// The menus are read on the first letter typed, not each time the bar opens.
    @Test func theMenusAreIndexedOnlyOnceTypingStarts() async throws {
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        await model.start()
        let menus = FakeMenus()
        model.menuCommands = menus
        model.showCommandBar()
        #expect(menus.indexed == 0)
        model.setCommandQuery("a")
        model.setCommandQuery("ad")
        #expect(menus.indexed == 1, "Once per opening")
        model.hideCommandBar()
        model.showCommandBar()
        model.setCommandQuery("a")
        #expect(menus.indexed == 2, "Read again for the next opening")
    }

    /// An item gone or disabled since the bar opened says so, rather than doing nothing silently.
    @Test func aMenuCommandNoLongerAvailableSaysSo() async throws {
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        var announced: [String] = []
        model.announce = { announced.append($0) }
        await model.start()
        let menus = FakeMenus()
        model.menuCommands = menus
        model.showCommandBar()
        model.setCommandQuery("address bar")
        let index = try #require(model.commandResults.firstIndex { if case .menuCommand = $0 { true } else { false } })
        menus.isAvailable = false
        await model.runCommand(at: index)
        #expect(model.notice?.message == "“Hide Address Bar in Sidebar” isn't available now.")
        #expect(announced.contains("“Hide Address Bar in Sidebar” isn't available now."))
    }
}
