import AxoCore
import Foundation
import WebKit
#if os(macOS)
import AppKit
#endif

/// The WebKit engine: a `WKWebView` per page and one `WKWebsiteDataStore(forIdentifier:)` per
/// profile, so cookies and storage never leak between profiles.
///
/// iPhone and iPad use it. The Mac runs on Chromium; it still uses WebKit in test runs until
/// Phase 4 removes it there (see `docs/chromium-engine.md`).
@MainActor
public final class WebKitEngine: WebEngine {
    private let makeDataStore: (Profile.ID) -> WKWebsiteDataStore
    private var dataStores: [Profile.ID: WKWebsiteDataStore] = [:]
    /// Functions that adjust each new web view's configuration, in the order added.
    private var configurators: [(WKWebViewConfiguration, Profile.ID) -> Void] = []
    /// The user scripts for per-site custom CSS and JavaScript.
    private var siteCustomizationScripts: [WKUserScript] = []
    /// Every page this engine made that's still alive, so site customizations reach them.
    private let pages = NSHashTable<WebKitPage>.weakObjects()
    private let downloads = WebKitDownloads()

    /// Whether pages play sound, and muting them (#71), which `WKWebView` offers only through
    /// private API, so the app sets this from AxoInspector. Without it, WebKit pages never
    /// report sound and can't be muted. Set it before making pages.
    public var audio: (any WebKitPageAudio)?

    /// WebKit never changes tabs on its own, so it never calls this.
    public weak var delegate: (any WebEngineDelegate)?

    /// Deletes a profile's stored website data for good. Replace it in tests. WebKit requires the
    /// main thread here (it crashes otherwise), hence `@MainActor`.
    public var removeDataStore: @MainActor (Profile.ID) async throws -> Void = { try await WKWebsiteDataStore.remove(forIdentifier: $0) }

    /// Creates an engine.
    ///
    /// - Parameter makeDataStore: Returns the website data store for a profile. Called once per
    ///   profile. Defaults to a persistent `WKWebsiteDataStore(forIdentifier:)` keyed by the
    ///   profile ID.
    public init(makeDataStore: @escaping (Profile.ID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) }) {
        self.makeDataStore = makeDataStore
    }

    /// Adds a function called with each new web view's configuration and profile before the
    /// web view is created, for example to attach the profile's extension controller or turn on
    /// developer tools. Configurators run in the order they were added.
    public func addWebViewConfigurator(_ configure: @escaping (WKWebViewConfiguration, Profile.ID) -> Void) {
        configurators.append(configure)
    }

    /// The website data store for a profile, created on first use and shared by all its pages.
    public func dataStore(for profileID: Profile.ID) -> WKWebsiteDataStore {
        if let store = dataStores[profileID] {
            return store
        }
        let store = makeDataStore(profileID)
        dataStores[profileID] = store
        return store
    }

    // MARK: WebEngine

    public func makePage(profileID: Profile.ID) -> any EnginePage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: profileID)
        // Element fullscreen (the Fullscreen API) is off by default; videos and pages expect it.
        configuration.preferences.isElementFullscreenEnabled = true
        UserAgent.apply(to: configuration)
        siteCustomizationScripts.forEach(configuration.userContentController.addUserScript)
        let hoveredLinks = HoveredLinks.install(in: configuration)
        configurators.forEach { $0(configuration, profileID) }
        let webView = PooledWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        let page = WebKitPage(webView: webView, downloads: downloads, audio: audio)
        hoveredLinks.page = page
        pages.add(page)
        return page
    }

    /// Axo's only other user script is the one ``HoveredLinks`` adds, so updating live web views
    /// replaces all of theirs and adds that one back.
    public func setSiteCustomizations(_ customizations: [SiteCustomization]) {
        siteCustomizationScripts = SiteCustomizationScripts.userScripts(for: customizations)
        for page in pages.allObjects {
            let controller = page.webView.configuration.userContentController
            controller.removeAllUserScripts()
            siteCustomizationScripts.forEach(controller.addUserScript)
            controller.addUserScript(HoveredLinks.userScript)
        }
    }

    public func clearWebsiteData(for profileID: Profile.ID) async {
        await dataStore(for: profileID).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    public func clearWebsiteData(forSite url: URL, profileID: Profile.ID) async {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return }
        let store = dataStore(for: profileID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        // WebKit keeps a record per site, named for its registrable domain.
        guard let site = WebsiteDataSite.recordName(forHost: host, among: records.map(\.displayName)) else { return }
        await store.removeData(ofTypes: types, for: records.filter { $0.displayName.lowercased() == site })
    }

    public func removeWebsiteData(for profileID: Profile.ID) async throws {
        dataStores[profileID] = nil
        try await removeDataStore(profileID)
    }
}

