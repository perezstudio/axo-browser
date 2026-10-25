import AppKit
import AxoChromium
import Foundation
import SwiftUI

/// The Chromium engine's debug setting (Phase 1 of `docs/chromium-engine.md`).
///
/// With the `ChromiumEngine` user default on, and a Debug build that embedded the engine (see
/// `scripts/embed-chromium-engine.sh`), every tab uses Chromium instead of WebKit. Turn it on
/// with `defaults write com.perezstudio.Axo ChromiumEngine -bool YES` or the launch argument
/// `-ChromiumEngine YES`, then relaunch. In UI testing mode it's off, unless a test opts in with
/// `AXO_UI_TESTING_CHROMIUM=1` (`ChromiumEngineUITests`).
enum ChromiumSupport {
    /// The user default that turns the engine on.
    static let settingKey = "ChromiumEngine"

    /// The engine's classes, when the setting is on and the engine loaded at launch.
    private(set) static var classes: ChromiumEngineClasses?

    /// Why the setting is on but Axo is using WebKit, said plainly for the person.
    private(set) static var problem: String?

    /// Set by UI tests that exercise the Chromium engine.
    static let uiTestingKey = "AXO_UI_TESTING_CHROMIUM"

    /// Where Chromium keeps profiles' website data: a temporary folder in UI testing mode.
    static var userDataDirectory: URL {
        AppEnvironment.isUITesting
            ? FileManager.default.temporaryDirectory.appending(path: "AxoUITests-Chromium-\(UUID().uuidString)", directoryHint: .isDirectory)
            : URL.applicationSupportDirectory.appending(path: "Axo/Chromium", directoryHint: .isDirectory)
    }

    /// Whether the Chromium engine was asked for: by the person's setting, or in UI testing mode
    /// only by a test that opts in.
    static func isRequested(in settings: UserDefaults, isUITesting: Bool, environment: [String: String]) -> Bool {
        isUITesting ? environment[uiTestingKey] == "1" : settings.bool(forKey: settingKey)
    }

    /// Loads the engine and makes `NSApp` its `AXOApplication`, which Chromium requires, when the
    /// setting is on. Called from ``AxoMain`` before SwiftUI starts, because `NSApp` must be an
    /// `AXOApplication` from the start.
    static func prepare() {
        guard isRequested(in: AppEnvironment.settings, isUITesting: AppEnvironment.isUITesting, environment: ProcessInfo.processInfo.environment) else { return }
        switch ChromiumFramework.load() {
        case .success(let loaded):
            guard ChromiumFramework.makeApplication() != nil else {
                problem = "The Chromium engine has no application class, so Axo is using WebKit."
                return
            }
            classes = loaded
        case .failure(let error):
            problem = "\(error) Axo is using WebKit."
        }
    }

    /// The pool's engine: Chromium, started, if it loaded at launch.
    static func makeEngine() -> ChromiumEngine? {
        guard let classes else { return nil }
        let engine = ChromiumEngine(classes: classes, userDataDirectory: userDataDirectory)
        engine.start()
        return engine
    }
}

/// Axo's entry point. It loads the Chromium engine when the debug setting asks for it, which has
/// to happen before SwiftUI creates `NSApp`, then runs the app.
@main
enum AxoMain {
    static func main() {
        ChromiumSupport.prepare()
        AxoApp.main()
    }
}
