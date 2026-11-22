import AxoCore
import AxoUI
import AxoWeb
import SwiftUI
import WebKit

/// Axo for iPhone and iPad.
@main
struct AxoiOSApp: App {
    @State private var model = AppEnvironment.makeBrowserModel()

    var body: some Scene {
        WindowGroup {
            MobileBrowserView(model: model)
                .defaultAppStorage(AppEnvironment.settings)
        }
    }
}

/// Builds the app's long-lived objects.
enum AppEnvironment {
    /// Set by UI tests: an in-memory database and non-persistent website data, so every launch
    /// starts empty and nothing touches the person's real data.
    static let isUITesting = ProcessInfo.processInfo.environment["AXO_UI_TESTING"] == "1"

    /// The settings views read with `@AppStorage` (such as where the iPhone's address bar sits).
    /// In UI testing mode a separate store, emptied at launch, so one test's settings never reach
    /// the next, nor the person's own.
    static let settings: UserDefaults = {
        guard isUITesting, let store = UserDefaults(suiteName: "com.perezstudio.Axo.iOS.uitesting") else { return .standard }
        store.removePersistentDomain(forName: "com.perezstudio.Axo.iOS.uitesting")
        return store
    }()

    /// Where Axo keeps its database, inside the app's container.
    static var databaseURL: URL {
        URL.applicationSupportDirectory.appending(path: "Axo/Axo.sqlite")
    }

    static func makeBrowserModel() -> BrowserModel {
        let pool = isUITesting ? WebViewPool(makeDataStore: { _ in .nonPersistent() }) : WebViewPool()
        // UI tests' pages never count as the person's Screen Time usage.
        if isUITesting { pool.reportsScreenTimeUsage = false }
        do {
            let store = isUITesting ? try TabStore.makeInMemory() : try TabStore.openOnDisk(at: databaseURL)
            return BrowserModel(store: store, pool: pool)
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
