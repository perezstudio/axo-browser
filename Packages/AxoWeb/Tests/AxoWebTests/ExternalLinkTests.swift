import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// Pages' links to other apps, as any engine reports them, reach the pool for their tab.
@MainActor
struct ExternalLinkTests {
    @Test func aPagesLinkToAnotherAppReachesThePool() throws {
        let engine = FakeEngine()
        let pool = WebViewPool.withFakeEngine(engine)
        let tab = Tab.testTab(url: URL(string: "https://example.zoom.us/j/42")!)
        pool.page(for: tab, profileID: UUID())
        let page = try #require(engine.pages.last)
        var links: [ExternalLinkRequest] = []
        pool.onExternalLink = { links.append($0) }
        let site = PageOrigin(scheme: "https", host: "example.zoom.us")

        page.openExternal(URL(string: "zoommtg://zoom.us/join?confno=42")!, origin: site, userGesture: false)
        #expect(links == [ExternalLinkRequest(tabID: tab.id, url: URL(string: "zoommtg://zoom.us/join?confno=42")!, origin: site, userGesture: false)])
    }
}
