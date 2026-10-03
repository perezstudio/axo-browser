//
//  AxoApp.swift
//  Axo
//
//  Created by Kevin Perez on 10/2/26.
//

import AxoCore
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

    /// Where downloads go during UI tests.
    static let uiTestingDownloadsDirectory = FileManager.default.temporaryDirectory
        .appending(path: "AxoUITests-Downloads-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Where the last Space the window showed is remembered between launches.
    static let lastSpaceKey = "lastSpaceID"

    static func makeBrowserModel() -> BrowserModel {
        let model = makeModel()
        if !isUITesting {
            model.onSpaceChange = { UserDefaults.standard.set($0.uuidString, forKey: lastSpaceKey) }
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
            return BrowserModel(store: store, pool: pool, initialSpaceID: lastSpaceID)
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
