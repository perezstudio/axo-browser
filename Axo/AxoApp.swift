//
//  AxoApp.swift
//  Axo
//
//  Created by Kevin Perez on 10/2/26.
//

import AxoCore
import AxoExtensions
import AxoImport
import AxoInspector
import AxoIntegration
import AxoUI
import AxoWeb
import AppIntents
import Foundation
import SwiftUI
import WebKit

@main
struct AxoApp: App {
    @State private var model = AppEnvironment.makeBrowserModel()

    init() {
        // Axo has its own tabs in the sidebar; macOS window tabs ("Show Tab Bar") would only confuse.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // One browser window for Milestone 1: the commands replace File > New Window, and every
        // window shares the same model.
        WindowGroup(id: AppEnvironment.browserWindowID) {
            BrowserWindow(model: model)
                .modifier(BrowserWindowOpener(model: model))
                // Links from other apps (as the default browser) and opened HTML files open in
                // mini windows, not another browser window (handlesExternalEvents below).
                .onOpenURL { url in
                    Task { await model.openExternalURL(url, sourceApp: LinkSource.currentSourceBundleID()) }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            if AppEnvironment.isUITesting {
                // UI tests can't send links from another app: XCUIApplication.open hands them to a
                // new Axo process launched outside testing mode, which would use the real
                // database. This sends one through the same path instead.
                CommandMenu("Testing") {
                    Button("Open Link from Another App") {
                        let environment = ProcessInfo.processInfo.environment
                        guard let url = environment["AXO_UI_TESTING_EXTERNAL_URL"].flatMap(URL.init(string:)) else { return }
                        Task { await model.openExternalURL(url, sourceApp: environment["AXO_UI_TESTING_SOURCE_APP"]) }
                    }
                    .keyboardShortcut("u", modifiers: [.command, .control, .option])
                }
            }
            // Show or hide the sidebar from the keyboard (View › Toggle Sidebar, ⌃⌘S).
            SidebarCommands()
            BrowserCommands()
        }
    }
}

/// Builds the app's long-lived objects.
enum AppEnvironment {
    /// Set by UI tests: use an in-memory database, non-persistent website data, and a temporary
    /// downloads folder, so every launch starts empty and nothing touches the user's real data.
    static let isUITesting = ProcessInfo.processInfo.environment["AXO_UI_TESTING"] == "1"

    /// Where Axo keeps its database.
    static var databaseURL: URL {
        URL.applicationSupportDirectory.appending(path: "Axo/Axo.sqlite")
    }


    /// The browser window group's ID, for reopening it.
    static let browserWindowID = "browser"

    /// Runs web extensions for every profile. Kept for the app's lifetime.
    static var extensionManager: ExtensionManager?
    /// Connects the window model and the extension manager. Kept for the app's lifetime.
    static var extensionBridge: ExtensionBridge?

    /// Where installed extensions live.
    static var extensionsFolder: URL {
        isUITesting
            ? FileManager.default.temporaryDirectory.appending(path: "AxoUITests-Extensions-\(UUID().uuidString)", directoryHint: .isDirectory)
            : URL.applicationSupportDirectory.appending(path: "Axo/Extensions", directoryHint: .isDirectory)
    }

