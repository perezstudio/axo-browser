import AppKit
import AxoCore
import AxoExtensionsTestSupport
import AxoWeb
import Foundation
import Testing
import WebKit
@testable import AxoExtensions

/// A browser window for extensions to see, with no UI.
@MainActor
final class FakeBrowser: ExtensionBrowsing {
    var currentProfileID: Profile.ID?
    var windowTabs: [Tab] = []
    var activeTabID: Tab.ID?
    var opened: [(url: URL?, active: Bool)] = []

    func openTab(url: URL?, active: Bool) async -> Tab.ID? {
        opened.append((url, active))
        let tab = Tab(spaceID: UUID(), url: url ?? URL(string: "about:blank")!, sortKey: "z\(windowTabs.count)")
        windowTabs.append(tab)
        if active { activeTabID = tab.id }
        return tab.id
    }

    func activateTab(_ id: Tab.ID) { activeTabID = id }

    func closeTab(_ id: Tab.ID) async { windowTabs.removeAll { $0.id == id } }
}

@MainActor
struct ExtensionToolbarTests {
    let store: TabStore
    let pool: WebViewPool
    let manager: ExtensionManager
    let browser = FakeBrowser()
    let profileID: Profile.ID

    init() async throws {
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        manager = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions, pool: pool, persistent: false)
        browser.currentProfileID = profileID
        browser.windowTabs = [
            Tab(spaceID: UUID(), url: URL(string: "https://example.com/a")!, title: "A", sortKey: "a0"),
            Tab(spaceID: UUID(), url: URL(string: "https://example.com/b")!, title: "B", sortKey: "a1"),
        ]
        browser.activeTabID = browser.windowTabs[1].id
        manager.browser = browser
    }

    /// An unpacked extension with the given manifest additions and files.
    private func makeExtension(_ manifestExtras: String, files: [String: String]) throws -> URL {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Toolbar Test", "version": "1.0", "manifest_version": 3, "description": "Tests.", \(manifestExtras)}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        for (name, contents) in files {
            try contents.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        return folder
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for \(what)")
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func theWindowShowsTheBrowsersTabsAndActiveTab() async throws {
        let record = try await manager.installUnpacked(at: try makeExtension(#""permissions": ["tabs"]"#, files: [:]), for: profileID)
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID))

        let tabs = manager.window.tabs(for: context).compactMap { $0 as? ExtensionTab }
        #expect(tabs.map(\.tabID) == browser.windowTabs.map(\.id))
        #expect((manager.window.activeTab(for: context) as? ExtensionTab)?.tabID == browser.activeTabID)
        #expect(tabs[0].title(for: context) == "A")
        #expect(tabs[1].indexInWindow(for: context) == 1)
        #expect(tabs[1].isSelected(for: context))
        #expect(tabs[0] === manager.tabAdapter(for: tabs[0].tabID), "Each tab has one stable object")
    }

    @Test func extensionsQueryAndCreateTabsThroughTheBrowser() async throws {
        // When the background script starts, it counts the window's tabs and opens one reporting
        // it. (Top-level code, since WebKit doesn't fire runtime.onInstalled; see docs/webkit-gaps.md.)
        let background = """
        (async () => {
          const tabs = await chrome.tabs.query({ currentWindow: true });
          await chrome.tabs.create({ url: "https://example.com/count-" + tabs.length, active: false });
        })();
        """
        _ = try await manager.installUnpacked(
            at: try makeExtension(#""permissions": ["tabs"], "background": {"service_worker": "bg.js"}"#, files: ["bg.js": background]),
            for: profileID
        )

        try await waitUntil("chrome.tabs.create") { !browser.opened.isEmpty }
        #expect(browser.opened.first?.url?.absoluteString == "https://example.com/count-2")
        #expect(browser.opened.first?.active == false)
    }

    @Test func toolbarActionsShowTitlesAndBadges() async throws {
        let background = """
        chrome.action.setBadgeText({ text: "7" });
        """
        let record = try await manager.installUnpacked(
            at: try makeExtension(#""action": {"default_title": "Count Things"}, "background": {"service_worker": "bg.js"}"#, files: ["bg.js": background]),
            for: profileID
        )

        try await waitUntil("the badge") {
            manager.toolbarActions(for: profileID, tabID: browser.activeTabID).first?.badge == "7"
        }
        let action = try #require(manager.toolbarActions(for: profileID, tabID: browser.activeTabID).first)
        #expect(action.id == record.extensionID)
        #expect(action.label == "Count Things")
        #expect(action.isEnabled)
        #expect(manager.toolbarActions(for: UUID(), tabID: nil).isEmpty, "Other profiles don't show it")
    }

    @Test func clickingAnActionWithAPopupPresentsIt() async throws {
        let record = try await manager.installUnpacked(
            at: try makeExtension(#""action": {"default_title": "Pop", "default_popup": "popup.html"}"#,
                                  files: ["popup.html": "<!doctype html><title>Popup</title><p>Hello from the popup</p>"]),
            for: profileID
        )
        var presented: [(String, NSPopover)] = []
        manager.onPresentPopup = { presented.append(($0, $1)) }

        manager.performAction(extensionID: record.extensionID, profileID: profileID, tabID: browser.activeTabID)

        try await waitUntil("the popup") { !presented.isEmpty }
        #expect(presented.first?.0 == record.extensionID)
    }

    /// Extensions open their own pages in tabs (1Password's welcome page, for one).
    @Test func extensionPagesLoadInTabs() async throws {
        let record = try await manager.installUnpacked(
            at: try makeExtension(#""action": {"default_title": "Pages"}"#,
                                  files: ["welcome.html": "<!doctype html><title>Welcome</title><p id=hi>Hello from the extension</p>"]),
            for: profileID
        )
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID))
        let url = try #require(URL(string: context.baseURL.appending(path: "welcome.html").absoluteString + "#/page/welcome?language=en"))
        let tab = Tab(spaceID: UUID(), url: url, sortKey: "b0")
        let webView = pool.webView(for: tab, profileID: profileID)

        try await waitUntil("the extension page") { webView.title == "Welcome" }
        let text = try await webView.evaluateJavaScript("document.getElementById('hi').textContent") as? String
        #expect(text == "Hello from the extension")
    }

    @Test func otherProfilesDontSeeTheWindow() async throws {
        _ = try await manager.installUnpacked(at: try makeExtension(#""permissions": ["tabs"]"#, files: [:]), for: profileID)
        #expect(manager.isCurrent(manager.controller(for: profileID)))

        browser.currentProfileID = UUID()
        #expect(!manager.isCurrent(manager.controller(for: profileID)))
    }
}
