import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// Connection security (#96): what each kind of page reports, and engines' reports reaching the
/// tab's state.
@MainActor
struct PageSecurityTests {
    /// A committed page's security; `url` is both the address shown and the one that committed.
    private func webKit(_ url: String, secureContent: Bool = true) -> PageSecurity {
        let url = URL(string: url)!
        return PageSecurity.webKit(url: url, committedURL: url, hasOnlySecureContent: secureContent, serverTrust: nil)
    }

    @Test func webKitPagesSecurityFollowsTheirAddressAndContent() {
        #expect(webKit("https://example.com/").level == .secure)
        #expect(webKit("https://example.com/", secureContent: false).level == .notSecure, "Content loaded over http")
        #expect(webKit("http://example.com/").level == .notSecure)
        for local in ["http://localhost:8080/", "http://localhost./", "http://127.0.0.1/", "http://127.1.2.3/",
                      "http://[::1]/", "http://app.localhost/"] {
            #expect(webKit(local).level == .none, "This Mac needs no encryption: \(local)")
        }
        for lookalike in ["http://127.attacker.example/", "http://127.0.0.1.attacker.example/", "http://localhost.attacker.example/",
                          "http://127.0.0.999/"] {
            #expect(webKit(lookalike).level == .notSecure, "Only a name that starts like this Mac: \(lookalike)")
        }
        for other in ["data:text/html,hi", "about:blank", "file:///tmp/a.html"] {
            #expect(webKit(other) == PageSecurity())
        }
        #expect(PageSecurity.webKit(url: nil, committedURL: nil, hasOnlySecureContent: false, serverTrust: nil) == PageSecurity())
    }

    @Test func whileAnotherPageLoadsWebKitShowsNothingOfTheOldOnes() {
        // webView.url is already the new page, while the content and trust are still the old one's.
        let loading = PageSecurity.webKit(url: URL(string: "https://other.example/")!,
                                          committedURL: URL(string: "https://bank.example/")!,
                                          hasOnlySecureContent: true, serverTrust: nil)
        #expect(loading == PageSecurity())
    }

    @Test func aWebKitTrustsCertificatesBecomeTheChain() throws {
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(PageSecurity.testCertificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let url = URL(string: "https://example.com/")!
        let security = PageSecurity.webKit(url: url, committedURL: url, hasOnlySecureContent: true, serverTrust: trust)
        #expect(security.certificates == [PageSecurity.testCertificate])
    }

    @Test func enginesReportsReachTheTabsState() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
        pool.page(for: tab, profileID: UUID())
        let page = try #require(engine.pages.last)
        let state = try #require(pool.state(for: tab.id))
        #expect(state.security == PageSecurity())

        let broken = PageSecurity(level: .broken, certificates: [PageSecurity.testCertificate])
        page.simulateSecurity(broken)
        #expect(state.security == broken)
        page.simulateSecurity(PageSecurity(level: .notSecure))
        #expect(state.security.level == .notSecure)
        #expect(state.security.certificates.isEmpty)
    }

    @Test func navigatingDropsTheOldPagesSecurity() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://bank.example/")!)
        pool.page(for: tab, profileID: UUID())
        let page = try #require(engine.pages.last)
        page.navigate(to: tab.url, title: "Bank")
        page.simulateSecurity(PageSecurity(level: .secure, certificates: [PageSecurity.testCertificate]))
        // A new address with no report from the engine yet: the bank's lock mustn't stay.
        page.navigate(to: URL(string: "http://evil.example/")!, title: "")
        #expect(pool.state(for: tab.id)?.security == PageSecurity())
    }

    @Test func aRealWebKitFilePageHasNothingToShow() async throws {
        let pages = try TestPages()
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("Local"))
        pool.page(for: tab, profileID: UUID())
        let state = try #require(pool.state(for: tab.id))
        try await waitUntil("the page") { state.title == "Local" && !state.isLoading }
        #expect(state.security == PageSecurity(), "A file page")
    }
}
