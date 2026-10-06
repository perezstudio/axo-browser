import AxoCore
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

@MainActor
struct SiteCustomizationModelTests {
    let store: TabStore
    let model: BrowserModel

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        await model.start()
    }

    /// Selects a tab on a loopback address with a closed port, so nothing loads and nothing
    /// leaves the machine.
    private func open(_ address: String) async throws {
        let tab = try await store.openTab(url: URL(string: address)!, in: try #require(model.space).id)
        try await waitUntil { model.tabs.contains { $0.id == tab.id } }
        model.select(tab.id)
    }

    @Test func customizingTheCurrentSiteStartsFromItsDomain() async throws {
        model.customizeCurrentSite()
        #expect(model.customizationDraft == nil, "Nothing to customize without a web page")

        try await open("http://127.0.0.1:9/story")
        model.customizeCurrentSite()
        #expect(model.customizationDraft?.domain == "127.0.0.1")
        #expect(model.customizationDraft?.css == "")
    }

    @Test func anExistingCustomizationIsEditedEvenWhenOff() async throws {
        let saved = try await store.siteCustomizations.save(SiteCustomization(domain: "localhost", css: "a {}", isEnabled: false))
        try await waitUntil { !model.siteCustomizations.isEmpty }
        try await open("http://localhost:9/")
        model.customizeCurrentSite()
        #expect(model.customizationDraft?.id == saved.id)
    }

    @Test func savingAppliesToThePoolAndReportsProblems() async throws {
        #expect(await model.saveCustomization(SiteCustomization(domain: "example.com", css: "p {}")) == nil)
        #expect(model.siteCustomizations.map(\.domain) == ["example.com"])
        #expect(await model.saveCustomization(SiteCustomization(domain: "www.example.com")) == "example.com already has a customization.")
        #expect(await model.saveCustomization(SiteCustomization(domain: "nope nope")) == "“nope nope” isn't a domain, like example.com.")

        let id = try #require(model.siteCustomizations.first?.id)
        await model.setCustomizationEnabled(false, id: id)
        #expect(model.siteCustomizations.first?.isEnabled == false)
        await model.deleteCustomization(id)
        #expect(model.siteCustomizations.isEmpty)
    }

    @Test func savedCustomizationsReachNewWebViews() async throws {
        await model.saveCustomization(SiteCustomization(domain: "example.com", js: "document.title = 'Customized'"))
        let tab = AxoCore.Tab(spaceID: UUID(), url: URL(string: "about:blank")!, sortKey: "a0")
        let webView = model.pool.webView(for: tab, profileID: try #require(model.space).profileID)
        // Other scripts (such as the Chrome Web Store button) are there too; look for this one.
        #expect(webView.configuration.userContentController.userScripts.contains { $0.source.contains("document.title = 'Customized'") })
    }
}
