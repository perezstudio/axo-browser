//
//  AxoApp.swift
//  Axo
//
//  Created by Kevin Perez on 10/2/26.
//

import AxoChromium
import AxoCore
import AxoExtensions
import AxoImport
import AxoInspector
import AxoIntegration
import AxoSync
import AxoUI
import AxoWeb
import AppIntents
import CoreSpotlight
import Foundation
import SwiftUI
import WebKit

/// The app's scenes. ``AxoMain`` starts it.
struct AxoApp: App {
    @State private var model = AppEnvironment.makeBrowserModel()

    init() {
        // Axo has its own tabs in the sidebar; macOS window tabs ("Show Tab Bar") would only confuse.
        NSWindow.allowsAutomaticWindowTabbing = false
        if AppEnvironment.isTestRun {
            // Start from the default window size and sidebar width, not an earlier test's.
            TestWindows.forgetSavedFrames(in: .standard)
        }
        if AppEnvironment.isUITesting, let appearance = AppEnvironment.uiTestingAppearance {
            // `shared`, not `NSApp`: on WebKit nothing has created the application yet (the
            // Chromium engine creates its own before SwiftUI starts, which `shared` returns).
            NSApplication.shared.appearance = appearance
        }
    }

    var body: some Scene {
        // One browser window for Milestone 1: the commands replace File > New Window, and every
        // window shares the same model.
        WindowGroup(id: AppEnvironment.browserWindowID) {
            BrowserWindow(model: model)
                .defaultAppStorage(AppEnvironment.settings)
                .modifier(BrowserWindowOpener(model: model))
                .background {
                    if AppEnvironment.isTestRun { TestWindowPlacer() }
                }
                // Links from other apps (as the default browser) and opened HTML files open in
                // mini windows, not another browser window (handlesExternalEvents below).
                .onOpenURL { url in
                    Task { await model.openExternalURL(url, sourceApp: LinkSource.currentSourceBundleID()) }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // A page handed off from another device.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    Task { await model.continueBrowsing(url) }
                }
                // A pinned tab or history page chosen in Spotlight.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                          let target = SpotlightTarget(identifier: identifier) else { return }
                    Task {
                        switch target {
                        case .tab(let id): _ = await model.showTabForIntent(id)
                        case .page(let url): await model.continueBrowsing(url)
                        }
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
        // Test runs share saved window state with the person's Axo, which has no scene for test
        // windows' ID, so they neither restore nor leave windows to restore.
        .restorationBehavior(AppEnvironment.isTestRun ? .disabled : .automatic)

        Settings {
            SettingsView(model: model)
                .defaultAppStorage(AppEnvironment.settings)
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

    /// The appearance UI tests ask for with `AXO_UI_TESTING_APPEARANCE` ("light" or "dark"), so
    /// they can check both without changing the Mac's own setting. The `-AppleInterfaceStyle`
    /// launch argument doesn't change Axo's appearance. `nil` follows the system.
    static var uiTestingAppearance: NSAppearance? {
        uiTestingAppearance(ProcessInfo.processInfo.environment["AXO_UI_TESTING_APPEARANCE"])
    }

    /// The appearance named by an `AXO_UI_TESTING_APPEARANCE` value.
    static func uiTestingAppearance(_ value: String?) -> NSAppearance? {
        switch value?.lowercased() {
        case "dark": NSAppearance(named: .darkAqua)
        case "light": NSAppearance(named: .aqua)
        default: nil
        }
    }

    /// Whether this launch runs tests: UI testing mode, or hosting the app's unit tests (XCTest
    /// sets `XCTestConfigurationFilePath`). Test runs get the same isolation as UI testing mode:
    /// an in-memory database, non-persistent website data, separate settings, and no system
    /// integrations, so nothing in a test run touches the person's real data.
    static let isTestRun = isTestRun(isUITesting: isUITesting, environment: ProcessInfo.processInfo.environment)

    /// Whether a launch with `environment` runs tests. See ``isTestRun``.
    static func isTestRun(isUITesting: Bool, environment: [String: String]) -> Bool {
        isUITesting || environment["XCTestConfigurationFilePath"] != nil
    }

    /// Where the person's choices in Settings live. Tests share user defaults with the person's
    /// own Axo, so test runs get a separate store, emptied at launch.
    static let settings: UserDefaults = {
        guard isTestRun else { return .standard }
        let name = "com.perezstudio.Axo.UITesting"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }()

    /// Where Axo keeps its database.
    static var databaseURL: URL {
        URL.applicationSupportDirectory.appending(path: "Axo/Axo.sqlite")
    }


    /// The store the app opened at launch. Tests check that hosting them never opens the
    /// on-disk database.
    private(set) static var store: TabStore?

    /// The window model the app made at launch. Tests check that hosting them leaves out the
    /// system integrations.
    private(set) static var browserModel: BrowserModel?

    /// Runs iCloud sync. Kept for the app's lifetime.
    static var iCloudSync: ICloudSyncController?

    /// Keeps Spotlight showing pinned tabs and history. Kept for the app's lifetime.
    static var spotlightIndexer: SpotlightIndexer?

    /// The browser window group's ID, for reopening it. Test runs have their own, so AppKit saves
    /// test windows' frames apart from the person's (``TestWindows``).
    static let browserWindowID = TestWindows.browserWindowID(isTestRun: isTestRun)

    /// Runs web extensions for every profile. Kept for the app's lifetime.
    static var extensionManager: ExtensionManager?
    /// Connects the window model and the extension manager. Kept for the app's lifetime.
    static var extensionBridge: ExtensionBridge?
    /// Connects the window model and the Chromium engine's extensions, when that engine runs.
    static var chromiumExtensionBridge: ChromiumExtensionBridge?

    /// Where installed extensions live.
    static var extensionsFolder: URL {
        isTestRun
            ? FileManager.default.temporaryDirectory.appending(path: "AxoUITests-Extensions-\(UUID().uuidString)", directoryHint: .isDirectory)
            : URL.applicationSupportDirectory.appending(path: "Axo/Extensions", directoryHint: .isDirectory)
    }

    /// Where downloads go during test runs.
    static let testDownloadsDirectory = FileManager.default.temporaryDirectory
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
            persistent: !isTestRun
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

    /// Where other browsers keep their data. Test runs never read the real folder: UI tests use
    /// `AXO_UI_TESTING_IMPORT_ROOT` (a folder of fixtures), and other test runs an empty folder.
    static var otherBrowsersFolder: URL {
        guard isTestRun else { return .applicationSupportDirectory }
        if isUITesting, let path = ProcessInfo.processInfo.environment["AXO_UI_TESTING_IMPORT_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appending(path: "AxoUITests-NoBrowsers-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Whether iCloud sync can run: in builds signed for it (`isEntitled`), never in test runs.
    static func syncsWithICloud(isTestRun: Bool, isEntitled: @autoclosure () -> Bool) -> Bool {
        !isTestRun && isEntitled()
    }

    static func makeBrowserModel() -> BrowserModel {
        let model = makeModel()
        if !isTestRun {
            model.onSpaceChange = { UserDefaults.standard.set($0.uuidString, forKey: lastSpaceKey) }
            // Not in test runs, so nothing in a test run can offer to change the default browser.
            model.defaultBrowser = SystemDefaultBrowser()
            // Not in test runs either, so a test run never shows macOS's location prompt.
            model.locationAuthorization = SystemLocationAuthorization()
            model.pageSummarizer = SystemPageSummarizer()
            model.externalApps = SystemExternalApps()
            // First run shows once, for a browser with nothing in it yet (#175).
            model.firstRunRecord = DefaultsFirstRunRecord(defaults: .standard)
        } else {
            // Test runs never offer their pages to the person's other devices, and their pages
            // never count as the person's Screen Time usage.
            model.isHandoffEnabled = false
            model.pool.reportsScreenTimeUsage = false
            // The on-device model's answers vary, so test runs get a predictable stand-in.
            model.pageSummarizer = UITestingPageSummarizer()
            // Test runs never open another app; a tab stands in for one.
            let externalApps = UITestingExternalApps()
            externalApps.onOpen = { [weak model] _ in
                Task { await model?.openTab(url: UITestingExternalApps.openedPage) }
            }
            model.externalApps = externalApps
            // Copy Link writes to a pasteboard of the test run's own, never the person's clipboard.
            model.copyLink = { url in
                let pasteboard = NSPasteboard(name: TestPasteboard.name)
                pasteboard.clearContents()
                pasteboard.setString(url.absoluteString, forType: .string)
            }
            // First run never shows in test runs, unless a UI test asks for it.
            if isUITesting, ProcessInfo.processInfo.environment["AXO_UI_TESTING_FIRST_RUN"] == "1" {
                model.firstRunRecord = InMemoryFirstRunRecord()
            }
            // Notices stay longer, so a slow UI query still finds them.
            model.noticeSleep = { duration in try? await Task.sleep(for: duration * 6) }
        }
        browserModel = model
        return model
    }

    private static func makeModel() -> BrowserModel {
        let lastSpaceID = isTestRun ? nil : UserDefaults.standard.string(forKey: lastSpaceKey).flatMap(UUID.init(uuidString:))
        // Test runs save into a temporary folder, on either engine, never the person's Downloads.
        let downloadsFolder = isTestRun ? testDownloadsDirectory : URL.downloadsDirectory
        let chromium = ChromiumSupport.makeEngine(downloadsFolder: downloadsFolder)
        let pool = if let chromium {
            WebViewPool(engine: chromium, downloads: DownloadManager(directory: downloadsFolder))
        } else if isTestRun {
            WebViewPool(
                makeDataStore: { _ in .nonPersistent() },
                downloads: DownloadManager(directory: testDownloadsDirectory)
            )
        } else {
            WebViewPool()
        }
        do {
            let store = isTestRun ? try TabStore.makeInMemory() : try TabStore.openOnDisk(at: databaseURL)
            self.store = store
            // WebKit's extensions (WKWebExtension) run only in test runs, which use WebKit. On
            // Chromium, ChromiumExtensionBridge connects the engine's own extensions.
            let manager = chromium == nil ? startExtensions(store: store, pool: pool) : nil
            let model = BrowserModel(store: store, pool: pool, initialSpaceID: lastSpaceID)
            if let manager {
                extensionBridge = ExtensionBridge(model: model, manager: manager)
            }
            if let chromium {
                chromium.onStateChange = { [weak model] (state: ChromiumEngine.State) in
                    guard case .failed(let reason) = state else { return }
                    // Pages can't load without it, and there's no other engine on the Mac.
                    if isUITesting {
                        model?.alertMessage = "The Chromium engine didn't start: \(reason)"
                    } else {
                        ChromiumSupport.failToLaunch(reason: reason)
                    }
                }
                chromiumExtensionBridge = ChromiumExtensionBridge(model: model, engine: chromium, store: store)
                // UI tests can preinstall an unpacked extension, as with WebKit.
                if isUITesting, let path = ProcessInfo.processInfo.environment["AXO_UI_TESTING_EXTENSION"] {
                    let previous = chromium.onStateChange
                    chromium.onStateChange = { [weak chromium] state in
                        previous?(state)
                        guard state == .ready, let chromium else { return }
                        Task {
                            guard let profileID = try? await store.bootstrap().profileID else { return }
                            _ = try? await chromium.loadUnpackedExtension(at: URL(fileURLWithPath: path, isDirectory: true), profileID: profileID)
                        }
                    }
                }
            }
            // Focus filters and other App Intents reach the store and window through this.
            IntentBridge.current = IntentBridge(store: store, window: BrowserIntentWindow(model: model))
            // Test runs use an in-memory database, which must never reach the system's Spotlight index.
            if !isTestRun {
                let indexer = SpotlightIndexer(store: store)
                indexer.start()
                spotlightIndexer = indexer
            }
            // iCloud sync, in builds signed for it and never in test runs (the pane then explains
            // that this copy can't sync).
            let sync = ICloudSyncController(
                store: SyncStore(database: store.database),
                isAvailable: syncsWithICloud(
                    isTestRun: isTestRun,
                    isEntitled: CloudKitSync.isAvailable(containerIdentifier: ICloudSyncController.containerIdentifier)
                )
            )
            iCloudSync = sync
            model.iCloudSync = sync
            Task { await sync.refresh() }
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

/// Registers the App Intents defined in AxoIntegration (Focus filters, Shortcuts actions) with
/// the app.
struct AxoAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [AxoIntegrationIntents.self] }
}

/// Phrases for Siri and Spotlight. Every action is also in the Shortcuts app.
struct AxoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowSpaceIntent(),
            phrases: [
                "Show \(\.$space) in \(.applicationName)",
                "Switch to \(\.$space) in \(.applicationName)",
            ],
            shortTitle: "Show Space",
            systemImageName: "square.stack"
        )
        AppShortcut(
            intent: FindTabsIntent(),
            phrases: ["Find tabs in \(.applicationName)", "Search \(.applicationName) tabs"],
            shortTitle: "Find Tabs",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: SaveTabToSpaceIntent(),
            phrases: ["Save this tab to \(\.$space) in \(.applicationName)"],
            shortTitle: "Save Tab to Space",
            systemImageName: "pin"
        )
        AppShortcut(
            intent: GetCurrentTabIntent(),
            phrases: ["Get the current tab in \(.applicationName)"],
            shortTitle: "Get Current Tab",
            systemImageName: "macwindow"
        )
    }
}

/// Connects AxoIntegration's intents to the window model.
@MainActor
final class BrowserIntentWindow: IntentWindow {
    private weak var model: BrowserModel?

    init(model: BrowserModel) {
        self.model = model
    }

    func applyFocusSpace(_ spaceID: Space.ID?) async {
        await model?.applyFocusSpace(spaceID)
    }

    func showSpace(_ spaceID: Space.ID) async -> Bool {
        await model?.showSpaceForIntent(spaceID) ?? false
    }

    func open(_ url: URL, in spaceID: Space.ID?) async {
        await model?.openForIntent(url, in: spaceID)
    }

    func showTab(_ tabID: AxoCore.Tab.ID) async -> Bool {
        await model?.showTabForIntent(tabID) ?? false
    }

    var currentTab: AxoCore.Tab? {
        model?.selectedTab
    }

    func saveCurrentTab(to spaceID: Space.ID, pinned: Bool) async throws -> AxoCore.Tab {
        guard let model else { throw IntentBridgeError.notReady }
        return try await model.saveCurrentTab(to: spaceID, pinned: pinned)
    }
}

/// Lets the model bring the browser window back: routed links and Open in Axo add tabs, which
/// need a window to show in, even if the person closed it.
private struct BrowserWindowOpener: ViewModifier {
    let model: BrowserModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            model.isAppActive = { NSApp.isActive }
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

/// Connects AxoIntegration's on-device summarizer to the model.
struct SystemPageSummarizer: PageSummarizing {
    let summarizer = PageSummarizer()

    var unavailableReason: String? { summarizer.availability.message }

    func summarize(title: String, url: URL?, text: String) async throws -> String {
        try await summarizer.summarize(title: title, url: url, text: text)
    }
}

/// A predictable summarizer for UI tests: the page's title and the start of its text.
struct UITestingPageSummarizer: PageSummarizing {
    var unavailableReason: String? { nil }

    func summarize(title: String, url: URL?, text: String) async throws -> String {
        "• \(title): \(text.prefix(40))"
    }
}

/// The pasteboard test runs copy links to, which UI tests read, instead of the person's clipboard.
enum TestPasteboard {
    static let name = NSPasteboard.Name("com.perezstudio.Axo.testing")
}

/// Finds and opens the apps pages' links to other apps go to, through Launch Services.
@MainActor
final class SystemExternalApps: ExternalAppOpening {
    func appName(for url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              // Axo opens nothing a page sends it this way.
              Bundle(url: app)?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Names an app for `mailto:` links (Mail) and none for others, and never opens an app: UI tests
/// see the prompt without any app opening. What would have opened shows as a tab titled "Opened
/// in another app" (`onOpen`), so a test can tell which answer the person gave.
@MainActor
final class UITestingExternalApps: ExternalAppOpening {
    /// Called with each link that would have opened in another app.
    var onOpen: (URL) -> Void = { _ in }

    func appName(for url: URL) -> String? {
        url.scheme?.lowercased() == "mailto" ? "Mail" : nil
    }

    func open(_ url: URL) {
        onOpen(url)
    }

    /// The page the tab shows for an opened link.
    static let openedPage = URL(string: "data:text/html,<title>Opened in another app</title>")!
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
