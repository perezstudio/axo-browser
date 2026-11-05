import AxoCore
import AxoWebTestSupport
import Foundation
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Pages' links to other apps (`mailto:`, `zoommtg:`): Axo asks before opening them, remembers
/// "Always Allow" per site, and says when no app opens them.
@MainActor
struct ExternalAppTests {
    /// Names apps for some schemes and records what it opens, so no app ever opens.
    final class FakeApps: ExternalAppOpening {
        var apps = ["zoommtg": "zoom.us", "mailto": "Mail"]
        var opened: [URL] = []
        func appName(for url: URL) -> String? { url.scheme.flatMap { apps[$0.lowercased()] } }
        func open(_ url: URL) { opened.append(url) }
    }

    let engine = FakeEngine()
    let model: BrowserModel
    let apps = FakeApps()
    let site = PageOrigin(scheme: "https", host: "example.zoom.us")
    let join = URL(string: "zoommtg://zoom.us/join?confno=42")!

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { _ in }
        model.externalApps = apps
        await model.start()
    }

    /// A shown tab's page.
    private func shownPage(_ url: URL = URL(string: "https://example.zoom.us/j/42")!) async throws -> (AxoCore.Tab.ID, FakePage) {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        model.pool.beginShowing(id)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        page.navigate(to: url, title: "Meeting")
        return (id, page)
    }

    /// Waits for the link's prompt and returns it.
    private func prompt() async throws -> ExternalAppRequest {
        try await waitUntil { model.currentPrompt != nil }
        guard case .externalApp(let request) = model.currentPrompt?.content else {
            Issue.record("Expected a link to another app")
            throw CancellationError()
        }
        return request
    }

    @Test func allowingOpensTheLinkOnce() async throws {
        let (tabID, page) = try await shownPage()
        page.openExternal(join, origin: site)
        let request = try await prompt()
        #expect(request == ExternalAppRequest(tabID: tabID, url: join, origin: site, appName: "zoom.us"))
        #expect(apps.opened.isEmpty, "Not before the person answers")

        model.answerExternalApp(.allow)
        try await waitUntil { apps.opened == [join] }

        page.openExternal(join, origin: site)
        _ = try await prompt()
        model.answerExternalApp(.cancel)
        #expect(model.currentPrompt == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(apps.opened == [join], "Allow is for this time only, and Cancel opens nothing")
    }

    @Test func alwaysAllowOpensWithoutAskingFromThenOnAndSiteSettingsCanForgetIt() async throws {
        let (_, page) = try await shownPage()
        page.openExternal(join, origin: site)
        _ = try await prompt()
        model.answerExternalApp(.alwaysAllow)
        try await waitUntil { apps.opened.count == 1 }

        page.openExternal(join, origin: site)
        try await waitUntil { apps.opened.count == 2 }
        #expect(model.currentPrompt == nil, "No question the second time")

        page.openExternal(URL(string: "mailto:a@example.com")!, origin: site)
        #expect(try await prompt().appName == "Mail", "Only links of that kind")
        model.answerExternalApp(.cancel)

        await model.refreshSiteSettings()
        #expect(model.siteExternalApps == ["zoommtg"])
        #expect(model.siteExternalAppTitles == ["zoommtg": "zoom.us (zoommtg:)"])
        await model.forgetSiteExternalApp("zoommtg")
        #expect(model.siteExternalApps.isEmpty)
        page.openExternal(join, origin: site)
        _ = try await prompt()
        model.answerExternalApp(.cancel)
    }

    @Test func resettingSiteSettingsForgetsTheAppsToo() async throws {
        let (_, page) = try await shownPage()
        page.openExternal(join, origin: site)
        _ = try await prompt()
        model.answerExternalApp(.alwaysAllow)
        try await waitUntil { apps.opened.count == 1 }

        await model.resetSiteSettings()
        #expect(model.siteExternalApps.isEmpty)
    }

    @Test func aLinkNoAppOpensSaysSo() async throws {
        let (_, page) = try await shownPage()
        page.openExternal(URL(string: "axotest-unknown:x")!, origin: site)
        let request = try await prompt()
        #expect(request.appName == nil)
        let copy = PagePromptModifier.externalAppCopy(for: request)
        #expect(copy.title == "Axo can't open this link")
        #expect(copy.message == "No app on this Mac opens “axotest-unknown:” links.")
        model.answerExternalApp(.cancel)
        #expect(apps.opened.isEmpty)
    }

    @Test func aPlainHTTPSiteCantBeAllowedForGood() async throws {
        let plain = PageOrigin(scheme: "http", host: "example.zoom.us")
        let (_, page) = try await shownPage(URL(string: "http://example.zoom.us/j/42")!)
        page.openExternal(join, origin: plain)
        let request = try await prompt()
        #expect(!request.canAlwaysAllow, "Anyone on the network could change its pages")
        #expect(PagePromptModifier.externalAppCopy(for: request).message == "The link opens in zoom.us.")
        model.answerExternalApp(.alwaysAllow)
        try await waitUntil { apps.opened.count == 1 }

        page.openExternal(join, origin: plain)
        _ = try await prompt()
        model.answerExternalApp(.cancel)
        #expect(apps.opened.count == 1, "It asked again: nothing was saved")
        #expect(ExternalAppRequest(tabID: UUID(), url: join, origin: PageOrigin(scheme: "http", host: "localhost", port: 3000), appName: "zoom.us").canAlwaysAllow, "This Mac is secure")
    }

    @Test func aSiteAllowedInAnotherProfileStillAsks() async throws {
        let work = try #require(await model.addProfile(named: "Work"))
        try await model.store.externalAppPermissions.allow(scheme: "zoommtg", origin: site.serialized, profileID: work.id)
        let (_, page) = try await shownPage()
        page.openExternal(join, origin: site)
        _ = try await prompt()
        model.answerExternalApp(.cancel)
        #expect(apps.opened.isEmpty)
    }

    @Test func schemesNoPageMayOpenAreRefusedWithoutAsking() async throws {
        let (_, page) = try await shownPage()
        apps.apps["applescript"] = "Script Editor"
        apps.apps["c"] = "Finder"
        page.openExternal(URL(string: "applescript://com.apple.scripteditor?action=new&script=x")!, origin: site)
        page.openExternal(URL(string: "C:/Windows/notepad.exe")!, origin: site)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.currentPrompt == nil)
        #expect(apps.opened.isEmpty)
    }

    @Test func afterCancelAPageCantAskAgainWithoutAClickUntilItNavigates() async throws {
        let (_, page) = try await shownPage()
        page.openExternal(join, origin: site, userGesture: false)
        _ = try await prompt()
        model.answerExternalApp(.cancel)
        try await waitUntil { model.tabsOpeningExternalLinks.isEmpty }

        page.openExternal(join, origin: site, userGesture: false)
        page.navigate(to: URL(string: "https://example.zoom.us/j/42")!, title: "Changed")
        page.openExternal(join, origin: site, userGesture: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.currentPrompt == nil, "A page repeating itself can't lock the window, even by changing its title")

        page.openExternal(join, origin: site, userGesture: true)
        _ = try await prompt()
        model.answerExternalApp(.cancel)
        // One link at a time: the cancelled one finishes first.
        try await waitUntil { model.tabsOpeningExternalLinks.isEmpty }

        page.navigate(to: URL(string: "https://example.zoom.us/j/43")!, title: "Next")
        page.openExternal(join, origin: site, userGesture: false)
        _ = try await prompt()
        model.answerExternalApp(.cancel)
    }

    @Test func aLinkNoAppOpensSaysSoOnlyAfterAClick() async throws {
        let (_, page) = try await shownPage()
        page.openExternal(URL(string: "axotest-unknown:x")!, origin: site, userGesture: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.currentPrompt == nil, "Pages try apps' links on their own to see what's installed")
    }

    @Test func aTabThatIsntShownCantAsk() async throws {
        let (tabID, page) = try await shownPage()
        model.pool.endShowing(tabID)
        page.openExternal(join, origin: site)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.currentPrompt == nil)
        #expect(apps.opened.isEmpty)
    }

    @Test func aPageAsksOneLinkAtATime() async throws {
        let (_, page) = try await shownPage()
        page.openExternal(join, origin: site)
        _ = try await prompt()
        page.openExternal(join, origin: site)
        page.openExternal(join, origin: site)
        model.answerExternalApp(.cancel)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.currentPrompt == nil, "The repeats while it asked were dropped")
    }

    @Test func closingTheTabCancelsItsLink() async throws {
        let (tabID, page) = try await shownPage()
        page.openExternal(join, origin: site)
        _ = try await prompt()
        await model.closeTab(tabID)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.currentPrompt == nil)
        #expect(apps.opened.isEmpty)
    }

    @Test func theAlertNamesTheSiteAndTheApp() {
        let tabID = UUID()
        let named = PagePromptModifier.externalAppCopy(for: ExternalAppRequest(tabID: tabID, url: join, origin: site, appName: "zoom.us"))
        #expect(named.title == "Allow “example.zoom.us” to open “zoom.us”?")
        #expect(named.message == "The link opens in zoom.us. With Always Allow, the site opens “zoommtg:” links without asking.")
        let unnamed = PagePromptModifier.externalAppCopy(for: ExternalAppRequest(tabID: tabID, url: join, origin: nil, appName: "zoom.us"))
        #expect(unnamed.title == "Allow this page to open “zoom.us”?")
        #expect(unnamed.message == "The link opens in zoom.us.")
    }

    @Test func axosDefaultOpensNothing() {
        let none = NoExternalApps()
        #expect(none.appName(for: URL(string: "mailto:a@example.com")!) == nil)
    }
}
