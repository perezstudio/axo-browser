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
        FakeProfile.removalError = FakeEngineError()
        FakeProfile.removed = []
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
    public var additionalArguments: [String] = []
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

    /// Each installed package's contents when it was installed.
    public private(set) var installedPackageData: [Data] = []

    public func installPackage(at url: URL, completion: @escaping (String?, (any Error)?) -> Void) {
        installedPackages.append(url)
        installedPackageData.append((try? Data(contentsOf: url)) ?? Data())
        completion("fake-package-id", nil)
    }
    public var extensions: [any AXOExtension] = []
    public var actions: [any AXOExtensionAction] = []
    public var onExtensionsChange: (() -> Void)?
    public var onExtensionPopupRequest: ((any AXOExtensionPopup) -> Void)?
    public var onExtensionWindowOpen: ((any AXOWindow, NSSize) -> Void)?
    public var onExtensionPrompt: ((any AXOExtensionPrompt, @escaping (AXOExtensionPromptAnswer) -> Void) -> Void)?
    public var onExtensionSidePanelOpen: ((any AXOExtensionSidePanel) -> Void)?
    public var onBookmarkChange: ((any AXOBookmarkChange) -> Void)?
    public var onHistoryChange: ((any AXOHistoryChange) -> Void)?
    public private(set) var bookmarkBar: [any AXOBookmarkNode] = []
    public private(set) var otherBookmarks: [any AXOBookmarkNode] = []
    public private(set) var bookmarkSetCount = 0
    public func setBookmarks(bar: [any AXOBookmarkNode], other: [any AXOBookmarkNode]) {
        bookmarkBar = bar
        otherBookmarks = other
        bookmarkSetCount += 1
    }
    public var extensionCommands: [any AXOExtensionCommand] = []
    public private(set) var performedCommands: [(name: String, extensionID: String, page: any AXOPage)] = []

    public func performExtensionCommand(_ name: String, extension extensionID: String, on page: any AXOPage, window: any AXOWindow, completion: @escaping ((any AXOExtensionPopup)?) -> Void) {
        performedCommands.append((name, extensionID, page))
        completion(name == "_execute_action" ? nextPopup : nil)
    }
    public private(set) var enabledChanges: [(String, Bool)] = []
    public private(set) var uninstalled: [String] = []
    public private(set) var performed: [(extensionID: String, page: any AXOPage, window: any AXOWindow)] = []
    public var nextPopup: FakeExtensionPopup?

    public func setExtension(_ extensionID: String, enabled: Bool) { enabledChanges.append((extensionID, enabled)) }
    public private(set) var userScriptChanges: [(String, Bool)] = []
    public func setUserScriptsAllowed(_ allowed: Bool, forExtension extensionID: String) { userScriptChanges.append((extensionID, allowed)) }
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

    /// What removing a profile answers; `nil` succeeds.
    public static var removalError: (any Error)? = FakeEngineError()
    public static var removed: [UUID] = []

    public static func removeProfile(withIdentifier identifier: UUID, completion: @escaping ((any Error)?) -> Void) {
        if removalError == nil {
            removed.append(identifier)
            made[identifier] = nil
        }
        completion(removalError)
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
    public private(set) var finds: [(text: String, backwards: Bool)] = []
    public func find(_ text: String, backwards: Bool, completion: @escaping (Bool) -> Void) {
        finds.append((text, backwards))
        completion(findResult)
    }
    public private(set) var stoppedFinding = 0
    public func stopFinding() { stoppedFinding += 1 }

    public func callFunctionBody(_ functionBody: String, arguments: [String: Any], inWorld world: String, completion: @escaping (Any?, (any Error)?) -> Void) {
        completion(nil, FakeEngineError())
    }

    public func snapshot(withWidth width: CGFloat, completion: @escaping (NSImage?) -> Void) { completion(nil) }
    public func startDownload(from url: URL) {}
    public func toggleDevTools() {}

    public func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation {
        NSPrintOperation(view: view, printInfo: printInfo)
    }

    public private(set) var exitedFullscreen = 0
    public func exitFullscreen() { exitedFullscreen += 1 }
    public func close() { isClosed = true }
}

public final class FakeWindow: NSObject, AXOWindow {
    public static var made: [FakeWindow] = []

    public let profile: FakeProfile
    public weak var delegate: (any AXOWindowDelegate)?
    public var pages: [any AXOPage] = []
    public weak var activePage: (any AXOPage)?
    public var isActive = false
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
    public let usesUserScripts: Bool, userScriptsAllowed: Bool