    /// Where downloads go during UI tests.
    static let uiTestingDownloadsDirectory = FileManager.default.temporaryDirectory
        .appending(path: "AxoUITests-Downloads-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Where the last Space the window showed is remembered between launches.
    static let lastSpaceKey = "lastSpaceID"

    /// Attaches extension controllers to the pool and loads every profile's enabled extensions.
    /// Loading is asynchronous, so a page that loads in the first moments after launch may run
    /// before its extensions are ready.
    private static func startExtensions(store: TabStore, pool: WebViewPool) -> ExtensionManager {
        let manager = ExtensionManager(
            installer: ExtensionInstaller(root: extensionsFolder),
            store: store.extensions,
            pool: pool,
            persistent: !isUITesting
        )
        // Developer tools (Inspect Element and the Web Inspector) for pages and for extensions'
        // popups and background pages.
        pool.addWebViewConfigurator { configuration, _ in
            WebInspector.enableDeveloperTools(in: configuration)
            // Picture in picture for web video (private WebKit preference, in AxoInspector).
            PictureInPicture.enable(in: configuration)
        }
        manager.configureExtensionWebViews = { WebInspector.enableDeveloperTools(in: $0) }
        extensionManager = manager
        Task {
            for profile in (try? await store.profiles()) ?? [] {
                await manager.loadExtensions(for: profile.id)
            }
            // UI tests can preinstall an unpacked extension to exercise the toolbar.
            if isUITesting, let path = ProcessInfo.processInfo.environment["AXO_UI_TESTING_EXTENSION"],
               let profileID = try? await store.bootstrap().profileID {
                _ = try? await manager.installUnpacked(at: URL(fileURLWithPath: path), for: profileID)
            }
        }
        return manager
    }

    /// Where other browsers keep their data. UI tests never read the real folder: they use
    /// `AXO_UI_TESTING_IMPORT_ROOT` (a folder of fixtures) or an empty folder.
    static var otherBrowsersFolder: URL {
        guard isUITesting else { return .applicationSupportDirectory }
        if let path = ProcessInfo.processInfo.environment["AXO_UI_TESTING_IMPORT_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appending(path: "AxoUITests-NoBrowsers-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func makeBrowserModel() -> BrowserModel {
        let model = makeModel()
        if !isUITesting {
            model.onSpaceChange = { UserDefaults.standard.set($0.uuidString, forKey: lastSpaceKey) }
            // Not in UI tests, so nothing in a test run can offer to change the default browser.
            model.defaultBrowser = SystemDefaultBrowser()
            // Not in UI tests either, so a test run never shows macOS's location prompt.
            model.locationAuthorization = SystemLocationAuthorization()
        }
        return model
    }

    private static func makeModel() -> BrowserModel {
        let lastSpaceID = isUITesting ? nil : UserDefaults.standard.string(forKey: lastSpaceKey).flatMap(UUID.init(uuidString:))
        let pool = isUITesting
            ? WebViewPool(
                makeDataStore: { _ in .nonPersistent() },
                downloads: DownloadManager(directory: uiTestingDownloadsDirectory)
            )
            : WebViewPool()
        do {
            let store = isUITesting ? try TabStore.makeInMemory() : try TabStore.openOnDisk(at: databaseURL)
            let manager = startExtensions(store: store, pool: pool)
            let model = BrowserModel(store: store, pool: pool, initialSpaceID: lastSpaceID)
            extensionBridge = ExtensionBridge(model: model, manager: manager)
            // Focus filters and other App Intents reach the store and window through this.
            IntentBridge.current = IntentBridge(store: store) { [weak model] spaceID in
                await model?.applyFocusSpace(spaceID)
            }
            model.browserImporter = BrowserImportBridge(importer: BrowserImporter(store: store, applicationSupport: otherBrowsersFolder))
            return model
        } catch {
            // Keep the browser usable for this session and say plainly that nothing will be saved.
            return BrowserModel(
                store: try! TabStore.makeInMemory(),
                pool: pool,
                alertMessage: "Axo couldn't open its database, so tabs you open won't be saved. (\(error.localizedDescription))"
            )
        }
    }
}

/// Connects AxoIntegration's default-browser check to the model. A wrapper rather than a
/// conformance, since the app owns neither the type nor the protocol.
@MainActor
struct SystemDefaultBrowser: DefaultBrowserSetting {
    let browser = DefaultBrowser()

    var isDefault: Bool { browser.isDefault }

    func makeDefault() async throws {
        try await browser.makeDefault()
    }
}

/// Registers the App Intents defined in AxoIntegration (Focus filters) with the app.
struct AxoAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [AxoIntegrationIntents.self] }
}

/// Lets the model bring the browser window back: routed links and Open in Axo add tabs, which
/// need a window to show in, even if the person closed it.
private struct BrowserWindowOpener: ViewModifier {
    let model: BrowserModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            model.showBrowserWindow = {
                let browserWindows = NSApp.windows.filter {
                    $0.identifier?.rawValue.hasPrefix(AppEnvironment.browserWindowID) == true
                }
                if let window = browserWindows.first(where: \.isVisible) {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: AppEnvironment.browserWindowID)
                }
                NSApp.activate()
            }
        }
    }
}

/// Finds the app that sent a link, so link routing rules can match by app. SwiftUI's
/// `onOpenURL` runs while AppKit is still handling the Get URL Apple Event, so the event and its
/// sender are available then. This was checked by hand with a small app sending a link to a
/// running Axo; when a link launches Axo, the sender may be unknown, and only domain rules apply.
enum LinkSource {
    /// The bundle ID of the app that sent the Apple Event being handled now, if any.
    static func currentSourceBundleID() -> String? {
        NSAppleEventManager.shared().currentAppleEvent.flatMap(sourceBundleID(of:))
    }

