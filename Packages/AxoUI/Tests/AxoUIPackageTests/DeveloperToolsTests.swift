import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
final class FakeDeveloperTools: DeveloperToolsProviding {
    var available = true
    var toggled: [AxoCore.Tab.ID] = []
    var consoles: [AxoCore.Tab.ID] = []

    func toggleInspector(for tabID: AxoCore.Tab.ID) -> Bool { toggled.append(tabID); return available }
    func showConsole(for tabID: AxoCore.Tab.ID) -> Bool { consoles.append(tabID); return available }
}

@MainActor
struct DeveloperToolsTests {
    let model: BrowserModel
    let tools = FakeDeveloperTools()

    init() async throws {
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.developerTools = tools
        await model.start()
        await model.openTab(url: URL(string: "about:blank")!)
    }

    @Test func theInspectorAndConsoleOpenForTheSelectedTab() throws {
        let tab = try #require(model.selectedTabID)
        model.toggleWebInspector()
        model.showJavaScriptConsole()
        #expect(tools.toggled == [tab])
        #expect(tools.consoles == [tab])
        #expect(model.alertMessage == nil)
    }

    @Test func whenTheBuiltInInspectorIsMissingSafariIsSuggested() {
        tools.available = false
        model.toggleWebInspector()
        #expect(model.alertMessage?.contains("Safari's Develop menu") == true)
    }

    @Test func nothingHappensWithoutATab() {
        model.select(nil)
        model.toggleWebInspector()
        #expect(tools.toggled.isEmpty)
    }
}
