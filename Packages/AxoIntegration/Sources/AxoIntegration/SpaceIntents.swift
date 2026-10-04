import AppIntents
import AxoCore
import Foundation

/// What App Intents need from Axo's window. The app implements it over its window model.
@MainActor
public protocol IntentWindow: AnyObject, Sendable {
    /// Shows a Space when a Focus starts, or the earlier Space when it ends (`nil`).
    func applyFocusSpace(_ spaceID: Space.ID?) async
    /// Switches the window to a Space and brings it forward. Returns whether the Space exists.
    func showSpace(_ spaceID: Space.ID) async -> Bool
    /// Opens a page in a new tab, in `spaceID` if given or else the current Space, and brings
    /// the window forward.
    func open(_ url: URL, in spaceID: Space.ID?) async
    /// Shows a tab in its Space and brings the window forward. Returns whether the tab exists.
    func showTab(_ tabID: Tab.ID) async -> Bool
    /// The tab the window shows, if any.
    var currentTab: Tab? { get }
    /// Copies the current tab's page into a Space as a new tab, pinned or not. Returns it.
    func saveCurrentTab(to spaceID: Space.ID, pinned: Bool) async throws -> Tab
}

/// What App Intents need from the running app: its store and its window. The app sets
/// ``current`` at launch. (App Intents' own `@Dependency` only resolves inside a real intent
/// run, which unit tests can't start.)
public final class IntentBridge: Sendable {
    /// The running app's bridge.
    @MainActor public static var current: IntentBridge?

    /// The bridge, or an error intents can show if the app isn't ready.
    @MainActor static func require() throws -> IntentBridge {
        guard let current else { throw IntentBridgeError.notReady }
        return current
    }

    let store: TabStore
    let window: any IntentWindow

    /// Creates a bridge over the app's store and window.
    public init(store: TabStore, window: any IntentWindow) {
        self.store = store
        self.window = window
    }
}

/// Axo couldn't reach its window or database.
public enum IntentBridgeError: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    /// The Space doesn't exist anymore.
    case spaceNotFound
    /// The tab doesn't exist anymore.
    case tabNotFound
    /// Axo's window isn't showing a tab.
    case noCurrentTab

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Axo isn't ready yet. Open Axo and try again."
        case .spaceNotFound: "That Space isn't in Axo anymore."
        case .tabNotFound: "That tab isn't in Axo anymore."
        case .noCurrentTab: "Axo isn't showing a tab."
        }
    }
}

/// A Space, for Focus filters and Shortcuts.
public struct SpaceEntity: AppEntity, Identifiable, Hashable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
    public static let defaultQuery = SpaceQuery()

    public var id: Space.ID
    public var name: String

    public init(id: Space.ID, name: String) {
        self.id = id
        self.name = name
    }

    public init(_ space: Space) {
        self.init(id: space.id, name: space.name)
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Finds Spaces by ID or name, in sidebar order.
public struct SpaceQuery: EntityStringQuery {
    public init() {}

    private func spaces() async throws -> [Space] {
        try await IntentBridge.require().store.spaces()
    }

    public func entities(for identifiers: [SpaceEntity.ID]) async throws -> [SpaceEntity] {
        try await spaces().filter { identifiers.contains($0.id) }.map(SpaceEntity.init)
    }

    public func entities(matching string: String) async throws -> [SpaceEntity] {
        try await spaces()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(SpaceEntity.init)
    }

    public func suggestedEntities() async throws -> [SpaceEntity] {
        try await spaces().map(SpaceEntity.init)
    }
}

/// A Focus filter that shows a Space while the Focus is on. When the Focus ends, Axo goes back
/// to the Space it showed before.
public struct SpaceFocusFilter: SetFocusFilterIntent {
    public static let title: LocalizedStringResource = "Show a Space"
    public static let description: IntentDescription? = IntentDescription("Switch Axo's window to a Space while this Focus is on.")

    @Parameter(title: "Space")
    public var space: SpaceEntity?

    public init() {}

    public var displayRepresentation: DisplayRepresentation {
        guard let space else { return DisplayRepresentation(title: "Choose a Space") }
        return DisplayRepresentation(title: "Show \(space.name)")
    }

    public func perform() async throws -> some IntentResult {
        try await IntentBridge.require().window.applyFocusSpace(space?.id)
        return .result()
    }
}

/// Makes AxoIntegration's App Intents known to the app, which lists this package in its own
/// `AppIntentsPackage`.
public struct AxoIntegrationIntents: AppIntentsPackage {}
