import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

/// First run (#175): it shows once, for a browser with nothing in it, and walks from the welcome
/// through importing (or starting fresh) to setting up the first Space.
@MainActor
struct FirstRunTests {
    let model: BrowserModel
    let record = InMemoryFirstRunRecord()

    init() async throws {
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
    }

    @Test func withoutARecordItNeverShows() async {
        await model.start()
        #expect(model.firstRun == nil, "Test runs and other models set no record")
    }

    @Test func aFreshBrowserShowsTheWelcome() async {
        model.firstRunRecord = record
        await model.start()
        #expect(model.firstRun?.step == .welcome)
        #expect(model.firstRun?.spaceName == model.space?.name)
        #expect(!record.isComplete, "Not done until it's finished")
    }

    @Test func itShowsOnlyOnce() async throws {
        record.isComplete = true
        model.firstRunRecord = record
        await model.start()
        #expect(model.firstRun == nil)
    }

    @Test func aBrowserWithTabsSkipsItAndRemembers() async throws {
        let store = try TabStore.makeInMemory()
        let space = try await store.bootstrap()
        _ = try await store.openTab(url: URL(string: "https://example.com")!, in: space.id)
        let model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        model.firstRunRecord = record
        await model.start()
        #expect(model.firstRun == nil, "Someone updating Axo never sees it")
        #expect(record.isComplete)
    }

    @Test func withNothingToImportItGoesStraightToSettingUp() async throws {
        model.firstRunRecord = record
        await model.start()
        model.continueFirstRun()
        #expect(model.firstRun?.step == .setUpSpace)

        let firstRun = try #require(model.firstRun)
        firstRun.spaceName = "  Personal "
        firstRun.spaceIcon = "leaf"
        firstRun.preset = .sage
        let spaceID = try #require(model.space?.id)
        await model.createFirstSpace()

        #expect(model.firstRun == nil)
        #expect(record.isComplete)
        // The Space's new record arrives through the model's observation.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline,
              model.spaces.first(where: { $0.id == spaceID }).map({ $0.icon != "leaf" || $0.theme == nil }) ?? true {
            try await Task.sleep(for: .milliseconds(20))
        }
        let space = try #require(model.spaces.first { $0.id == spaceID })
        #expect(space.name == "Personal", "Trimmed")
        #expect(space.icon == "leaf")
        #expect(space.theme == ThemePreset.sage.theme)
    }

    @Test func startingFreshSkipsTheImport() async throws {
        let importer = FakeBrowserImporter()
        model.browserImporter = importer
        model.firstRunRecord = record
        await model.start()
        model.continueFirstRun()
        #expect(model.firstRun?.step == .importing)
        let session = try #require(model.firstRun?.importSession)
        #expect(session.sources.map(\.name) == ["Arc", "Google Chrome"])

        model.startFresh()
        #expect(model.firstRun?.step == .setUpSpace)
        #expect(importer.imports.isEmpty)
    }

    @Test func importingFinishesWithoutSettingUp() async throws {
        let importer = FakeBrowserImporter()
        model.browserImporter = importer
        model.firstRunRecord = record
        await model.start()
        model.continueFirstRun()
        let session = try #require(model.firstRun?.importSession)
        // Arc is read first.
        try await waitUntil { session.canImport }
        #expect(session.sourceID == "arc")
        #expect(session.canImport)

        await model.importInFirstRun()
        #expect(importer.imports.map(\.0) == ["arc"])
        #expect(model.firstRun?.hasImported == true, "It waits on the import step for Continue")

        model.finishFirstRun()
        #expect(model.firstRun == nil)
        #expect(record.isComplete)
    }

    @Test func aBrowserWithOnlyHistorySkipsIt() async throws {
        let store = try TabStore.makeInMemory()
        let space = try await store.bootstrap()
        try await store.history.recordVisit(to: URL(string: "https://example.com")!, title: "Example", profileID: space.profileID)
        let model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        model.firstRunRecord = record
        await model.start()
        #expect(model.firstRun == nil, "Someone who closed every tab still has history")
        #expect(record.isComplete)
    }

    /// Spaces arriving from iCloud end first run, so it never renames or rethemes one of them.
    @Test func spacesArrivingEndItWithoutChangingThem() async throws {
        let store = try TabStore.makeInMemory()
        let model = BrowserModel(store: store, pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        model.announce = { _ in }
        model.firstRunRecord = record
        await model.start()
        let firstRun = try #require(model.firstRun)
        firstRun.spaceName = "Renamed"
        let home = try #require(model.space)

        let synced = try await store.createSpace(name: "Work", profileID: home.profileID)
        try await waitUntil { model.firstRun == nil }
        #expect(record.isComplete)

        await model.createFirstSpace()
        #expect(model.spaces.map(\.name).sorted() == ["Home", "Work"], "Nothing renamed")
        #expect(model.spaces.contains { $0.id == synced.id })
    }

    /// A link from another app while first run shows ends it, so its tab isn't hidden.
    @Test func aLinkFromAnotherAppEndsIt() async throws {
        model.firstRunRecord = record
        await model.start()
        #expect(model.firstRun != nil)
        await model.openExternalURL(URL(string: "https://example.com/link")!)
        #expect(model.firstRun == nil)
        #expect(record.isComplete)
    }
}
