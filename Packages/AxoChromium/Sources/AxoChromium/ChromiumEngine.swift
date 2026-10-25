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
    /// Profiles whose extension changes are being followed.
    private var followedProfiles: Set<Profile.ID> = []

    /// Creates an engine.
    ///
    /// - Parameters:
    ///   - classes: The engine's classes, from ``ChromiumFramework/load(from:)``.
    ///   - userDataDirectory: Where profiles keep their data, one folder per profile.
    ///   - schedule: Runs a block on a later turn of the main run loop. Tests replace it.
    public init(
        classes: ChromiumEngineClasses,
        userDataDirectory: URL,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = ChromiumEngine.onNextRunLoopTurn
    ) {
        self.classes = classes
        self.userDataDirectory = userDataDirectory
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
    }

    private func attach(_ page: ChromiumPage) {
        guard !page.isClosed else { return }
        let profile = classes.profile.profile(withIdentifier: page.profileID)
        let enginePage = classes.page.page(with: profile)
        pagesByEnginePage.setObject(page, forKey: enginePage)
        page.attach(enginePage)
    }

    /// The engine's profile for `profileID` once the engine is ready, following its extension
    /// changes from then on.
    func readyProfile(_ profileID: Profile.ID) -> (any AXOProfile)? {
        guard state == .ready else { return nil }
        let profile = classes.profile.profile(withIdentifier: profileID)
        if followedProfiles.insert(profileID).inserted {
            profile.onExtensionsChange = { [weak self] in self?.onExtensionsChange?(profileID) }
        }
        return profile
    }

    /// The profile's engine window, for extension popups.
    func engineWindow(for profileID: Profile.ID) -> any AXOWindow {
        window(for: profileID)
    }

    /// The profile's engine window, made on first use.
    private func window(for profileID: Profile.ID) -> any AXOWindow {
        if let window = windows[profileID] { return window }
        let window = classes.window.window(with: classes.profile.profile(withIdentifier: profileID))
        window.delegate = windowEvents
        windows[profileID] = window
        return window
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

    fileprivate func window(_ window: any AXOWindow, didOpen enginePage: any AXOPage, at index: Int) {
        guard let profileID = windows.first(where: { $0.value === window })?.key else {
            enginePage.close()
            return
        }
        let page = ChromiumPage(profileID: profileID)
        pagesByEnginePage.setObject(page, forKey: enginePage)
        page.attach(enginePage)
        delegate?.engine(self, didOpen: page, profileID: profileID, at: index)
    }

    fileprivate func window(_ window: any AXOWindow, didClose enginePage: any AXOPage) {
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
        let page = ChromiumPage(profileID: profileID)
        if state == .ready {
            attach(page)
        } else {
            waitingPages.append(page)
        }
        return page
    }

    /// Not supported by the Chromium engine yet (Phase 3); customizations are ignored.
    public func setSiteCustomizations(_ customizations: [SiteCustomization]) {}

    public func clearWebsiteData(for profileID: Profile.ID) async {
        guard state == .ready else { return }
        await classes.profile.profile(withIdentifier: profileID).clearWebsiteData()
    }

    public func removeWebsiteData(for profileID: Profile.ID) async throws {
        guard state == .ready else { return }
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
