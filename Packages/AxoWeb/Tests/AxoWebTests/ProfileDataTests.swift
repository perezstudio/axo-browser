import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct ProfileDataTests {
    let profileID = UUID()

    @Test func clearingRemovesAProfilesCookies() async throws {
        let pool = WebViewPool.forTesting()
        let cookies = pool.dataStore(for: profileID).httpCookieStore
        let cookie = try #require(HTTPCookie(properties: [.name: "session", .value: "1", .domain: "example.com", .path: "/"]))
        await cookies.setCookie(cookie)
        #expect(await cookies.allCookies().count == 1)

        await pool.clearWebsiteData(for: profileID)
        #expect(await cookies.allCookies().isEmpty)
    }

    /// Clearing one site (#110) removes its cookies and its subdomains' in that profile, and keeps
    /// other sites' and other profiles'.
    @Test func clearingASiteRemovesOnlyThatSitesCookies() async throws {
        let pool = WebViewPool.forTesting()
        let other = UUID()
        let cookies = pool.dataStore(for: profileID).httpCookieStore
        let theirCookies = pool.dataStore(for: other).httpCookieStore
        func cookie(_ domain: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.name: "session", .value: "1", .domain: domain, .path: "/"]))
        }
        await cookies.setCookie(try cookie("example.com"))
        await cookies.setCookie(try cookie("docs.example.com"))
        await cookies.setCookie(try cookie("example.org"))
        await theirCookies.setCookie(try cookie("example.com"))

        await pool.clearWebsiteData(forSite: try #require(URL(string: "https://www.example.com/page")), profileID: profileID)
        let left = await cookies.allCookies().map(\.domain)
        #expect(left == ["example.org"], "Only example.com and its subdomains go: \(left)")
        #expect(await theirCookies.allCookies().count == 1, "Another profile keeps its own")

        // Addresses that aren't web sites clear nothing.
        await pool.clearWebsiteData(forSite: try #require(URL(string: "file:///tmp/example.org")), profileID: profileID)
        #expect(await cookies.allCookies().count == 1)
    }

    @Test func aHostsSiteIsTheLongestRecordItIsUnder() {
        let names = ["github.com", "github.io", "me.github.io", "localhost", "com", "127.0.0.1"]
        #expect(WebsiteDataSite.recordName(forHost: "gist.github.com", among: names) == "github.com")
        #expect(WebsiteDataSite.recordName(forHost: "GitHub.com", among: names) == "github.com")
        #expect(WebsiteDataSite.recordName(forHost: "me.github.io", among: names) == "me.github.io",
                "A public suffix it's under is never chosen over its own site")
        // Without a public suffix list, a site with no data of its own matches the suffix's.
        #expect(WebsiteDataSite.recordName(forHost: "you.github.io", among: names) == "github.io")
        #expect(WebsiteDataSite.recordName(forHost: "localhost", among: names) == "localhost")
        #expect(WebsiteDataSite.recordName(forHost: "127.0.0.1", among: names) == "127.0.0.1")
        #expect(WebsiteDataSite.recordName(forHost: "example.com", among: names) == nil, "A top-level domain alone never matches")
        #expect(WebsiteDataSite.recordName(forHost: "notgithub.com", among: names) == nil, "Only whole labels count")
        #expect(WebsiteDataSite.recordName(forHost: "", among: names) == nil)
    }

    @Test func removingAProfilesDataDiscardsItsWebViewsAndStore() async throws {
        let pool = WebViewPool.forTesting()
        var removed: [Profile.ID] = []
        pool.removeDataStore = { removed.append($0) }
        let mine = Tab.testTab(url: URL(string: "about:blank")!), other = Tab.testTab(url: URL(string: "about:blank")!)
        let first = pool.webView(for: mine, profileID: profileID)
        _ = pool.webView(for: other, profileID: UUID())
        let store = pool.dataStore(for: profileID)

        await pool.removeWebsiteData(for: profileID)
        #expect(removed == [profileID])
        #expect(pool.liveWebView(for: mine.id) == nil, "Its web views are gone")
        #expect(pool.liveWebView(for: other.id) != nil, "Other profiles' stay")
        #expect(pool.dataStore(for: profileID) !== store, "A later use gets a fresh store")
        _ = first
    }

    /// The real removal, for a profile that never had data. WebKit crashes if it runs off the
    /// main thread.
    @Test func removingAStoreThatNeverExistedIsHarmless() async throws {
        let pool = WebViewPool.forTesting()
        try? await pool.removeDataStore(UUID())
        // WebKit answers before its own work for the removal is done; if this test runs last,
        // the process could exit meanwhile, and WebKit crashed reaching the gone main run loop.
        try await Task.sleep(for: .seconds(1))
    }
}
