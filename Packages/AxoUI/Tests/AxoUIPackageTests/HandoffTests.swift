import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct HandoffTests {
    let store: TabStore
    let model: BrowserModel

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        await model.start()
    }

    /// A closed loopback port, so the page never loads and nothing leaves the machine.
    private let page = URL(string: "http://127.0.0.1:9/article")!

    @Test func onlyWebPagesAreOfferedAndOnlyWhenEnabled() async throws {
        #expect(model.handoffURL == nil)
        await model.openTab(url: page)
        #expect(model.handoffURL == page)

        model.isHandoffEnabled = false
        #expect(model.handoffURL == nil)
        model.isHandoffEnabled = true

        await model.openTab(url: URL(string: "data:text/html,hi")!)
        #expect(model.handoffURL == nil, "Not a web page")
    }

    @Test func pagesFromOtherDevicesOpenAsTabsIfTheyreWebPages() async throws {
        await model.continueBrowsing(URL(fileURLWithPath: "/etc/hosts"))
        #expect(model.tabs.isEmpty, "Another device can't open local files")
        await model.continueBrowsing(page)
        #expect(model.selectedTab?.url == page)
    }
}
