import AxoCore
import Foundation
import Testing
@testable import AxoImport

struct BrowserImporterTests {
    let fixtures: BrowserFixtures
    let store: TabStore
    let home: Space
    let importer: BrowserImporter
    let visit = Date(timeIntervalSince1970: 1_800_000_000)

    init() async throws {
        fixtures = try BrowserFixtures()
        store = try TabStore.makeInMemory()
        home = try await store.bootstrap()
        importer = BrowserImporter(store: store, applicationSupport: fixtures.root)
    }

    private func writeArc() throws {
        try fixtures.write(BrowserFixtures.arcSidebar, to: "Arc/StorableSidebar.json")
        try fixtures.write(BrowserFixtures.localState, to: "Arc/User Data/Local State")
        try fixtures.writeHistory(to: "Arc/User Data/Default/History", pages: [
            ("https://personal.example.com/", "Personal page", 2, BrowserFixtures.chromiumTime(visit), false),
        ])
        try fixtures.writeHistory(to: "Arc/User Data/Profile 1/History", pages: [
            ("https://work.example.com/", "Work page", 4, BrowserFixtures.chromiumTime(visit), false),
            ("https://work.example.com/other", "Other", 1, BrowserFixtures.chromiumTime(visit), false),
        ])
    }

    private func writeChrome() throws {
        try fixtures.write(BrowserFixtures.localState, to: "Google/Chrome/Local State")
        try fixtures.write(BrowserFixtures.chromeBookmarks, to: "Google/Chrome/Profile 1/Bookmarks")
        try fixtures.writeHistory(to: "Google/Chrome/Profile 1/History", pages: [
            ("https://webkit.org/", "WebKit", 7, BrowserFixtures.chromiumTime(visit), false),
        ])
    }

    /// Names of a Space's pinned items at the top level.
    private func topLevel(_ space: Space) async throws -> [String] {
        let folders = try await store.folders(in: space.id).filter { $0.parentID == nil }.map { ($0.sortKey, $0.name) }
        let tabs = try await store.tabs(in: space.id).filter { $0.isPinned && $0.folderID == nil }.map { ($0.sortKey, $0.title) }
        return (folders + tabs).sorted { $0.0 < $1.0 }.map(\.1)
    }

    @Test func findsInstalledBrowsers() throws {
        #expect(importer.availableSources().isEmpty)
        try writeArc()
        try writeChrome()
        #expect(importer.availableSources().map(\.id) == ["arc", "chrome:Default", "chrome:Profile 1", "chrome:Profile 2", "chrome:Profile 10"])
    }

    @Test func chromeWithoutAReadableProfileListOffersItsDefaultProfile() throws {
        try FileManager.default.createDirectory(at: fixtures.root.appending(path: "Google/Chrome"), withIntermediateDirectories: true)
        #expect(importer.availableSources() == [.chrome(ChromiumProfile(directory: "Default", name: "Default"))])
    }

    @Test func previewingArcCountsWithoutChangingAnything() async throws {
        try writeArc()
        let counts = try await importer.preview(.arc)
        #expect(counts == BrowserImporter.Counts(spaces: 2, pinnedTabs: 4, favorites: 2, openTabs: 2, historyPages: 3))
        #expect(try await store.spaces().count == 1)
    }

    @Test func importingArcAddsSpacesProfilesFavoritesTabsAndHistory() async throws {
        try writeArc()
        let counts = try await importer.importData(from: .arc, parts: .all, currentSpace: home)
        #expect(counts == BrowserImporter.Counts(spaces: 2, pinnedTabs: 4, favorites: 2, openTabs: 2, historyPages: 3))

        let spaces = try await store.spaces()
        #expect(spaces.map(\.name) == ["Home", "Personal", "Work"])
        let (personal, work) = (spaces[1], spaces[2])
        #expect(personal.profileID == home.profileID, "Arc's default profile is the current profile")
        let profiles = try await store.profiles()
        #expect(profiles.first { $0.id == work.profileID }?.name == "Arc Work", "Each other Arc profile gets its own profile")

        #expect(try await topLevel(personal) == ["My News", "Recipes"], "Favorites aren't pinned tabs")
        #expect(try await topLevel(work) == ["Docs"])
        #expect(try await store.favorites.favorites(for: home.profileID).count == 1, "Arc's favorites become favorites")
        #expect(try await store.favorites.favorites(for: work.profileID).count == 1, "in their own profile")
        #expect(try await store.tabs(in: personal.id).filter { !$0.isPinned }.map(\.title) == ["Left", "Right"])

        #expect(try await store.history.recent(profileID: home.profileID).map(\.title) == ["Personal page"])
        #expect(try await store.history.recent(profileID: work.profileID).count == 2, "History goes to the matching profile")
    }

    @Test func arcPartsCanBeLeftOut() async throws {
        try writeArc()
        let counts = try await importer.importData(from: .arc, parts: [.spaces], currentSpace: home)
        #expect(counts == BrowserImporter.Counts(spaces: 2, pinnedTabs: 4))

        let personal = try await store.spaces()[1]
        #expect(try await topLevel(personal) == ["My News", "Recipes"])
        #expect(try await store.tabs(in: personal.id).allSatisfy(\.isPinned))
        #expect(try await store.history.recent(profileID: home.profileID).isEmpty)

        #expect(try await importer.importData(from: .arc, parts: [.favorites, .history], currentSpace: home) == .init(),
                "Favorites and history from Arc need its Spaces")
    }

    @Test func aFailedArcImportLeavesNoNewProfiles() async throws {
        try writeArc()
        // The current Space's profile doesn't exist, so writing the Spaces fails.
        let orphan = Space(profileID: UUID(), name: "Orphan", sortKey: "a0")
        await #expect(throws: TabStoreError.self) {
            try await importer.importData(from: .arc, parts: .all, currentSpace: orphan)
        }
        #expect(try await store.profiles().count == 1)
        #expect(try await store.spaces().count == 1)
    }

    @Test func importingChromeAddsBookmarksAndHistoryToTheCurrentSpace() async throws {
        try writeChrome()
        let source = BrowserImporter.Source.chrome(ChromiumProfile(directory: "Profile 1", name: "Work"))
        #expect(try await importer.preview(source) == BrowserImporter.Counts(bookmarks: 3, historyPages: 1))

        let counts = try await importer.importData(from: source, parts: .all, currentSpace: home)
        #expect(counts == BrowserImporter.Counts(bookmarks: 3, historyPages: 1))
        #expect(try await topLevel(home) == ["Imported from Chrome"])
        #expect(try await store.tabs(in: home.id).filter(\.isPinned).count == 3)
        #expect(try await store.history.recent(profileID: home.profileID).first?.visitCount == 7)
    }

    @Test func aChromeProfileWithoutDataImportsNothing() async throws {
        try writeChrome()
        let source = BrowserImporter.Source.chrome(ChromiumProfile(directory: "Profile 2", name: "Side"))
        #expect(try await importer.preview(source) == .init())
        #expect(try await importer.importData(from: source, parts: .all, currentSpace: home) == .init())
        #expect(try await store.folders(in: home.id).isEmpty)
    }

    @Test func unreadableArcDataIsReported() async throws {
        let file = fixtures.root.appending(path: "Arc/StorableSidebar.json")
        await #expect(throws: ImportError.notFound(file)) { try await importer.preview(.arc) }
        try fixtures.write("{}", to: "Arc/StorableSidebar.json")
        await #expect(throws: ImportError.unrecognizedFormat(file)) { try await importer.preview(.arc) }
    }
}
