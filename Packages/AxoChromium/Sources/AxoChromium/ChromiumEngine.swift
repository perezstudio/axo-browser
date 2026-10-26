import AxoCore
import AxoEngineAPI
import AxoWeb
import Foundation

/// The Chromium engine as an AxoWeb ``WebEngine``: one Chromium profile per Axo profile, an
/// `AXOPage` per tab, and an `AXOWindow` per profile holding the current Space's tabs, which is
/// what Chrome's extension APIs see as the window.
///
/// The engine starts a moment after launch (see ``start()``), but the pool may make pages before
/// that. Those pages show an empty view and remember what they were asked to load; they attach
/// to Chromium as soon as the engine is ready.
@MainActor
public final class ChromiumEngine: WebEngine {
    /// Where the engine stands.
    public enum State: Equatable {
        /// ``start()`` hasn't been called.
        case notStarted
        /// Chromium is starting.
        case starting
        /// Pages can be made.
        case ready
        /// Chromium couldn't start, with the reason.
        case failed(String)
    }

    /// Where the engine stands.
    public private(set) var state = State.notStarted

    /// Called when ``state`` changes, for example to tell the person the engine failed.
    public var onStateChange: ((State) -> Void)?

    private let classes: ChromiumEngineClasses
    private let userDataDirectory: URL
    private let nativeMessagingHostFolders: [URL]
    private let isEphemeral: Bool
    private let additionalArguments: [String]
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private var running: (any AXOEngine)?
    /// Pages made before the engine was ready, attached once it is.
    private var waitingPages: [ChromiumPage] = []

    public weak var delegate: (any WebEngineDelegate)?

    /// Each profile's engine window.
    private var windows: [Profile.ID: any AXOWindow] = [:]
    /// Window lists sent before the engine was ready, applied once it is.
    private var waitingWindowPages: [Profile.ID: (pages: [any EnginePage], active: (any EnginePage)?)] = [:]
    /// The Axo page wrapping each engine page, for events about engine pages.
    private let pagesByEnginePage = NSMapTable<AnyObject, ChromiumPage>.weakToWeakObjects()
    /// Hears the windows' events. Kept for the engine's lifetime.
    private lazy var windowEvents = WindowEvents(engine: self)

    /// Called when a profile's extensions or their toolbar buttons change, with the profile.
    public var onExtensionsChange: ((Profile.ID) -> Void)?
    /// Called when an extension's side panel opens (`chrome.sidePanel`), with its profile. Show it
    /// beside the page.
    public var onExtensionSidePanelOpen: ((ChromiumExtensionSidePanel, Profile.ID) -> Void)?
    /// Called with each change an extension makes to a profile's bookmarks (`chrome.bookmarks`).
    /// Apply it, then set the tree again with ``setBookmarks(_:profileID:)``.
    public var onBookmarkChange: ((BookmarkChange, Profile.ID) -> Void)?
    /// Called when a profile's history changes other than by a page visit: an extension added a
    /// visit or deleted history. The engine keeps its own copy of history, for visited links and
    /// extensions; apply these to Axo's so the two stay in step.
    public var onHistoryChange: ((ChromiumHistoryChange, Profile.ID) -> Void)?

    /// Called when something needs the person's answer that Chrome would ask in its own dialog:
    /// permission requests, installs and uninstalls, and what to share when recording the screen.
    /// Ask, then call the closure once. Without a handler, everything is answered Cancel.
    public var onExtensionPrompt: ((ChromiumExtensionPrompt, Profile.ID, @escaping (ChromiumExtensionPrompt.Answer) -> Void) -> Void)?