/// A page in a `WKWebView`, which it also serves as navigation and UI delegate.
@MainActor
public final class WebKitPage: NSObject, EnginePage {
    /// The page's web view, for WebKit-only features such as extensions and the inspector.
    public let webView: WKWebView
    public weak var delegate: (any EnginePageDelegate)?
    private let downloads: WebKitDownloads
    private var observations: [NSKeyValueObservation] = []
    private let audio: (any WebKitPageAudio)?
    private var audioObservation: AnyObject?
    /// Set when the web content process ends, until the page starts loading again.
    private var contentProcessEnded = false
    /// Why the last load failed, until another starts (#178).
    private var failure: (loadError: PageLoadError?, warning: PageWarning?)?
    /// The address showing when the load failed (the page before), so moving on from it clears
    /// the failure.
    private var failedAt: URL?
    /// The address of the page that last committed. While another loads, `webView.url` is already
    /// the new one but `hasOnlySecureContent` and `serverTrust` are still the old page's (#96).
    private var committedURL: URL?

    init(webView: PooledWebView, downloads: WebKitDownloads, audio: (any WebKitPageAudio)? = nil) {
        self.webView = webView
        self.downloads = downloads
        self.audio = audio
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.onFocus = { [weak self] in
            guard let self else { return }
            self.delegate?.pageDidTakeFocus(self)
        }
        // WKWebView posts these KVO notifications on the main thread, so assuming main-actor
        // isolation inside the handlers is safe.
        let changed: @Sendable (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.pageStateDidChange(self)
            }
        }
        observations = [
            webView.observe(\.url) { webView, _ in changed(webView) },
            webView.observe(\.title) { webView, _ in changed(webView) },
            webView.observe(\.isLoading) { webView, _ in changed(webView) },
            webView.observe(\.estimatedProgress) { webView, _ in changed(webView) },
            webView.observe(\.canGoBack) { webView, _ in changed(webView) },
            webView.observe(\.canGoForward) { webView, _ in changed(webView) },
        ]
        #if os(iOS)
        // How far the page is scrolled, for the iPhone's bar shrinking while reading (#182).
        observations.append(webView.scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let insets = scrollView.adjustedContentInset
                // Within the content: a bounce past either end isn't scrolling back.
                let end = max(0, scrollView.contentSize.height + insets.top + insets.bottom - scrollView.bounds.height)
                let offset = min(max(scrollView.contentOffset.y + insets.top, 0), end)
                // Only the person's own scrolling counts (a page scrolling itself, an anchor, or
                // Back restoring a place doesn't), except reaching the top, which always does.
                let byPerson = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
                guard byPerson || offset < ChromeCollapse.topZone else { return }
                self.delegate?.page(self, didScrollTo: offset)
            }
        })
        #endif
        let mediaChanged: @Sendable (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.pageMediaDidChange(self)
            }
        }
        let securityChanged: @Sendable (WKWebView) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.pageSecurityDidChange(self)
            }
        }
        // A same-document navigation (Back to an anchor, pushState) moves on from a failed load
        // without a new load starting or committing.
        let urlChanged: @Sendable (WKWebView) -> Void = { [weak self] webView in
            MainActor.assumeIsolated {
                guard let self, let failedAt = self.failedAt, webView.url != failedAt else { return }
                self.clearFailure()
            }
        }
        observations.append(webView.observe(\.url) { webView, _ in urlChanged(webView) })
        observations += [
            webView.observe(\.hasOnlySecureContent) { webView, _ in securityChanged(webView) },
            webView.observe(\.serverTrust) { webView, _ in securityChanged(webView) },
            webView.observe(\.url) { webView, _ in securityChanged(webView) },
        ]
        observations += [
            webView.observe(\.cameraCaptureState) { webView, _ in mediaChanged(webView) },
            webView.observe(\.microphoneCaptureState) { webView, _ in mediaChanged(webView) },
        ]
        audioObservation = audio?.observe(webView) { [weak self] in
            guard let self else { return }
            self.delegate?.pageMediaDidChange(self)
        }
    }

    public var view: PlatformView { webView }

    /// The camera and microphone come from `WKWebView`'s capture states; sound and muting from
    /// ``WebKitPageAudio``. WebKit has no public way to tell screen sharing or location in use.
    public var media: PageMedia {
        var capture: PageCapture = []
        if webView.cameraCaptureState == .active { capture.insert(.camera) }
        if webView.microphoneCaptureState == .active { capture.insert(.microphone) }
        return PageMedia(
            isPlayingAudio: audio?.isPlayingAudio(in: webView) ?? false,
            isMuted: audio?.isMuted(in: webView) ?? false,
            capture: capture
        )
    }

    public func setAudioMuted(_ muted: Bool) {
        audio?.setMuted(muted, in: webView)
    }

    /// The camera and microphone, through `WKWebView`'s public capture states; WebKit has no
    /// public way to stop location.
    public func stopCapture(_ kinds: PageCapture) {
        if kinds.contains(.camera), webView.cameraCaptureState != .none {
            webView.setCameraCaptureState(.none, completionHandler: nil)
        }
        if kinds.contains(.microphone), webView.microphoneCaptureState != .none {
            webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
    }

    /// From the address, `hasOnlySecureContent`, and `serverTrust`. WebKit refuses untrusted
    /// certificates outright, so its pages are never ``PageSecurity/Level/broken``.
    public var security: PageSecurity {
        PageSecurity.webKit(url: webView.url, committedURL: committedURL,
                            hasOnlySecureContent: webView.hasOnlySecureContent, serverTrust: webView.serverTrust)
    }

    /// A crash only: WebKit tells neither why its content process ended nor, publicly, that a
    /// page stopped responding (`docs/webkit-gaps.md`).
    public var problem: PageProblem? { contentProcessEnded ? .crashed(errorCode: nil) : nil }
    public var url: URL? { webView.url }
    public var title: String { webView.title ?? "" }
    public var isLoading: Bool { webView.isLoading }
    public var estimatedProgress: Double { webView.estimatedProgress }
    public var canGoBack: Bool { webView.canGoBack }
    public var canGoForward: Bool { webView.canGoForward }
    public var interactionState: Any? { webView.interactionState }

    public func restore(interactionState: Any) {
        webView.interactionState = interactionState
    }

    public func load(_ url: URL) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    public func goBack() { webView.goBack() }

    public var backHistory: [HistoryEntry] {
        webView.backForwardList.backList.reversed().map { HistoryEntry(title: $0.title ?? "", url: $0.url) }
    }

    public var forwardHistory: [HistoryEntry] {
        webView.backForwardList.forwardList.map { HistoryEntry(title: $0.title ?? "", url: $0.url) }
    }

    public func goToHistoryOffset(_ offset: Int) {
        guard let item = webView.backForwardList.item(at: offset), offset != 0 else { return }
        webView.go(to: item)
    }
    public func goForward() { webView.goForward() }
    public func reload() { webView.reload() }
    public func stopLoading() { webView.stopLoading() }

    public func find(_ text: String, backwards: Bool) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        return (try? await webView.find(text, configuration: configuration).matchFound) ?? false
    }

    /// WebKit marks its match as the page's selection. Clearing it from Axo's own isolated world
    /// doesn't run or expose anything to the page's scripts.
    public func endFind() async {
        _ = try? await callJavaScript("window.getSelection()?.removeAllRanges()", arguments: [:], in: "AxoFind")
    }

    public func callJavaScript(_ functionBody: String, arguments: [String: Any], in world: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(functionBody, arguments: arguments, contentWorld: Self.contentWorld(named: world))
    }

    /// Content worlds by name, kept for the app's lifetime. WebKit makes a fresh world once the
    /// last `WKContentWorld` for a name is released, which would lose what earlier scripts left in
    /// it (such as the nodes page translation collects before replacing their text).
    private static var contentWorlds: [String: WKContentWorld] = [:]

    private static func contentWorld(named name: String) -> WKContentWorld {
        if let world = contentWorlds[name] { return world }
        let world = WKContentWorld.world(name: name)
        contentWorlds[name] = world
        return world
    }

    public func snapshot(width: CGFloat) async -> PlatformImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(width))
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    public func startDownload(_ url: URL) {
        // Track inside the completion handler: WebKit only guarantees delivering events to a
        // delegate set there, so tracking after an `await` could miss an early failure.
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.track(download)
        }
    }

    /// WebKit shows element full screen in a window of its own and leaves it itself.
    public func exitFullscreen() {}

    #if os(macOS)
    public func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation {
        let operation = webView.printOperation(with: printInfo)
        // WebKit's print view needs a frame, or it prints blank pages.
        operation.view?.frame = webView.bounds
        return operation
    }
    #endif

    public func close() {
        observations.forEach { $0.invalidate() }
        observations = []
        audioObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// Hands a WebKit download to the delegate's download list, or cancels it with no delegate.
    private func track(_ download: WKDownload) {
        guard let delegate else {
            download.cancel { _ in }
            return
        }
        let item = delegate.page(self, didStartDownloadFrom: download.originalRequest?.url) {
            download.cancel { _ in }
        }
        downloads.track(download, reportingTo: item)
    }
}

