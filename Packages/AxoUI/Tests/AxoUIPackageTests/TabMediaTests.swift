import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Tab rows' sound and devices (#71, #74): what rows show, the speaker's muting, and what
/// VoiceOver hears.
@MainActor
struct TabMediaTests {
    let engine = FakeEngine()
    let model: BrowserModel
    var announced: [String] { announcements.messages }
    private let announcements = Announcements()

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
        return (id, try #require(model.pool.livePage(for: id) as? FakePage))
    }

    @Test func rowsShowTheirPagesSoundAndDevices() async throws {
        let (id, page) = try await openPage(URL(string: "https://example.com/")!)
        #expect(!model.tabMedia(id).hasSound)

        page.simulateMedia(isPlayingAudio: true, capture: [.camera, .microphone])
        #expect(model.tabMedia(id).isPlayingAudio)
        #expect(model.tabMedia(id).capture == [.camera, .microphone])
        #expect(model.shownTabMedia == model.tabMedia(id))
    }

    @Test func theSpeakerMutesAndUnmutes() async throws {
        let (id, page) = try await openPage(URL(string: "https://example.com/")!)
        page.simulateMedia(isPlayingAudio: true)

        model.toggleMuted([id])
        #expect(page.muteRequests == [true])
        #expect(model.tabMedia(id).isMuted)
        #expect(model.tabMedia(id).hasSound, "A muted tab keeps its speaker, to unmute it")
        model.toggleMuted([id])
        #expect(page.muteRequests == [true, false])
        #expect(!model.tabMedia(id).isMuted)
        #expect(announced == ["Muted", "Unmuted"])
    }

    @Test func aSplitMutesOnlyItsPanesWithSound() async throws {
        let (quiet, quietPage) = try await openPage(URL(string: "https://example.com/")!)
        let (loud, loudPage) = try await openPage(URL(string: "https://example.org/")!)
        loudPage.simulateMedia(isPlayingAudio: true)
        #expect(model.tabMedia([quiet, loud]).isPlayingAudio)

        model.toggleMuted([quiet, loud])
        #expect(quietPage.muteRequests.isEmpty)
        #expect(loudPage.muteRequests == [true])
        #expect(model.tabMedia([quiet, loud]).isMuted)
    }

    @Test func combinedMediaIsMutedOnlyWhenNothingPlaysUnmuted() {
        let playing = PageMedia(isPlayingAudio: true)
        let muted = PageMedia(isPlayingAudio: true, isMuted: true)
        #expect(!PageMedia.combined([playing, muted]).isMuted)
        #expect(PageMedia.combined([muted, PageMedia()]).isMuted)
        #expect(PageMedia.combined([PageMedia(capture: [.camera]), PageMedia(capture: [.location])]).capture == [.camera, .location])
        #expect(!PageMedia.combined([]).hasSound)
    }

    @Test func voiceOverHearsWhatTheRowShows() {
        #expect(TabRow.stateDescription(isLoading: false, isDimmed: false,
                                        media: PageMedia(isPlayingAudio: true)) == "Playing audio")
        #expect(TabRow.stateDescription(isLoading: false, isDimmed: false,
                                        media: PageMedia(isPlayingAudio: true, isMuted: true)) == "Muted")
        #expect(TabRow.stateDescription(isLoading: true, isDimmed: false,
                                        media: PageMedia(capture: [.camera, .microphone]))
                == "Loading, Using the camera and the microphone")
        #expect(PageMedia(capture: [.screen, .location]).captureDescription == "Using your location, Sharing the screen")
        #expect(PageMedia(capture: [.microphone]).captureDescription == "Using the microphone")
        #expect(PageMedia().captureDescription == nil)
    }
}

@MainActor
private final class Announcements {
    var messages: [String] = []
}
