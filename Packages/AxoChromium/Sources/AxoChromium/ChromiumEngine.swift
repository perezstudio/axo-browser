import AxoCore
import AxoEngineAPI
import AxoWeb
import Foundation

/// The Chromium engine as an AxoWeb ``WebEngine``: one Chromium profile per Axo profile, and an
/// `AXOPage` per tab.
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
        page.attach(classes.page.page(with: profile))
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
        try await classes.profile.removeProfile(withIdentifier: profileID)
    }
}
