import AppIntents
import AxoCore
import Foundation
import Testing
@testable import AxoIntegration

/// Records the Spaces the Focus filter asks to show.
@MainActor
final class FocusRecorder {
    var requests: [Space.ID?] = []
}

// One shared bridge, so these run one at a time.
@MainActor
@Suite(.serialized)
struct SpaceIntentTests {
    let store: TabStore
    let recorder = FocusRecorder()
    let home: Space
    let work: Space

    init() async throws {
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
        work = try await store.createSpace(name: "Work", profileID: home.profileID)
        let recorder = recorder
        let bridge = IntentBridge(store: store) { recorder.requests.append($0) }
        IntentBridge.current = bridge
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
        #expect(recorder.requests == [work.id, nil])
    }

    @Test func theFilterDescribesItself() {
        let filter = SpaceFocusFilter()
        #expect(String(localized: filter.displayRepresentation.title) == "Choose a Space")
        filter.space = SpaceEntity(id: UUID(), name: "Work")
        #expect(String(localized: filter.displayRepresentation.title) == "Show Work")
    }
}
