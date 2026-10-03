import AxoCore
import Foundation
import WebKit

/// A tab's live web view and the bookkeeping that goes with it. Owned by ``WebViewPool``.
@MainActor
final class LiveTab {
    let tabID: Tab.ID
    let profileID: Profile.ID
    let webView: WKWebView
    let state = WebTabState()
    let delegate = WebViewDelegate()
    var lastUsed: Date
    var onPageChange: ((URL, String) -> Void)?
    /// Called when a main-frame load finishes successfully.
    var onLoadFinished: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []

    init(tabID: Tab.ID, profileID: Profile.ID, webView: WKWebView, lastUsed: Date) {
        self.tabID = tabID
        self.profileID = profileID
        self.webView = webView
        self.lastUsed = lastUsed
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        delegate.onLoadFinished = { [weak self] in
            self?.state.restoringSnapshot = nil
            self?.onLoadFinished?()
        }
        delegate.onLoadFailed = { [weak self] in
            self?.state.restoringSnapshot = nil
        }
        observe()
    }

    /// Mirrors the web view's KVO-observable properties into ``state``.
    private func observe() {
        // WKWebView posts these KVO notifications on the main thread, so assuming main-actor
        // isolation inside the handlers is safe.
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.pageDidChange() }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.pageDidChange() }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.state.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.state.estimatedProgress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.state.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.state.canGoForward = webView.canGoForward }
            },
        ]
    }

    private func pageDidChange() {
        let url = webView.url
        let title = webView.title ?? ""
        guard url != state.url || title != state.title else { return }
        state.url = url
        state.title = title
        if let url {
            onPageChange?(url, title)
        }
    }

    /// Stops the web view and detaches it so it can be deallocated.
    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }
}

/// Navigation and UI delegate for one web view.
@MainActor
final class WebViewDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onOpenInNewTab: ((URL) -> Void)?
    var onLoadFinished: (() -> Void)?
    var onLoadFailed: (() -> Void)?
    var onDownload: ((WKDownload) -> Void)?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // Links with a `download` attribute save instead of navigating.
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        Self.shouldDownload(navigationResponse) ? .download : .allow
    }

    /// Main-frame responses download when WebKit can't display them or the server sends them
    /// as attachments.
    static func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
        guard navigationResponse.isForMainFrame else { return false }
        if !navigationResponse.canShowMIMEType { return true }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased()
        return disposition?.hasPrefix("attachment") == true
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        onDownload?(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        onDownload?(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoadFinished?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLoadFailed?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onLoadFailed?()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Links that target a new window open as a new Axo tab instead of a popup web view.
        if let url = navigationAction.request.url {
            onOpenInNewTab?(url)
        }
        return nil
    }
}
