import AppIntents
import AxoCore
import Foundation

/// A tab, for Shortcuts.
public struct TabEntity: AppEntity, Identifiable, Hashable {
    public static func == (lhs: TabEntity, rhs: TabEntity) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tab"
    public static let defaultQuery = TabQuery()

    public var id: Tab.ID
    /// The page title, or the address while there's none.
    @Property(title: "Title") public var title: String
    @Property(title: "Address") public var url: URL
    @Property(title: "Space") public var spaceName: String

    public init(_ tab: Tab, spaceName: String) {
        id = tab.id
        title = tab.title.isEmpty ? (tab.url.host() ?? tab.url.absoluteString) : tab.title
        url = tab.url
        self.spaceName = spaceName
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(url.host() ?? url.absoluteString) · \(spaceName)")
    }

    /// Entities for tabs, with their Spaces' names.
    static func entities(for tabs: [Tab], store: TabStore) async throws -> [TabEntity] {
        let names = Dictionary(uniqueKeysWithValues: try await store.spaces().map { ($0.id, $0.name) })
        return tabs.map { TabEntity($0, spaceName: names[$0.spaceID] ?? "") }
    }
}

/// Finds tabs by ID, or by title and address across every Space.
public struct TabQuery: EntityStringQuery {
    public init() {}

    public func entities(for identifiers: [TabEntity.ID]) async throws -> [TabEntity] {
        let store = try await IntentBridge.require().store
        var tabs: [Tab] = []
        for id in identifiers {
            if let tab = try await store.tab(id: id), tab.archivedAt == nil { tabs.append(tab) }
        }
        return try await TabEntity.entities(for: tabs, store: store)
    }

    public func entities(matching string: String) async throws -> [TabEntity] {
        let store = try await IntentBridge.require().store
        return try await TabEntity.entities(for: store.searchTabs(matching: string), store: store)
    }

    public func suggestedEntities() async throws -> [TabEntity] {
        try await entities(matching: "")
    }
}

/// Opens a page in Axo, optionally in a chosen Space.
public struct OpenInAxoIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open in Axo"
    public static let description = IntentDescription("Open a web page in a new Axo tab.")
    public static let openAppWhenRun = true

    @Parameter(title: "Address") public var url: URL
    @Parameter(title: "Space", description: "Leave empty to use the current Space.") public var space: SpaceEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url) in \(\.$space)")
    }

    public func perform() async throws -> some IntentResult {
        try await IntentBridge.require().window.open(url, in: space?.id)
        return .result()
    }
}

/// Switches Axo's window to a Space.
public struct ShowSpaceIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Space"
    public static let description = IntentDescription("Switch Axo's window to a Space, with its pinned tabs ready.")
    public static let openAppWhenRun = true

    @Parameter(title: "Space") public var space: SpaceEntity

    public init() {}

    public init(space: SpaceEntity) {
        self.space = space
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$space)")
    }

    public func perform() async throws -> some IntentResult {
        guard try await IntentBridge.require().window.showSpace(space.id) else { throw IntentBridgeError.spaceNotFound }
        return .result()
    }
}

/// Finds open tabs in every Space by title or address.
public struct FindTabsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Find Tabs"
    public static let description = IntentDescription("Find tabs in any Space whose title or address contains some text.")

    @Parameter(title: "Text") public var text: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Find tabs matching \(\.$text)")
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<[TabEntity]> {
        let store = try await IntentBridge.require().store
        return .result(value: try await TabEntity.entities(for: store.searchTabs(matching: text), store: store))
    }
}

/// Shows a tab in Axo's window.
public struct ShowTabIntent: AppIntent {
    public static let title: LocalizedStringResource = "Show Tab"
    public static let description = IntentDescription("Show a tab in Axo's window, switching to its Space.")
    public static let openAppWhenRun = true

    @Parameter(title: "Tab") public var tab: TabEntity

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$tab)")
    }

    public func perform() async throws -> some IntentResult {
        guard try await IntentBridge.require().window.showTab(tab.id) else { throw IntentBridgeError.tabNotFound }
        return .result()
    }
}

/// The tab Axo's window shows.
public struct GetCurrentTabIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Current Tab"
    public static let description = IntentDescription("Get the tab Axo's window is showing, with its title and address.")

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<TabEntity> {
        let bridge = try await IntentBridge.require()
        guard let tab = await bridge.window.currentTab else { throw IntentBridgeError.noCurrentTab }
        return .result(value: try await TabEntity.entities(for: [tab], store: bridge.store)[0])
    }
}

/// Copies the current tab into a Space, pinned by default, to keep it there.
public struct SaveTabToSpaceIntent: AppIntent {
    public static let title: LocalizedStringResource = "Save Tab to Space"
    public static let description = IntentDescription("Copy the page Axo is showing into a Space, pinned so it stays.")

    @Parameter(title: "Space") public var space: SpaceEntity
    @Parameter(title: "Pin It", default: true) public var pinned: Bool

    public init() {}

    public init(space: SpaceEntity) {
        self.space = space
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Save the current tab to \(\.$space)") {
            \.$pinned
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<TabEntity> {
        let bridge = try await IntentBridge.require()
        guard await bridge.window.currentTab != nil else { throw IntentBridgeError.noCurrentTab }
        let saved = try await bridge.window.saveCurrentTab(to: space.id, pinned: pinned)
        return .result(value: try await TabEntity.entities(for: [saved], store: bridge.store)[0])
    }
}
