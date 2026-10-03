import AxoCRX
import AxoCore
import AxoWeb
import Foundation
import Observation
import WebKit
import os

/// Runs web extensions: one `WKWebExtensionController` per profile, attached to that profile's
/// web views, with each enabled extension loaded into it.
///
/// Installs, updates, enabling, and uninstalling go through here, so the files on disk
/// (``ExtensionInstaller``), the records in the database (`ExtensionStore`), and what WebKit
/// has loaded stay in step.
@MainActor
@Observable
public final class ExtensionManager {
    /// Load errors by extension ID, such as a folder that's gone or a manifest WebKit rejects.
    public private(set) var loadErrors: [String: String] = [:]
    /// Changes whenever toolbar actions change (an extension loads, unloads, or updates its
    /// icon, badge, or title), so views reading ``toolbarActions(for:tabID:)`` refresh.
    public private(set) var actionsRevision = 0

    /// The browser window extensions see. Set by the app.
    @ObservationIgnored public weak var browser: (any ExtensionBrowsing)?
    /// Called when an extension's toolbar button should show its popup.
    @ObservationIgnored public var onPresentPopup: ((_ extensionID: String, _ popover: NSPopover) -> Void)?

    @ObservationIgnored private let installer: ExtensionInstaller
    @ObservationIgnored private let store: ExtensionStore
    @ObservationIgnored let pool: WebViewPool
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored private var controllers: [Profile.ID: WKWebExtensionController] = [:]
    @ObservationIgnored private var contexts: [Profile.ID: [String: WKWebExtensionContext]] = [:]
    @ObservationIgnored private var loadedProfiles: Set<Profile.ID> = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.perezstudio.Axo", category: "Extensions")
    @ObservationIgnored private var tabAdapters: [Tab.ID: ExtensionTab] = [:]
    @ObservationIgnored private lazy var delegate = ControllerDelegate(manager: self)
    @ObservationIgnored lazy var window = ExtensionWindow(manager: self)

    /// Creates a manager and attaches its controllers to the pool's new web views.
    ///
    /// - Parameters:
    ///   - installer: Where installed extension files live.
    ///   - store: Records of which extensions are installed and enabled.
    ///   - pool: The web view pool whose web views run extensions.
    ///   - persistent: Whether extension storage persists per profile. `false` for tests.
    public init(installer: ExtensionInstaller, store: ExtensionStore, pool: WebViewPool, persistent: Bool = true) {
        self.installer = installer
        self.store = store
        self.pool = pool
        self.persistent = persistent
        pool.configureWebView = { [weak self] configuration, profileID in
            guard let self else { return }
            configuration.webExtensionController = self.controller(for: profileID)
        }
    }

    // MARK: Controllers

    /// The profile's extension controller, created on first use. Its storage is kept per profile,
    /// and its extension pages use the profile's website data.
    public func controller(for profileID: Profile.ID) -> WKWebExtensionController {
        if let controller = controllers[profileID] { return controller }
        let configuration: WKWebExtensionController.Configuration = persistent
            ? .init(identifier: profileID)
            : .nonPersistent()
        configuration.defaultWebsiteDataStore = pool.dataStore(for: profileID)
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = delegate
        controllers[profileID] = controller
        return controller
    }

    /// The loaded context for an extension, if it's enabled and loaded.
    public func context(for extensionID: String, profileID: Profile.ID) -> WKWebExtensionContext? {
        contexts[profileID]?[extensionID]
    }

    /// Loads a profile's enabled extensions, once. Call early (for example at launch) so content
    /// scripts are ready before the first pages load.
    public func loadExtensions(for profileID: Profile.ID) async {
        guard loadedProfiles.insert(profileID).inserted else { return }
        let records = (try? await store.extensions(for: profileID)) ?? []
        for record in records where record.isEnabled {
            await load(record)
        }
    }

    /// Whether a controller belongs to the profile the window shows; only that one sees it.
    func isCurrent(_ controller: WKWebExtensionController) -> Bool {
        guard let profileID = browser?.currentProfileID else { return false }
        return controllers[profileID] === controller
    }

    // MARK: Tabs and window

    /// The stable object extensions see for a tab.
    func tabAdapter(for id: Tab.ID) -> ExtensionTab {
        if let adapter = tabAdapters[id] { return adapter }
        let adapter = ExtensionTab(tabID: id, manager: self)
        tabAdapters[id] = adapter
        return adapter
    }

    private var currentController: WKWebExtensionController? {
        browser?.currentProfileID.map { controller(for: $0) }
    }

    /// Tells extensions a tab opened (`chrome.tabs.onCreated`).
    public func tabDidOpen(_ id: Tab.ID) {
        currentController?.didOpenTab(tabAdapter(for: id))
    }

    /// Tells extensions a tab closed (`chrome.tabs.onRemoved`).
    public func tabDidClose(_ id: Tab.ID) {
        guard let adapter = tabAdapters.removeValue(forKey: id) else { return }
        currentController?.didCloseTab(adapter, windowIsClosing: false)
    }

    /// Tells extensions which tab is now active (`chrome.tabs.onActivated`).
    public func tabDidActivate(_ id: Tab.ID?, previous: Tab.ID?) {
        guard let id else { return }
        currentController?.didActivateTab(tabAdapter(for: id), previousActiveTab: previous.map { tabAdapter(for: $0) })
        actionsDidChange()
    }

    /// Tells extensions a tab's page changed (`chrome.tabs.onUpdated`).
    public func tabDidChange(_ id: Tab.ID) {
        currentController?.didChangeTabProperties([.URL, .title, .loading], for: tabAdapter(for: id))
    }

    /// Tells extensions the window now shows another Space (and possibly another profile).
    public func windowDidChangeSpace() {
        currentController?.didFocusWindow(window)
        actionsDidChange()
    }

