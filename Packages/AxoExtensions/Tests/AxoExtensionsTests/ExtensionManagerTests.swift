import AxoExtensionsTestSupport
import AxoCore
import AxoWeb
import Foundation
import Testing
import WebKit
@testable import AxoExtensions

@MainActor
struct ExtensionManagerTests {
    let store: TabStore
    let pool: WebViewPool
    let manager: ExtensionManager
    let profileID: Profile.ID
    let server: LoopbackWebServer

    init() async throws {
        // Content scripts don't run on file: pages, so tests load http: pages from loopback.
        server = try await LoopbackWebServer(html: "<!doctype html><title>Page</title><p>hi</p>")
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        manager = ExtensionManager(
            installer: ExtensionInstaller(root: temporaryFolder()),
            store: store.extensions,
            pool: pool,
            persistent: false
        )
    }

    /// An unpacked extension whose content script marks every page it runs on.
    private func markingExtension(named name: String = "Marker", mark: String = "marked") throws -> URL {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "\(name)", "version": "1.0", "manifest_version": 3, "description": "Marks pages for tests.",
         "content_scripts": [{"matches": ["<all_urls>"], "js": ["mark.js"], "run_at": "document_start"}]}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "document.documentElement.dataset.axo = '\(mark)';"
            .write(to: folder.appending(path: "mark.js"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Loads a page in a new tab's web view and returns the extension's mark, if any.
    private func markOnNewPage(profileID: Profile.ID? = nil) async throws -> String? {
        let tab = Tab(spaceID: UUID(), url: server.url(path: "/page-\(UUID().uuidString)"), sortKey: "a0")
        let webView = pool.webView(for: tab, profileID: profileID ?? self.profileID)
        let deadline = ContinuousClock.now + .seconds(10)
        while pool.state(for: tab.id)?.title != "Page" || pool.state(for: tab.id)?.isLoading == true {
            try #require(ContinuousClock.now < deadline, "Page didn't load")
            try await Task.sleep(for: .milliseconds(20))
        }
        // Content scripts can run just after load; give them a moment.
        try await Task.sleep(for: .milliseconds(200))
        return try await webView.callAsyncJavaScript("return document.documentElement.dataset.axo ?? null", contentWorld: .page) as? String
    }

    @Test func webViewsGetTheirProfilesController() {
        let webView = pool.webView(for: Tab(spaceID: UUID(), url: URL(string: "about:blank")!, sortKey: "a0"), profileID: profileID)
        #expect(webView.configuration.webExtensionController === manager.controller(for: profileID))
        #expect(manager.controller(for: UUID()) !== manager.controller(for: profileID), "Each profile has its own controller")
    }

    @Test func anInstalledExtensionsContentScriptRunsOnPages() async throws {
        let record = try await manager.installUnpacked(at: try markingExtension(), for: profileID)

        #expect(record.isEnabled && record.isUnpacked && record.name == "Marker")
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID))
        #expect(context.uniqueIdentifier == record.extensionID, "browser.runtime.id is the Chrome ID")
        #expect(context.hasInjectedContent)
        #expect(context.errors.isEmpty, "WebKit reports no problems with the extension")
        #expect(try await markOnNewPage() == "marked")
    }

    @Test func disabledExtensionsDontRunAndCanBeTurnedBackOn() async throws {
        let record = try await manager.installUnpacked(at: try markingExtension(), for: profileID)

        try await manager.setEnabled(false, extensionID: record.extensionID, profileID: profileID)
        #expect(manager.context(for: record.extensionID, profileID: profileID) == nil)
        #expect(try await markOnNewPage() == nil)
        #expect(try await store.extensions.record(record.extensionID, profileID: profileID)?.isEnabled == false)

        try await manager.setEnabled(true, extensionID: record.extensionID, profileID: profileID)
        #expect(try await markOnNewPage() == "marked")
    }

    @Test func extensionsOnlyRunInTheirProfile() async throws {
        let other = try await store.createProfile(name: "Work")
        _ = try await manager.installUnpacked(at: try markingExtension(), for: profileID)
        #expect(try await markOnNewPage(profileID: other.id) == nil)
    }

    @Test func savedExtensionsLoadAtLaunch() async throws {
        let record = try await manager.installUnpacked(at: try markingExtension(), for: profileID)

        // A new manager over the same database, like a relaunch.
        let relaunchedPool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        let relaunched = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions, pool: relaunchedPool, persistent: false)
        #expect(relaunched.context(for: record.extensionID, profileID: profileID) == nil)

        await relaunched.loadExtensions(for: profileID)
        #expect(relaunched.context(for: record.extensionID, profileID: profileID) != nil)
    }

    @Test func installingACRXRunsItAndUninstallingRemovesIt() async throws {
        let builder = try CRXBuilder()
        let record = try await manager.install(crx: try builder.build(zip: sampleExtensionZip(name: "Packed")), for: profileID)
        #expect(!record.isUnpacked && manager.context(for: record.extensionID, profileID: profileID) != nil)

        try await manager.uninstall(record.extensionID, profileID: profileID)

        #expect(manager.context(for: record.extensionID, profileID: profileID) == nil)
        #expect(try await manager.extensions(for: profileID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: record.folderPath))
    }

    @Test func extensionsThatCantLoadReportAnError() async throws {
        let folder = try markingExtension()
        let record = try await manager.installUnpacked(at: folder, for: profileID)
        try await manager.setEnabled(false, extensionID: record.extensionID, profileID: profileID)
        try FileManager.default.removeItem(at: folder)

        try await manager.setEnabled(true, extensionID: record.extensionID, profileID: profileID)

        #expect(manager.loadErrors[record.extensionID] != nil)
        #expect(manager.context(for: record.extensionID, profileID: profileID) == nil)
    }
}
