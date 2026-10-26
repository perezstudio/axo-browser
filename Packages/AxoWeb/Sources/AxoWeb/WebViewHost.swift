import AxoCore
import ScreenTime
import SwiftUI
#if os(macOS)
import AppKit

/// The platform's view type.
public typealias PlatformView = NSView
#else
import UIKit

/// The platform's view type.
public typealias PlatformView = UIView
#endif

/// Shows a tab's page in SwiftUI.
///
/// The host never creates or destroys pages: it asks ``WebViewPool`` for the tab's page and
/// mounts its view. Switching tabs swaps which pooled page is mounted, so pages keep their
/// state. The host also tells the pool which tab is visible, so it never hibernates.
@MainActor
public struct WebViewHost {
    private let tab: AxoCore.Tab
    private let profileID: Profile.ID
    private let pool: WebViewPool

    /// Creates a host for `tab`.
    ///
    /// - Parameters:
    ///   - tab: The tab to show.
    ///   - profileID: The profile of the tab's Space.
    ///   - pool: The pool that owns the tab's page.
    public init(tab: AxoCore.Tab, profileID: Profile.ID, pool: WebViewPool) {
        self.tab = tab
        self.profileID = profileID
        self.pool = pool
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(pool: pool)
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
            let page = pool.page(for: tab, profileID: profileID)
            container.mount(page.view, state: pool.state(for: tab.id))
            container.configureScreenTime(profileID: profileID, recordsUsage: pool.reportsScreenTimeUsage)
        }

        func hide(from container: WebViewContainer) {
            container.unmount()
            if let shownTabID { pool.endShowing(shownTabID) }
            shownTabID = nil
        }
    }
}

#if os(macOS)
extension WebViewHost: NSViewRepresentable {
    public func makeNSView(context: Context) -> WebViewContainer {
        WebViewContainer()
    }

    public func updateNSView(_ container: WebViewContainer, context: Context) {
        context.coordinator.show(tab, profileID: profileID, in: container)
    }

    public static func dismantleNSView(_ container: WebViewContainer, coordinator: Coordinator) {
        coordinator.hide(from: container)
    }
}
#else
extension WebViewHost: UIViewRepresentable {
    public func makeUIView(context: Context) -> WebViewContainer {
        WebViewContainer()
    }

    public func updateUIView(_ container: WebViewContainer, context: Context) {
        context.coordinator.show(tab, profileID: profileID, in: container)
    }

    public static func dismantleUIView(_ container: WebViewContainer, coordinator: Coordinator) {
        coordinator.hide(from: container)
    }
}
#endif

/// The view that holds whichever pooled page's view is mounted, with Screen Time's webpage
/// controller on top of it.
public final class WebViewContainer: PlatformView {
    /// The page view currently mounted, if any.
    public private(set) var mountedView: PlatformView?

    /// Reports the mounted page's URL to Screen Time and shows Screen Time's block screen over it
    /// when the site is over its limit or blocked by a parent. Created on first mount.
    public private(set) var screenTime: STWebpageController?
    /// The mounted page's state, whose URL Screen Time follows.
    private var mountedState: WebTabState?
    private var urlUpdates: Task<Void, Never>?

    /// Mounts a page's view, filling the container, and unmounts any other. Screen Time follows
    /// `state`'s URL.
    ///
    /// The view resizes with the container through its autoresizing mask, not Auto Layout.
    /// When WebKit's Web Inspector docks, WebKit shrinks the web view's frame and puts the
    /// inspector beside it in this container; constraints would fight that, leaving the page's
    /// content at full size, drawn over the inspector.
    func mount(_ view: PlatformView, state: WebTabState?) {
        guard mountedView !== view else { return }
        unmount()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = bounds
        view.autoresizingMask = Self.fillingMask
        if let screenTimeView = screenTime?.view {
            insert(view, below: screenTimeView)
        } else {
            addSubview(view)
        }
        mountedView = view
        mountedState = state
        screenTime?.url = state?.url
        if let state {
            urlUpdates = Task { [weak self] in
                for await url in Observations({ state.url }) {
                    self?.screenTime?.url = url
                }
            }
        }
    }

    /// Sets up Screen Time for the mounted page's profile. Each profile's web history stays
    /// separate in Screen Time.
    func configureScreenTime(profileID: Profile.ID, recordsUsage: Bool) {
        let controller = screenTime ?? makeScreenTimeController()
        controller.suppressUsageRecording = !recordsUsage
        let identifier = STWebHistory.ProfileIdentifier(rawValue: profileID.uuidString)
        if controller.profileIdentifier != identifier { controller.profileIdentifier = identifier }
        controller.url = mountedState?.url
    }

    private func makeScreenTimeController() -> STWebpageController {
        let controller = STWebpageController()
        // Above the page (and a docked inspector), filling the container. It only draws and takes
        // clicks when it shows the block screen.
        controller.view.frame = bounds
        controller.view.autoresizingMask = Self.fillingMask
        addSubview(controller.view)
        screenTime = controller
        return controller
    }

    #if os(macOS)
    private static let fillingMask: NSView.AutoresizingMask = [.width, .height]

    private func insert(_ view: NSView, below sibling: NSView) {
        addSubview(view, positioned: .below, relativeTo: sibling)
    }
    #else
    private static let fillingMask: UIView.AutoresizingMask = [.flexibleWidth, .flexibleHeight]

    private func insert(_ view: UIView, below sibling: UIView) {
        insertSubview(view, belowSubview: sibling)
    }
    #endif

    /// Removes the mounted view without destroying its page; the pool still owns it. A view
    /// another container took meanwhile stays there: SwiftUI can dismantle the old host after the
    /// new one mounted the page (a page moving to full screen and back).
    func unmount() {
        urlUpdates?.cancel()
        urlUpdates = nil
        mountedState = nil
        if mountedView?.superview === self {
            mountedView?.removeFromSuperview()
        }
        mountedView = nil
        screenTime?.url = nil
    }
}
