import AppKit
import AxoChromium
import Foundation
import SwiftUI

/// The Mac's web engine: Chromium (see `docs/chromium-engine.md`).
///
/// Every Mac launch runs its tabs on the Chromium engine that the build embedded (see
/// `scripts/embed-chromium-engine.sh`). There's no WebKit fallback: if the engine can't load,
/// Axo says why and quits. Test runs are the exception, for now: unit tests and UI testing mode
/// use WebKit, except UI tests that opt in with `AXO_UI_TESTING_CHROMIUM=1`
/// (`ChromiumEngineUITests`).
enum ChromiumSupport {
    /// The engine's classes, once the engine loaded at launch.
    private(set) static var classes: ChromiumEngineClasses?

    /// Set by UI tests that exercise the Chromium engine.
    static let uiTestingKey = "AXO_UI_TESTING_CHROMIUM"

    /// Where Chromium keeps profiles' website data: a temporary folder in UI testing mode.
    static var userDataDirectory: URL {
        AppEnvironment.isUITesting
            ? FileManager.default.temporaryDirectory.appending(path: "AxoUITests-Chromium-\(UUID().uuidString)", directoryHint: .isDirectory)
            : URL.applicationSupportDirectory.appending(path: "Axo/Chromium", directoryHint: .isDirectory)
    }

    /// Where else the engine finds native messaging hosts: Google Chrome's folders, where apps
    /// like 1Password register the hosts their extensions talk to (they don't know Axo). None in
    /// UI testing mode, so tests never start the person's real hosts.
    static func nativeMessagingHostFolders(isUITesting: Bool, home: URL = URL.homeDirectory) -> [URL] {
        guard !isUITesting else { return [] }
        return [
            home.appending(path: "Library/Application Support/Google/Chrome/NativeMessagingHosts", directoryHint: .isDirectory),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true),
        ]
    }

    /// Whether this launch runs on Chromium: always, except in test runs. Unit tests host in Axo
    /// (XCTest sets `XCTestConfigurationFilePath`) and stay on WebKit, so they never start the
    /// engine on the person's website data; UI tests use it only when they opt in.
    static func isRequired(isUITesting: Bool, environment: [String: String]) -> Bool {
        if isUITesting { return environment[uiTestingKey] == "1" }
        return environment["XCTestConfigurationFilePath"] == nil
    }

    /// Loads the engine and makes `NSApp` its `AXOApplication`, which Chromium requires. Called
    /// from ``AxoMain`` before SwiftUI starts, because `NSApp` must be an `AXOApplication` from
    /// the start. When the engine can't load, explains why and quits.
    static func prepare() {
        guard isRequired(isUITesting: AppEnvironment.isUITesting, environment: ProcessInfo.processInfo.environment) else { return }
        switch ChromiumFramework.load() {
        case .success(let loaded):
            guard ChromiumFramework.makeApplication() != nil else {
                failToLaunch(reason: "The Chromium engine has no application class.")
            }
            classes = loaded
        case .failure(let error):
            failToLaunch(reason: "\(error)")
        }
    }

    /// The message shown when the engine can't load, said plainly.
    static func launchFailureMessage(reason: String) -> String {
        "\(reason) Axo runs its pages on this engine, so it can't open without it. Reinstall Axo, or if you built it yourself, build axo-chromium next to it."
    }

    private static func failToLaunch(reason: String) -> Never {
        // SwiftUI hasn't made `NSApp` yet; the alert needs one.
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Axo can't open"
        alert.informativeText = launchFailureMessage(reason: reason)
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }

    /// The pool's engine: Chromium, started, if it loaded at launch.
    static func makeEngine() -> ChromiumEngine? {
        guard let classes else { return nil }
        let engine = ChromiumEngine(
            classes: classes, userDataDirectory: userDataDirectory,
            nativeMessagingHostFolders: nativeMessagingHostFolders(isUITesting: AppEnvironment.isUITesting)
        )
        engine.start()
        return engine
    }
}

/// Axo's entry point. It loads the Chromium engine, which has to happen before SwiftUI creates
/// `NSApp`, then runs the app.
@main
enum AxoMain {
    static func main() {
        ChromiumSupport.prepare()
        AxoApp.main()
    }
}
