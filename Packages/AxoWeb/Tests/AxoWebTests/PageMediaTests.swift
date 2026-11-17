import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoWeb

/// Sound and devices in use (#71, #74): the engine's reports reach the tab's state, and muting
/// lasts while the tab is open, through hibernation, but not once it's closed.
@MainActor
struct PageMediaTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let profileID = UUID()
    let tab = Tab.testTab(url: URL(string: "https://example.com/start")!)

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    @Test func soundAndDevicesReachTheTabsState() throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        let state = try #require(pool.state(for: tab.id))
        #expect(state.media == PageMedia())

        page.simulateMedia(isPlayingAudio: true)
        #expect(state.media.isPlayingAudio)
        page.simulateMedia(capture: [.camera, .microphone])
        #expect(state.media.capture == [.camera, .microphone])
        page.simulateMedia(isPlayingAudio: false, capture: [])
        #expect(state.media == PageMedia())
    }

    @Test func mutingMutesThePageAndIsReported() throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.simulateMedia(isPlayingAudio: true)

        pool.setMuted(true, tabID: tab.id)
        #expect(page.muteRequests == [true])
        #expect(pool.state(for: tab.id)?.media.isMuted == true)
        #expect(pool.mutedTabs == [tab.id])

        pool.setMuted(false, tabID: tab.id)
        #expect(page.muteRequests == [true, false])
        #expect(pool.state(for: tab.id)?.media.isMuted == false)
        #expect(pool.mutedTabs.isEmpty)
    }

    @Test func aTabMutedBeforeItHasAPageStartsMuted() throws {
        pool.setMuted(true, tabID: tab.id)
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        #expect(page.muteRequests == [true])
        #expect(pool.state(for: tab.id)?.media.isMuted == true)
    }

    @Test func mutingLastsThroughHibernation() async throws {
        pool.page(for: tab, profileID: profileID)
        let first = try #require(engine.pages.last)
        first.finishLoad()
        pool.setMuted(true, tabID: tab.id)

        // A page the engine closes to hibernate (WebKit) comes back muted.
        #expect(await pool.hibernate(tab.id))
        pool.page(for: tab, profileID: profileID)
        let second = try #require(engine.pages.last)
        #expect(second !== first)
        #expect(second.muteRequests == [true])
    }

    @Test func aKeptPageIsUnmutedWhileHibernated() async throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.canDiscard = true
        page.finishLoad()
        pool.setMuted(true, tabID: tab.id)
        #expect(await pool.hibernate(tab.id))
        #expect(page.isDiscarded)

        pool.setMuted(false, tabID: tab.id)
        #expect(page.muteRequests == [true, false], "Chromium keeps the discarded page's muting")
    }

    @Test func closingATabForgetsItsMuting() throws {
        pool.setMuted(true, tabID: tab.id)
        pool.discard(tab.id)
        #expect(pool.mutedTabs.isEmpty)
        pool.page(for: tab, profileID: profileID)
        #expect(try #require(engine.pages.last).muteRequests.isEmpty)
    }
}