extension WebKitPage: WKNavigationDelegate, WKUIDelegate {
    // MARK: Permissions

    public func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        let kind: PermissionKind = switch type {
        case .camera: .camera
        case .microphone: .microphone
        default: .cameraAndMicrophone
        }
        return await decide(kind, for: origin)
    }

    public func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo
    ) async -> WKPermissionDecision {
        await decide(.location, for: origin)
    }

    /// Asks the delegate, denying when there's no answer (WebKit keeps none, so nothing lasts).
    private func decide(_ kind: PermissionKind, for origin: WKSecurityOrigin) async -> WKPermissionDecision {
        let decision = await delegate?.page(self, requestsPermission: kind, origin: PageOrigin(origin)) ?? .deny
        return decision == .allow ? .grant : .deny
    }

    // MARK: JavaScript dialogs and file uploads

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await delegate?.page(self, showsDialog: .alert, message: message, origin: PageOrigin(frame.securityOrigin))
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let result = await delegate?.page(self, showsDialog: .confirm, message: message, origin: PageOrigin(frame.securityOrigin))
        return result?.accepted ?? false
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let result = await delegate?.page(self, showsDialog: .prompt(defaultText: defaultText ?? ""), message: prompt, origin: PageOrigin(frame.securityOrigin))
        guard let result, result.accepted else { return nil }
        return result.text ?? ""
    }

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        await delegate?.page(self, selectsFilesAllowingMultiple: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories) ?? nil
    }

    // MARK: Navigation

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // Links with a `download` attribute save instead of navigating.
        if navigationAction.shouldPerformDownload { return .download }
        #if os(macOS)
        // A link to another app (mailto:, zoommtg:), in any frame: Axo asks the person and opens
        // it. WebKit would fail to load it. (On iPhone and iPad, WebKit hands such links to iOS.)
        if let url = navigationAction.request.url, ExternalLinks.isExternal(url),
           webView.configuration.urlSchemeHandler(forURLScheme: url.scheme ?? "") == nil {
            // WebKit can give no source frame for a load the app started, despite the SDK.
            let source = (navigationAction.sourceFrame as WKFrameInfo?)?.securityOrigin
            // Only a web site can be named and remembered, as on Chromium.
            let origin = source.flatMap { ["http", "https"].contains($0.protocol.lowercased()) && !$0.host.isEmpty ? PageOrigin($0) : nil }
            let userGesture = navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .formSubmitted
            delegate?.page(self, opensExternalURL: url, origin: origin, userGesture: userGesture)
            return .cancel
        }
        #endif
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           delegate?.page(self, shouldHandleLinkTo: url, modifiers: LinkModifiers(navigationAction.modifierFlags)) == true {
            return .cancel
        }
        return .allow
    }

    public func webView(
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

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.pageDidFinishLoad(self)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        contentProcessEnded = true
        delegate?.pageProblemDidChange(self)
        // Its loads end with it.
        delegate?.pageStateDidChange(self)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedURL = webView.url
        clearFailure()
        delegate?.pageSecurityDidChange(self)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Another load starts: the failed one's page goes (it comes back if this one fails too).
        clearFailure()
        // A new content process is loading the page, as Chrome hides its sad tab once a new
        // renderer is ready.
        guard contentProcessEnded else { return }
        contentProcessEnded = false
        delegate?.pageProblemDidChange(self)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        delegate?.pageDidFailLoad(self)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failed = Self.failure(for: error as NSError)
        if failed.loadError != nil || failed.warning != nil {
            failure = failed
            failedAt = webView.url
            delegate?.pageErrorDidChange(self)
        }
        delegate?.pageDidFailLoad(self)
    }

    public var loadError: PageLoadError? { failure?.loadError }
    public var warning: PageWarning? { failure?.warning }

    /// WebKit keeps the page that was showing when a load fails, so leaving the error or the
    /// warning shows it again.
    public func leaveLoadError() { clearFailure() }
    public func leaveWarning() { clearFailure() }

    private func clearFailure() {
        guard failure != nil else { return }
        failure = nil
        failedAt = nil
        delegate?.pageErrorDidChange(self)
    }

    /// What a failed load shows: a certificate warning (WebKit refuses untrusted certificates, so
    /// it never allows visiting), or a Can't Connect page; nothing for a load that was cancelled
    /// or replaced (a new navigation, a download).
    static func failure(for error: NSError) -> (loadError: PageLoadError?, warning: PageWarning?) {
        let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        let code = "\(error.domain) \(error.code)"
        guard error.domain == NSURLErrorDomain else { return (nil, nil) }
        switch error.code {
        case NSURLErrorCancelled:
            return (nil, nil)
        // Only the server's certificate: a failed handshake or a client certificate is a failed
        // load, not a site pretending to be another.
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return (nil, PageWarning(kind: .certificate, url: url, code: code, allowsVisiting: false))
        default:
            return (PageLoadError(kind: PageLoadError.kind(urlErrorCode: error.code), code: code, url: url), nil)
        }
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Links that target a new window open as a new Axo tab instead of a popup web view.
        if let url = navigationAction.request.url {
            delegate?.page(self, wantsToOpenInNewTab: url)
        }
        return nil
    }
}

