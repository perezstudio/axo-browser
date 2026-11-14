import AxoCore
import Foundation
import Observation

/// Whether the person has been through first run, kept outside the database so a fresh database
/// (after a reset) doesn't show it again.
public protocol FirstRunRecord: AnyObject {
    /// Whether first run has finished, or was skipped because the browser already had data.
    var isComplete: Bool { get set }
}

/// A ``FirstRunRecord`` kept in memory, for tests and UI tests that ask for first run.
public final class InMemoryFirstRunRecord: FirstRunRecord {
    public var isComplete: Bool

    public init(isComplete: Bool = false) {
        self.isComplete = isComplete
    }
}

/// A ``FirstRunRecord`` kept in user defaults.
public final class DefaultsFirstRunRecord: FirstRunRecord {
    /// The defaults key.
    public static let key = "firstRunComplete"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var isComplete: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// First run (#175): a welcome, then importing from another browser (or starting fresh), then
/// setting up the first Space, all in one card. There's no profile step: people start in the
/// Default profile.
@MainActor
@Observable
public final class FirstRun {
    /// Where first run is.
    public enum Step: Equatable, Sendable {
        /// The welcome.
        case welcome
        /// What another browser on this Mac has, with Import and Start Fresh; or, with nothing to
        /// import, a note saying so.
        case importing
        /// Naming the first Space and choosing its icon and color.
        case setUpSpace
    }

    /// The step shown.
    public internal(set) var step: Step = .welcome
    /// The import of the step before setting up, while there's a browser to import from.
    public internal(set) var importSession: ImportSession?
    /// The first Space's name.
    public var spaceName: String
    /// The first Space's icon, an SF Symbol.
    public var spaceIcon: String
    /// The first Space's theme, a preset; `nil` is the system's look.
    var preset: ThemePreset?

    /// The icons offered for the first Space.
    static let icons = ["house", "briefcase", "book", "sparkles", "leaf", "gamecontroller"]
    /// Each icon's name, for VoiceOver and tooltips.
    static let iconNames = ["house": "House", "briefcase": "Briefcase", "book": "Book", "sparkles": "Sparkles",
                            "leaf": "Leaf", "gamecontroller": "Game Controller"]

    init(spaceName: String) {
        self.spaceName = spaceName
        spaceIcon = Self.icons[0]
    }

    /// Whether the import finished, so the next step is Continue.
    var hasImported: Bool {
        if case .finished = importSession?.phase { true } else { false }
    }
}

extension BrowserModel {
    /// Shows first run if this browser has never been through it and has nothing in it yet: one
    /// Space, no tabs or favorites. A browser that already has data (someone updating Axo) is
    /// marked as done without showing it. Nothing happens without a ``firstRunRecord``, which
    /// the app sets outside test runs (and UI tests set only when they ask for first run).
    func beginFirstRunIfNeeded() {
        guard let firstRunRecord, !firstRunRecord.isComplete, firstRun == nil, let space else { return }
        guard spaces.count == 1, tabs.isEmpty, favorites.isEmpty else {
            firstRunRecord.isComplete = true
            return
        }
        firstRun = FirstRun(spaceName: space.name)
    }

    /// Leaves the welcome: to importing when another browser is on this Mac, otherwise straight
    /// to setting up the first Space.
    public func continueFirstRun() {
        guard let firstRun, firstRun.step == .welcome else { return }
        guard let browserImporter else {
            firstRun.step = .setUpSpace
            return
        }
        let session = ImportSession(importer: browserImporter)
        session.announce = { [weak self] in self?.announce($0) }
        guard let source = session.sources.first(where: { $0.id.lowercased().contains("arc") }) ?? session.sources.first else {
            firstRun.step = .setUpSpace
            return
        }
        firstRun.importSession = session
        firstRun.step = .importing
        Task { await session.selectSource(source.id) }
    }

    /// Imports everything the browser has, then waits on the import step for Continue.
    public func importInFirstRun() async {
        guard let session = firstRun?.importSession, let space else { return }
        await session.run(currentSpace: space)
    }

    /// Skips importing and goes on to setting up the first Space.
    public func startFresh() {
        guard let firstRun, firstRun.step == .importing else { return }
        firstRun.step = .setUpSpace
    }

    /// Names the first Space and gives it the chosen icon and color, then finishes first run.
    public func createFirstSpace() async {
        guard let firstRun, let space else { return }
        let name = firstRun.spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != space.name { await renameSpace(space.id, to: name) }
        await setSpaceAppearance(space.id, color: nil, icon: firstRun.spaceIcon)
        if let preset = firstRun.preset { await setSpaceTheme(space.id, theme: preset.theme) }
        finishFirstRun()
    }

    /// Ends first run for good: after setting up a Space, or after an import (whose Spaces need
    /// no setting up).
    public func finishFirstRun() {
        guard firstRun != nil else { return }
        firstRunRecord?.isComplete = true
        firstRun = nil
        announce("Welcome to Axo")
    }
}
