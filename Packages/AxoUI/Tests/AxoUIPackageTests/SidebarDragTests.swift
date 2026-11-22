#if os(macOS)
import AppKit
#endif
import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AxoUI
@testable import AxoWeb

/// Dragging rows between Pinned, folders, the tabs section, and Favorites (#77): where each drop
/// lands, what it pins or unpins, and that one row changes per row moved.
@MainActor
struct SidebarDragTests {
    let engine = FakeEngine()
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        await model.start()
    }

    private func tab(_ name: String, pinned: Bool = false) async throws -> AxoCore.Tab {
        await model.openTab(url: URL(string: "https://\(name).example/")!)
        let tab = try #require(model.tabs.last)
        if pinned { await model.setPinned(true, tabID: tab.id) }
        return tab
    }

    private func name(_ tab: AxoCore.Tab) -> String { tab.url.host()!.replacingOccurrences(of: ".example", with: "") }

    /// The pinned section as nested names.
    private func describe(_ nodes: [PinnedNode]) -> [String] {
        nodes.map { node in
            switch node {
            case .tab(let tab): name(tab)
            case .folder(let folder, let children): "\(folder.name)[\(describe(children).joined(separator: ", "))]"
            }
        }
    }

    private var unpinned: [String] { model.unpinnedTabs.map(name) }

    @Test func aDropLandsBeforeTheFirstRowAtItsPointThatIsntMoving() {
        let a = PinnedItem.tab(UUID()), b = PinnedItem.tab(UUID()), c = PinnedItem.tab(UUID())
        #expect(SidebarDrop.target(before: 0, in: [a, b, c], moving: []) == a)
        #expect(SidebarDrop.target(before: 3, in: [a, b, c], moving: []) == nil, "The end")
        #expect(SidebarDrop.target(before: 1, in: [a, b, c], moving: [b]) == c, "Dropped on its own place: stays")
        #expect(SidebarDrop.target(before: 2, in: [a, b, c], moving: [b, c]) == nil)
        #expect(SidebarDrop.target(before: -1, in: [a, b, c], moving: []) == nil)
    }

    @Test func aDropFromElsewhereMovesRowsAndFavoritesButNothingElse() async throws {
        let a = try await tab("a"), b = try await tab("b", pinned: true)
        await model.receiveSidebarDrop(SidebarDragPayload.text(for: .tab(a.id)), to: .pinned(nil), before: .tab(b.id))
        #expect(describe(model.pinnedTree) == ["a", "b"], "A row from the tabs section, pinned before b")

        let c = try await tab("c")
        await model.addToFavorites(c.id)
        await model.receiveSidebarDrop(SidebarDragPayload.text(forFavorite: c.id), to: .tabs, before: nil)
        #expect(model.unpinnedTabs.map(name) == ["c"], "A favorite's tile becomes a tab there")

        await model.receiveSidebarDrop("https://example.com", to: .tabs, before: nil)
        await model.receiveSidebarDrop("favorite:\(UUID().uuidString)", to: .tabs, before: nil)
        await model.receiveSidebarDrop(UUID().uuidString, to: .tabs, before: nil)
        #expect(model.unpinnedTabs.map(name) == ["c"] && describe(model.pinnedTree) == ["a", "b"], "Other text does nothing")
    }

    @Test func aTabDroppedInPinnedIsPinnedAtTheDropPoint() async throws {
        let a = try await tab("a", pinned: true)
        _ = try await tab("b", pinned: true)
        let c = try await tab("c")
        let sortKeysBefore = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.sortKey) })

        await model.moveSidebarItems([.tab(c.id)], to: .pinned(nil), before: .tab(a.id))
        #expect(describe(model.pinnedTree) == ["c", "a", "b"])
        #expect(model.tabs.first { $0.id == c.id }?.isPinned == true)
        let changed = model.tabs.filter { sortKeysBefore[$0.id] != $0.sortKey }.map(\.id)
        #expect(changed == [c.id], "One row changes per row moved")
    }

    @Test func aPinnedTabDroppedInTheTabsSectionIsUnpinnedThere() async throws {
        let pinned = try await tab("pinned", pinned: true)
        let x = try await tab("x")
        _ = try await tab("y")

        await model.moveSidebarItems([.tab(pinned.id)], to: .tabs, before: .tab(x.id))
        #expect(unpinned == ["pinned", "x", "y"])
        #expect(model.pinnedTree.isEmpty)
        #expect(model.tabs.first { $0.id == pinned.id }?.homeURL == nil)

        // At the end, with no row under the drop.
        let other = try await tab("other", pinned: true)
        await model.moveSidebarItems([.tab(other.id)], to: .tabs, before: nil)
        #expect(unpinned.last == "other")
    }

    @Test func dropsIntoAFolderLandAmongItsRows() async throws {
        let a = try await tab("a", pinned: true)
        let b = try await tab("b", pinned: true)
        let loose = try await tab("loose")
        await model.createFolder(named: "Work", moving: .tab(a.id))
        await model.move(.tab(b.id), toFolder: try #require(model.folders.first?.id))
        let work = try #require(model.folders.first)
        #expect(describe(model.pinnedTree) == ["Work[a, b]"])

        await model.moveSidebarItems([.tab(loose.id)], to: .pinned(work.id), before: .tab(b.id))
        #expect(describe(model.pinnedTree) == ["Work[a, loose, b]"])
        await model.moveSidebarItems([.tab(a.id)], to: .pinned(nil), before: nil)
        #expect(describe(model.pinnedTree) == ["Work[loose, b]", "a"])
    }

    @Test func foldersMoveBetweenLevelsButNeverIntoThemselvesOrTheTabsSection() async throws {
        let a = try await tab("a", pinned: true)
        await model.createFolder(named: "Outer", moving: .tab(a.id))
        let outer = try #require(model.folders.first { $0.name == "Outer" })
        await model.createFolder(named: "Inner", parent: outer.id)
        let inner = try #require(model.folders.first { $0.name == "Inner" })
        await model.createFolder(named: "Other")
        let other = try #require(model.folders.first { $0.name == "Other" })
        let before = describe(model.pinnedTree)

        await model.moveSidebarItems([.folder(outer.id)], to: .pinned(inner.id), before: nil)
        #expect(describe(model.pinnedTree) == before, "Not into a folder inside it")
        await model.moveSidebarItems([.folder(outer.id)], to: .tabs, before: nil)
        #expect(describe(model.pinnedTree) == before, "Folders stay in Pinned")

        await model.moveSidebarItems([.folder(other.id)], to: .pinned(outer.id), before: nil)
        #expect(describe(model.pinnedTree) == ["Outer[a, Inner[], Other[]]"])
    }

    @Test func aSplitMovesAsOneKeepingItsOrder() async throws {
        let left = try await tab("left")
        let right = try await tab("right")
        _ = try await tab("after")
        model.select(left.id)
        await model.addToSplit(right.id)
        try #require(model.split(of: left.id) != nil)
        let rowTab = model.sidebarRowTab(for: left.id)
        let others = model.tabs.filter { model.split(of: $0.id) == nil }.map(\.id)
        let sortKeysBefore = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.sortKey) })

        await model.moveSidebarItems([.tab(rowTab)], to: .pinned(nil), before: nil)
        #expect(model.tabs.first { $0.id == left.id }?.isPinned == true)
        #expect(model.tabs.first { $0.id == right.id }?.isPinned == true, "Its other pane goes with it")
        #expect(model.sidebarRowTab(for: left.id) == rowTab, "The same pane still stands for the row")
        #expect(model.pinnedTabs.map(name) == ["left", "right"], "The panes keep their order")
        #expect(unpinned == ["after"])
        let changed = model.tabs.filter { sortKeysBefore[$0.id] != $0.sortKey }.map(\.id)
        #expect(!changed.contains { others.contains($0) }, "Only the split's panes change")
    }

    @Test func aDropAfterASplitsRowNeverLandsBetweenItsPanes() async throws {
        let left = try await tab("left", pinned: true)
        let right = try await tab("right", pinned: true)
        let other = try await tab("other")
        model.select(left.id)
        await model.addToSplit(right.id)
        try #require(model.split(of: left.id) != nil)
        try #require(model.pinnedTabs.map(name) == ["left", "right"])

        await model.moveSidebarItems([.tab(other.id)], to: .pinned(nil), before: nil)
        #expect(model.pinnedTabs.map(name) == ["left", "right", "other"])
    }

    @Test func foldersMixedIntoADragToTheTabsSectionStayPinned() async throws {
        let pinned = try await tab("pinned", pinned: true)
        await model.createFolder(named: "Work")
        let work = try #require(model.folders.first)
        _ = try await tab("x")
        await model.moveSidebarItems([.folder(work.id), .tab(pinned.id)], to: .tabs, before: nil)
        #expect(unpinned == ["x", "pinned"])
        #expect(describe(model.pinnedTree) == ["Work[]"])
    }

    @Test func aFavoriteDroppedInTheSidebarBecomesATabThereKeepingItsID() async throws {
        let fav = try await tab("fav")
        await model.addToFavorites(fav.id)
        try #require(model.favorites.contains { $0.id == fav.id })
        let x = try await tab("x")

        await model.moveFavoriteToSidebar(fav.id, to: .tabs, before: .tab(x.id))
        #expect(!model.favorites.contains { $0.id == fav.id })
        #expect(unpinned == ["fav", "x"], "In the tabs section, at the drop point")
        #expect(model.tabs.first { $0.id == fav.id }?.isPinned == false)

        await model.addToFavorites(fav.id)
        let pinned = try await tab("pinned", pinned: true)
        await model.moveFavoriteToSidebar(fav.id, to: .pinned(nil), before: .tab(pinned.id))
        #expect(describe(model.pinnedTree) == ["fav", "pinned"])

        // Into a folder.
        await model.addToFavorites(fav.id)
        await model.createFolder(named: "Work")
        let work = try #require(model.folders.first)
        await model.moveFavoriteToSidebar(fav.id, to: .pinned(work.id), before: nil)
        #expect(describe(model.pinnedTree) == ["pinned", "Work[fav]"])
    }

    @Test func aRowDroppedOnFavoritesBecomesAFavoriteThere() async throws {
        let first = try await tab("first")
        await model.addToFavorites(first.id)
        let second = try await tab("second")
        await model.addToFavorites(second.id)
        let dragged = try await tab("dragged")

        await model.dropTabOnFavorites(dragged.id, before: second.id)
        try await waitUntil { model.favorites.map(\.id) == [first.id, dragged.id, second.id] }
        #expect(!model.tabs.contains { $0.id == dragged.id })

        // On the grid itself, not a tile: at the end.
        let last = try await tab("last")
        await model.dropTabOnFavorites(last.id, before: nil)
        try await waitUntil { model.favorites.map(\.id).last == last.id }
    }

    @Test func aSplitsRowDoesntBecomeAFavoriteByDrag() async throws {
        let left = try await tab("left")
        let right = try await tab("right")
        model.select(left.id)
        await model.addToSplit(right.id)
        await model.dropTabOnFavorites(left.id, before: nil)
        #expect(model.favorites.isEmpty)
        #expect(model.split(of: left.id) != nil, "The split stays whole")
    }

    // MARK: Dragging to other apps (#78)

    /// The type identifiers a drag's provider offers, and what it gives for each.
    private func registered(_ provider: NSItemProvider) -> [String] { provider.registeredTypeIdentifiers }

    @Test func aRowsDragCarriesItsIDFirstAndItsAddressForOtherApps() async throws {
        let id = UUID()
        let provider = SidebarDragPayload.provider(for: SidebarDragPayload.text(for: .tab(id)),
                                                   address: URL(string: "https://example.com/page")!)
        let types = registered(provider)
        #expect(types == [UTType.utf8PlainText.identifier, UTType.url.identifier],
                "The ID first, as text (never as a URL), for Axo's drop targets; then a URL for other apps")

        // What Axo's drop targets read (`String`): the ID, never the address.
        let text: String = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: String.self) { continuation.resume(with: $0) }
        }
        #expect(text == "tab:\(id.uuidString)")
        let url: URL? = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (object as? NSURL) as URL?) }
            }
        }
        #expect(url == URL(string: "https://example.com/page"))
    }

    @Test func aFavoritesDragExportsItsIDAsTextAndItsAddressAsAURL() async throws {
        let id = UUID()
        let drag = FavoriteDrag(text: SidebarDragPayload.text(forFavorite: id), address: URL(string: "https://example.com/")!)
        #expect(try await drag.exported(as: .utf8PlainText) == Data("favorite:\(id.uuidString)".utf8))
        let url = try await drag.exported(as: .url)
        #expect(URL(dataRepresentation: url, relativeTo: nil) == URL(string: "https://example.com/")
                || String(decoding: url, as: UTF8.self) == "https://example.com/")
        // As a drag registers it: the ID first, and no URL without an address (the placeholder
        // never goes out). `exported(as:)` alone ignores the condition.
        let withAddress = NSItemProvider()
        withAddress.register(drag)
        #expect(withAddress.registeredTypeIdentifiers == [UTType.utf8PlainText.identifier, UTType.url.identifier])
        let withoutAddress = NSItemProvider()
        withoutAddress.register(FavoriteDrag(text: "favorite:\(id.uuidString)", address: nil))
        #expect(withoutAddress.registeredTypeIdentifiers == [UTType.utf8PlainText.identifier])
    }

    @Test func onlyAddressesOtherAppsCanUseAreOffered() {
        func offered(_ string: String) -> Bool {
            SidebarDragPayload.addressForOtherApps(URL(string: string)) != nil
        }
        #expect(offered("https://example.com/") && offered("http://example.com/") && offered("HTTPS://example.com/"))
        let atLimit = "data:text/html," + String(repeating: "a", count: SidebarDragPayload.maxDataAddressLength - 15)
        #expect(atLimit.count == SidebarDragPayload.maxDataAddressLength && offered(atLimit), "Exactly at the limit")
        #expect(offered("data:text/html,<title>Hi</title>"), "A short data: address")
        #expect(!offered("data:text/html," + String(repeating: "a", count: SidebarDragPayload.maxDataAddressLength)),
                "A long data: address (it can hold a whole file)")
        #expect(!offered("file:///Users/someone/page.html"), "Finder would copy the file")
        #expect(!offered("about:blank") && !offered("chrome-extension://abc/popup.html"))
        #expect(SidebarDragPayload.addressForOtherApps(URL(string: "https://me:secret@example.com/a?b=1"))
                == URL(string: "https://example.com/a?b=1"), "No user name or password")
        #expect(SidebarDragPayload.addressForOtherApps(nil) == nil)

        // A folder, or a page with no address other apps can use, drags only its ID.
        let folder = SidebarDragPayload.provider(for: SidebarDragPayload.text(for: .folder(UUID())), address: nil)
        #expect(registered(folder) == [UTType.utf8PlainText.identifier], "Never the ID as a URL")
        let file = SidebarDragPayload.provider(for: SidebarDragPayload.text(for: .tab(UUID())),
                                               address: URL(fileURLWithPath: "/tmp/page.html"))
        #expect(registered(file) == [UTType.utf8PlainText.identifier])
    }

    @Test func aTabDragsTheAddressItsPageIsOn() async throws {
        let a = try await tab("a")
        #expect(model.dragAddress(for: a.id) == URL(string: "https://a.example/"))
        let page = try #require(engine.pages.last)
        page.navigate(to: URL(string: "https://a.example/elsewhere")!, title: "Elsewhere")
        #expect(model.dragAddress(for: a.id) == URL(string: "https://a.example/elsewhere"), "Where its page is now")
        #expect(model.dragAddress(for: UUID()) == nil)
        page.navigate(to: URL(string: "about:blank")!, title: "")
        #expect(model.dragAddress(for: a.id) == URL(string: "https://a.example/"), "Still on about:blank: its record's")

        let b = try await tab("b")
        await model.addToFavorites(b.id)
        let favoritePage = try #require(engine.pages.last)
        favoritePage.navigate(to: URL(string: "https://b.example/away")!, title: "Away")
        #expect(model.dragAddress(for: b.id) == URL(string: "https://b.example/away"), "A favorite's page, where it is")
        let favorite = try #require(model.favorites.first { $0.id == b.id })
        #expect(model.dragAddress(forFavorite: favorite) == URL(string: "https://b.example/away"))
        model.closeFavorite(b.id)
        #expect(model.dragAddress(for: b.id) == URL(string: "https://b.example/"), "With no page, its record's")
        #expect(model.dragAddress(forFavorite: favorite) == URL(string: "https://b.example/"))
    }

    #if os(macOS)
    // MARK: Drops on the page (#78)

    /// A drag over the page, as AppKit hands one to a drop target.
    @MainActor
    private final class Drag: NSObject, @MainActor NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingLocation: NSPoint

        init(text: String?, x: CGFloat) {
            // A pasteboard of the test's own, never the person's clipboard.
            draggingPasteboard = NSPasteboard.withUniqueName()
            draggingPasteboard.clearContents()
            if let text { draggingPasteboard.setString(text, forType: .string) }
            draggingLocation = NSPoint(x: x, y: 50)
        }

        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .every }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// A page under the catcher: it takes text drags and records the calls that reach it.
    private final class StandInPage: NSView {
        var calls: [String] = []
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.string])
        }
        required init?(coder: NSCoder) { nil }
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { calls.append("entered"); return .copy }
        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { calls.append("perform"); return true }
        override func draggingEnded(_ sender: any NSDraggingInfo) { calls.append("ended") }
    }

    @Test func thePageKeepsEveryDragFromTheSidebarAndSplitsOnlyAtItsEdges() async throws {
        let a = try await tab("a"), b = try await tab("b")
        #expect(model.selectedTabID == b.id)
        // Over a stand-in page that takes text drags and records what reaches it.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let page = StandInPage(frame: content.bounds)
        let catcher = PageSplitDrop.CatcherView(frame: content.bounds)
        content.addSubview(page)
        content.addSubview(catcher)
        catcher.model = model
        var sides: [PageSplitDropSide?] = []
        catcher.onSideChange = { sides.append($0) }
        #expect(catcher.registeredDraggedTypes == [.string])

        let row = SidebarDragPayload.text(for: .tab(a.id))
        for (text, x, what) in [(row, CGFloat(150), "the middle third"),
                                (SidebarDragPayload.text(for: .tab(b.id)), 10, "the selected tab"),
                                (SidebarDragPayload.text(for: .folder(UUID())), 10, "a folder"),
                                (SidebarDragPayload.text(forFavorite: UUID()), 10, "a favorite")] {
            #expect(catcher.draggingEntered(Drag(text: text, x: x)) == [], "Kept, and nothing: \(what)")
            #expect(!catcher.performDragOperation(Drag(text: text, x: x)))
            catcher.draggingEnded(Drag(text: text, x: x))
        }
        #expect(page.calls.isEmpty, "The page never gets a drag from the sidebar or Favorites")

        // Other drags (a link, text) go to the page, call for call.
        let link = Drag(text: "https://example.com/", x: 10)
        #expect(catcher.draggingEntered(link) == .copy)
        #expect(catcher.performDragOperation(link))
        catcher.draggingEnded(link)
        #expect(page.calls == ["entered", "perform", "ended"])

        #expect(catcher.draggingEntered(Drag(text: row, x: 10)) == .move)
        #expect(sides.last == .leading)
        #expect(catcher.performDragOperation(Drag(text: row, x: 10)))
        try await waitUntil { model.split(of: a.id) != nil }
        #expect(sides.last == .some(nil), "The highlight goes on the drop")
    }

    @Test func aFavoritesPageCatchesSidebarDragsButMakesNoSplit() async throws {
        let a = try await tab("a")
        #expect(model.catchesSidebarDragsOnPage, "A tab's page")
        let b = try await tab("b")
        await model.addToFavorites(b.id)
        model.select(b.id)
        try await waitUntil { model.shownTab?.id == b.id && model.selectedTab == nil }
        #expect(model.catchesSidebarDragsOnPage,
                "A favorite's page too, so a row dropped on it never loads its address there")
        #expect(model.tabToSplit(droppedAs: SidebarDragPayload.text(for: .tab(a.id))) == nil)
    }
    #endif
}
