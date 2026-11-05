import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// The sidebar's address bar: clicking it (or ⌘L) edits the shown page's address in the command
/// bar, which loads in the same tab, and Copy Link copies it.
@MainActor
struct AddressBarModelTests {
    let engine = FakeEngine()
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        await model.start()
    }

    private func openPage(_ url: URL) async throws -> (AxoCore.Tab.ID, FakePage) {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        page.navigate(to: url, title: "Page")
        return (id, page)
    }

    @Test func editingTheAddressStartsWithTheFullURLSelected() async throws {
        let url = URL(string: "https://www.example.com/path?query=1")!
        let (id, _) = try await openPage(url)
        let selections = model.commandQuerySelectionRequest

        model.editAddress()
        #expect(model.isCommandBarVisible)
        #expect(model.commandQuery == url.absoluteString)
        #expect(model.commandBarEditedTabID == id)
        #expect(model.commandQuerySelectionRequest == selections + 1, "Selected, so typing replaces it")
    }

    @Test func returnLoadsTheEditedAddressInTheSameTab() async throws {
        let (id, page) = try await openPage(URL(string: "https://example.com/")!)
        let tabCount = model.tabs.count

        model.editAddress()
        model.setCommandQuery("example.org")
        await model.runCommand()
        #expect(page.loads.last == URL(string: "https://example.org"))
        #expect(model.selectedTabID == id)
        #expect(model.tabs.count == tabCount, "No new tab")
        #expect(!model.isCommandBarVisible)
        #expect(model.commandBarEditedTabID == nil)
    }

    @Test func returnOnTheUnchangedAddressJustCloses() async throws {
        let url = URL(string: "https://example.com/")!
        let (_, page) = try await openPage(url)
        let loads = page.loads.count

        model.editAddress()
        await model.runCommand()
        #expect(page.loads.count == loads, "Nothing reloads")
        #expect(!model.isCommandBarVisible)
    }

    @Test func aSearchFromTheEditedAddressLoadsInTheTab() async throws {
        let (_, page) = try await openPage(URL(string: "https://example.com/")!)
        model.editAddress()
        model.setCommandQuery("axolotl facts")
        await model.runCommand()
        #expect(page.loads.last == AddressInput.searchURL(for: "axolotl facts"))
    }

    @Test func aNewTabStillOpensATab() async throws {
        _ = try await openPage(URL(string: "https://example.com/")!)
        model.editAddress()
        model.showCommandBar() // ⌘T while editing: a new tab's command bar
        #expect(model.commandBarEditedTabID == nil)
        #expect(model.commandQuery.isEmpty)
        let tabCount = model.tabs.count
        model.setCommandQuery("example.org")
        await model.runCommand()
        #expect(model.tabs.count == tabCount + 1)
    }

    @Test func withNoPageEditingOpensAnEmptyCommandBar() async throws {
        model.editAddress()
        #expect(model.isCommandBarVisible)
        #expect(model.commandQuery.isEmpty)
        #expect(model.commandBarEditedTabID == nil)
    }

    @Test func copyLinkCopiesTheShownAddressAndSaysSo() async throws {
        var copied: [URL] = []
        var said: [String] = []
        model.copyLink = { copied.append($0) }
        model.announce = { said.append($0) }
        model.copyShownPageLink()
        #expect(copied.isEmpty, "No page, nothing to copy")

        let url = URL(string: "https://example.com/a?b=c")!
        _ = try await openPage(url)
        model.copyShownPageLink()
        #expect(copied == [url])
        #expect(said.last == "Link copied")
    }

    @Test func hidingTheAddressBarAsksTheWindowsForAValue() {
        let before = model.sidebarAddressBarRequest.count
        model.setSidebarAddressBarShown(false)
        #expect(model.sidebarAddressBarRequest.count == before + 1)
        #expect(model.sidebarAddressBarRequest.shown == false, "A value, not a toggle, so two windows agree")
    }

    @Test func switchingTabsWhileEditingClosesTheBar() async throws {
        let (first, firstPage) = try await openPage(URL(string: "https://example.com/")!)
        _ = try await openPage(URL(string: "https://example.org/")!)
        model.select(first)
        model.editAddress()
        let loads = firstPage.loads.count

        let other = try #require(model.tabs.first { $0.id != first }?.id)
        model.select(other)
        #expect(!model.isCommandBarVisible, "Return mustn't load into the tab left behind")
        #expect(firstPage.loads.count == loads)
    }

    @Test func closingTheEditedTabClosesTheBar() async throws {
        let (id, _) = try await openPage(URL(string: "https://example.com/")!)
        _ = try await openPage(URL(string: "https://example.org/")!)
        model.select(id)
        model.editAddress()
        model.setCommandQuery("example.net")

        await model.closeTab(id)
        #expect(!model.isCommandBarVisible, "What was typed can't load into a tab that's gone")
        #expect(model.commandBarEditedTabID == nil)
    }

    @Test func editingClosesPeekAndForgetsAPendingSplit() async throws {
        let (id, _) = try await openPage(URL(string: "https://example.com/")!)
        model.openPeek(URL(string: "https://example.org/peek")!, from: id)
        #expect(model.peek != nil)
        model.editAddress()
        #expect(model.peek == nil)
        #expect(model.pendingSplitAnchor == nil)
        #expect(model.commandBarEditedTabID == id)
    }

    @Test func copyLinkCopiesPeeksPageWhileItsOpen() async throws {
        var copied: [URL] = []
        model.copyLink = { copied.append($0) }
        let (id, _) = try await openPage(URL(string: "https://example.com/")!)
        let peekURL = URL(string: "https://example.org/peek")!
        model.openPeek(peekURL, from: id)
        model.copyShownPageLink()
        #expect(copied == [peekURL])
    }
}
