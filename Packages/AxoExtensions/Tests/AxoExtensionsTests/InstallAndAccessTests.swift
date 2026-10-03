import AxoCore
import AxoExtensionsTestSupport
import AxoWeb
import Foundation
import Testing
import WebKit
@testable import AxoExtensions

@MainActor
struct InstallAndAccessTests {
    let store: TabStore
    let pool: WebViewPool
    let manager: ExtensionManager
    let profileID: Profile.ID
    let server: LoopbackWebServer

    init() async throws {
        server = try await LoopbackWebServer(html: "<!doctype html><title>Page</title><p>hi</p>")
        store = try TabStore.makeInMemory()
        profileID = try await store.bootstrap().profileID
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        manager = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions, pool: pool, persistent: false)
    }

    private func makeExtension(_ manifestExtras: String = "", files: [String: String] = [:]) throws -> URL {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"name": "Access Test", "version": "1.0", "manifest_version": 3, "description": "Tests."\(manifestExtras.isEmpty ? "" : ", " + manifestExtras)}
        """.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        for (name, contents) in files {
            try contents.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        return folder
    }

    private var markingExtras: String {
        #""permissions": ["storage"], "host_permissions": ["<all_urls>"], "content_scripts": [{"matches": ["<all_urls>"], "js": ["mark.js"], "run_at": "document_start"}]"#
    }

    private func markOnNewPage() async throws -> String? {
        let tab = Tab(spaceID: UUID(), url: server.url(path: "/p-\(UUID().uuidString)"), sortKey: "a0")
        let webView = pool.webView(for: tab, profileID: profileID)
        let deadline = ContinuousClock.now + .seconds(10)
        while pool.state(for: tab.id)?.title != "Page" || pool.state(for: tab.id)?.isLoading == true {
            try #require(ContinuousClock.now < deadline, "Page didn't load")
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        return try await webView.callAsyncJavaScript("return document.documentElement.dataset.axo ?? null", contentWorld: .page) as? String
    }

    // MARK: Install prompt

    @Test func preparingAnInstallSavesItTurnedOffAndDescribesIt() async throws {
        let folder = try makeExtension(markingExtras, files: ["mark.js": "document.documentElement.dataset.axo = 'marked';"])

        let summary = try await manager.prepareInstall(from: folder, for: profileID)

        #expect(summary.name == "Access Test" && summary.version == "1.0" && summary.isUnpacked)
        #expect(summary.lines.first == "Read and change your data on all websites")
        #expect(manager.context(for: summary.extensionID, profileID: profileID) == nil, "Nothing runs before the person agrees")
        #expect(try await store.extensions.record(summary.extensionID, profileID: profileID)?.isEnabled == false)
        #expect(try await markOnNewPage() == nil)

        try await manager.confirmInstall(summary.extensionID, profileID: profileID)
        #expect(try await markOnNewPage() == "marked")
    }

    @Test func cancellingAnInstallRemovesIt() async throws {
        let summary = try await manager.prepareInstall(from: try makeExtension(), for: profileID)
        try await manager.uninstall(summary.extensionID, profileID: profileID)
        #expect(try await manager.extensions(for: profileID).isEmpty)
    }

    @Test func installingACRXFileThroughThePromptWorksToo() async throws {
        let crx = temporaryFolder().appendingPathExtension("crx")
        try FileManager.default.createDirectory(at: crx.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CRXBuilder().build(zip: sampleExtensionZip(name: "Packed")).write(to: crx)

        let summary = try await manager.prepareInstall(from: crx, for: profileID)

        #expect(summary.name == "Packed" && !summary.isUnpacked)
    }

    @Test func updatingAnEnabledExtensionKeepsItOn() async throws {
        let folder = try makeExtension()
        let first = try await manager.prepareInstall(from: folder, for: profileID)
        try await manager.confirmInstall(first.extensionID, profileID: profileID)

        _ = try await manager.prepareInstall(from: folder, for: profileID)

        #expect(try await store.extensions.record(first.extensionID, profileID: profileID)?.isEnabled == true)
    }

    // MARK: Site access

    @Test func onClickSiteAccessStopsContentScriptsUntilSetBack() async throws {
        let record = try await manager.installUnpacked(
            at: try makeExtension(markingExtras, files: ["mark.js": "document.documentElement.dataset.axo = 'marked';"]),
            for: profileID
        )
        #expect(try await markOnNewPage() == "marked")

        try await manager.setSiteAccess(.click, extensionID: record.extensionID, profileID: profileID)
        #expect(try await markOnNewPage() == nil)
        #expect(!manager.grantedDescription(for: record.extensionID, profileID: profileID).contains("Read and change your data on all websites"))

        try await manager.setSiteAccess(.all, extensionID: record.extensionID, profileID: profileID)
        #expect(try await markOnNewPage() == "marked")
    }

    // MARK: Optional permissions

    @Test func approvedOptionalAccessIsRememberedAndRestored() async throws {
        let record = try await manager.installUnpacked(at: try makeExtension(#""optional_permissions": ["cookies"]"#), for: profileID)
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID))
        var asked: [ExtensionManager.PermissionRequest] = []
        manager.onPermissionRequest = { asked.append($0); return true }

        #expect(await manager.requestAccess(context, permissions: ["cookies"], patterns: []))
        #expect(asked.first?.lines == ["Read and change cookies for websites it can reach"])
        #expect(asked.first?.extensionName == "Access Test")
        #expect(try await store.extensions.record(record.extensionID, profileID: profileID)?.grantedOptional == ["cookies"])

        // A relaunch applies the saved approval.
        let relaunched = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions, pool: pool, persistent: false)
        await relaunched.loadExtensions(for: profileID)
        let restored = try #require(relaunched.context(for: record.extensionID, profileID: profileID))
        #expect(restored.permissionStatus(for: .cookies) == .grantedExplicitly)
    }

    @Test func declinedOrUnansweredRequestsAreDenied() async throws {
        let record = try await manager.installUnpacked(at: try makeExtension(#""optional_permissions": ["cookies"]"#), for: profileID)
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID))

        #expect(await manager.requestAccess(context, permissions: ["cookies"], patterns: []) == false, "No one to ask")
        manager.onPermissionRequest = { _ in false }
        #expect(await manager.requestAccess(context, permissions: ["cookies"], patterns: []) == false)
        #expect(try await store.extensions.record(record.extensionID, profileID: profileID)?.grantedOptional == [])
    }
}
