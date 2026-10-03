import AxoCore
import AxoWeb
import Foundation
import WebKit

/// What extensions can see and do in the browser window. The app implements it over its window
/// model, so this package doesn't depend on the UI.
///
/// Axo has one browser window; its tabs are the current Space's tabs, pinned first.
@MainActor
public protocol ExtensionBrowsing: AnyObject {
    /// The profile of the Space the window shows.
    var currentProfileID: Profile.ID? { get }
    /// The window's tabs, in sidebar order.
    var windowTabs: [Tab] { get }
    /// The selected tab.
    var activeTabID: Tab.ID? { get }
    /// Opens a tab (blank when `url` is `nil`) and returns its ID.
    func openTab(url: URL?, active: Bool) async -> Tab.ID?
    /// Selects a tab.
    func activateTab(_ id: Tab.ID)
    /// Closes a tab.
    func closeTab(_ id: Tab.ID) async
}

/// A browser tab as extensions see it (`chrome.tabs`). One object per tab ID, so WebKit sees a
/// stable identity.
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    let tabID: Tab.ID
    private weak var manager: ExtensionManager?

    init(tabID: Tab.ID, manager: ExtensionManager) {
        self.tabID = tabID
        self.manager = manager
    }

    private var tab: Tab? { manager?.browser?.windowTabs.first { $0.id == tabID } }
    private var webView: WKWebView? { manager?.pool.liveWebView(for: tabID) }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        manager?.window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        manager?.browser?.windowTabs.firstIndex { $0.id == tabID } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }

    func title(for context: WKWebExtensionContext) -> String? {
        webView?.title ?? tab?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        webView?.url ?? tab?.url
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.isPinned ?? false }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        manager?.browser?.activeTabID == tabID
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(webView?.isLoading ?? false)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        manager?.browser?.activateTab(tabID)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let browser = manager?.browser else { return completionHandler(nil) }
        Task {
            await browser.closeTab(tabID)
            completionHandler(nil)
        }
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        manager?.pool.load(url, in: tabID)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        manager?.pool.reload(tabID)
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        manager?.pool.goBack(in: tabID)
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        manager?.pool.goForward(in: tabID)
        completionHandler(nil)
    }

    /// Clicking an extension's toolbar button grants it `activeTab` for that tab, as in Chrome.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// The browser window as extensions see it (`chrome.windows`).
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    private weak var manager: ExtensionManager?

    init(manager: ExtensionManager) {
        self.manager = manager
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let manager, let browser = manager.browser else { return [] }
        return browser.windowTabs.map { manager.tabAdapter(for: $0.id) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let manager, let id = manager.browser?.activeTabID else { return nil }
        return manager.tabAdapter(for: id)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.mainWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        NSApp.mainWindow?.screen?.frame ?? NSScreen.main?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}

/// Answers WebKit's questions about windows, new tabs, and popups for every controller.
@MainActor
final class ControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    private weak var manager: ExtensionManager?

    init(manager: ExtensionManager) {
        self.manager = manager
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let manager, manager.isCurrent(controller) else { return [] }
        return [manager.window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let manager, manager.isCurrent(controller) else { return nil }
        return manager.window
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        guard let manager, let browser = manager.browser, manager.isCurrent(controller) else {
            return completionHandler(nil, nil)
        }
        Task {
            let id = await browser.openTab(url: configuration.url, active: configuration.shouldBeActive)
            completionHandler(id.map { manager.tabAdapter(for: $0) }, nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        manager?.presentPopup(for: action, in: context)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        manager?.actionsDidChange()
    }
}
