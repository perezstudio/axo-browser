import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct FocusSpaceTests {
    let model: BrowserModel

    init() async throws {
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        await model.start()
    }

    private func space(_ name: String) throws -> Space {
        try #require(model.spaces.first { $0.name == name })
    }

    @Test func aFocusShowsItsSpaceAndTheEarlierOneReturnsAfter() async throws {
        await model.createSpace(name: "Work")
        await model.createSpace(name: "Play")
        await model.selectSpace(try space("Home").id)

        await model.applyFocusSpace(try space("Work").id)
        #expect(model.space?.name == "Work")
        // A second Focus right after keeps the original Space to go back to.
        await model.applyFocusSpace(try space("Play").id)
        #expect(model.space?.name == "Play")

        await model.applyFocusSpace(nil)
        #expect(model.space?.name == "Home")
        await model.applyFocusSpace(nil)
        #expect(model.space?.name == "Home", "Ending again does nothing")
    }

    @Test func deletedSpacesAreIgnored() async throws {
        await model.applyFocusSpace(UUID())
        #expect(model.space?.name == TabStore.defaultSpaceName)
    }
}
