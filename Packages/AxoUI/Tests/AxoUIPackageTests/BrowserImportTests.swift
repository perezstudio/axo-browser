import AxoCore
import AxoWeb
import Foundation
import Testing
@testable import AxoUI

/// An importer with canned data that records what it was asked to import.
@MainActor
final class FakeBrowserImporter: BrowserImporting {
    var sources = [ImportSourceOption(id: "arc", name: "Arc"), ImportSourceOption(id: "chrome", name: "Google Chrome")]
    var previews: [String: ImportCounts] = [
        "arc": ImportCounts(spaces: 2, pinnedTabs: 5, favorites: 1, openTabs: 0, historyPages: 1_200),
        "chrome": ImportCounts(bookmarks: 3),
    ]
    var failingSources: Set<String> = []
    var imports: [(String, Set<ImportPart>, Space.ID)] = []

    struct Unreadable: LocalizedError {
        var errorDescription: String? { "macOS didn't allow Axo to read Bookmarks." }
    }

    func availableSources() -> [ImportSourceOption] { sources }

    func preview(_ sourceID: String) async throws -> ImportCounts {
        if failingSources.contains(sourceID) { throw Unreadable() }
        return previews[sourceID] ?? ImportCounts()
    }

    func importData(from sourceID: String, parts: Set<ImportPart>, currentSpace: Space) async throws -> ImportCounts {
        imports.append((sourceID, parts, currentSpace.id))
        var counts = previews[sourceID] ?? ImportCounts()
        if !parts.contains(.history) { counts.historyPages = 0 }
        return counts
    }
}

@MainActor
struct BrowserImportTests {
    let model: BrowserModel
    let fake = FakeBrowserImporter()

    init() async throws {
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: WebViewPool(makeDataStore: { _ in .nonPersistent() }))
        await model.start()
    }

    private func openSession() async throws -> ImportSession {
        model.browserImporter = fake
        model.beginImport()
        let session = try #require(model.importSession)
        try await waitUntil { session.phase != .loading }
        return session
    }

    @Test func importingNeedsAnImporter() {
        model.beginImport()
        #expect(model.importSession == nil)
        #expect(!model.availableActions.contains(.importBrowserData))
        model.browserImporter = fake
        #expect(model.availableActions.contains(.importBrowserData))
    }

    @Test func theFirstBrowserIsReadWhenTheSheetOpens() async throws {
        let session = try await openSession()
        #expect(session.sources.map(\.id) == ["arc", "chrome"])
        #expect(session.sourceID == "arc")
        #expect(session.phase == .choosing(fake.previews["arc"]!))
        #expect(session.canImport)
    }

    @Test func partsCanBeTurnedOffExceptArcsSpaces() async throws {
        let session = try await openSession()
        session.setPart(.history, included: false)
        session.setPart(.spaces, included: false)
        #expect(!session.selectedParts.contains(.history))
        #expect(session.selectedParts.contains(.spaces), "The Spaces are the Arc import itself")

        await model.runImport()
        let request = try #require(fake.imports.first)
        #expect(request.0 == "arc" && request.2 == model.space?.id)
        #expect(!request.1.contains(.history))
        #expect(session.phase == .finished(ImportCounts(spaces: 2, pinnedTabs: 5, favorites: 1)))
    }

    @Test func importNeedsSomethingChosen() async throws {
        let session = try await openSession()
        await session.selectSource("chrome")
        #expect(session.canImport)
        session.setPart(.bookmarks, included: false)
        #expect(!session.canImport)
        await model.runImport()
        #expect(fake.imports.isEmpty)
    }

    @Test func unreadableBrowsersSayWhy() async throws {
        fake.failingSources = ["chrome"]
        let session = try await openSession()
        await session.selectSource("chrome")
        #expect(session.phase == .unreadable("macOS didn't allow Axo to read Bookmarks."))
        #expect(!session.canImport)
        await session.selectSource("arc")
        #expect(session.canImport, "Switching browsers reads the other one")
    }

    @Test func withNoBrowsersTheSheetStillOpens() {
        fake.sources = []
        model.browserImporter = fake
        model.beginImport()
        #expect(model.importSession?.sources.isEmpty == true)
        #expect(model.importSession?.canImport == false)
    }

    @Test func theCommandBarOffersImport() async throws {
        model.browserImporter = fake
        model.showCommandBar()
        model.setCommandQuery("import")
        let index = try #require(model.commandResults.firstIndex(of: .action(.importBrowserData)))
        await model.runCommand(at: index)
        #expect(model.importSession != nil)
    }

    @Test func countsDescribeThemselvesPlainly() {
        let counts = ImportCounts(spaces: 5, pinnedTabs: 141, favorites: 1, openTabs: 1, bookmarks: 2, historyPages: 1_273)
        #expect(counts.parts == ImportPart.allCases)
        #expect(counts.description(of: .spaces) == "5 Spaces, with 141 pinned tabs")
        #expect(counts.description(of: .favorites) == "1 favorite")
        #expect(counts.description(of: .openTabs) == "1 open tab")
        #expect(counts.description(of: .history) == "1,273 pages of history")
        #expect(ImportCounts(spaces: 1, pinnedTabs: 1).summary == "1 Space and 1 pinned tab")
        #expect(ImportCounts().summary == "Nothing")
        #expect(ImportCounts(bookmarks: 3).parts == [.bookmarks])
    }
}
