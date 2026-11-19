import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Settings' Website Permissions pane (#133), on the fake engine: defaults answer without
/// asking, denying stops a site's pages using the device, and the engine's copy follows.
@MainActor
struct WebsitePermissionsTests {
    let engine = FakeEngine()
    let store: TabStore
    let model: BrowserModel
    let meet = PageOrigin(scheme: "https", host: "meet.example.com")
    var said: [String] { messages.items }
    let messages = Messages()

    @MainActor final class Messages {
        var items: [String] = []
    }

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        store = try TabStore.makeInMemory()
        model = BrowserModel(store: store, pool: pool)
        model.announce = { [messages] in messages.items.append($0) }
        await model.start()
    }

    private var profileID: Profile.ID { model.space!.profileID }

    private func openPage(_ url: URL) async throws -> FakePage {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        page.navigate(to: url, title: "Meeting")
        return page
    }

    @Test func aDefaultAnswersSitesWithoutAskingAndASitesOwnAnswerWins() async throws {
        var asked = 0
        model.pool.onPermissionRequest = { _ in
            asked += 1
            return .allow
        }
        await model.setWebsitePermissionDefault(.deny, for: .camera, profileID: profileID)
        #expect(await model.pool.decidePermission(.camera, origin: meet, tabID: UUID(), profileID: profileID) == .deny)
        #expect(asked == 0, "Answered by the default, without asking")
        #expect(try await store.sitePermissions.decision(.camera, origin: meet.serialized, profileID: profileID) == nil,
                "A default answer isn't saved as the site's own")

        await model.setWebsitePermission(.allow, for: .camera, origin: meet, profileID: profileID)
        #expect(await model.pool.decidePermission(.camera, origin: meet, tabID: UUID(), profileID: profileID) == .allow)

        // Camera and microphone together: the default fills in what the site hasn't answered.
        #expect(await model.pool.decidePermission(.cameraAndMicrophone, origin: meet, tabID: UUID(), profileID: profileID) == .allow)
        #expect(asked == 1, "The microphone had no answer and no default, so it asked")
        await model.setWebsitePermissionDefault(nil, for: .camera, profileID: profileID)
        #expect(said.last == "Other websites ask for camera")
    }

    @Test func denyingStopsTheSitesPagesUsingTheDevice() async throws {
        let page = try await openPage(URL(string: "https://meet.example.com/room")!)
        page.simulateMedia(capture: [.camera, .microphone])
        let other = try await openPage(URL(string: "https://other.example.com/")!)
        other.simulateMedia(capture: [.camera])

        await model.setWebsitePermission(.deny, for: .camera, origin: meet, profileID: profileID)
        #expect(page.stopCaptureRequests == [.camera])
        #expect(page.media.capture == [.microphone], "Only the denied device")
        #expect(other.stopCaptureRequests.isEmpty, "Another site's page keeps its camera")
        #expect(said.last == "Camera not allowed for meet.example.com")

        await model.setWebsitePermission(.allow, for: .microphone, origin: meet, profileID: profileID)
        #expect(page.stopCaptureRequests == [.camera], "Allowing stops nothing")
    }

    @Test func notificationsAndTheClipboardFollowInTheEngine() async throws {
        let before = engine.defaultPermissions.count
        await model.setWebsitePermissionDefault(.deny, for: .notifications, profileID: profileID)
        #expect(engine.defaultPermissions.last?.kind == .notifications)
        #expect(engine.defaultPermissions.last?.decision == .deny)
        await model.setWebsitePermissionDefault(.allow, for: .camera, profileID: profileID)
        #expect(engine.defaultPermissions.count == before + 1, "The camera's default is Axo's, not the engine's")

        await model.setWebsitePermission(.allow, for: .clipboard, origin: meet, profileID: profileID)
        await model.setWebsitePermission(.deny, for: .notifications, origin: meet, profileID: profileID)
        #expect(engine.lastingPermissions.suffix(2).map(\.kind) == [.clipboard, .notifications])
        await model.removeAllWebsitePermissions(for: .notifications, profileID: profileID)
        #expect(engine.lastingPermissions.last?.kind == .notifications && engine.lastingPermissions.last?.decision == nil,
                "Removing all clears the engine's copy too")
        #expect(try await store.sitePermissions.permissions(.notifications, profileID: profileID).isEmpty)
        #expect(try await store.sitePermissions.decision(.clipboard, origin: meet.serialized, profileID: profileID) == .allow)
    }

    @Test func sitesAreAddedOnlyAsWebsites() async throws {
        #expect(BrowserModel.websiteOrigin(from: " meet.example.com ")?.serialized == "https://meet.example.com")
        #expect(BrowserModel.websiteOrigin(from: "http://localhost:3000/room")?.serialized == "http://localhost:3000")
        #expect(BrowserModel.websiteOrigin(from: "HTTPS://Meet.Example.com:443")?.serialized == "https://meet.example.com")
        for invalid in ["", "meet", "meet.", ".com", "a..b.com", "ftp://example.com", "file:///Users", "javascript:alert(1)",
                        "two words.com", "https://user:pw@example.com"] {
            #expect(BrowserModel.websiteOrigin(from: invalid) == nil, "\(invalid)")
        }
        #expect(BrowserModel.websiteOrigin(from: "192.168.1.20:8080")?.serialized == "https://192.168.1.20:8080")
        // Notifications and the clipboard reach only secure sites.
        #expect(BrowserModel.websiteOrigin(from: "http://news.example.com", for: .notifications) == nil)
        #expect(BrowserModel.websiteOrigin(from: "http://localhost:3000", for: .notifications) != nil)
        #expect(BrowserModel.websiteOrigin(from: "http://news.example.com", for: .camera) != nil)
        #expect(await model.addWebsitePermission("zoom.example.com", decision: .deny, for: .microphone, profileID: profileID))
        #expect(!(await model.addWebsitePermission("not a site", decision: .deny, for: .microphone, profileID: profileID)))
        #expect(try await store.sitePermissions.permissions(.microphone, profileID: profileID).map(\.origin) == ["https://zoom.example.com"])
    }

    @Test func thePaneOffersTheKindsTheEngineAsksAbout() {
        #expect(model.websitePermissionKinds == SitePermission.Kind.allCases)
        engine.askedPermissionKinds = [.camera, .microphone, .cameraAndMicrophone, .location]
        #expect(model.websitePermissionKinds == [.camera, .microphone, .location], "WebKit doesn't ask about the rest")
    }

    #if os(macOS)
    @Test func thePanesSearchMatchesSitesOfTheKind() {
        let answers = [
            SitePermission(profileID: UUID(), origin: "https://meet.example.com", kind: .camera, decision: .allow),
            SitePermission(profileID: UUID(), origin: "https://news.example.com", kind: .camera, decision: .deny),
            SitePermission(profileID: UUID(), origin: "https://meet.example.com", kind: .location, decision: .deny),
        ]
        #expect(WebsitePermissionsSheet.shownAnswers(answers, kind: .camera, query: "").map(\.origin).count == 2)
        #expect(WebsitePermissionsSheet.shownAnswers(answers, kind: .camera, query: "MEET").map(\.origin) == ["https://meet.example.com"])
        #expect(WebsitePermissionsSheet.shownAnswers(answers, kind: .location, query: "news").isEmpty)
    }

    #endif
    #if os(macOS)
    @Test func eachRowSaysHowManySitesAnsweredAndWhatOthersGet() {
        let profile = UUID()
        let snapshot = SitePermissionSnapshot(answers: [
            SitePermission(profileID: profile, origin: "https://a.example", kind: .camera, decision: .allow),
            SitePermission(profileID: profile, origin: "https://b.example", kind: .camera, decision: .deny),
            SitePermission(profileID: profile, origin: "https://a.example", kind: .location, decision: .deny),
        ], defaults: [.camera: .deny])
        #expect(WebsitePermissionsSection.summary(snapshot, kind: .camera) == "2 websites, others not allowed")
        #expect(WebsitePermissionsSection.summary(snapshot, kind: .location) == "1 website, others ask")
        #expect(WebsitePermissionsSection.summary(snapshot, kind: .microphone) == "No websites, others ask")
    }

    #endif
    @Test func siteSettingsOpensThePaneOnItsSite() async throws {
        _ = try await openPage(URL(string: "https://meet.example.com/room")!)
        model.isShowingSiteSettings = true
        model.manageWebsitePermissions()
        let first = try #require(model.websitePermissionsRequest)
        #expect(first.origin == meet && first.profileID == profileID)
        #expect(!model.isShowingSiteSettings)
        // Asking again for the same site is a new request, so Settings shows it again.
        model.manageWebsitePermissions()
        #expect(model.websitePermissionsRequest?.id != first.id)
    }

    /// Settings opens on a kind the site has an answer for, not just the first.
    @Test func theRequestedSiteOpensOnAKindItAnswered() {
        let snapshot = SitePermissionSnapshot(answers: [
            SitePermission(profileID: UUID(), origin: meet.serialized, kind: .location, decision: .deny),
        ], defaults: [:])
        let kinds: [SitePermission.Kind] = [.camera, .microphone, .location]
        #expect(BrowserModel.kindToShow(for: meet, in: snapshot, kinds: kinds) == .location)
        #expect(BrowserModel.kindToShow(for: PageOrigin(scheme: "https", host: "other.example"), in: snapshot, kinds: kinds) == .camera)
    }

    /// A default that becomes deny, or an answer removed under a deny default, stops what the
    /// site is using; a site allowed on its own keeps it.
    @Test func whatTheDefaultDeniesStopsToo() async throws {
        let page = try await openPage(URL(string: "https://meet.example.com/room")!)
        page.simulateMedia(capture: [.camera])
        let allowed = try await openPage(URL(string: "https://allowed.example.com/")!)
        allowed.simulateMedia(capture: [.camera])
        await model.setWebsitePermission(.allow, for: .camera, origin: PageOrigin(scheme: "https", host: "allowed.example.com"), profileID: profileID)
        await model.setWebsitePermission(.allow, for: .camera, origin: meet, profileID: profileID)

        await model.setWebsitePermissionDefault(.deny, for: .camera, profileID: profileID)
        #expect(page.stopCaptureRequests.isEmpty, "Its own Allow wins over the default")
        await model.setWebsitePermission(nil, for: .camera, origin: meet, profileID: profileID)
        #expect(page.stopCaptureRequests == [.camera], "Removed: the default denies it now")
        #expect(allowed.stopCaptureRequests.isEmpty)
        await model.removeAllWebsitePermissions(for: .camera, profileID: profileID)
        #expect(allowed.stopCaptureRequests == [.camera], "Remove All under a deny default stops the rest")
    }

    /// Every site, iframes and ads included, would get the device without asking.
    @Test func theCameraMicrophoneAndLocationNeverDefaultToAllow() async throws {
        #expect(!BrowserModel.allowsAllowDefault(.camera) && !BrowserModel.allowsAllowDefault(.location))
        #expect(BrowserModel.allowsAllowDefault(.notifications))
        await model.setWebsitePermissionDefault(.allow, for: .camera, profileID: profileID)
        #expect(try await store.sitePermissions.defaults(profileID: profileID).isEmpty)
    }

    @Test func siteSettingsSaysWhatTheDefaultGives() {
        #expect(SiteSettingsView.defaultTitle(nil) == "Ask")
        #expect(SiteSettingsView.defaultTitle(.deny) == "Don't Allow (Default)")
    }

    /// At launch, Chrome gets each profile's notification and clipboard defaults, a cleared one
    /// as Ask.
    @Test func launchGivesTheEngineEachProfilesDefaults() async throws {
        try await store.sitePermissions.setDefault(.deny, for: .notifications, profileID: profileID)
        let before = engine.defaultPermissions.count
        await model.syncLastingPermissions()
        let sent = engine.defaultPermissions.dropFirst(before).filter { $0.profileID == profileID }
        #expect(sent.first { $0.kind == .notifications }?.decision == .deny)
        #expect(sent.contains { $0.kind == .clipboard && $0.decision == nil }, "No default is sent as Ask")
    }
}
