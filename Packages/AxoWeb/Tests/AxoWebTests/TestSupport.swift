import AxoCore
import Foundation
import WebKit
@testable import AxoWeb

/// Local HTML pages in a temporary folder, so tests never touch the network.
struct TestPages {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AxoWebTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes a page titled `title` and returns its file URL.
    func page(_ title: String, body: String = "") throws -> URL {
        let url = directory.appending(path: "\(title).html")
        try "<!doctype html><title>\(title)</title><body>\(body)</body>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// A clock tests can move forward.
@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 0)

    func advance(by interval: TimeInterval) {
        now += interval
    }
}

@MainActor
extension WebViewPool {
    /// A pool with non-persistent data stores, a controllable clock, and downloads saved to a
    /// temporary folder (never the user's Downloads folder).
    static func forTesting(
        clock: TestClock = TestClock(),
        timeout: TimeInterval = 60,
        downloadsDirectory: URL = FileManager.default.temporaryDirectory
            .appending(path: "AxoWebTests-Downloads-\(UUID().uuidString)", directoryHint: .isDirectory)
    ) -> WebViewPool {
        WebViewPool(
            configuration: .init(hibernationTimeout: timeout),
            makeDataStore: { _ in .nonPersistent() },
            downloads: DownloadManager(directory: downloadsDirectory),
            now: { clock.now }
        )
    }
}

extension Tab {
    /// A tab in a throwaway Space.
    static func testTab(url: URL) -> Tab {
        Tab(spaceID: UUID(), url: url, sortKey: SortKey.initial)
    }
}

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` on the main actor until it's true, or throws after `timeout`.
@MainActor
func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TimeoutError(description: "Timed out waiting for \(what)") }
        try await Task.sleep(for: .milliseconds(20))
    }
}
