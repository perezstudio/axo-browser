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

    private let page = URL(string: "https://example.com/article")!

    /// Each case follows the Page context menu board's items and order (#173), ending with
    /// Inspect Element.
    @Test func aPageGetsNavigationItsToolsCopyLinkAndShare() {
        let menu = FakeContextMenu()
        menu.canInspectElement = true
        let context = PageMenuContext(canGoBack: true, pageURL: page, canTranslate: true, canSummarize: true)
        let entries = PageMenu.entries(for: menu, context: context)
        #expect(titles(entries) == [
            "Back", "(Forward)", "Reload Page", "—", "Translate Page", "Summarize Page", "—",
            "Copy Link", "Share", "—", "Inspect Element",
        ])
        #expect(entries.first?.shortcut == .command("["))
        #expect(entries.first { $0.title == "Reload Page" }?.shortcut == .command("r"))
        #expect(entries.first { $0.title == "Copy Link" }?.shortcut == .command("c", shift: true))
        #expect(entries.last?.shortcut == .command("i", option: true))
        guard case .share(.url(let shared)) = entries.first(where: { $0.title == "Share" })?.kind else {
            Issue.record("Share shares the page")
            return
        }
        #expect(shared == page)
    }

    @Test func aPageWithoutTheModelOrAWebAddressLeavesThoseOut() {
        let menu = FakeContextMenu()
        let context = PageMenuContext(isTranslated: true, canSummarize: nil)
        #expect(titles(PageMenu.entries(for: menu, context: context)) == [
            "(Back)", "(Forward)", "Reload Page", "—", "Show Original Page", "—", "(Inspect Element)",
        ], "A translated page offers the original; no summary without the model; no link without an address")
    }

    @Test func aLinkOpensFourWaysThenSavesCopiesAndShares() {
        let menu = FakeContextMenu()
        menu.linkURL = URL(string: "https://example.com/next")
        menu.canInspectElement = true
        #expect(titles(PageMenu.entries(for: menu, context: PageMenuContext(canGoBack: true, pageURL: page, canOpenInSplit: true))) == [
            "Open Link in New Tab", "Open Link in Peek", "Open Link in Split View", "—",
            "Download Linked File", "Copy Link", "Share", "—", "Inspect Element",
        ])
        #expect(titles(PageMenu.entries(for: menu, context: PageMenuContext())).contains("(Open Link in Split View)"),
                "Not from a page that can't split")
    }

    @Test func anImageCanBeCopiedOnlyOnceItsLoaded() {
        let menu = FakeContextMenu()
        menu.media = .image
        menu.sourceURL = URL(string: "https://example.com/photo.jpg")
        #expect(titles(PageMenu.entries(for: menu, context: PageMenuContext())) == [
            "Open Image in New Tab", "Open Image in Peek", "—",
            "Download Image", "(Copy Image)", "Copy Image Address", "Share", "—", "(Inspect Element)",
        ])
    }

    @Test func aLinkedImageGetsBothAndSharesTheLink() {
        let menu = FakeContextMenu()
        menu.linkURL = URL(string: "https://example.com/next")
        menu.media = .image
        menu.sourceURL = URL(string: "https://example.com/photo.jpg")
        menu.hasImageContents = true
        let entries = PageMenu.entries(for: menu, context: PageMenuContext(canOpenInSplit: true))
        #expect(titles(entries) == [
            "Open Link in New Tab", "Open Link in Peek", "Open Link in Split View", "Open Image in New Tab", "Open Image in Peek", "—",
            "Download Linked File", "Copy Link", "Download Image", "Copy Image", "Copy Image Address", "Share", "—", "(Inspect Element)",
        ])
        guard case .share(.url(let shared)) = entries.first(where: { $0.title == "Share" })?.kind else {
            Issue.record("Share shares the link")
            return
        }
        #expect(shared == menu.linkURL)
    }

    @Test func aSelectionCanBeLookedUpSearchedCopiedSharedAndSpoken() {
        let menu = FakeContextMenu()
        menu.selectionText = "  axolotls live in lakes and canals near Mexico City\n"
        let entries = PageMenu.entries(for: menu, context: PageMenuContext(searchEngineName: "DuckDuckGo"))
        #expect(titles(entries) == [
            "Look Up “axolotls live in lakes and can…”", "Search with DuckDuckGo", "—",
            "Copy", "Share", "Speech", "—", "(Inspect Element)",
        ])
        guard case .submenu(let speech) = entries.first(where: { $0.title == "Speech" })?.kind else {
            Issue.record("Speech is a submenu")
            return
        }
        #expect(titles(speech) == ["Start Speaking", "(Stop Speaking)"])
        guard case .submenu(let speaking) = PageMenu.entries(for: menu, context: PageMenuContext(isSpeaking: true))
            .first(where: { $0.title == "Speech" })?.kind else { return }
        #expect(titles(speaking) == ["(Start Speaking)", "Stop Speaking"])
        guard case .share(.text(let text)) = entries.first(where: { $0.title == "Share" })?.kind else {
            Issue.record("Share shares the selection")
            return
        }
        #expect(text == "axolotls live in lakes and canals near Mexico City")
    }

    @Test func aTextFieldGetsSpellingAndEditing() {
        let menu = FakeContextMenu()
        menu.isEditable = true
        menu.misspelledWord = "teh"
        menu.suggestions = ["the", "tech"]
        menu.edits = [.copy, .paste, .selectAll]
        let entries = PageMenu.entries(for: menu, context: PageMenuContext())
        #expect(titles(entries) == [
            "the", "tech", "—", "(Cut)", "Copy", "Paste", "Paste and Match Style", "—", "(Inspect Element)",
        ])
        #expect(entries.first { $0.title == "Paste and Match Style" }?.shortcut == .command("v", shift: true, option: true))
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
        let entries = PageMenu.entries(for: menu, context: PageMenuContext())
        #expect(titles(entries).suffix(4) == ["—", "(Inspect Element)", "—", "Save to Notes", "Password Manager"].suffix(4))
        #expect(titles(entries).last == "Password Manager")
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

    /// Open Link in Split View makes a split of the page and the link (#173).
    @Test func openLinkInSplitViewMakesASplitWithTheLink() async throws {
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(engine: FakeEngine()))
        model.announce = { _ in }
        await model.start()
        await model.openTab(url: URL(string: "https://example.com/")!)
        let tabID = try #require(model.selectedTabID)
        #expect(model.pageMenuContext(for: tabID).canOpenInSplit)

        model.perform(.openLinkInSplit(URL(string: "https://example.com/next")!), menu: FakeContextMenu(), tabID: tabID)
        try await waitUntil { model.split(of: tabID) != nil }
        let split = try #require(model.split(of: tabID))
        #expect(model.panes(of: split.id).map(\.url.path) == ["/", "/next"])
        #expect(!model.pageMenuContext(for: UUID()).canOpenInSplit, "Only from one of the Space's tabs")
    }

    @Test func speechImagesPeekAndInspectRunFromTheMenu() async throws {
        let model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(engine: FakeEngine()))
        model.announce = { _ in }
        let speech = FakeSpeech()
        model.selectionSpeech = speech
        await model.start()
        await model.openTab(url: URL(string: "https://example.com/")!)
        let tabID = try #require(model.selectedTabID)
        let menu = FakeContextMenu()

        model.perform(.startSpeaking("Hello"), menu: menu, tabID: tabID)
        #expect(speech.spoken == ["Hello"])
        #expect(model.pageMenuContext(for: tabID).isSpeaking)
        model.perform(.stopSpeaking, menu: menu, tabID: tabID)
        #expect(!model.pageMenuContext(for: tabID).isSpeaking)

        model.perform(.inspectElement, menu: menu, tabID: tabID)
        #expect(menu.performed == ["inspect"])

        model.perform(.openImageInPeek(URL(string: "https://example.com/photo.jpg")!), menu: menu, tabID: tabID)
        #expect(model.peekURL?.lastPathComponent == "photo.jpg")
        #expect(model.pageMenuContext(for: tabID).pageURL == nil || model.pageMenuContext(for: tabID).pageURL?.host() == "example.com")
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

/// Records speech instead of speaking.
@MainActor
final class FakeSpeech: SelectionSpeaking {
    var spoken: [String] = []
    var isSpeaking = false
    func speak(_ text: String) { spoken.append(text); isSpeaking = true }
    func stop() { isSpeaking = false }
}
