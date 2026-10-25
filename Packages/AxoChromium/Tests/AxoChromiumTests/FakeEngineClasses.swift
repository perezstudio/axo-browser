import AppKit
import AxoChromium
import AxoEngineAPI
import Foundation

/// Stand-ins for the engine framework's classes, written against the same protocols. The real
/// classes keep their state in class-level registries, so these do too; tests reset them first
/// and run serialized.
@MainActor
enum FakeEngine {
    static var classes: ChromiumEngineClasses {
        ChromiumEngineClasses(engine: FakeAXOEngine.self, configuration: FakeConfiguration.self, profile: FakeProfile.self, page: FakePage.self)
    }

    static func reset() {
        FakeAXOEngine.apiVersionOverride = nil
        FakeAXOEngine.failure = nil
        FakeAXOEngine.configurations = []
        FakeProfile.made = [:]
        FakePage.made = []
    }
}

struct FakeEngineError: LocalizedError {
    var errorDescription: String? { "The fake engine refused to start." }
}

final class FakeAXOEngine: NSObject, AXOEngine {
    static var apiVersionOverride: Int?
    static var failure: (any Error)?
    static var configurations: [any AXOEngineConfiguration] = []

    static var apiVersion: Int { apiVersionOverride ?? ChromiumFramework.apiVersion }
    static var chromiumVersion: String { "156.0.0.0" }

    static func run(with configuration: any AXOEngineConfiguration, ready: @escaping ((any AXOEngine)?, (any Error)?) -> Void) {
        configurations.append(configuration)
        if let failure {
            ready(nil, failure)
        } else {
            ready(FakeAXOEngine(), nil)
        }
    }

    func shutdown() {}
}

final class FakeConfiguration: NSObject, AXOEngineConfiguration {
    var userDataDirectory = URL(fileURLWithPath: "/")
    var ephemeral = false
}

final class FakeProfile: NSObject, AXOProfile {
    static var made: [UUID: FakeProfile] = [:]

    let identifier: UUID
    private(set) var clearCount = 0

    init(identifier: UUID) {
        self.identifier = identifier
    }

    static func profile(withIdentifier identifier: UUID) -> any AXOProfile {
        if let existing = made[identifier] { return existing }
        let profile = FakeProfile(identifier: identifier)
        made[identifier] = profile
        return profile
    }

    func clearWebsiteData(completion: @escaping () -> Void) {
        clearCount += 1
        completion()
    }

    private(set) var loadedExtensions: [URL] = []

    func loadUnpackedExtension(at url: URL, completion: @escaping (String?, (any Error)?) -> Void) {
        loadedExtensions.append(url)
        completion("fake-extension-id", nil)
    }

    static func removeProfile(withIdentifier identifier: UUID, completion: @escaping ((any Error)?) -> Void) {
        completion(FakeEngineError())
    }
}

final class FakePage: NSObject, AXOPage {
    static var made: [FakePage] = []

    let profile: FakeProfile
    weak var delegate: (any AXOPageDelegate)?
    let view = NSView()
    var url: URL?
    var title = ""
    var isLoading = false
    var estimatedProgress = 0.0
    var canGoBack = false
    var canGoForward = false
    var navigationState: Data?
    private(set) var loads: [URL] = []
    private(set) var restored: [Data] = []
    private(set) var isClosed = false
    var findResult = true

    init(profile: FakeProfile) {
        self.profile = profile
    }

    static func page(with profile: any AXOProfile) -> any AXOPage {
        let page = FakePage(profile: profile as! FakeProfile)
        made.append(page)
        return page
    }

    /// Commits a navigation and tells the delegate.
    func navigate(to url: URL, title: String) {
        self.url = url
        self.title = title
        delegate?.pageStateDidChange(self)
    }

    func restoreNavigationState(_ state: Data) { restored.append(state) }
    func load(_ url: URL) { loads.append(url) }
    func goBack() {}
    func goForward() {}
    func reload() {}
    func stopLoading() {}
    func find(_ text: String, backwards: Bool, completion: @escaping (Bool) -> Void) { completion(findResult) }
    func stopFinding() {}

    func callFunctionBody(_ functionBody: String, arguments: [String: Any], inWorld world: String, completion: @escaping (Any?, (any Error)?) -> Void) {
        completion(nil, FakeEngineError())
    }

    func snapshot(withWidth width: CGFloat, completion: @escaping (NSImage?) -> Void) { completion(nil) }
    func startDownload(from url: URL) {}
    func toggleDevTools() {}

    func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation {
        NSPrintOperation(view: view, printInfo: printInfo)
    }

    func close() { isClosed = true }
}

final class FakeDownload: NSObject, AXODownload {
    let sourceURL: URL?
    weak var observer: (any AXODownloadObserver)?
    private(set) var isCancelled = false

    init(sourceURL: URL?) {
        self.sourceURL = sourceURL
    }

    func cancel() { isCancelled = true }
}
