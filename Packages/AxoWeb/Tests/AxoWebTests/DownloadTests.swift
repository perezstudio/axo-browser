import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct DownloadTests {
    let pages: TestPages
    let downloadsDirectory: URL
    let pool: WebViewPool
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
        downloadsDirectory = pages.directory.appending(path: "Downloads", directoryHint: .isDirectory)
        pool = WebViewPool.forTesting(downloadsDirectory: downloadsDirectory)
    }

    /// Loads a page whose only link downloads `contents` as `name`, then clicks it.
    ///
    /// The link uses a `data:` URL because browsers ignore `download` on cross-origin links, and
    /// every `file:` URL is its own origin.
    private func clickDownloadLink(named name: String, contents: String) async throws -> Tab {
        let href = "data:text/plain," + contents.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let page = pages.directory.appending(path: "links-\(UUID().uuidString).html")
        try "<!doctype html><title>Links</title><a id='link' href='\(href)' download='\(name)'>Get it</a>"
            .write(to: page, atomically: true, encoding: .utf8)
        let tab = Tab.testTab(url: page)
        let webView = pool.webView(for: tab, profileID: profileID)
        try await waitUntil("links page") { pool.state(for: tab.id)?.title == "Links" && pool.state(for: tab.id)?.isLoading == false }
        _ = try await webView.callAsyncJavaScript("document.getElementById('link').click()", contentWorld: .page)
        return tab
    }

    // MARK: Starting downloads

    @Test func linksWithTheDownloadAttributeSaveToTheDownloadsFolder() async throws {
        var ended: [DownloadState] = []
        pool.downloads.onEnd = { ended.append($0.state) }
        let tab = try await clickDownloadLink(named: "report.txt", contents: "quarterly numbers")

        try await waitUntil("download to finish") { pool.downloads.items.first?.state == .finished }
        let item = try #require(pool.downloads.items.first)
        let destination = try #require(item.destination)
        #expect(destination.deletingLastPathComponent().standardizedFileURL == downloadsDirectory.standardizedFileURL)
        #expect(item.filename == "report.txt")
        #expect(try String(contentsOf: destination, encoding: .utf8) == "quarterly numbers")
        #expect(item.sourceTabID == tab.id)
        #expect(item.fractionCompleted == 1)
        #expect(item.completedBytes == 17)
        #expect(pool.downloads.activeCount == 0)
        #expect(ended == [.finished], "The app hears when a download ends")
    }

    @Test func responsesWebKitCannotShowDownloadInsteadOfNavigating() async throws {
        let archive = pages.directory.appending(path: "bundle.zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18)).write(to: archive)
        let start = try pages.page("Start")
        let tab = Tab.testTab(url: start)
        _ = pool.webView(for: tab, profileID: profileID)
        try await waitUntil("start page") { pool.state(for: tab.id)?.title == "Start" }

        pool.load(archive, in: tab.id)

        try await waitUntil("download to finish") { pool.downloads.items.first?.state == .finished }
        #expect(pool.downloads.items.first?.filename == "bundle.zip")
        #expect(pool.state(for: tab.id)?.url == start, "The tab stays on its page")
    }

    #if os(macOS)
    @Test func finishedDownloadsAreQuarantined() async throws {
        _ = try await clickDownloadLink(named: "tool.sh", contents: "echo hi")
        try await waitUntil("download to finish") { pool.downloads.items.first?.state == .finished }

        let destination = try #require(pool.downloads.items.first?.destination)
        let properties = try #require(try destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect(properties[kLSQuarantineAgentNameKey as String] as? String == "Axo")
        #expect(properties[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
    }
    #endif

    @Test func repeatedDownloadsGetUniqueNames() async throws {
        _ = try await clickDownloadLink(named: "notes.txt", contents: "v1")
        try await waitUntil("first download") { pool.downloads.items.first?.state == .finished }
        _ = try await clickDownloadLink(named: "notes.txt", contents: "v2")
        try await waitUntil("second download") {
            pool.downloads.items.count == 2 && pool.downloads.items.allSatisfy { $0.state == .finished }
        }

        #expect(pool.downloads.items.map(\.filename) == ["notes 2.txt", "notes.txt"], "Newest first")
    }

    @Test func failedDownloadsReportAnError() async throws {
        let tab = Tab.testTab(url: try pages.page("Start"))
        _ = pool.webView(for: tab, profileID: profileID)
        // Port 9 (discard) on the loopback address refuses connections, so this fails quickly
        // without leaving the machine.
        let unreachable = URL(string: "http://127.0.0.1:9/file.bin")!

        var ended = 0
        pool.downloads.onEnd = { _ in ended += 1 }
        pool.startDownload(unreachable, in: tab.id)

        try await waitUntil("download to fail") {
            if case .failed = pool.downloads.items.first?.state { return true }
            return false
        }
        #expect(pool.downloads.activeCount == 0)
        #expect(ended == 1)
    }

    // MARK: Managing the list

    @Test func clearingRemovesFinishedDownloadsButKeepsFiles() async throws {
        _ = try await clickDownloadLink(named: "keep.txt", contents: "keep me")
        try await waitUntil("download to finish") { pool.downloads.items.first?.state == .finished }
        let destination = try #require(pool.downloads.items.first?.destination)

        pool.downloads.clearInactive()

        #expect(pool.downloads.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancellingAFinishedDownloadDoesNothing() async throws {
        _ = try await clickDownloadLink(named: "done.txt", contents: "done")
        try await waitUntil("download to finish") { pool.downloads.items.first?.state == .finished }
        let item = try #require(pool.downloads.items.first)

        pool.downloads.cancel(item)

        #expect(item.state == .finished)
        #expect(FileManager.default.fileExists(atPath: try #require(item.destination).path))
    }

    // MARK: Destinations

    @Test func uniqueDestinationsFollowFinderNaming() throws {
        let directory = pages.directory.appending(path: "names", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["photo.jpg", "photo 2.jpg", "README"] {
            FileManager.default.createFile(atPath: directory.appending(path: name).path, contents: Data())
        }

        #expect(DownloadManager.uniqueDestination(for: "photo.jpg", in: directory).lastPathComponent == "photo 3.jpg")
        #expect(DownloadManager.uniqueDestination(for: "README", in: directory).lastPathComponent == "README 2")
        #expect(DownloadManager.uniqueDestination(for: "new.pdf", in: directory).lastPathComponent == "new.pdf")
    }

    @Test(arguments: [
        ("../../etc/passwd", "-..-etc-passwd"),
        (".hidden", "hidden"),
        ("a:b.txt", "a-b.txt"),
        ("   ", "Download"),
    ])
    func suggestedNamesAreSanitized(suggested: String, expected: String) {
        let url = DownloadManager.uniqueDestination(for: suggested, in: pages.directory)
        #expect(url.lastPathComponent == expected)
        #expect(url.deletingLastPathComponent().standardizedFileURL == pages.directory.standardizedFileURL)
    }
}
