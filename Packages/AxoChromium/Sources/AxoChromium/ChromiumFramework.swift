import AppKit
import AxoEngineAPI
import Foundation

/// The Chromium engine's classes, found by name in the loaded framework.
///
/// Axo never links the engine: the framework is large and only machines that build Chromium
/// have it. It's loaded at runtime, and these are the classes Axo talks to through the
/// `AxoEngineAPI` protocols. Tests pass fakes.
@MainActor
public struct ChromiumEngineClasses {
    /// Runs the browser process (`AXOEngine`).
    public var engine: any AXOEngine.Type
    /// Makes engine configurations (`AXOEngineConfiguration`).
    public var configuration: NSObject.Type
    /// Profiles (`AXOProfile`).
    public var profile: any AXOProfile.Type
    /// Pages (`AXOPage`).
    public var page: any AXOPage.Type
    /// Windows (`AXOWindow`): what Chrome's extension APIs see as a window's tabs.
    public var window: any AXOWindow.Type

    /// Creates the set of classes.
    public init(
        engine: any AXOEngine.Type,
        configuration: NSObject.Type,
        profile: any AXOProfile.Type,
        page: any AXOPage.Type,
        window: any AXOWindow.Type
    ) {
        self.engine = engine
        self.configuration = configuration
        self.profile = profile
        self.page = page
        self.window = window
    }
}

/// Why the engine framework couldn't be used.
public enum ChromiumFrameworkError: Error, Equatable, CustomStringConvertible {
    /// The app bundle has no engine framework.
    case notEmbedded
    /// `dlopen` failed, with its message.
    case failedToLoad(String)
    /// The framework doesn't have a class Axo needs.
    case missingClass(String)
    /// The framework implements another version of the API than Axo's copy of the header.
    case apiVersionMismatch(framework: Int, axo: Int)

    public var description: String {
        switch self {
        case .notEmbedded: "The Chromium engine isn't in this build of Axo."
        case .failedToLoad(let message): "The Chromium engine didn't load: \(message)"
        case .missingClass(let name): "The Chromium engine has no \(name) class."
        case .apiVersionMismatch(let framework, let axo): "The Chromium engine implements API version \(framework), but this Axo expects \(axo)."
        }
    }
}

/// Finds and loads the Chromium engine framework (`AxoEngine`, built by the axo-chromium fork).
@MainActor
public enum ChromiumFramework {
    /// The API version Axo's copy of `AxoEngineProtocols.h` describes.
    public static let apiVersion = Int(AXO_ENGINE_API_VERSION)

    /// Where an app keeps the engine: inside its Frameworks folder, as in Chromium.app, so
    /// Chromium finds its helper apps and resources next to it.
    public static func binaryURL(in bundle: Bundle) -> URL? {
        bundle.privateFrameworksURL?
            .appending(path: "Chromium Framework.framework/Versions/Current/Chromium Framework")
    }

    /// Loads the framework embedded in `bundle` and returns its classes.
    public static func load(from bundle: Bundle = .main) -> Result<ChromiumEngineClasses, ChromiumFrameworkError> {
        guard let url = binaryURL(in: bundle), FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.notEmbedded)
        }
        guard dlopen(url.path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST) != nil else {
            return .failure(.failedToLoad(dlerror().map { String(cString: $0) } ?? "unknown error"))
        }
        return classes(lookingUp: NSClassFromString)
    }

    /// Finds the engine's classes with `lookUp` (`NSClassFromString` for the real framework) and
    /// checks that they implement Axo's API version.
    public static func classes(lookingUp lookUp: (String) -> AnyClass?) -> Result<ChromiumEngineClasses, ChromiumFrameworkError> {
        guard let engine = lookUp("AXOEngine") as? any AXOEngine.Type else { return .failure(.missingClass("AXOEngine")) }
        guard let configuration = lookUp("AXOEngineConfiguration") as? NSObject.Type,
              configuration is any AXOEngineConfiguration.Type
        else { return .failure(.missingClass("AXOEngineConfiguration")) }
        guard let profile = lookUp("AXOProfile") as? any AXOProfile.Type else { return .failure(.missingClass("AXOProfile")) }
        guard let page = lookUp("AXOPage") as? any AXOPage.Type else { return .failure(.missingClass("AXOPage")) }
        guard let window = lookUp("AXOWindow") as? any AXOWindow.Type else { return .failure(.missingClass("AXOWindow")) }
        guard engine.apiVersion == apiVersion else {
            return .failure(.apiVersionMismatch(framework: engine.apiVersion, axo: apiVersion))
        }
        return .success(ChromiumEngineClasses(engine: engine, configuration: configuration, profile: profile, page: page, window: window))
    }

    /// Creates `NSApp` as the engine's `AXOApplication`, which Chromium requires. Call it before
    /// anything else touches `NSApp`, after ``load(from:)`` succeeded. Returns `nil` if the
    /// framework has no such class.
    public static func makeApplication() -> NSApplication? {
        (NSClassFromString("AXOApplication") as? NSApplication.Type)?.shared
    }
}