/// The web view the WebKit engine creates for each page. It reports when it takes keyboard focus.
final class PooledWebView: WKWebView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}

/// Reports WebKit downloads to their ``DownloadItem``s.
@MainActor
final class WebKitDownloads: NSObject, WKDownloadDelegate {
    private struct Tracked {
        let item: DownloadItem
        let progressObservation: NSKeyValueObservation
    }

    private var tracked: [ObjectIdentifier: Tracked] = [:]

    func track(_ download: WKDownload, reportingTo item: DownloadItem) {
        download.delegate = self
        // Progress may report on any thread, so hop to the main actor before touching the item.
        let observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                item?.reportProgress(completedBytes: completed, totalBytes: total)
            }
        }
        tracked[ObjectIdentifier(download)] = Tracked(item: item, progressObservation: observation)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let item = tracked[ObjectIdentifier(download)]?.item else { return nil }
        let destination = item.chooseDestination(suggestedFilename: suggestedFilename, expectedLength: response.expectedContentLength)
        if destination == nil { stopTracking(download) }
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        stopTracking(download)?.reportFinished()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        stopTracking(download)?.reportFailed(error.localizedDescription)
    }

    @discardableResult
    private func stopTracking(_ download: WKDownload) -> DownloadItem? {
        guard let entry = tracked.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        entry.progressObservation.invalidate()
        return entry.item
    }
}

