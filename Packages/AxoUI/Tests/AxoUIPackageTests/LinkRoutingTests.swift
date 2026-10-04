import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct LinkRoutingTests {
    let store: TabStore
    let model: BrowserModel
    var shown: [MiniWindow] { windows.shown }
    let windows = Windows()

    final class Windows {
        var shown: [MiniWindow] = []
    }

    init() async throws {
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        let windows = windows
        model.presentMiniWindow = { windows.shown.append($0) }
        model.announce = { _ in }
        await model.start()
    }

    /// A closed loopback port, so the page never loads and nothing leaves the machine.
    private func link(_ host: String) -> URL {
        URL(string: "http://\(host):9/page")!
    }

    @Test func aDomainRuleOpensTheLinkAsATabInItsSpace() async throws {
        await model.createSpace(name: "Work")
        let work = try #require(model.space)
        let home = try #require(model.spaces.first { $0.name == TabStore.defaultSpaceName })
        await model.selectSpace(home.id)
        #expect(await model.addDomainRoute("127.0.0.1", spaceID: work.id) == nil)

        await model.openExternalURL(link("127.0.0.1"))
        #expect(model.space?.id == work.id, "The window switches to the rule's Space")
        #expect(model.tabs.map(\.url) == [link("127.0.0.1")])
        #expect(model.selectedTab?.url == link("127.0.0.1"))
        #expect(shown.isEmpty)
    }

    @Test func anAppRuleMatchesLinksFromThatApp() async throws {
        let home = try #require(model.space)
        try await store.linkRoutes.add(.app, value: "com.example.chat", displayName: "Chat", spaceID: home.id)

        await model.openExternalURL(link("localhost"), sourceApp: "com.example.chat")
        #expect(model.tabs.count == 1)
        await model.openExternalURL(link("localhost"), sourceApp: "com.example.mail")
        #expect(model.tabs.count == 1, "Other apps' links still use mini windows")
        #expect(shown.count == 1)
    }

    @Test func linksWithoutARuleOpenInAMiniWindow() async throws {
        await model.openExternalURL(link("localhost"))
        #expect(shown.count == 1)
        #expect(model.tabs.isEmpty)
    }

    @Test func rulesFollowTheirSourceAppEvenDuringLaunch() async throws {
        let store = try TabStore.makeInMemory()
        let space = try await store.bootstrap()
        try await store.linkRoutes.add(.app, value: "com.example.chat", spaceID: space.id)
        let early = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        early.presentMiniWindow = { _ in }

        await early.openExternalURL(link("localhost"), sourceApp: "com.example.chat")
        await early.start()
        #expect(early.tabs.map(\.url) == [link("localhost")])
    }

    @Test func rulesCanBeAddedChangedAndDeleted() async throws {
        let home = try #require(model.space)
        #expect(await model.addDomainRoute("not a domain", spaceID: home.id) == "“not a domain” isn't a domain, like example.com.")
        #expect(await model.addDomainRoute("https://www.GitHub.com/axo", spaceID: home.id) == nil)
        #expect(await model.addDomainRoute("github.com", spaceID: home.id) == "There's already a rule for github.com.")
        #expect(model.linkRoutes.map(\.value) == ["github.com"])

        await model.createSpace(name: "Work")
        let work = try #require(model.space)
        let rule = try #require(model.linkRoutes.first)
        await model.setRouteSpace(work.id, for: rule.id)
        #expect(model.linkRoutes.first?.spaceID == work.id)

        await model.deleteRoute(rule.id)
        #expect(model.linkRoutes.isEmpty)
    }

    @Test func appRulesReadTheAppsBundle() async throws {
        let home = try #require(model.space)
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        #expect(await model.addAppRoute(safari, spaceID: home.id) == nil)
        let rule = try #require(model.linkRoutes.first)
        #expect(rule.kind == .app && rule.value == "com.apple.Safari" && rule.displayName == "Safari")
        #expect(await model.addAppRoute(URL(fileURLWithPath: "/tmp"), spaceID: home.id) == "Axo couldn't read that app.")
    }
}