    /// The bundle ID of the app that sent an Apple Event, if it's still running. macOS sets the
    /// sender when the event is sent.
    static func sourceBundleID(of event: NSAppleEventDescriptor) -> String? {
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value else { return nil }
        return bundleID(ofProcess: pid)
    }

    /// The bundle ID of a running app.
    static func bundleID(ofProcess pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}

/// Connects AxoIntegration's location authorization to the model. Creating it at launch keeps
/// a `CLLocationManager` alive, which WebKit needs before it asks Axo about pages' location
/// requests; macOS only prompts when the person first allows a site.
@MainActor
final class SystemLocationAuthorization: LocationAuthorizing {
    let authorization = LocationAuthorization()

    func requestIfNeeded() {
        authorization.requestIfNeeded()
    }
}

/// Connects AxoImport to the window model's Import sheet.
@MainActor
final class BrowserImportBridge: BrowserImporting {
    private let importer: BrowserImporter
    /// The sources from the last ``availableSources()``, by option ID.
    private var sources: [String: BrowserImporter.Source] = [:]

    init(importer: BrowserImporter) {
        self.importer = importer
    }

    func availableSources() -> [ImportSourceOption] {
        let found = importer.availableSources()
        sources = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chromeProfiles = found.filter { if case .chrome = $0 { true } else { false } }.count
        return found.map { source in
            switch source {
            case .arc:
                ImportSourceOption(id: source.id, name: "Arc")
            case .chrome(let profile):
                ImportSourceOption(id: source.id, name: chromeProfiles > 1 ? "Google Chrome (\(profile.name))" : "Google Chrome")
            }
        }
    }

    func preview(_ sourceID: String) async throws -> ImportCounts {
        guard let source = sources[sourceID] else { return ImportCounts() }
        return Self.counts(try await importer.preview(source))
    }

    func importData(from sourceID: String, parts: Set<ImportPart>, currentSpace: Space) async throws -> ImportCounts {
        guard let source = sources[sourceID] else { return ImportCounts() }
        var chosen: BrowserImporter.Parts = []
        for part in parts {
            switch part {
            case .spaces: chosen.insert(.spaces)
            case .favorites: chosen.insert(.favorites)
            case .openTabs: chosen.insert(.openTabs)
            case .bookmarks: chosen.insert(.bookmarks)
            case .history: chosen.insert(.history)
            }
        }
        return Self.counts(try await importer.importData(from: source, parts: chosen, currentSpace: currentSpace))
    }

    private static func counts(_ counts: BrowserImporter.Counts) -> ImportCounts {
        ImportCounts(
            spaces: counts.spaces, pinnedTabs: counts.pinnedTabs, favorites: counts.favorites,
            openTabs: counts.openTabs, bookmarks: counts.bookmarks, historyPages: counts.historyPages
        )
    }
}

/// Connects the window model (AxoUI) and the extension manager (AxoExtensions), which don't
/// depend on each other: extensions see the window's tabs, hear about tab events, and show their
/// toolbar buttons and popups.
@MainActor
final class ExtensionBridge: ExtensionBrowsing, ExtensionToolbarProviding, ExtensionManaging, DeveloperToolsProviding {
    private weak var model: BrowserModel?
    private let manager: ExtensionManager

    init(model: BrowserModel, manager: ExtensionManager) {
        self.model = model
        self.manager = manager
        manager.browser = self
        manager.onPresentPopup = { [weak model] extensionID, popover in
            model?.presentExtensionPopup(popover, extensionID: extensionID)
        }
        model.extensionToolbar = self
        model.extensionManagement = self
        model.developerTools = self
        manager.onPermissionRequest = { [weak model] request in
            await model?.askExtensionPermission(
                ExtensionPermissionPrompt(extensionName: request.extensionName, lines: request.lines)
            ) ?? false
        }
        model.onTabEvent = { [weak manager] event in
            guard let manager else { return }
            switch event {
            case .opened(let id): manager.tabDidOpen(id)
            case .closed(let id): manager.tabDidClose(id)
            case .activated(let id, let previous): manager.tabDidActivate(id, previous: previous)
            case .changed(let id): manager.tabDidChange(id)
            case .spaceChanged: manager.windowDidChangeSpace()
            }
        }
    }