extension PageOrigin {
    @MainActor
    init(_ origin: WKSecurityOrigin) {
        self.init(scheme: origin.protocol, host: origin.host, port: origin.port)
    }
}

// MARK: WebKit-only pool access

/// WebKit-only features of the pool, for code that only exists with WebKit: AxoExtensions
/// (`WKWebExtension`), AxoInspector, and tests. AxoUI must not use them, so the Mac can switch
/// engines (see `docs/chromium-engine.md`).
extension WebViewPool {
    /// Creates a pool with a ``WebKitEngine``.
    ///
    /// - Parameters:
    ///   - configuration: Hibernation settings.
    ///   - makeDataStore: Returns the website data store for a profile. Called once per profile.
    ///     Defaults to a persistent `WKWebsiteDataStore(forIdentifier:)` keyed by the profile ID.
    ///   - downloads: Tracks downloads and decides where files go. Defaults to the user's
    ///     Downloads folder.
    ///   - now: The current time. Override in tests.
    public convenience init(
        configuration: Configuration = Configuration(),
        makeDataStore: @escaping (Profile.ID) -> WKWebsiteDataStore = { WKWebsiteDataStore(forIdentifier: $0) },
        downloads: DownloadManager = DownloadManager(),
        now: @escaping () -> Date = Date.init
    ) {
        self.init(engine: WebKitEngine(makeDataStore: makeDataStore), configuration: configuration, downloads: downloads, now: now)
    }