    // MARK: Toolbar

    /// A toolbar button for an extension: what its action shows for a tab.
    public struct ToolbarAction: Identifiable, Equatable {
        /// The extension ID.
        public var id: String
        /// The button's title (`action.default_title`, or the extension's name).
        public var label: String
        /// The icon at toolbar size.
        public var icon: NSImage?
        /// The badge text, or an empty string.
        public var badge: String
        /// Whether the button can be clicked.
        public var isEnabled: Bool
    }

    /// The toolbar buttons for a profile's loaded extensions, for the given tab, by name.
    public func toolbarActions(for profileID: Profile.ID, tabID: Tab.ID?) -> [ToolbarAction] {
        _ = actionsRevision
        let tab = tabID.map { tabAdapter(for: $0) }
        return (contexts[profileID] ?? [:])
            .compactMap { id, context -> ToolbarAction? in
                guard let action = context.action(for: tab) else { return nil }
                return ToolbarAction(
                    id: id,
                    label: action.label.isEmpty ? (context.webExtension.displayName ?? id) : action.label,
                    icon: action.icon(for: CGSize(width: 16, height: 16)),
                    badge: action.badgeText,
                    isEnabled: action.isEnabled
                )
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Clicks an extension's toolbar button: shows its popup, or sends `action.onClicked`.
    public func performAction(extensionID: String, profileID: Profile.ID, tabID: Tab.ID?) {
        context(for: extensionID, profileID: profileID)?.performAction(for: tabID.map { tabAdapter(for: $0) })
    }

    func presentPopup(for action: WKWebExtension.Action, in context: WKWebExtensionContext) {
        guard let popover = action.popupPopover else { return }
        onPresentPopup?(context.uniqueIdentifier, popover)
    }

    func actionsDidChange() {
        actionsRevision += 1
    }

    // MARK: Installing

    /// Installs (or updates) an extension from a CRX file and runs it.
    @discardableResult
    public func install(crx data: Data, for profileID: Profile.ID) async throws -> WebExtensionRecord {
        let installed = try installer.install(crx: data, for: profileID)
        return try await register(installed, profileID: profileID)
    }

    /// Adds an unpacked extension folder (developer mode) and runs it from where it is.
    @discardableResult
    public func installUnpacked(at folder: URL, for profileID: Profile.ID) async throws -> WebExtensionRecord {
        let installed = try installer.inspectUnpacked(at: folder)
        return try await register(installed, profileID: profileID)
    }

    /// Turns an extension on (loading it) or off (unloading it).
    public func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async throws {
        try await store.setEnabled(enabled, extensionID: extensionID, profileID: profileID)
        if enabled, let record = try await store.record(extensionID, profileID: profileID) {
            await load(record)
        } else {
            unload(extensionID, profileID: profileID)
        }
    }

    /// Stops and removes an extension. Axo's copy of its files is deleted; an unpacked folder is
    /// left alone.
    public func uninstall(_ extensionID: String, profileID: Profile.ID) async throws {
        unload(extensionID, profileID: profileID)
        if let record = try await store.record(extensionID, profileID: profileID) {
            try? installer.uninstall(
                InstalledExtension(
                    id: record.extensionID,
                    manifest: ExtensionManifest(name: record.name, version: record.version, manifestVersion: 3),
                    folder: record.folder,
                    isUnpacked: record.isUnpacked
                ),
                for: profileID
            )
        }
        try await store.remove(extensionID, profileID: profileID)
        loadErrors[extensionID] = nil
    }

    /// A profile's installed extensions.
    public func extensions(for profileID: Profile.ID) async throws -> [WebExtensionRecord] {
        try await store.extensions(for: profileID)
    }

    private func register(_ installed: InstalledExtension, profileID: Profile.ID) async throws -> WebExtensionRecord {
        try await store.save(WebExtensionRecord(
            profileID: profileID,
            extensionID: installed.id,
            name: installed.manifest.name,
            version: installed.manifest.version,
            folderPath: installed.folder.path,
            isUnpacked: installed.isUnpacked
        ))
        let record = try await store.record(installed.id, profileID: profileID) ?? {
            throw ExtensionInstallError.couldNotWrite
        }()
        // Reload so an update's new files take effect.
        unload(installed.id, profileID: profileID)
        if record.isEnabled {
            await load(record)
        }
        return record
    }

    // MARK: Loading

    private func load(_ record: WebExtensionRecord) async {
        guard context(for: record.extensionID, profileID: record.profileID) == nil else { return }
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: record.folder)
            let context = WKWebExtensionContext(for: webExtension)
            // Chrome's ID, so `browser.runtime.id` matches what native messaging hosts and other
            // extensions expect, and a stable base URL so the extension's storage survives relaunches.
            context.uniqueIdentifier = record.extensionID
            if let baseURL = URL(string: "webkit-extension://\(record.extensionID)/") {
                context.baseURL = baseURL
            }
            // Developers can inspect background pages from Safari's Develop menu until Axo's own
            // Web Inspector arrives.
            context.isInspectable = true
            // Grant what the manifest asks for, as Chrome does at install. Optional permissions
            // stay ungranted until the extension requests them.
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller(for: record.profileID).load(context)
            contexts[record.profileID, default: [:]][record.extensionID] = context
            loadErrors[record.extensionID] = nil
            actionsDidChange()
        } catch {
            logger.error("Couldn't load extension \(record.extensionID): \(error)")
            loadErrors[record.extensionID] = error.localizedDescription
        }
    }

    private func unload(_ extensionID: String, profileID: Profile.ID) {
        guard let context = contexts[profileID]?.removeValue(forKey: extensionID) else { return }
        try? controller(for: profileID).unload(context)
        actionsDidChange()
    }
}