    /// Called when an extension opens its own popup (`chrome.action.openPopup`), as some do when
    /// their toolbar button is clicked, with its profile. Show it under the extension's button.
    public var onExtensionPopupRequest: ((ChromiumExtensionPopup, Profile.ID) -> Void)?
    /// Observers of the app becoming active and inactive, made with the first window.
    private var activationObservers: [any NSObjectProtocol] = []
    /// Extensions' popup windows that are open, kept until Chrome closes their page.
    private var popupWindows: [any AXOWindow] = []
    /// Profiles whose extension changes are being followed.
    private var followedProfiles: Set<Profile.ID> = []
    /// Each profile's bookmarks, given to its engine profile once that's in use.
    var bookmarkTrees: [Profile.ID: BookmarkTree] = [:]
    /// Profiles whose data was removed. They're never loaded again, so a late call can't bring
    /// one back.
    private var removedProfiles: Set<Profile.ID> = []
    /// Calls waiting for the engine to be ready or to fail, with whether it's ready.
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - classes: The engine's classes, from ``ChromiumFramework/load(from:)``.
    ///   - userDataDirectory: Where profiles keep their data, one folder per profile.
    ///   - nativeMessagingHostFolders: More folders to find native messaging hosts in, after
    ///     Chromium's own, such as Google Chrome's, where apps like 1Password register theirs.
    ///   - isEphemeral: For tests: the engine uses a stand-in keychain (never the person's) and
    ///     makes no background requests of its own.
    ///   - additionalArguments: More Chromium switches, for debugging.
    ///   - schedule: Runs a block on a later turn of the main run loop. Tests replace it.
    public init(
        classes: ChromiumEngineClasses,
        userDataDirectory: URL,
        nativeMessagingHostFolders: [URL] = [],
        isEphemeral: Bool = false,
        additionalArguments: [String] = [],
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = ChromiumEngine.onNextRunLoopTurn
    ) {
        self.classes = classes
        self.userDataDirectory = userDataDirectory
        self.nativeMessagingHostFolders = nativeMessagingHostFolders
        self.isEphemeral = isEphemeral
        self.additionalArguments = additionalArguments
        self.schedule = schedule
    }

