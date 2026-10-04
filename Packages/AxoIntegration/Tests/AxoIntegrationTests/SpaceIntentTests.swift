import AppIntents
import AxoCore
import Foundation
import Testing
@testable import AxoIntegration

/// A window that records what intents ask of it.
@MainActor
final class FakeWindow: IntentWindow {
    let store: TabStore
    var focusRequests: [Space.ID?] = []
    var shownSpaces: [Space.ID] = []
    var opened: [(URL, Space.ID?)] = []
    var shownTabs: [Tab.ID] = []
    var currentTab: Tab?

    init(store: TabStore) {
        self.store = store
    }

    func applyFocusSpace(_ spaceID: Space.ID?) async { focusRequests.append(spaceID) }

    func showSpace(_ spaceID: Space.ID) async -> Bool {
        guard (try? await store.spaces().contains { $0.id == spaceID }) == true else { return false }
        shownSpaces.append(spaceID)
        return true
    }

    func open(_ url: URL, in spaceID: Space.ID?) async { opened.append((url, spaceID)) }

    func showTab(_ tabID: Tab.ID) async -> Bool {
        guard (try? await store.tab(id: tabID)) != nil else { return false }
        shownTabs.append(tabID)
        return true
    }

    func saveCurrentTab(to spaceID: Space.ID, pinned: Bool) async throws -> Tab {
        let current = try #require(currentTab)
        let tab = try await store.openTab(url: current.url, title: current.title, in: spaceID)
        if pinned { try await store.setPinned(true, tabID: tab.id) }
        return try #require(try await store.tab(id: tab.id))
    }
}

// One shared bridge, so these run one at a time.
@MainActor
@Suite(.serialized)
struct SpaceIntentTests {
    let store: TabStore
    let window: FakeWindow
    let home: Space
    let work: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
        work = try await store.createSpace(name: "Work", profileID: home.profileID)
        window = FakeWindow(store: store)
        IntentBridge.current = IntentBridge(store: store, window: window)
    }

    @Test func intentsSayWhenAxoIsntReady() async throws {
        IntentBridge.current = nil
        await #expect(throws: IntentBridgeError.self) { try await SpaceQuery().suggestedEntities() }
    }

    @Test func spacesAreFoundByIDNameAndSuggestion() async throws {
        let query = SpaceQuery()
        #expect(try await query.suggestedEntities().map(\.name) == ["Home", "Work"])
        #expect(try await query.entities(for: [work.id]).map(\.name) == ["Work"])
        #expect(try await query.entities(matching: "wor").map(\.id) == [work.id])
    }

    @Test func theFocusFilterShowsItsSpaceAndGoesBackWhenItEnds() async throws {
        let filter = SpaceFocusFilter()
        filter.space = SpaceEntity(work)
        _ = try await filter.perform()
        filter.space = nil
        _ = try await filter.perform()
        #expect(window.focusRequests == [work.id, nil])
    }

    @Test func theFilterDescribesItself() {
        let filter = SpaceFocusFilter()
        #expect(String(localized: filter.displayRepresentation.title) == "Choose a Space")
        filter.space = SpaceEntity(id: UUID(), name: "Work")
        #expect(String(localized: filter.displayRepresentation.title) == "Show Work")
    }

    // MARK: Shortcuts actions

    @Test func openInAxoOpensThePageInTheChosenSpace() async throws {
        let intent = OpenInAxoIntent()
        intent.url = URL(string: "https://swift.org")!
        intent.space = SpaceEntity(work)
        _ = try await intent.perform()
        intent.space = nil
        _ = try await intent.perform()
        #expect(window.opened.map(\.1) == [work.id, nil])
        #expect(OpenInAxoIntent.openAppWhenRun)
    }

    @Test func showSpaceSwitchesAndReportsMissingSpaces() async throws {
        _ = try await ShowSpaceIntent(space: SpaceEntity(work)).perform()
        #expect(window.shownSpaces == [work.id])
        await #expect(throws: IntentBridgeError.self) {
            try await ShowSpaceIntent(space: SpaceEntity(id: UUID(), name: "Gone")).perform()
        }
    }

    @Test func tabsAreFoundAcrossSpacesAndShown() async throws {
        let docs = try await store.openTab(url: URL(string: "https://docs.example.com")!, title: "Design Doc", in: work.id)
        _ = try await store.openTab(url: URL(string: "https://mail.example.com")!, title: "Inbox", in: home.id)

        let find = FindTabsIntent()
        find.text = "design"
        let result = try await find.perform()
        let found = try #require(result.value)
        #expect(found.map(\.id) == [docs.id])
        #expect(found.first?.spaceName == "Work")
        #expect(try await TabQuery().entities(for: [docs.id]).map(\.title) == ["Design Doc"])

        let show = ShowTabIntent()
        show.tab = try #require(found.first)
        _ = try await show.perform()
        #expect(window.shownTabs == [docs.id])
    }

    @Test func theCurrentTabCanBeReadAndSavedToASpace() async throws {
        await #expect(throws: IntentBridgeError.self) { try await GetCurrentTabIntent().perform() }

        window.currentTab = try await store.openTab(url: URL(string: "https://swift.org/blog")!, title: "Swift Blog", in: home.id)
        let current = try #require(try await GetCurrentTabIntent().perform().value)
        #expect(current.title == "Swift Blog" && current.spaceName == "Home")

        let save = SaveTabToSpaceIntent(space: SpaceEntity(work))
        let saved = try #require(try await save.perform().value)
        #expect(saved.spaceName == "Work")
        let stored = try #require(try await store.tab(id: saved.id))
        #expect(stored.isPinned, "Pinned by default, so it stays")
        #expect(try await store.tabs(in: home.id).count == 1, "A copy: the original stays")
    }
}
