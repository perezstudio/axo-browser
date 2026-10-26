import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Axo's own menu for a right-click in a page, for engines that leave it to Axo (Chromium).
@MainActor
struct PageMenuTests {
    private func titles(_ entries: [PageMenuEntry]) -> [String] {
        entries.map { entry in
            if case .separator = entry.kind { return "—" }
            return entry.isEnabled ? entry.title : "(\(entry.title))"
        }
    }

    @Test func aPageGetsBackForwardAndReload() {
        let menu = FakeContextMenu()
        #expect(titles(PageMenu.entries(for: menu, canGoBack: true, canGoForward: false)) == ["Back", "(Forward)", "Reload"])
    }

    @Test func aLinkGetsLinkItems() {
        let menu = FakeContextMenu()
        menu.linkURL = URL(string: "https://example.com/next")
        #expect(titles(PageMenu.entries(for: menu, canGoBack: true, canGoForward: true)) == [
            "Open Link in New Tab", "Open Link in Peek", "Download Linked File", "Copy Link",
        ])
    }

    @Test func anImageCanBeCopiedOnlyOnceItsLoaded() {
        let menu = FakeContextMenu()
        menu.media = .image
        menu.sourceURL = URL(string: "https://example.com/photo.jpg")
        #expect(titles(PageMenu.entries(for: menu, canGoBack: false, canGoForward: false)) == [
            "Open Image in New Tab", "Download Image", "(Copy Image)", "Copy Image Address",
        ])
    }

    @Test func aSelectionCanBeLookedUpSearchedAndCopied() {
        let menu = FakeContextMenu()
        menu.selectionText = "  axolotls live in lakes and canals near Mexico City\n"
        #expect(titles(PageMenu.entries(for: menu, canGoBack: false, canGoForward: false)) == [
            "Look Up “axolotls live in lakes and can…”", "Search the Web for “axolotls live in lakes and can…”", "—", "Copy",
        ])
    }

    @Test func aTextFieldGetsSpellingAndEditing() {
        let menu = FakeContextMenu()
        menu.isEditable = true
        menu.misspelledWord = "teh"
        menu.suggestions = ["the", "tech"]
        menu.edits = [.copy, .paste, .selectAll]
        #expect(titles(PageMenu.entries(for: menu, canGoBack: false, canGoForward: false)) == [
            "the", "tech", "—", "(Cut)", "Copy", "Paste", "Paste and Match Style", "Select All",
        ])
    }

    @Test func extensionItemsComeLastAsTheExtensionGroupsThem() {
        let menu = FakeContextMenu()
        menu.extensionItems = [
            PageContextMenuItem(kind: .command, title: "Save to Notes"),
            PageContextMenuItem(kind: .submenu, title: "Password Manager", children: [
                PageContextMenuItem(kind: .command, title: "Fill Password"),
                PageContextMenuItem(kind: .checkbox, title: "Show Icons", isChecked: true),
            ]),
        ]
        let entries = PageMenu.entries(for: menu, canGoBack: false, canGoForward: false)
        #expect(titles(entries) == ["(Back)", "(Forward)", "Reload", "—", "Save to Notes", "Password Manager"])
        guard case .submenu(let children) = entries.last?.kind else {
            Issue.record("The extension's items are a submenu")
            return
        }
        #expect(children.map(\.title) == ["Fill Password", "Show Icons"])
        #expect(children.last?.isChecked == true)
    }

    // MARK: Actions

    @Test func menuActionsRunOnThePageOrOpenTabs() async throws {
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(engine: FakeEngine()))
        model.announce = { _ in }
        await model.start()
        await model.openTab(url: URL(string: "https://example.com/")!)
        let tabID = try #require(model.selectedTabID)
        let menu = FakeContextMenu()
        let item = PageContextMenuItem(kind: .command, title: "Save to Notes")

        model.perform(.edit(.copy), menu: menu, tabID: tabID)
        model.perform(.replaceMisspelling("the"), menu: menu, tabID: tabID)
        model.perform(.download(URL(string: "https://example.com/file.zip")!), menu: menu, tabID: tabID)
        model.perform(.extensionItem(item), menu: menu, tabID: tabID)
        #expect(menu.performed == ["copy", "replace the", "download https://example.com/file.zip", "item Save to Notes"])

        model.perform(.openLinkInNewTab(URL(string: "https://example.com/next")!), menu: menu, tabID: tabID)
        try await waitUntil { model.tabs.count == 2 }
        #expect(model.tabs.map(\.url.path) == ["/", "/next"], "Right after the page that was clicked")
    }

    @Test func rightClicksReachTheModelThroughThePool() async throws {
        let engine = FakeEngine()
        let pool = WebViewPool(engine: engine)
        var clicked: [Tab.ID] = []
        pool.onContextMenu = { _, tabID in
            clicked.append(tabID)
            return true
        }
        let tab = AxoCore.Tab(spaceID: UUID(), url: URL(string: "https://example.com/")!, sortKey: SortKey.initial)
        let page = try #require(pool.page(for: tab, profileID: UUID()) as? FakePage)

        #expect(page.rightClick(FakeContextMenu()))
        #expect(clicked == [tab.id])
    }

    // MARK: Side panels

    @Test func sidePanelsShowAndCloseEitherWay() async throws {
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(engine: FakeEngine()))
        var announced: [String] = []
        model.announce = { announced.append($0) }
        var closed: [String] = []
        let panel = { (id: String) in ExtensionSidePanel(id: id, title: "Notes", view: PlatformView()) { closed.append(id) } }

        model.showExtensionSidePanel(panel("notes"))
        #expect(model.extensionSidePanel?.id == "notes")
        #expect(announced == ["Notes side panel opened"])

        model.closeExtensionSidePanel()
        #expect(model.extensionSidePanel == nil)
        #expect(closed == ["notes"], "The close button closes it in the engine")

        model.showExtensionSidePanel(panel("notes"))
        model.extensionSidePanelDidClose("other")
        #expect(model.extensionSidePanel?.id == "notes", "Another extension's close doesn't touch it")
        model.extensionSidePanelDidClose("notes")
        #expect(model.extensionSidePanel == nil)
        #expect(closed == ["notes"], "The extension closed it already")
    }

    @Test func sidePanelsStayWithTheirProfile() async throws {
        let store = try TabStore.makeInMemory()
        let model = BrowserModel(store: store, pool: WebViewPool(engine: FakeEngine()))
        model.announce = { _ in }
        await model.start()
        let home = try #require(model.space)
        let work = try await store.createProfile(name: "Work")
        let workSpace = try await store.createSpace(name: "Work", profileID: work.id)
        var closed: [String] = []
        let panel = { (id: String, profileID: Profile.ID) in
            ExtensionSidePanel(id: id, title: "Notes", view: PlatformView(), profileID: profileID) { closed.append(id) }
        }

        model.showExtensionSidePanel(panel("theirs", work.id))
        #expect(model.extensionSidePanel == nil, "Another profile's panel doesn't show here")
        #expect(closed == ["theirs"])

        model.showExtensionSidePanel(panel("mine", home.profileID))
        try await waitUntil { model.spaces.contains { $0.id == workSpace.id } }
        await model.selectSpace(workSpace.id)
        #expect(model.extensionSidePanel == nil, "Switching to another profile's Space closes it")
        #expect(closed == ["theirs", "mine"])
    }
}
