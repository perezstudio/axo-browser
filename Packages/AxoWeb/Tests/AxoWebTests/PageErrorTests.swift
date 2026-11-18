import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// Failed loads and warnings (#178): how engines' errors are read, and their reports reaching the
/// tab's state.
@MainActor
struct PageErrorTests {
    @Test func chromiumsErrorsAreReadByKind() {
        #expect(PageLoadError.kind(chromiumCode: -106) == .offline)
        #expect(PageLoadError.kind(chromiumCode: -105) == .serverNotFound)
        #expect(PageLoadError.kind(chromiumCode: -118) == .timedOut)
        #expect(PageLoadError.kind(chromiumCode: -102) == .cantConnect)
        #expect(PageLoadError.kind(chromiumCode: -310) == .other)
    }

    @Test func webKitsFailuresBecomeErrorsOrWarnings() {
        let url = URL(string: "https://example.invalid/")!
        func failure(_ code: Int) -> (loadError: PageLoadError?, warning: PageWarning?) {
            WebKitPage.failure(for: NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: url]))
        }
        #expect(failure(NSURLErrorNotConnectedToInternet).loadError?.kind == .offline)
        #expect(failure(NSURLErrorCannotFindHost).loadError == PageLoadError(kind: .serverNotFound, code: "NSURLErrorDomain -1003", url: url))
        #expect(failure(NSURLErrorTimedOut).loadError?.kind == .timedOut)
        #expect(failure(NSURLErrorCannotConnectToHost).loadError?.kind == .cantConnect)
        let certificate = failure(NSURLErrorServerCertificateUntrusted)
        #expect(certificate.loadError == nil)
        #expect(certificate.warning?.kind == .certificate)
        #expect(certificate.warning?.allowsVisiting == false, "WebKit refuses untrusted certificates outright")
        #expect(failure(NSURLErrorCancelled).loadError == nil, "A cancelled load is no error")
        #expect(failure(NSURLErrorCancelled).warning == nil)
        // WebKit's own errors (a load replaced by a download, say) aren't failures to show.
        let replaced = WebKitPage.failure(for: NSError(domain: "WebKitErrorDomain", code: 102))
        #expect(replaced.loadError == nil && replaced.warning == nil)
    }

    @Test func enginesReportsReachTheTabsState() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
        pool.page(for: tab, profileID: UUID())
        let page = try #require(engine.pages.last)
        let state = try #require(pool.state(for: tab.id))

        let error = PageLoadError(kind: .serverNotFound, code: "ERR_NAME_NOT_RESOLVED", url: tab.url)
        page.simulateLoadError(error)
        #expect(state.loadError == error)
        let warning = PageWarning(kind: .deceptiveSite, url: tab.url, code: nil, allowsVisiting: true)
        page.simulateLoadError(nil)
        page.simulateWarning(warning)
        #expect(state.loadError == nil)
        #expect(state.warning == warning)
        page.simulateWarning(nil)
        #expect(state.warning == nil)
    }

    /// A real WebKit page failing to reach a port on this Mac that nothing listens on, which
    /// never leaves this Mac; then a page loading clears it.
    @Test func aWebKitPageThatCantConnectSaysSoUntilAPageLoads() async throws {
        let pages = try TestPages()
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("Before"))
        pool.page(for: tab, profileID: UUID())
        let state = try #require(pool.state(for: tab.id))
        try await waitUntil("the page") { state.title == "Before" && !state.isLoading }

        let closed = URL(string: "http://127.0.0.1:\(try ClosedPort.find())/")!
        pool.load(closed, in: tab.id)
        try await waitUntil("the failure") { state.loadError != nil }
        // It lasts once WebKit is done with the load (its address settling back included).
        try await waitUntil("the load to end") { !state.isLoading }
        try await Task.sleep(for: .milliseconds(200))
        #expect(state.loadError?.kind == .cantConnect)
        #expect(state.loadError?.url == closed)
        #expect(state.title == "Before", "WebKit keeps the page that was showing")

        pool.livePage(for: tab.id)?.leaveLoadError()
        #expect(state.loadError == nil, "Leaving shows it again")

        // Moving within the page before (an anchor: no new load, no commit) moves on from it.
        pool.load(closed, in: tab.id)
        try await waitUntil("the failure again") { state.loadError != nil }
        let before = try pages.page("Before")
        pool.load(URL(string: before.absoluteString + "#section")!, in: tab.id)
        try await waitUntil("the anchor") { state.loadError == nil }

        pool.load(closed, in: tab.id)
        try await waitUntil("the failure once more") { state.loadError != nil }
        pool.load(try pages.page("After"), in: tab.id)
        try await waitUntil("a page") { state.title == "After" && !state.isLoading }
        #expect(state.loadError == nil)
    }
}

/// A port on this Mac that nothing listens on: bound, then closed, so connecting is refused and
/// nothing leaves the Mac.
enum ClosedPort {
    static func find() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw TimeoutError(description: "No socket") }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw TimeoutError(description: "No port") }
        return UInt16(bigEndian: address.sin_port)
    }
}
