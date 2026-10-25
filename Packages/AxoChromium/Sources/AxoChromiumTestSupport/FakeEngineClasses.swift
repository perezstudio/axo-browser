import AppKit
import AxoEngineAPI
import Foundation

/// Stand-ins for the engine framework's classes, written against the same protocols.
///
/// They depend only on AxoEngineAPI, so a test target that also gets AxoChromium through its host
/// app doesn't link a second copy of it; each test target builds `ChromiumEngineClasses` from
/// them. The real classes keep their state in class-level registries, so these do too; tests
/// reset them first and run serialized.
@MainActor
public enum FakeEngine {
    public static func reset() {
        FakeAXOEngine.apiVersionOverride = nil
        FakeAXOEngine.failure = nil
        FakeAXOEngine.configurations = []
        FakeProfile.made = [:]
        FakePage.made = []
        FakeWindow.made = []
    }
}

public struct FakeEngineError: LocalizedError {
    public init() {}

    public var errorDescription: String? { "The fake engine refused to start." }
}

public final class FakeAXOEngine: NSObject, AXOEngine {
    public static var apiVersionOverride: Int?
    public static var failure: (any Error)?
    public static var configurations: [any AXOEngineConfiguration] = []

    public static var apiVersion: Int { apiVersionOverride ?? Int(AXO_ENGINE_API_VERSION) }
    public static var chromiumVersion: String { "156.0.0.0" }

    public static func run(with configuration: any AXOEngineConfiguration, ready: @escaping ((any AXOEngine)?, (any Error)?) -> Void) {
        configurations.append(configuration)
        if let failure {
            ready(nil, failure)
        } else {
            ready(FakeAXOEngine(), nil)
        }
    }

    public func shutdown() {}
}

public final class FakeConfiguration: NSObject, AXOEngineConfiguration {
    public var userDataDirectory = URL(fileURLWithPath: "/")
    public var ephemeral = false
    public var nativeMessagingHostFolders: [URL] = []
}

public final class FakeProfile: NSObject, AXOProfile {
    public static var made: [UUID: FakeProfile] = [:]

    public let identifier: UUID
    public private(set) var clearCount = 0

    public init(identifier: UUID) {
        self.identifier = identifier
    }

    public static func profile(withIdentifier identifier: UUID) -> any AXOProfile {
        if let existing = made[identifier] { return existing }
        let profile = FakeProfile(identifier: identifier)
        made[identifier] = profile
        return profile
    }

    public func clearWebsiteData(completion: @escaping () -> Void) {
        clearCount += 1
        completion()
    }

    public private(set) var loadedExtensions: [URL] = []
    public private(set) var installedPackages: [URL] = []

    public func installPackage(at url: URL, completion: @escaping (String?, (any Error)?) -> Void) {
        installedPackages.append(url)
        completion("fake-package-id", nil)
    }
    public var extensions: [any AXOExtension] = []
    public var actions: [any AXOExtensionAction] = []
    public var onExtensionsChange: (() -> Void)?
    public var onExtensionPopupRequest: ((any AXOExtensionPopup) -> Void)?
    public private(set) var enabledChanges: [(String, Bool)] = []
    public private(set) var uninstalled: [String] = []
    public private(set) var performed: [(extensionID: String, page: any AXOPage, window: any AXOWindow)] = []
    public var nextPopup: FakeExtensionPopup?

    public func setExtension(_ extensionID: String, enabled: Bool) { enabledChanges.append((extensionID, enabled)) }
    public func uninstallExtension(_ extensionID: String) { uninstalled.append(extensionID) }
    public func extensionActions(for page: any AXOPage) -> [any AXOExtensionAction] { actions }

    public func performExtensionAction(_ extensionID: String, on page: any AXOPage, window: any AXOWindow, completion: @escaping ((any AXOExtensionPopup)?) -> Void) {
        performed.append((extensionID, page, window))
        completion(nextPopup)
    }

    public func loadUnpackedExtension(at url: URL, completion: @escaping (String?, (any Error)?) -> Void) {
        loadedExtensions.append(url)
        completion("fake-extension-id", nil)
    }

