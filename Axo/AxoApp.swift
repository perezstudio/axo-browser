//
//  AxoApp.swift
//  Axo
//
//  Created by Kevin Perez on 10/2/26.
//

import AxoCore
import AxoExtensions
import AxoIntegration
import AxoUI
import AxoWeb
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
        WindowGroup {
            BrowserWindow(model: model)
                // Links from other apps (as the default browser) and opened HTML files become
                // tabs in this window instead of opening another window.
                .onOpenURL { url in
                    Task { await model.openExternalURL(url) }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1200, height: 800)
        .commands { BrowserCommands() }
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

    static func makeBrowserModel() -> BrowserModel {
        let model = makeModel()
        if !isUITesting {
            model.onSpaceChange = { UserDefaults.standard.set($0.uuidString, forKey: lastSpaceKey) }
            // Not in UI tests, so nothing in a test run can offer to change the default browser.
            model.defaultBrowser = SystemDefaultBrowser()
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

/// Connects the window model (AxoUI) and the extension manager (AxoExtensions), which don't
/// depend on each other: extensions see the window's tabs, hear about tab events, and show their
/// toolbar buttons and popups.
@MainActor
final class ExtensionBridge: ExtensionBrowsing, ExtensionToolbarProviding, ExtensionManaging {
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
}