    /// Runs `block` on a later turn of the main run loop, as a run-loop callout rather than a
    /// main-queue block. Chromium's loop runs nested inside the call that starts it, and a nested
    /// loop inside a main-queue block would stall the main queue, and with it the main actor.
    public nonisolated static func onNextRunLoopTurn(_ block: @escaping @MainActor () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            // CFRunLoopPerformBlock on the main run loop runs on the main thread.
            MainActor.assumeIsolated { block() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Starts Chromium on a later turn of the main run loop. Call once, after creating the app's
    /// `NSApp` with ``ChromiumFramework/makeApplication()``.
    ///
    /// Chromium then runs until the app quits; the call that runs it doesn't return before that.
    public func start() {
        guard state == .notStarted else { return }
        setState(.starting)
        schedule { [self] in
            guard let configuration = classes.configuration.init() as? any AXOEngineConfiguration else {
                setState(.failed("The Chromium engine's configuration class is unusable."))
                return
            }
            configuration.userDataDirectory = userDataDirectory
            configuration.nativeMessagingHostFolders = nativeMessagingHostFolders
            configuration.ephemeral = isEphemeral
            configuration.additionalArguments = additionalArguments
            classes.engine.run(with: configuration) { [self] engine, error in
                if let engine {
                    running = engine
                    setState(.ready)
                    let pages = waitingPages
                    waitingPages = []
                    pages.forEach(attach)
                    let windowPages = waitingWindowPages
                    waitingWindowPages = [:]
                    for (profileID, request) in windowPages {
                        setWindowPages(request.pages, active: request.active, profileID: profileID)
                    }
                } else {
                    setState(.failed(error?.localizedDescription ?? "Chromium didn't start."))
                }
            }
        }
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
        switch newState {
        case .notStarted, .starting:
            break
        case .ready, .failed:
            let waiters = readyWaiters
            readyWaiters = []
            waiters.forEach { $0.resume(returning: newState == .ready) }
        }
    }

    /// Waits until the engine is ready, returning `false` if it failed or never started.
    private func whenReady() async -> Bool {
        switch state {
        case .ready: return true
        case .failed, .notStarted: return false
        case .starting: return await withCheckedContinuation { readyWaiters.append($0) }
        }
    }

    private func attach(_ page: ChromiumPage) {
        guard !page.isClosed else { return }
        guard let profile = readyProfile(page.profileID) else { return }
        let enginePage = classes.page.page(with: profile)
        pagesByEnginePage.setObject(page, forKey: enginePage)
        page.attach(enginePage)
    }

    /// The engine's profile for `profileID` once the engine is ready, following its extension
    /// changes and giving it its bookmarks from then on.
    func readyProfile(_ profileID: Profile.ID) -> (any AXOProfile)? {
        guard state == .ready, !removedProfiles.contains(profileID) else { return nil }
        let profile = classes.profile.profile(withIdentifier: profileID)
        if followedProfiles.insert(profileID).inserted {
            profile.onExtensionsChange = { [weak self] in self?.onExtensionsChange?(profileID) }
            profile.onExtensionPopupRequest = { [weak self] popup in
                self?.onExtensionPopupRequest?(ChromiumExtensionPopup(popup), profileID)
            }
            profile.onExtensionWindowOpen = { [weak self] window, size in
                self?.popupWindowOpened(window, size: size, profileID: profileID)
            }
            profile.onExtensionSidePanelOpen = { [weak self] panel in
                self?.onExtensionSidePanelOpen?(ChromiumExtensionSidePanel(panel), profileID)
            }
            profile.onBookmarkChange = { [weak self] change in
                guard let change = BookmarkChange(change) else { return }
                self?.onBookmarkChange?(change, profileID)
            }
            profile.onHistoryChange = { [weak self] change in
                guard let change = ChromiumHistoryChange(change) else { return }
                self?.onHistoryChange?(change, profileID)
            }
            if let tree = bookmarkTrees[profileID] {
                profile.setBookmarks(tree)
            }
            profile.onExtensionPrompt = { [weak self] prompt, answer in
                guard let handler = self?.onExtensionPrompt else {
                    answer(.cancel)
                    return
                }
                handler(ChromiumExtensionPrompt(prompt), profileID) { answer($0.engineAnswer) }
            }
        }
        return profile
    }

    /// Whether the profile is in use in the engine.
    func isFollowing(_ profileID: Profile.ID) -> Bool {
        followedProfiles.contains(profileID)
    }

    /// Whether the profile can still be loaded (its data wasn't removed).
    func readyProfileIsAllowed(_ profileID: Profile.ID) -> Bool {
        !removedProfiles.contains(profileID)
    }

    /// The profile's engine window, for extension popups.
    func engineWindow(for profileID: Profile.ID) -> any AXOWindow {
        window(for: profileID)
    }

    /// The profile's engine window, made on first use.
    private func window(for profileID: Profile.ID) -> any AXOWindow {
        if let window = windows[profileID] { return window }
        // Through readyProfile, so the profile's callbacks and bookmarks are set before its
        // extensions start.
        let window = classes.window.window(with: readyProfile(profileID) ?? classes.profile.profile(withIdentifier: profileID))
        window.delegate = windowEvents
        // Extension calls that need the active window work while Axo is the active app.
        followAppActivation()
        window.isActive = NSApp?.isActive ?? false
        windows[profileID] = window
        return window
    }

    /// Keeps the engine's windows active while Axo is the active app, and not otherwise.
    private func followAppActivation() {
        guard activationObservers.isEmpty else { return }
        for (name, active) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setWindowsActive(active) }
            })
        }
    }

    /// Marks every engine window active or not, as the app becomes active or inactive.
    func setWindowsActive(_ active: Bool) {
        windows.values.forEach { $0.isActive = active }
    }

    public func setWindowPages(_ pages: [any EnginePage], active: (any EnginePage)?, profileID: Profile.ID) {
        guard state == .ready else {
            waitingWindowPages[profileID] = (pages, active)
            return
        }
        let window = window(for: profileID)
        window.pages = pages.compactMap { ($0 as? ChromiumPage)?.page }
        window.activePage = (active as? ChromiumPage)?.page
    }

    // MARK: Window events

    /// An extension's popup window: its first page goes to the pool, which shows it in a small
    /// window. Others close; popup windows show one page.
    private func popupWindowOpened(_ window: any AXOWindow, size: NSSize, profileID: Profile.ID) {
        guard let first = window.pages.first else {
            window.close()
            return
        }
        window.pages.dropFirst().forEach { $0.close() }
        window.delegate = windowEvents
        popupWindows.append(window)
        let page = makeChromiumPage(profileID: profileID)
        pagesByEnginePage.setObject(page, forKey: first)
        page.attach(first)
        delegate?.engine(self, didOpenPopupWindowWith: page, size: CGSize(width: size.width, height: size.height), profileID: profileID)
    }

    fileprivate func window(_ window: any AXOWindow, didOpen enginePage: any AXOPage, at index: Int) {
        guard let profileID = windows.first(where: { $0.value === window })?.key else {
            enginePage.close()
            return
        }
        delegate?.engine(self, didOpen: wrap(enginePage, profileID: profileID), profileID: profileID, at: index)
    }

    /// A ``ChromiumPage`` for a page the engine made itself, attached to it.
    func wrap(_ enginePage: any AXOPage, profileID: Profile.ID) -> ChromiumPage {
        let page = makeChromiumPage(profileID: profileID)
        pagesByEnginePage.setObject(page, forKey: enginePage)
        page.attach(enginePage)
        return page
    }

    private func makeChromiumPage(profileID: Profile.ID) -> ChromiumPage {
        let page = ChromiumPage(profileID: profileID)
        page.engine = self
        return page
    }

    fileprivate func window(_ window: any AXOWindow, didClose enginePage: any AXOPage) {
        // A popup window goes once Chrome closed its page.
        popupWindows.removeAll { $0 === window }
        guard let page = pagesByEnginePage.object(forKey: enginePage) else { return }
        page.closedByEngine()
        delegate?.engine(self, didClose: page)
    }

    fileprivate func window(_ window: any AXOWindow, didActivate enginePage: any AXOPage) {
        guard let page = pagesByEnginePage.object(forKey: enginePage) else { return }
        delegate?.engine(self, didActivate: page)
    }

    // MARK: WebEngine

    public func makePage(profileID: Profile.ID) -> any EnginePage {
        let page = makeChromiumPage(profileID: profileID)
        if state == .ready {
            attach(page)
        } else {
            waitingPages.append(page)
        }
        return page
    }

    /// Not supported by the Chromium engine yet (Phase 3); customizations are ignored.
    public func setSiteCustomizations(_ customizations: [SiteCustomization]) {}

    /// Clears a profile's website data (not its history, which is Axo's), once the engine is
    /// ready.
    public func clearWebsiteData(for profileID: Profile.ID) async {
        guard await whenReady(), let profile = readyProfile(profileID) else { return }
        await profile.clearWebsiteData()
    }

    /// Deletes a profile's engine data for good, once the engine is ready. The profile is never
    /// loaded again.
    public func removeWebsiteData(for profileID: Profile.ID) async throws {
        removedProfiles.insert(profileID)
        followedProfiles.remove(profileID)
        bookmarkTrees[profileID] = nil
        waitingWindowPages[profileID] = nil
        guard await whenReady() else { return }
        windows.removeValue(forKey: profileID)?.close()
        try await classes.profile.removeProfile(withIdentifier: profileID)
    }
}

/// Passes `AXOWindowDelegate` events to the engine. A separate object, because the protocol needs
/// an `NSObject`.
@MainActor
private final class WindowEvents: NSObject, AXOWindowDelegate {
    private weak var engine: ChromiumEngine?

    init(engine: ChromiumEngine) {
        self.engine = engine
    }

    func window(_ window: any AXOWindow, didOpen page: any AXOPage, at index: Int) {
        engine?.window(window, didOpen: page, at: index)
    }

    func window(_ window: any AXOWindow, didClose page: any AXOPage) {
        engine?.window(window, didClose: page)
    }

    func window(_ window: any AXOWindow, didActivate page: any AXOPage) {
        engine?.window(window, didActivate: page)
    }

    /// Not passed on yet: placing an extension's move among Axo's pinned tabs, folders, and splits
    /// needs its own design.
    func window(_ window: any AXOWindow, didMove page: any AXOPage, to index: Int) {}
}