    public static func removeProfile(withIdentifier identifier: UUID, completion: @escaping ((any Error)?) -> Void) {
        completion(FakeEngineError())
    }
}

public final class FakePage: NSObject, AXOPage {
    public static var made: [FakePage] = []

    public let profile: FakeProfile
    public weak var delegate: (any AXOPageDelegate)?
    public let view = NSView()
    public var url: URL?
    public var title = ""
    public var isLoading = false
    public var estimatedProgress = 0.0
    public var canGoBack = false
    public var canGoForward = false
    public var navigationState: Data?
    public private(set) var loads: [URL] = []
    public private(set) var restored: [Data] = []
    public private(set) var isClosed = false
    public var findResult = true

    public init(profile: FakeProfile) {
        self.profile = profile
    }

    public static func page(with profile: any AXOProfile) -> any AXOPage {
        let page = FakePage(profile: profile as! FakeProfile)
        made.append(page)
        return page
    }

    /// Commits a navigation and tells the delegate.
    public func navigate(to url: URL, title: String) {
        self.url = url
        self.title = title
        delegate?.pageStateDidChange(self)
    }

    public func restoreNavigationState(_ state: Data) { restored.append(state) }
    public func load(_ url: URL) { loads.append(url) }
    public func goBack() {}
    public func goForward() {}
    public func reload() {}
    public func stopLoading() {}
    public func find(_ text: String, backwards: Bool, completion: @escaping (Bool) -> Void) { completion(findResult) }
    public func stopFinding() {}

    public func callFunctionBody(_ functionBody: String, arguments: [String: Any], inWorld world: String, completion: @escaping (Any?, (any Error)?) -> Void) {
        completion(nil, FakeEngineError())
    }

    public func snapshot(withWidth width: CGFloat, completion: @escaping (NSImage?) -> Void) { completion(nil) }
    public func startDownload(from url: URL) {}
    public func toggleDevTools() {}

    public func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation {
        NSPrintOperation(view: view, printInfo: printInfo)
    }

    public func close() { isClosed = true }
}

public final class FakeWindow: NSObject, AXOWindow {
    public static var made: [FakeWindow] = []

    public let profile: FakeProfile
    public weak var delegate: (any AXOWindowDelegate)?
    public var pages: [any AXOPage] = []
    public weak var activePage: (any AXOPage)?
    public private(set) var isClosed = false

    public init(profile: FakeProfile) {
        self.profile = profile
    }

    public static func window(with profile: any AXOProfile) -> any AXOWindow {
        let window = FakeWindow(profile: profile as! FakeProfile)
        made.append(window)
        return window
    }

    public func close() { isClosed = true }
}

public final class FakeExtension: NSObject, AXOExtension {
    public let identifier: String, name: String, version: String
    public let isEnabled: Bool, isUnpacked: Bool

    public init(identifier: String, name: String, version: String = "1.0", isEnabled: Bool = true, isUnpacked: Bool = true) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.isUnpacked = isUnpacked
    }
}

public final class FakeExtensionAction: NSObject, AXOExtensionAction {
    public let extensionIdentifier: String, title: String, badgeText: String
    public let icon: NSImage? = nil
    public let isEnabled = true, hasPopup = true

    public init(extensionIdentifier: String, title: String, badgeText: String) {
        self.extensionIdentifier = extensionIdentifier
        self.title = title
        self.badgeText = badgeText
    }
}

public final class FakeExtensionPopup: NSObject, AXOExtensionPopup {
    public let extensionIdentifier: String
    public let view = NSView()
    public var title = "Popup"
    public var preferredSize = NSSize(width: 25, height: 25)
    public var onResize: ((NSSize) -> Void)?
    public var onLoad: (() -> Void)?
    public var onClose: (() -> Void)?
    public private(set) var isClosed = false

    public init(extensionIdentifier: String) {
        self.extensionIdentifier = extensionIdentifier
    }

    public func close() { isClosed = true }
}

public final class FakeDownload: NSObject, AXODownload {
    public let sourceURL: URL?
    public weak var observer: (any AXODownloadObserver)?
    public private(set) var isCancelled = false

    public init(sourceURL: URL?) {
        self.sourceURL = sourceURL
    }

    public func cancel() { isCancelled = true }
}
