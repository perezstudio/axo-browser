import AxoCore
import Foundation
import Testing
@testable import AxoImport

struct ReaderTests {
    let source = URL(fileURLWithPath: "/fixture")

    private func tab(_ title: String, _ address: String) -> ImportedItem {
        .tab(title: title, url: URL(string: address)!)
    }

    @Test func arcSpacesKeepTheirFoldersAndProfiles() throws {
        let sidebar = try ArcSidebar(data: Data(BrowserFixtures.arcSidebar.utf8), from: source)

        #expect(sidebar.spaces.map(\.name) == ["Personal", "Work"])
        #expect(sidebar.spaces.map(\.profile) == [.default, .custom(directory: "Profile 1")])
        #expect(sidebar.spaces[0].pinned == [
            tab("My News", "https://news.example.com/"),
            .folder(name: "Recipes", children: [
                tab("Soup", "https://food.example.com/soup"),
                .folder(name: "Folder", children: [tab("Bread", "https://food.example.com/bread")]),
            ]),
        ], "Renamed tabs keep their custom title, and unknown items (an easel) are skipped")
        #expect(sidebar.spaces[0].unpinned == [tab("Left", "https://left.example.com/"), tab("Right", "https://right.example.com/")],
                "Split views become their tabs")
        #expect(sidebar.favorites == [
            .default: [tab("Mail", "https://mail.example.com/")],
            .custom(directory: "Profile 1"): [tab("Calendar", "https://calendar.example.com/")],
        ])
    }

    @Test(arguments: ["[]", "{}", "{\"sidebar\": {\"containers\": [{\"global\": {}}]}}", "not json"])
    func unexpectedArcDataIsReported(text: String) {
        #expect(throws: ImportError.unrecognizedFormat(source)) {
            try ArcSidebar(data: Data(text.utf8), from: source)
        }
    }

    @Test func chromiumProfilesAreListedDefaultFirst() throws {
        let fixtures = try BrowserFixtures()
        try fixtures.write(BrowserFixtures.localState, to: "Local State")
        let profiles = try ChromiumProfile.profiles(inLocalState: fixtures.root.appending(path: "Local State"))
        #expect(profiles.map(\.directory) == ["Default", "Profile 1", "Profile 2", "Profile 10"])
        #expect(profiles.map(\.name) == ["Personal", "Work", "Side", "Profile 10"], "A profile without a name uses its folder name")
    }

    @Test func chromeBookmarksBecomeOneFolder() throws {
        let folder = try ChromeBookmarks.folder(named: "Imported", from: Data(BrowserFixtures.chromeBookmarks.utf8), url: source)
        #expect(folder == .folder(name: "Imported", children: [
            tab("WebKit", "https://webkit.org/"),
            .folder(name: "Swift", children: [tab("Forums", "https://forums.swift.org/")]),
            .folder(name: "Empty", children: []),
            .folder(name: "Other Bookmarks", children: [tab("Recipes", "https://food.example.com/")]),
        ]), "The bookmarks bar comes first; empty roots are left out")

        let empty = #"{"roots": {"bookmark_bar": {"children": []}}}"#
        #expect(try ChromeBookmarks.folder(named: "Imported", from: Data(empty.utf8), url: source) == nil)
        #expect(throws: ImportError.unrecognizedFormat(source)) {
            try ChromeBookmarks.folder(named: "Imported", from: Data("{}".utf8), url: source)
        }
    }

    @Test func chromiumHistoryReadsRecentWebPages() throws {
        let fixtures = try BrowserFixtures()
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        try fixtures.writeHistory(to: "History", pages: [
            ("https://old.example.com/", "Old", 3, BrowserFixtures.chromiumTime(older), false),
            ("https://new.example.com/", "New", 1, BrowserFixtures.chromiumTime(recent), false),
            ("chrome://settings/", "Settings", 9, BrowserFixtures.chromiumTime(recent), false),
            ("https://hidden.example.com/", "Hidden", 1, BrowserFixtures.chromiumTime(recent), true),
        ])
        let file = fixtures.root.appending(path: "History")

        let pages = try ChromiumHistory.pages(at: file)
        #expect(pages.map(\.title) == ["New", "Old"], "Newest first; only visible web pages")
        #expect(pages[1].visitCount == 3)
        #expect(abs(pages[0].lastVisitedAt.timeIntervalSince(recent)) < 0.001)
        #expect(try ChromiumHistory.pages(at: file, limit: 1).map(\.title) == ["New"])
        #expect(try ChromiumHistory.pageCount(at: file) == 2)
        #expect(try ChromiumHistory.pageCount(at: file, limit: 1) == 1)
    }

    @Test func historyErrorsAreReported() throws {
        let fixtures = try BrowserFixtures()
        let missing = fixtures.root.appending(path: "History")
        #expect(throws: ImportError.notFound(missing)) { try ChromiumHistory.pages(at: missing) }
        try fixtures.write("not a database", to: "History")
        #expect(throws: ImportError.unrecognizedFormat(missing)) { try ChromiumHistory.pages(at: missing) }
    }
}
