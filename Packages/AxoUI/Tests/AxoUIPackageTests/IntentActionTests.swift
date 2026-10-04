import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct IntentActionTests {
    let store: TabStore
    let model: BrowserModel
    let windowShown = Counter()

    final class Counter { var count = 0 }

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        let windowShown = windowShown
        model.showBrowserWindow = { windowShown.count += 1 }
        await model.start()
        await model.createSpace(name: "Work")
        await model.selectSpace(try #require(model.spaces.first).id)
    }

    private var work: Space { model.spaces.first { $0.name == "Work" }! }
    /// A closed loopback port, so nothing loads and nothing leaves the machine.
    private let page = URL(string: "http://127.0.0.1:9/page")!

    @Test func showingASpaceSwitchesAndBringsTheWindowForward() async throws {
        #expect(await model.showSpaceForIntent(work.id))
        #expect(model.space?.id == work.id)
        #expect(windowShown.count == 1)
        #expect(await model.showSpaceForIntent(UUID()) == false)
    }

    @Test func openingAPageUsesTheChosenSpace() async throws {
        await model.openForIntent(page, in: work.id)
        #expect(model.space?.id == work.id)
        #expect(model.selectedTab?.url == page)
        await model.openForIntent(page, in: nil)
        #expect(model.tabs.count == 2, "Without a Space, the current one")
    }

    @Test func showingATabSwitchesToItsSpace() async throws {
        let tab = try await store.openTab(url: page, title: "Report", in: work.id)
        #expect(await model.showTabForIntent(tab.id))
        #expect(model.space?.id == work.id && model.selectedTabID == tab.id)
        #expect(await model.showTabForIntent(UUID()) == false)
    }

    @Test func savingCopiesTheCurrentTabIntoASpace() async throws {
        await model.openTab(url: page)
        let saved = try await model.saveCurrentTab(to: work.id, pinned: true)
        #expect(saved.spaceID == work.id && saved.isPinned && saved.homeURL == page)
        #expect(model.tabs.count == 1, "The original stays")
    }
}