    /// The pool's engine if it's WebKit.
    public var webKitEngine: WebKitEngine? {
        engine as? WebKitEngine
    }

    private var requiredWebKitEngine: WebKitEngine {
        guard let engine = webKitEngine else {
            preconditionFailure("This WebKit-only feature was used with another engine.")
        }
        return engine
    }

    /// Returns the tab's web view, creating or waking it if needed. WebKit only.
    public func webView(for tab: Tab, profileID: Profile.ID) -> WKWebView {
        guard let page = page(for: tab, profileID: profileID) as? WebKitPage else {
            preconditionFailure("This WebKit-only feature was used with another engine.")
        }
        return page.webView
    }

    /// The tab's web view if it is live, without creating one. `nil` with another engine.
    public func liveWebView(for tabID: Tab.ID) -> WKWebView? {
        (livePage(for: tabID) as? WebKitPage)?.webView
    }

    /// Adds a function called with each new web view's configuration and profile. Does nothing
    /// with another engine. See ``WebKitEngine/addWebViewConfigurator(_:)``.
    public func addWebViewConfigurator(_ configure: @escaping (WKWebViewConfiguration, Profile.ID) -> Void) {
        webKitEngine?.addWebViewConfigurator(configure)
    }

    /// The website data store for a profile. WebKit only.
    public func dataStore(for profileID: Profile.ID) -> WKWebsiteDataStore {
        requiredWebKitEngine.dataStore(for: profileID)
    }

    /// Deletes a profile's stored website data for good. Replace it in tests. WebKit only.
    public var removeDataStore: @MainActor (Profile.ID) async throws -> Void {
        get { requiredWebKitEngine.removeDataStore }
        set { requiredWebKitEngine.removeDataStore = newValue }
    }
}

/// Sound in a `WKWebView`, which WebKit offers only through private API (AxoInspector's
/// `PageAudio`). ``WebKitEngine/audio``.
@MainActor
public protocol WebKitPageAudio: AnyObject {
    /// Whether the page plays sound now, muted or not.
    func isPlayingAudio(in webView: WKWebView) -> Bool
    /// Whether the page's sound is muted.
    func isMuted(in webView: WKWebView) -> Bool
    /// Mutes or unmutes the page's sound (not its camera or microphone).
    func setMuted(_ muted: Bool, in webView: WKWebView)
    /// Calls `changed` on the main actor whenever the page starts or stops playing sound, until
    /// the returned object is released. Nil when it can't tell.
    func observe(_ webView: WKWebView, changed: @escaping @MainActor () -> Void) -> AnyObject?
}
