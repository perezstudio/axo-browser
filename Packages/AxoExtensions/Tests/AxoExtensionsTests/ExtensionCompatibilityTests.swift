import AxoCore
import AxoExtensionsTestSupport
import AxoWeb
import Foundation
import Testing
import WebKit
@testable import AxoExtensions

struct ExtensionCompatibilityTests {
    /// An extension folder with `manifest` and files.
    private func folder(_ manifest: String, files: [String: String] = [:]) throws -> URL {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        for (path, contents) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return folder
    }

    private func manifest(in folder: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json"))) as? [String: Any] ?? [:]
    }

    private func text(_ name: String, in folder: URL) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    @Test func moduleWorkersImportTheScriptFirst() throws {
        let folder = try folder(#"{"name": "M", "version": "1", "manifest_version": 3, "background": {"service_worker": "/background/main.js", "type": "module"}}"#)
        #expect(try ExtensionCompatibility.apply(to: folder))
        #expect(try (manifest(in: folder)["background"] as? [String: Any])?["service_worker"] as? String == "axo-background.js")
        #expect(try text("axo-background.js", in: folder) == "import \"./axo-compat.js\";\nimport \"./background/main.js\";\n")
        #expect(try text("axo-compat.js", in: folder).contains("chrome.notifications"))

        // Applying again changes nothing.
        #expect(try ExtensionCompatibility.apply(to: folder))
        #expect(try text("axo-background.js", in: folder).contains("./background/main.js"))
    }

    @Test func classicWorkersAndManifestV2ScriptsGetItToo() throws {
        let classic = try folder(#"{"name": "C", "version": "1", "manifest_version": 3, "background": {"service_worker": "sw.js"}}"#)
        #expect(try ExtensionCompatibility.apply(to: classic))
        #expect(try text("axo-background.js", in: classic) == "importScripts(\"/axo-compat.js\", \"/sw.js\");\n")

        let mv2 = try folder(#"{"name": "V2", "version": "1", "manifest_version": 2, "background": {"scripts": ["a.js", "b.js"]}}"#)
        #expect(try ExtensionCompatibility.apply(to: mv2))
        #expect(try ExtensionCompatibility.apply(to: mv2))
        #expect(try (manifest(in: mv2)["background"] as? [String: Any])?["scripts"] as? [String] == ["axo-compat.js", "a.js", "b.js"])
    }

    @Test func extensionsWithoutAWorkerOrScriptsAreLeftAlone() throws {
        let none = try folder(#"{"name": "N", "version": "1", "manifest_version": 3}"#)
        #expect(try !ExtensionCompatibility.apply(to: none))
        let page = try folder(#"{"name": "P", "version": "1", "manifest_version": 2, "background": {"page": "bg.html"}}"#)
        #expect(try !ExtensionCompatibility.apply(to: page))
        #expect(!FileManager.default.fileExists(atPath: page.appending(path: "axo-compat.js").path))
    }

    /// Code like 1Password's and Todoist's: it uses chrome.notifications, a webNavigation event
    /// WebKit lacks, and a header WebKit rejects, all at startup.
    @Test @MainActor func anExtensionUsingMissingFeaturesStarts() async throws {
        let background = """
        chrome.notifications.onClicked.addListener(() => {});
        chrome.webNavigation.onCreatedNavigationTarget.addListener(() => {});
        await chrome.declarativeNetRequest.updateSessionRules({ addRules: [
          { id: 1, priority: 1, condition: { urlFilter: "example.com" },
            action: { type: "modifyHeaders", requestHeaders: [{ header: "X-Axo-Custom", operation: "set", value: "1" }] } },
          { id: 2, priority: 1, condition: { urlFilter: "example.com" },
            action: { type: "modifyHeaders", requestHeaders: [{ header: "X-Axo-Custom", operation: "set", value: "1" }, { header: "user-agent", operation: "set", value: "Axo" }] } },
        ] });
        // Later, as 1Password does after its startup awaits: the stand-ins must still be there.
        await chrome.storage.local.get("anything");
        chrome.webNavigation.onCreatedNavigationTarget.addListener(() => {});
        await new Promise((resolve) => setTimeout(resolve, 200));
        chrome.webNavigation.onCreatedNavigationTarget.addListener(() => {});
        chrome.notifications.onClicked.addListener(() => {});
        const rules = await chrome.declarativeNetRequest.getSessionRules();
        await chrome.storage.local.set({ started: rules.map((rule) => rule.id).join(",") });
        """
        let folder = try folder("""
        {"name": "Needs Chrome", "version": "1", "manifest_version": 3, "description": "Uses Chrome features WebKit lacks.",
         "background": {"service_worker": "background/background.js", "type": "module"},
         "permissions": ["notifications", "webNavigation", "storage", "declarativeNetRequestWithHostAccess"],
         "host_permissions": ["<all_urls>"]}
        """, files: ["background/background.js": background])
        try ExtensionCompatibility.apply(to: folder)

        let store = try TabStore.makeInMemory()
        let profileID = try await store.bootstrap().profileID
        let manager = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions,
                                       pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }), persistent: false)
        let record = try await manager.installUnpacked(at: folder, for: profileID)
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID))
        try await context.loadBackgroundContent()
        try await Task.sleep(for: .seconds(1))
        for error in context.errors { print("COMPAT ERROR \(error.localizedDescription)") }
        #expect(context.errors.isEmpty)
    }
}

