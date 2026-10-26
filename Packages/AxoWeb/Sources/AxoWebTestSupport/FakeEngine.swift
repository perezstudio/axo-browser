import AxoCore
import AxoWeb
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An engine with no browser behind it, so pool tests can check the pool's own logic and drive
/// page events directly.
@MainActor
public final class FakeEngine: WebEngine {
    public private(set) var pages: [FakePage] = []
    public private(set) var siteCustomizations: [SiteCustomization] = []
    public private(set) var clearedProfiles: [Profile.ID] = []
    public private(set) var removedProfiles: [Profile.ID] = []
    public weak var delegate: (any WebEngineDelegate)?
    /// The last window pages and active page the pool sent, by profile.
    public private(set) var windowPages: [Profile.ID: (pages: [any EnginePage], active: (any EnginePage)?)] = [:]

    public func setWindowPages(_ pages: [any EnginePage], active: (any EnginePage)?, profileID: Profile.ID) {
        windowPages[profileID] = (pages, active)
    }

    /// Plays the engine opening `page` on its own, as an extension's `chrome.tabs.create` would.
    public func openPageOnItsOwn(_ page: any EnginePage, profileID: Profile.ID, at index: Int) {
        delegate?.engine(self, didOpen: page, profileID: profileID, at: index)
    }

    /// Plays the engine opening `page` in a popup window, as an extension's
    /// `chrome.windows.create({type: "popup"})` would.
    public func openPopupWindowOnItsOwn(_ page: any EnginePage, size: CGSize, profileID: Profile.ID) {
        delegate?.engine(self, didOpenPopupWindowWith: page, size: size, profileID: profileID)
    }

    /// Plays the engine closing `page` on its own, as `chrome.tabs.remove` would.
    public func closePageOnItsOwn(_ page: any EnginePage) {
        delegate?.engine(self, didClose: page)
    }

    /// Plays the engine selecting `page` on its own.
    public func activatePageOnItsOwn(_ page: any EnginePage) {
        delegate?.engine(self, didActivate: page)
    }

    /// Creates an engine with no pages.
    public init() {}

    public func makePage(profileID: Profile.ID) -> any EnginePage {
        let page = FakePage(profileID: profileID)
        pages.append(page)
        return page
    }

    public func setSiteCustomizations(_ customizations: [SiteCustomization]) {
        siteCustomizations = customizations
    }

    public func clearWebsiteData(for profileID: Profile.ID) async {
        clearedProfiles.append(profileID)
    }

    public func removeWebsiteData(for profileID: Profile.ID) async throws {
        removedProfiles.append(profileID)
    }
}

/// A page that records what the pool asks of it. Tests change its state with ``navigate(to:title:)``
/// and send events through ``delegate``.
@MainActor
public final class FakePage: EnginePage {
    /// The profile the page was made for.
    public let profileID: Profile.ID
    public weak var delegate: (any EnginePageDelegate)?
    public let view = PlatformView()

    public private(set) var url: URL?
    public private(set) var title = ""
    public var isLoading = false
    public var estimatedProgress = 0.0
    public var canGoBack = false
    public var canGoForward = false

    /// Every URL passed to ``load(_:)``, in order.
    public private(set) var loads: [URL] = []
    /// The history passed to ``restore(interactionState:)``.
    public private(set) var restoredState: String?
    /// "back", "forward", "reload", and "stop", in the order asked.
    public private(set) var navigation: [String] = []
    /// Every find, in order.
    public private(set) var finds: [(text: String, backwards: Bool)] = []
    /// Every script run, with its world, in order.
    public private(set) var scripts: [(body: String, world: String)] = []
    /// Every URL passed to ``startDownload(_:)``.
    public private(set) var downloadRequests: [URL] = []
    /// Whether the pool closed the page.
    public private(set) var isClosed = false
    /// What ``snapshot(width:)`` returns.
    public var snapshotImage: PlatformImage?
    /// What ``find(_:backwards:)`` returns.
    public var findResult = true

    /// Creates a page for `profileID`'s profile.
    public init(profileID: Profile.ID) {
        self.profileID = profileID
    }

    /// Commits a navigation to `url` and tells the delegate.
    public func navigate(to url: URL, title: String) {
        self.url = url
        self.title = title
        delegate?.pageStateDidChange(self)
    }

    public var interactionState: Any? { url.map { "history:\($0.absoluteString)" } }

    public func restore(interactionState: Any) {
        restoredState = interactionState as? String
    }

    public func load(_ url: URL) {
        loads.append(url)
    }

    /// Plays a right-click in the page, as an engine that leaves the menu to Axo reports it.
    @discardableResult
    public func rightClick(_ menu: any PageContextMenu) -> Bool {
        delegate?.page(self, showContextMenu: menu) ?? false
    }

    public func goBack() { navigation.append("back") }
    public func goForward() { navigation.append("forward") }
    public func reload() { navigation.append("reload") }
    public func stopLoading() { navigation.append("stop") }

    public func find(_ text: String, backwards: Bool) async -> Bool {
        finds.append((text, backwards))
        return findResult
    }

    public func callJavaScript(_ functionBody: String, arguments: [String: Any], in world: String) async throws -> Any? {
        scripts.append((functionBody, world))
        return nil
    }

    public func snapshot(width: CGFloat) async -> PlatformImage? {
        snapshotImage
    }

    public func startDownload(_ url: URL) {
        downloadRequests.append(url)
    }

    #if os(macOS)
    public func printOperation(with printInfo: NSPrintInfo) -> NSPrintOperation {
        NSPrintOperation(view: view, printInfo: printInfo)
    }
    #endif

    public private(set) var exitedFullscreen = 0
    public func exitFullscreen() { exitedFullscreen += 1 }

    /// Asks to fill the screen, or to stop, as a page's `requestFullscreen()` would.
    public func setFullscreen(_ fullscreen: Bool) {
        delegate?.page(self, setsFullscreen: fullscreen)
    }

    /// Opens another page, as a page's `window.open` would.
    public func open(_ opened: FakePage, url: URL, as kind: OpenedPage.Kind) {
        opened.url = url
        delegate?.page(self, didOpen: OpenedPage(page: opened, url: url, kind: kind))
    }

    public func close() {
        isClosed = true
    }
}

/// A right-click for tests: what was clicked is set directly, and actions are recorded.
@MainActor
public final class FakeContextMenu: PageContextMenu {
    public var linkURL: URL?
    public var linkText = ""
    public var media = PageContextMenuMedia.none
    public var sourceURL: URL?
    public var hasImageContents = false
    public var selectionText = ""
    public var isEditable = false
    public var edits: PageEdits = []
    public var misspelledWord = ""
    public var suggestions: [String] = []
    public var location = CGPoint(x: 10, y: 10)
    public var extensionItems: [PageContextMenuItem] = []

    /// What the menu did, in order, such as "copy", "replace teh", or "item Mark".
    public private(set) var performed: [String] = []
    public private(set) var closedLink: URL??

    public init() {}

    public func perform(_ edit: PageEdit) { performed.append("\(edit)") }
    public func replaceMisspelling(with word: String) { performed.append("replace \(word)") }
    public func copyImage() { performed.append("copy image") }
    public func download(_ url: URL) { performed.append("download \(url.absoluteString)") }
    public func lookUpSelection() { performed.append("look up") }
    public func perform(_ item: PageContextMenuItem) { performed.append("item \(item.title)") }
    public func closed(followingLink url: URL?) { closedLink = .some(url) }
}
