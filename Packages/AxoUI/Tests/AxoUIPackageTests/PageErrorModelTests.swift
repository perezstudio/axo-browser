import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Axo's own pages for failed loads and warnings (#178): which shows, and what their buttons do.
@MainActor
struct PageErrorModelTests {
    let engine = FakeEngine()
    let model: BrowserModel
    private let announcements = ErrorAnnouncements()

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { [announcements] in announcements.messages.append($0) }
        await model.start()
    }

    private func openPage(_ url: URL) async throws -> (AxoCore.Tab.ID, FakePage) {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        page.navigate(to: url, title: "Page")
        return (id, page)
    }

    @Test func tryAgainLoadsTheFailedAddressAndGoBackLeavesIt() async throws {
        let (id, page) = try await openPage(URL(string: "https://before.example/")!)
        let failed = URL(string: "https://shop.example/")!
        page.simulateLoadError(PageLoadError(kind: .serverNotFound, code: "ERR_NAME_NOT_RESOLVED", url: failed))
        #expect(model.tabLoadError(id)?.kind == .serverNotFound)
        #expect(model.canLeaveLoadError(id), "WebKit keeps the page before, under its own address")

        let loadsBefore = page.loads.count
        model.retryLoad(id)
        #expect(page.loads.count == loadsBefore + 1)
        #expect(page.loads.last == failed)
        model.leaveLoadError(id)
        #expect(page.errorActions == ["leaveLoadError"])
    }

    @Test func aFirstLoadThatFailsHasNothingToGoBackTo() async throws {
        await model.openTab(url: URL(string: "https://shop.example/")!)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        page.simulateLoadError(PageLoadError(kind: .offline, code: "ERR_INTERNET_DISCONNECTED", url: URL(string: "https://shop.example/")))
        #expect(!model.canLeaveLoadError(id))
    }

    @Test func goBackLeavesTheWarningOrOpensTheStartPage() async throws {
        let (id, page) = try await openPage(URL(string: "https://bank.example/")!)
        page.simulateWarning(PageWarning(kind: .certificate, url: URL(string: "https://bank.example/"), code: "ERR_CERT_AUTHORITY_INVALID", allowsVisiting: true))
        page.canGoBack = true
        page.navigate(to: URL(string: "https://bank.example/")!, title: "Privacy error")
        model.leaveWarning(id)
        #expect(page.errorActions == ["leaveWarning"])
        // The engine goes back and reports no warning: the cover goes.
        page.simulateWarning(nil)
        #expect(model.tabWarning(id) == nil)
        #expect(model.pool.state(for: id)?.isCovered == false)

        page.simulateWarning(PageWarning(kind: .certificate, url: URL(string: "https://bank.example/"), code: nil, allowsVisiting: true))

        // Nothing before it: Axo's start page, never the engine's new tab page.
        page.canGoBack = false
        page.navigate(to: URL(string: "https://bank.example/")!, title: "Privacy error")
        model.leaveWarning(id)
        #expect(page.errorActions == ["leaveWarning"])
        #expect(page.loads.last == URL(string: "about:blank"))
    }

    @Test func visitingAnywayOnlyWhereTheWarningAllowsIt() async throws {
        let (id, page) = try await openPage(URL(string: "https://bank.example/")!)
        page.simulateWarning(PageWarning(kind: .certificate, url: nil, code: nil, allowsVisiting: false))
        model.visitDespiteWarning(id)
        #expect(page.errorActions.isEmpty, "Not for a warning that can't be skipped")
        page.simulateWarning(PageWarning(kind: .deceptiveSite, url: nil, code: nil, allowsVisiting: true))
        model.visitDespiteWarning(id)
        #expect(page.errorActions == ["visitDespiteWarning"])
    }

    @Test func anErrorOrWarningOnScreenIsAnnouncedAndCoversThePage() async throws {
        let (id, page) = try await openPage(URL(string: "https://bank.example/")!)
        #expect(model.pool.state(for: id)?.isCovered == false)
        page.simulateWarning(PageWarning(kind: .deceptiveSite, url: nil, code: nil, allowsVisiting: true))
        #expect(announcements.messages == ["Deceptive Website"])
        #expect(model.pool.state(for: id)?.isCovered == true)
        // A click on its row doesn't hand keys to the engine's page under the cover.
        model.pageFocusTask = nil
        model.focusPage()
        #expect(model.pageFocusTask == nil, "No focus handed to a covered page")
        page.simulateWarning(nil)
        page.simulateLoadError(PageLoadError(kind: .offline, code: "", url: nil))
        #expect(announcements.messages.last == "You’re Not Connected to the Internet")

        // A background tab's says nothing.
        let (_, other) = try await openPage(URL(string: "https://other.example/")!)
        _ = other
        let count = announcements.messages.count
        page.simulateLoadError(PageLoadError(kind: .timedOut, code: "", url: nil))
        #expect(announcements.messages.count == count)
    }

    @Test func thePagesSayWhatHappenedPlainly() {
        #expect(PageWarning(kind: .certificate, url: nil, code: "ERR_CERT_DATE_INVALID", allowsVisiting: true)
                .message(host: "bank.example").contains("clock"))
        #expect(PageLoadError(kind: .offline, code: "", url: nil).title == "You’re Not Connected to the Internet")
        #expect(PageLoadError(kind: .serverNotFound, code: "", url: nil).message(host: "shop.exmaple.com")
                == "There’s no server at shop.exmaple.com. Check the address for typos. If it’s right, the site may be down.")
        let certificate = PageWarning(kind: .certificate, url: nil, code: "ERR_CERT_COMMON_NAME_INVALID", allowsVisiting: true)
        #expect(certificate.title == "This Connection Isn’t Private")
        #expect(certificate.details(host: "bank.example.com").hasSuffix("(ERR_CERT_COMMON_NAME_INVALID)"))
        #expect(certificate.visitTitle == "Visit This Website")
        #expect(PageWarning(kind: .deceptiveSite, url: nil, code: nil, allowsVisiting: true).visitTitle == "Visit This Unsafe Website")
    }
}

/// What the model announced.
@MainActor
private final class ErrorAnnouncements {
    var messages: [String] = []
}