/// What the Extensions window says when an extension's background stops.
struct ExtensionProblemTests {
    private func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: WKWebExtensionContext.errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @Test func aFailedBackgroundNamesTheExceptionNotTheLogs() {
        let errors = [
            error(7, "just a log (bg.js:1:14)"),
            error(7, "TypeError: undefined is not an object (evaluating 'chrome.notifications.onClicked') (bg.js:4:2)"),
            error(6, "The background content failed to load due to an error."),
            error(7, "TypeError: TypeError: undefined is not an object"),
        ]
        #expect(ExtensionManager.backgroundProblem(in: errors) == "Its background couldn't start: TypeError: undefined is not an object (evaluating 'chrome.notifications.onClicked') (bg.js:4:2)")
    }

    @Test func onlyAFailureCountsAsAProblem() {
        #expect(ExtensionManager.backgroundProblem(in: [error(7, "TypeError: handled later")]) == nil, "An error alone doesn't mean it stopped")
        #expect(ExtensionManager.backgroundProblem(in: [error(7, "a log"), error(6, "failed")]) == "Its background couldn't start.")
    }

    @Test @MainActor func aBrokenExtensionReportsItsProblem() async throws {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"name": "Broken", "version": "1", "manifest_version": 3, "description": "Throws.", "background": {"service_worker": "bg.js"}}"#
            .write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "console.error('only a log'); chrome.missingAPI.call();".write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)
        let store = try TabStore.makeInMemory()
        let profileID = try await store.bootstrap().profileID
        let manager = ExtensionManager(installer: ExtensionInstaller(root: temporaryFolder()), store: store.extensions,
                                       pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }), persistent: false)
        let record = try await manager.installUnpacked(at: folder, for: profileID)
        let context = try #require(manager.context(for: record.extensionID, profileID: profileID))
        #expect(manager.problem(for: record.extensionID, profileID: profileID) == nil, "Nothing wrong yet")
        // A failing background never finishes loading, so don't wait on it.
        Task { try? await context.loadBackgroundContent() }
        let deadline = ContinuousClock.now + .seconds(10)
        while manager.problem(for: record.extensionID, profileID: profileID) == nil {
            try #require(ContinuousClock.now < deadline, "No problem reported")
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(manager.problem(for: record.extensionID, profileID: profileID)?.hasPrefix("Its background couldn't start: TypeError:") == true)
    }
}
