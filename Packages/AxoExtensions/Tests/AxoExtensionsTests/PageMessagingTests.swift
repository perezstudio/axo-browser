import AxoCore
import AxoExtensionsTestSupport
import AxoWeb
import Foundation
import Testing
import WebKit
@testable import AxoExtensions

/// Pages that aren't sidebar tabs (favorites, Peek, mini windows, other Spaces) still count as
/// tabs for extensions, so their content scripts can message the extension.
@MainActor
struct PageMessagingTests {
    let store: TabStore
    let pool: WebViewPool
    let manager: ExtensionManager
    let browser = FakeBrowser()
    let profileID: Profile.ID
    let server: LoopbackWebServer

    init() async throws {
        server = try await LoopbackWebServer(html: "<!doctype html><title>Page</title><p>hi</p>")
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        manager = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions, pool: pool, persistent: false)
        browser.currentProfileID = profileID
        browser.windowTabs = [Tab(spaceID: UUID(), url: URL(string: "https://example.com/a")!, title: "A", sortKey: "a0")]
        manager.browser = browser
    }

    @Test func theWindowListsSidebarTabsThenOtherLivePagesOfTheProfile() {
        let page = Tab(spaceID: UUID(), url: URL(string: "about:blank")!, sortKey: "b0")
        let otherProfile = Tab(spaceID: UUID(), url: URL(string: "about:blank")!, sortKey: "b1")
        _ = pool.webView(for: page, profileID: profileID)
        _ = pool.webView(for: otherProfile, profileID: UUID())
        _ = pool.webView(for: browser.windowTabs[0], profileID: profileID)

        #expect(manager.windowTabIDs == [browser.windowTabs[0].id, page.id], "Sidebar order first, no duplicates, only this profile")
    }

    @Test func aPageOutsideTheSidebarCanMessageItsExtension() async throws {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Messaging", "version": "1.0", "manifest_version": 3, "description": "Tests.",
         "background": {"service_worker": "background.js"}, "host_permissions": ["<all_urls>"],
         "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_idle"}]}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.onMessage.addListener((message, sender, reply) => { reply(message + ":" + (sender.tab ? "from a tab" : "no tab")); });
        """.write(to: folder.appending(path: "background.js"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.sendMessage("ping")
          .then((reply) => { document.documentElement.dataset.reply = reply; })
          .catch((error) => { document.documentElement.dataset.reply = "error: " + error.message; });
        """.write(to: folder.appending(path: "content.js"), atomically: true, encoding: .utf8)
        let record = try await manager.installUnpacked(at: folder, for: profileID)
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID))
        try await context.loadBackgroundContent()

        // Like a favorite or Peek: a live page the sidebar doesn't list.
        let page = Tab(spaceID: UUID(), url: server.url(path: "/favorite"), sortKey: "b0")
        let webView = pool.webView(for: page, profileID: profileID)
        let deadline = ContinuousClock.now + .seconds(10)
        var reply: String?
        while reply == nil {
            try #require(ContinuousClock.now < deadline, "No reply")
            try await Task.sleep(for: .milliseconds(50))
            reply = try await webView.callAsyncJavaScript("return document.documentElement.dataset.reply ?? null", contentWorld: .page) as? String
        }
        #expect(reply == "ping:from a tab")
    }
}
