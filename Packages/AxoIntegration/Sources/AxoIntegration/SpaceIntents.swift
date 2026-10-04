import AppIntents
import AxoCore
import Foundation

/// What App Intents need from the running app: the Spaces, and a way to show one. The app sets
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
    /// Shows a Space when a Focus starts, or the earlier Space when it ends (`nil`).
    let applyFocusSpace: @Sendable @MainActor (Space.ID?) async -> Void

    /// Creates a bridge over the app's store and window.
    public init(store: TabStore, applyFocusSpace: @escaping @Sendable @MainActor (Space.ID?) async -> Void) {
        self.store = store
        self.applyFocusSpace = applyFocusSpace
    }
}

/// Axo couldn't reach its window or database.
public enum IntentBridgeError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    public var localizedStringResource: LocalizedStringResource {
        "Axo isn't ready yet. Open Axo and try again."
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
        try await IntentBridge.require().applyFocusSpace(space?.id)
        return .result()
    }
}

/// Makes AxoIntegration's App Intents known to the app, which lists this package in its own
/// `AppIntentsPackage`.
public struct AxoIntegrationIntents: AppIntentsPackage {}