    // MARK: ExtensionBrowsing

    var currentProfileID: Profile.ID? { model?.space?.profileID }
    var windowTabs: [AxoCore.Tab] { model?.tabs ?? [] }
    var activeTabID: AxoCore.Tab.ID? { model?.selectedTabID }

    func openTab(url: URL?, active: Bool) async -> AxoCore.Tab.ID? {
        guard let model else { return nil }
        let previous = model.selectedTabID
        await model.openTab(url: url ?? URL(string: "about:blank")!)
        let opened = model.selectedTabID
        if !active, let previous { model.select(previous) }
        return opened
    }

    func activateTab(_ id: AxoCore.Tab.ID) {
        model?.select(id)
    }

    func closeTab(_ id: AxoCore.Tab.ID) async {
        await model?.closeTab(id)
    }

    // MARK: ExtensionToolbarProviding

    func toolbarItems(profileID: Profile.ID, tabID: AxoCore.Tab.ID?) -> [ExtensionToolbarItem] {
        manager.toolbarActions(for: profileID, tabID: tabID).map {
            ExtensionToolbarItem(id: $0.id, label: $0.label, icon: $0.icon, badge: $0.badge, isEnabled: $0.isEnabled)
        }
    }

    func performAction(extensionID: String, profileID: Profile.ID, tabID: AxoCore.Tab.ID?) {
        manager.performAction(extensionID: extensionID, profileID: profileID, tabID: tabID)
    }

    // MARK: ExtensionManaging

    func prepareInstall(from url: URL, profileID: Profile.ID) async throws -> ExtensionInstallPrompt {
        let summary = try await manager.prepareInstall(from: url, for: profileID)
        return ExtensionInstallPrompt(
            id: summary.extensionID, name: summary.name, version: summary.version,
            lines: summary.lines, isUnpacked: summary.isUnpacked
        )
    }

    func confirmInstall(_ extensionID: String, profileID: Profile.ID) async throws {
        try await manager.confirmInstall(extensionID, profileID: profileID)
    }

    func uninstall(_ extensionID: String, profileID: Profile.ID) async throws {
        try await manager.uninstall(extensionID, profileID: profileID)
    }

    func installedExtensions(profileID: Profile.ID) async -> [ExtensionSummary] {
        let records = (try? await manager.extensions(for: profileID)) ?? []
        return records.map { record in
            let context = manager.context(for: record.extensionID, profileID: profileID)
            return ExtensionSummary(
                id: record.extensionID,
                name: context?.webExtension.displayName ?? record.name,
                version: record.version,
                isEnabled: record.isEnabled,
                isUnpacked: record.isUnpacked,
                reachesAllRequestedSites: record.siteAccess == .all,
                lines: manager.grantedDescription(for: record.extensionID, profileID: profileID),
                loadError: manager.loadErrors[record.extensionID]
            )
        }
    }

    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async throws {
        try await manager.setEnabled(enabled, extensionID: extensionID, profileID: profileID)
    }

    func setReachesAllRequestedSites(_ all: Bool, extensionID: String, profileID: Profile.ID) async throws {
        try await manager.setSiteAccess(all ? .all : .click, extensionID: extensionID, profileID: profileID)
    }

    func inspectBackgroundPage(_ extensionID: String, profileID: Profile.ID) async -> Bool {
        guard let context = manager.context(for: extensionID, profileID: profileID) else { return false }
        if WebInspector.backgroundWebView(of: context) == nil {
            let failed: Bool = await withCheckedContinuation { continuation in
                context.loadBackgroundContent { continuation.resume(returning: $0 != nil) }
            }
            if failed { return false }
        }
        guard let background = WebInspector.backgroundWebView(of: context) else { return false }
        return WebInspector.show(background)
    }

    // MARK: DeveloperToolsProviding

    func toggleInspector(for tabID: AxoCore.Tab.ID) -> Bool {
        guard let webView = model?.pool.liveWebView(for: tabID) else { return true }
        if WebInspector.toggle(webView) { return true }
        WebInspector.allowSafariInspection(of: webView)
        return false
    }

    func showConsole(for tabID: AxoCore.Tab.ID) -> Bool {
        guard let webView = model?.pool.liveWebView(for: tabID) else { return true }
        if WebInspector.showConsole(webView) { return true }
        WebInspector.allowSafariInspection(of: webView)
        return false
    }
}
