import AxoCore
@testable import AxoWeb
import Foundation
import Testing
@testable import AxoUI

/// Records requests instead of asking macOS about location.
@MainActor
final class FakeLocationAuthorization: LocationAuthorizing {
    var requests = 0
    func requestIfNeeded() { requests += 1 }
}

@MainActor
struct SiteSettingsTests {
    let store: TabStore
    let model: BrowserModel
    let pool: WebViewPool
    let meet = PageOrigin(scheme: "https", host: "meet.example.com")

    init() async throws {
        store = try TabStore.makeInMemory()
        pool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        model = BrowserModel(store: store, pool: pool)
        await model.start()
    }

    private var profileID: Profile.ID { model.space!.profileID }

    /// Answers each page prompt with `decision` as soon as it appears.
    private func answerPrompts(with decision: PermissionDecision) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                if case .permission = model.currentPrompt?.content { model.answerPermission(decision) }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    @Test func answersAreSavedAndUsedAfterARestart() async throws {
        let answering = answerPrompts(with: .allow)
        defer { answering.cancel() }
        #expect(await pool.decidePermission(.cameraAndMicrophone, origin: meet, tabID: UUID(), profileID: profileID) == .allow)
        answering.cancel()

        let saved = try await store.sitePermissions.decisions(origin: meet.serialized, profileID: profileID)
        #expect(saved == [.camera: .allow, .microphone: .allow], "Camera and microphone together save an answer for each")

        // A new model and pool over the same database, as after relaunching.
        let relaunchedPool = WebViewPool(makeDataStore: { _ in .nonPersistent() })
        let relaunched = BrowserModel(store: store, pool: relaunchedPool)
        await relaunched.start()
        #expect(await relaunchedPool.decidePermission(.camera, origin: meet, tabID: UUID(), profileID: profileID) == .allow)
        #expect(relaunched.currentPrompt == nil, "No prompt for a saved answer")
    }

    @Test func cameraAndMicrophoneCountAsAnsweredOnlyWhenBothAre() async throws {
        let adapter = SitePermissionAdapter(store: store.sitePermissions)
        try await store.sitePermissions.setDecision(.allow, for: [.camera], origin: meet.serialized, profileID: profileID)
        #expect(await adapter.savedDecision(for: .cameraAndMicrophone, origin: meet, profileID: profileID) == nil)

        try await store.sitePermissions.setDecision(.allow, for: [.microphone], origin: meet.serialized, profileID: profileID)
        #expect(await adapter.savedDecision(for: .cameraAndMicrophone, origin: meet, profileID: profileID) == .allow)

        try await store.sitePermissions.setDecision(.deny, for: [.camera], origin: meet.serialized, profileID: profileID)
        #expect(await adapter.savedDecision(for: .cameraAndMicrophone, origin: meet, profileID: profileID) == .deny,
                "Either one denied denies both")
    }

    @Test func siteSettingsShowAndChangeTheSelectedSitesAnswers() async throws {
        #expect(model.siteSettingsOrigin == nil)
        await model.showSiteSettings()
        #expect(!model.isShowingSiteSettings, "Nothing to show without a web page")

        // A closed loopback port: the page never loads, but the tab has its URL.
        await model.openTab(url: URL(string: "http://127.0.0.1:9/room")!)
        #expect(model.siteSettingsOrigin?.serialized == "http://127.0.0.1:9")
        try await store.sitePermissions.setDecision(.deny, for: [.location], origin: "http://127.0.0.1:9", profileID: profileID)

        await model.showSiteSettings()
        #expect(model.isShowingSiteSettings)
        #expect(model.sitePermissions == [.location: .deny])

        await model.setSitePermission(.allow, for: .camera)
        await model.setSitePermission(nil, for: .location)
        #expect(model.sitePermissions == [.camera: .allow])
        #expect(try await store.sitePermissions.decisions(origin: "http://127.0.0.1:9", profileID: profileID) == [.camera: .allow])

        await model.resetSiteSettings()
        #expect(model.sitePermissions.isEmpty)
    }

    @Test func allowingLocationAsksMacOSOnce() async throws {
        let location = FakeLocationAuthorization()
        model.locationAuthorization = location
        let answering = answerPrompts(with: .allow)
        defer { answering.cancel() }

        _ = await pool.decidePermission(.camera, origin: meet, tabID: UUID(), profileID: profileID)
        #expect(location.requests == 0, "Only location involves macOS location services")
        _ = await pool.decidePermission(.location, origin: meet, tabID: UUID(), profileID: profileID)
        #expect(location.requests == 1)
        _ = await pool.decidePermission(.location, origin: meet, tabID: UUID(), profileID: profileID)
        #expect(location.requests == 1, "The saved answer doesn't prompt again")
    }

    @Test func denyingLocationLeavesMacOSAlone() async throws {
        let location = FakeLocationAuthorization()
        model.locationAuthorization = location
        let answering = answerPrompts(with: .deny)
        defer { answering.cancel() }
        _ = await pool.decidePermission(.location, origin: meet, tabID: UUID(), profileID: profileID)
        #expect(location.requests == 0)
    }
}
