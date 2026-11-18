import Foundation
import Testing
import WebKit
@testable import AxoInspector

extension WebKitSuites {
    @MainActor
    struct WebContentProcessTests {
        /// Records the web content process ending.
        private final class Delegate: NSObject, WKNavigationDelegate {
            var terminated = false
            func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { terminated = true }
        }

        @Test func endingAPagesProcessIsReportedAsItsTermination() async throws {
            let webView = WKWebView(frame: .zero, configuration: .isolated())
            let delegate = Delegate()
            webView.navigationDelegate = delegate
            webView.loadHTMLString("<title>Page</title>", baseURL: nil)
            // Only a guard against hangs: other tests' web views share the main thread.
            let deadline = ContinuousClock.now + .seconds(60)
            while webView.isLoading || webView.title != "Page" {
                try #require(ContinuousClock.now < deadline, "The page didn't load")
                try await Task.sleep(for: .milliseconds(25))
            }

            let identifier = try #require(WebContentProcess.identifier(of: webView))
            #expect(identifier != ProcessInfo.processInfo.processIdentifier, "Not this process")
            #expect(WebContentProcess.end(for: webView))
            while !delegate.terminated {
                try #require(ContinuousClock.now < deadline, "WebKit didn't report the process ending")
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        @Test func aWebViewWithNoPageHasNoProcessToEnd() {
            #expect(WebContentProcess.identifier(of: WKWebView(frame: .zero, configuration: .isolated())) == nil)
            #expect(!WebContentProcess.end(for: WKWebView(frame: .zero, configuration: .isolated())))
        }
    }
}
