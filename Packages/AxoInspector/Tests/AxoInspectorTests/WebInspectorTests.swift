import AppKit
import Foundation
import Testing
import WebKit
@testable import AxoInspector

@MainActor
struct WebInspectorTests {
    /// A web view in an off-screen window, since the inspector attaches to the web view's window.
    private func webViewInWindow(configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> (WKWebView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        // Closing a window that releases itself would over-release it under ARC and crash a later test.
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
        window.contentView?.addSubview(webView)
        webView.loadHTMLString("<title>Inspect me</title><p>hi</p>", baseURL: nil)
        return (webView, window)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for \(what)")
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func developerToolsCanBeTurnedOn() {
        let configuration = WKWebViewConfiguration()
        #expect(WebInspector.enableDeveloperTools(in: configuration))
        #expect(configuration.preferences.value(forKey: "_developerExtrasEnabled") as? Bool == true)
    }

    @Test func safariInspectionUsesThePublicFlag() {
        let webView = WKWebView()
        WebInspector.allowSafariInspection(of: webView)
        #expect(webView.isInspectable)
    }

    @Test func theInspectorOpensAndCloses() async throws {
        let configuration = WKWebViewConfiguration()
        WebInspector.enableDeveloperTools(in: configuration)
        let (webView, window) = webViewInWindow(configuration: configuration)
        defer { WebInspector.close(webView); window.close() }

        #expect(WebInspector.show(webView))
        try await waitUntil("the inspector to open") { WebInspector.isVisible(webView) }

        #expect(WebInspector.toggle(webView))
        try await waitUntil("the inspector to close") { !WebInspector.isVisible(webView) }

        #expect(WebInspector.showConsole(webView))
        try await waitUntil("the console to open") { WebInspector.isVisible(webView) }
        #expect(WebInspector.undock(webView))
        #expect(WebInspector.dock(webView))
    }

    @Test func missingPrivateAPIDegradesGracefully() {
        // A plain object stands in for a future WebKit without these selectors.
        let missing = NSObject()
        #expect(WebInspector.inspector(of: missing) == nil)
        #expect(WebInspector.perform("show", onInspectorOf: missing) == false)
        #expect(WebInspector.object("_backgroundWebView", of: missing) == nil)
        #expect(WebInspector.bool("isVisible", of: missing) == false)
        #expect(WebInspector.set(true, key: "developerExtrasEnabled", setter: "_setDeveloperExtrasEnabled:", on: missing) == false)
    }

    @Test func anExtensionsBackgroundPageCanBeReached() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "AxoInspectorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"name": "BG", "version": "1.0", "manifest_version": 3, "description": "x", "background": {"service_worker": "bg.js"}}"#
            .write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try "console.log('background')".write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        let error: Error? = await withCheckedContinuation { continuation in
            context.loadBackgroundContent { continuation.resume(returning: $0) }
        }
        #expect(error == nil)

        let background = try #require(WebInspector.backgroundWebView(of: context))
        #expect(background.url?.scheme == "webkit-extension")
    }
}
