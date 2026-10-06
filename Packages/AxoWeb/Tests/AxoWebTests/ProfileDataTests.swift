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
    @Test func removingAStoreThatNeverExistedIsHarmless() async {
        let pool = WebViewPool.forTesting()
        try? await pool.removeDataStore(UUID())
    }
}
