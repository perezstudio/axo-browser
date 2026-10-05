import AppKit
import AxoCore
import ScreenTime
import SwiftUI
import WebKit

/// Shows a tab's web view in SwiftUI.
///
/// The host never creates or destroys web views: it asks ``WebViewPool`` for the tab's web view
/// and mounts it. Switching tabs swaps which pooled web view is mounted, so pages keep their
/// state. The host also tells the pool which tab is visible, so it never hibernates.
public struct WebViewHost: NSViewRepresentable {
    private let tab: AxoCore.Tab
    private let profileID: Profile.ID
    private let pool: WebViewPool

    /// Creates a host for `tab`.
    ///
    /// - Parameters:
    ///   - tab: The tab to show.
    ///   - profileID: The profile of the tab's Space.
    ///   - pool: The pool that owns the tab's web view.
    public init(tab: AxoCore.Tab, profileID: Profile.ID, pool: WebViewPool) {
        self.tab = tab
        self.profileID = profileID
        self.pool = pool
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(pool: pool)
    }

    public func makeNSView(context: Context) -> WebViewContainer {
        WebViewContainer()
    }

    public func updateNSView(_ container: WebViewContainer, context: Context) {
        context.coordinator.show(tab, profileID: profileID, in: container)
    }

    public static func dismantleNSView(_ container: WebViewContainer, coordinator: Coordinator) {
        coordinator.hide(from: container)
    }

    /// Tracks which tab the host is showing so visibility is reported exactly once per tab.
    @MainActor
    public final class Coordinator {
        let pool: WebViewPool
        private(set) var shownTabID: AxoCore.Tab.ID?

        init(pool: WebViewPool) {
            self.pool = pool
        }

        func show(_ tab: AxoCore.Tab, profileID: Profile.ID, in container: WebViewContainer) {
            if shownTabID != tab.id {
                if let previous = shownTabID { pool.endShowing(previous) }
                pool.beginShowing(tab.id)
                shownTabID = tab.id
            }
            container.mount(pool.webView(for: tab, profileID: profileID))
            container.configureScreenTime(profileID: profileID, recordsUsage: pool.reportsScreenTimeUsage)
        }

        func hide(from container: WebViewContainer) {
            container.unmount()
            if let shownTabID { pool.endShowing(shownTabID) }
            shownTabID = nil
        }
    }
}

/// The AppKit view that holds whichever pooled web view is mounted, with Screen Time's webpage
/// controller on top of it.
public final class WebViewContainer: NSView {
    /// The web view currently mounted, if any.
    public private(set) var mountedWebView: WKWebView?

    /// Reports the mounted page's URL to Screen Time and shows Screen Time's block screen over it
    /// when the site is over its limit or blocked by a parent. Created on first mount.
    public private(set) var screenTime: STWebpageController?
    private var urlObservation: NSKeyValueObservation?

    /// Mounts `webView`, filling the container, and unmounts any other web view.
    ///
    /// The web view resizes with the container through its autoresizing mask, not Auto Layout.
    /// When the Web Inspector docks, WebKit shrinks the web view's frame and puts the inspector
    /// beside it in this container; constraints would fight that, leaving the page's content at
    /// full size, drawn over the inspector.
    func mount(_ webView: WKWebView) {
        guard mountedWebView !== webView else { return }
        unmount()
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        if let screenTimeView = screenTime?.view {
            addSubview(webView, positioned: .below, relativeTo: screenTimeView)
        } else {
            addSubview(webView)
        }
        mountedWebView = webView
        urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.screenTime?.url = webView.url }
        }
    }

    /// Sets up Screen Time for the mounted page's profile. Each profile's web history stays
    /// separate in Screen Time.
    func configureScreenTime(profileID: Profile.ID, recordsUsage: Bool) {
        let controller = screenTime ?? makeScreenTimeController()
        controller.suppressUsageRecording = !recordsUsage
        let identifier = STWebHistory.ProfileIdentifier(rawValue: profileID.uuidString)
        if controller.profileIdentifier != identifier { controller.profileIdentifier = identifier }
        controller.url = mountedWebView?.url
    }

    private func makeScreenTimeController() -> STWebpageController {
        let controller = STWebpageController()
        // Above the page (and a docked inspector), filling the container. It only draws and takes
        // clicks when it shows the block screen.
        controller.view.frame = bounds
        controller.view.autoresizingMask = [.width, .height]
        addSubview(controller.view, positioned: .above, relativeTo: nil)
        screenTime = controller
        return controller
    }

    /// Removes the mounted web view without destroying it; the pool still owns it.
    func unmount() {
        urlObservation?.invalidate()
        urlObservation = nil
        mountedWebView?.removeFromSuperview()
        mountedWebView = nil
        screenTime?.url = nil
    }
}