    public init(identifier: String, name: String, version: String = "1.0", isEnabled: Bool = true, isUnpacked: Bool = true, usesUserScripts: Bool = false, userScriptsAllowed: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.isUnpacked = isUnpacked
        self.usesUserScripts = usesUserScripts
        self.userScriptsAllowed = userScriptsAllowed
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

public final class FakeExtensionCommand: NSObject, AXOExtensionCommand {
    public let extensionIdentifier: String
    public let name: String
    public let title: String
    public let keyEquivalent: String
    public let modifierFlags: NSEvent.ModifierFlags

    public init(extensionIdentifier: String, name: String, title: String, keyEquivalent: String, modifierFlags: NSEvent.ModifierFlags) {
        self.extensionIdentifier = extensionIdentifier
        self.name = name
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
    }
}

public final class FakeExtensionPrompt: NSObject, AXOExtensionPrompt {
    public let kind: AXOExtensionPromptKind
    public let extensionIdentifier: String
    public let extensionName: String
    public let title: String
    public let details: [String]
    public let requestingExtensionName: String?
    public let allowsScreen: Bool
    public let allowsWindow: Bool

    public init(kind: AXOExtensionPromptKind, extensionIdentifier: String = "ext", extensionName: String, title: String = "", details: [String] = [], requestingExtensionName: String? = nil) {
        self.kind = kind
        self.extensionIdentifier = extensionIdentifier
        self.extensionName = extensionName
        self.title = title
        self.details = details
        self.requestingExtensionName = requestingExtensionName
        allowsScreen = kind == .screenCapture
        allowsWindow = kind == .screenCapture
    }
}

public final class FakeAXOContextMenuItem: NSObject, AXOContextMenuItem {
    public let type: AXOContextMenuItemType
    public let title: String
    public let isEnabled = true
    public let isChecked: Bool
    public let children: [any AXOContextMenuItem]

    public init(type: AXOContextMenuItemType = .command, title: String, checked: Bool = false, children: [any AXOContextMenuItem] = []) {
        self.type = type
        self.title = title
        isChecked = checked
        self.children = children
    }
}

public final class FakeAXOContextMenu: NSObject, AXOContextMenu {
    public var linkURL: URL?
    public var linkText = ""
    public var media = AXOContextMenuMedia.none
    public var sourceURL: URL?
    public var hasImageContents = false
    public var selectionText = ""
    public var isEditable = false
    public var edits: AXOContextMenuEdits = []
    public var misspelledWord = ""
    public var suggestions: [String] = []
    public var pageURL = URL(string: "https://example.com/")!
    public var location = NSPoint(x: 10, y: 20)
    public var extensionItems: [any AXOContextMenuItem] = []
    public private(set) var performedEdits: [AXOContextMenuEdit] = []
    public private(set) var performedItems: [any AXOContextMenuItem] = []
    public private(set) var isClosed = false

    public func perform(_ edit: AXOContextMenuEdit) { performedEdits.append(edit) }
    public func replaceMisspelling(with word: String) {}
    public func copyImage() {}
    public func download(_ url: URL) {}
    public func lookUpSelection() {}
    public func performExtensionItem(_ item: any AXOContextMenuItem) { performedItems.append(item) }
    public func closed(followingLink url: URL?) { isClosed = true }
}

public final class FakeExtensionSidePanel: NSObject, AXOExtensionSidePanel {
    public let extensionIdentifier: String
    public let title: String
    public let view = NSView()
    public var onClose: (() -> Void)?
    public private(set) var isClosed = false

    public init(extensionIdentifier: String, title: String) {
        self.extensionIdentifier = extensionIdentifier
        self.title = title
    }

    public func close() { isClosed = true }
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

public final class FakeBookmarkChange: NSObject, AXOBookmarkChange {
    public let kind: AXOBookmarkChangeKind
    public let identifier: String
    public let parentRoot: AXOBookmarkRoot
    public let parentIdentifier: String?
    public let index: UInt
    public let title: String
    public let url: URL?

    public init(kind: AXOBookmarkChangeKind, identifier: String, parentRoot: AXOBookmarkRoot = .none, parentIdentifier: String? = nil, index: UInt = 0, title: String = "", url: URL? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.parentRoot = parentRoot
        self.parentIdentifier = parentIdentifier
        self.index = index
        self.title = title
        self.url = url
    }
}

public final class FakeHistoryChange: NSObject, AXOHistoryChange {
    public let kind: AXOHistoryChangeKind
    public let urls: [URL]
    public let title: String
    public let date: Date?
    public let endDate: Date?

    public init(kind: AXOHistoryChangeKind, urls: [URL] = [], title: String = "", date: Date? = nil, endDate: Date? = nil) {
        self.kind = kind
        self.urls = urls
        self.title = title
        self.date = date
        self.endDate = endDate
    }
}
