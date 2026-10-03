import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

@MainActor
struct TabEventTests {
    let model: BrowserModel
    let directory: URL
    var events: [TabEvent] { recorder.events }
    let recorder = Recorder()

    @MainActor
    final class Recorder {
        var events: [TabEvent] = []
    }

    init() async throws {
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoTabEventTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await model.start()
        let recorder = recorder
        model.onTabEvent = { recorder.events.append($0) }
    }

    private func page(_ name: String) throws -> URL {
        let url = directory.appending(path: "\(name).html")
        try "<title>\(name)</title>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func openingSelectingAndClosingTabsAreReported() async throws {
        await model.openTab(url: try page("a"))
        let a = try #require(model.selectedTabID)
        await model.openTab(url: try page("b"))
        let b = try #require(model.selectedTabID)
        model.select(a)
        await model.closeTab(a)

        #expect(events.filter { if case .changed = $0 { false } else { true } } == [
            .opened(a), .activated(a, previous: nil),
            .opened(b), .activated(b, previous: a),
            .activated(a, previous: b),
            .closed(a), .activated(b, previous: a),
        ])
    }

    @Test func selectingTheSameTabAgainIsNotAnEvent() async throws {
        await model.openTab(url: try page("a"))
        recorder.events.removeAll()
        model.select(model.selectedTabID)
        #expect(events.isEmpty)
    }

    @Test func pageChangesAndSpaceSwitchesAreReported() async throws {
        await model.openTab(url: try page("a"))
        let a = try #require(model.selectedTabID)
        try await waitUntil { recorder.events.contains(.changed(a)) }

        await model.createSpace(name: "Work")
        #expect(events.contains(.spaceChanged))
    }

    @Test func closingAPinnedTabIsNotAClose() async throws {
        await model.openTab(url: try page("a"))
        let a = try #require(model.selectedTabID)
        await model.setPinned(true, tabID: a)
        recorder.events.removeAll()

        await model.closeTab(a)

        #expect(!events.contains(.closed(a)), "A pinned tab stays in the window")
    }
}
