import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// The address bar's connection indicator and details (#96).
@MainActor
struct ConnectionSecurityTests {
    let engine = FakeEngine()
    let model: BrowserModel

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        await model.start()
    }

    private func openPage(_ url: URL) async throws -> FakePage {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        page.navigate(to: url, title: "Page")
        return page
    }

    @Test func theIndicatorFollowsThePagesSecurity() async throws {
        let page = try await openPage(URL(string: "https://bank.example/")!)
        #expect(model.connectionIndicator == nil, "Nothing reported yet")

        page.simulateSecurity(PageSecurity(level: .secure, certificates: [PageSecurity.testCertificate]))
        #expect(model.connectionIndicator == .secure)
        page.simulateSecurity(PageSecurity(level: .notSecure))
        #expect(model.connectionIndicator == .notSecure)
        page.simulateSecurity(PageSecurity(level: .broken, certificates: [PageSecurity.testCertificate], hasCertificateError: true))
        #expect(model.connectionIndicator == .notPrivate)
        page.simulateSecurity(PageSecurity(level: .broken, certificates: [PageSecurity.testCertificate]))
        #expect(model.connectionIndicator == .notSecure, "Broken only for running http content: not secure, not \"Not Private\"")
        #expect(ConnectionIndicator.notPrivate.addressPrefix == "Not private, ")
        page.simulateSecurity(PageSecurity())
        #expect(model.connectionIndicator == nil)
    }

    @Test func aTabThatHasntLoadedGoesByItsAddress() {
        #expect(BrowserModel.unloadedSecurity(of: URL(string: "http://plain.example/")).level == .notSecure)
        #expect(BrowserModel.unloadedSecurity(of: URL(string: "http://localhost:3000/")).level == .none, "This Mac")
        #expect(BrowserModel.unloadedSecurity(of: URL(string: "https://bank.example/")).level == .none,
                "Not known to be secure until its page says so")
        #expect(BrowserModel.unloadedSecurity(of: nil).level == .none)
    }

    @Test func showCertificateShowsTheShownPagesChain() async throws {
        let page = try await openPage(URL(string: "https://bank.example/")!)
        var shown: [[SecCertificate]] = []
        model.showCertificates = { shown.append($0) }
        model.showShownPageCertificates()
        #expect(shown.isEmpty, "No certificates, nothing to show")

        page.simulateSecurity(PageSecurity(level: .broken, certificates: [PageSecurity.testCertificate]))
        model.isShowingConnectionInfo = true
        model.showShownPageCertificates()
        #expect(shown == [[PageSecurity.testCertificate]])
        #expect(!model.isShowingConnectionInfo, "The details close for the certificate's view")
    }

    #if os(macOS)
    @Test func theFloatingSidebarStaysWhileTheDetailsShow() {
        #expect(!FloatingSidebar.isHolding(model))
        model.isShowingConnectionInfo = true
        #expect(FloatingSidebar.isHolding(model))
    }
    #endif

    @Test func switchingTabsClosesTheDetails() async throws {
        _ = try await openPage(URL(string: "https://one.example/")!)
        let first = try #require(model.selectedTabID)
        _ = try await openPage(URL(string: "https://two.example/")!)
        model.isShowingConnectionInfo = true
        model.select(first)
        #expect(!model.isShowingConnectionInfo)
    }

    @Test func theDetailsSayWhatItMeansPlainly() {
        #expect(ConnectionInfoView.message(for: .notSecure, host: "corner-bakery.example", isHTTPS: false)
                .hasPrefix("corner-bakery.example uses plain http."))
        #expect(ConnectionInfoView.message(for: .notSecure, host: "shop.example", isHTTPS: true).contains("content loaded over plain http"))
        #expect(!ConnectionInfoView.message(for: .notSecure, host: "shop.example", isHTTPS: true).contains("uses plain http"))
        #expect(ConnectionInfoView.title(for: .notPrivate) == "Your connection to this site isn’t private")
        #expect(ConnectionInfoView.issued([PageSecurity.testCertificate]) == "Issued to Axo Test Site")
        #expect(ConnectionInfoView.issued([PageSecurity.testCertificate, PageSecurity.testCertificate])
                == "Issued to Axo Test Site by Axo Test Site")
        #expect(ConnectionInfoView.issued([]) == nil)
    }
}
