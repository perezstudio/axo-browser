import AxoCore
import AxoWebTestSupport
import Foundation
import SwiftUI
import Testing
@testable import AxoUI
@testable import AxoWeb

/// Crashed and unresponsive pages (#75): what rows and the page's place show, recovering, and
/// what VoiceOver hears.
@MainActor
struct PageProblemTests {
    let engine = FakeEngine()
    let model: BrowserModel
    var announced: [String] { announcements.messages }
    private let announcements = ProblemAnnouncements()

    init() async throws {
        let pool = WebViewPool(engine: engine)
        pool.reportsScreenTimeUsage = false
        model = BrowserModel(store: try TabStore.makeInMemory(), pool: pool)
        model.announce = { [announcements] in announcements.messages.append($0) }
        await model.start()
    }

    /// Opens a tab whose page has loaded `url`.
    private func openPage(_ url: URL) async throws -> (AxoCore.Tab.ID, FakePage) {
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        page.navigate(to: url, title: url.host() ?? "")
        return (id, page)
    }

    @Test func aCrashShowsUntilReloadAndIsAnnouncedForTheShownTab() async throws {
        let (id, page) = try await openPage(URL(string: "https://example.com/")!)
        #expect(model.tabProblem(id) == nil)

        page.simulateProblem(.crashed(errorCode: 11))
        #expect(model.tabProblem(id) == .crashed(errorCode: 11))
        #expect(announced == ["This Page Stopped"])

        model.reloadStoppedPages([id])
        #expect(page.navigation.last == "reload")
        page.simulateProblem(nil)
        #expect(model.tabProblem(id) == nil)
    }

    @Test func aPageThatCrashedBeforeLoadingLoadsItsAddressAgain() async throws {
        let url = URL(string: "https://example.com/first")!
        await model.openTab(url: url)
        let id = try #require(model.selectedTabID)
        let page = try #require(model.pool.livePage(for: id) as? FakePage)
        #expect(page.url == nil, "Nothing committed")
        let loadsBefore = page.loads.count
        page.simulateProblem(.crashed(errorCode: nil))

        model.reloadStoppedPages([id])
        #expect(!page.navigation.contains("reload"), "There's nothing to reload")
        #expect(page.loads.count == loadsBefore + 1)
        #expect(page.loads.last == url)
    }

    @Test func aCrashInPeekIsAnnounced() async throws {
        let (id, _) = try await openPage(URL(string: "https://example.com/")!)
        model.openPeek(URL(string: "https://example.org/peek")!, from: id)
        let peek = try #require(model.peek)
        // Made when Peek's view appears.
        let profileID = try #require(model.space?.profileID)
        let peekPage = try #require(model.pool.page(for: peek.tab, profileID: profileID) as? FakePage)
        peekPage.simulateProblem(.crashed(errorCode: nil))
        #expect(announced.last == "This Page Stopped")
    }

    @Test func aBackgroundTabsCrashIsntAnnounced() async throws {
        let (background, backgroundPage) = try await openPage(URL(string: "https://example.com/")!)
        _ = try await openPage(URL(string: "https://example.org/")!)
        #expect(model.selectedTabID != background)

        backgroundPage.simulateProblem(.outOfMemory)
        #expect(model.tabProblem(background) == .outOfMemory)
        #expect(announced.isEmpty, "Its row says so in its value instead")
    }

    @Test func aSplitPanesCrashIsAnnouncedAndItsRowReloadsOnlyThatPane() async throws {
        let (working, workingPage) = try await openPage(URL(string: "https://example.com/")!)
        let (crashing, crashingPage) = try await openPage(URL(string: "https://example.org/")!)
        model.select(working)
        await model.addToSplit(crashing)
        try #require(model.split(of: working) != nil)
        model.select(working)

        crashingPage.simulateProblem(.crashed(errorCode: nil))
        #expect(announced.last == "This Page Stopped")
        #expect(model.tabProblem([working, crashing]) == .crashed(errorCode: nil))

        model.reloadStoppedPages([working, crashing])
        #expect(!workingPage.navigation.contains("reload"), "A working pane isn't reloaded")
        #expect(crashingPage.navigation.last == "reload")
    }

    @Test func waitGivesAHungPageMoreTime() async throws {
        let (id, page) = try await openPage(URL(string: "https://example.com/")!)
        page.simulateProblem(.unresponsive)
        #expect(announced == ["This Page Isn’t Responding"])

        #expect(model.shownPageIsUnresponsive, "View › Wait for Page is on")
        model.waitForShownPage()
        #expect(page.waitsForResponse == 1)
        page.simulateProblem(nil)
        #expect(!model.shownPageIsUnresponsive)
        model.waitForShownPage()
        #expect(page.waitsForResponse == 1, "Only a page that isn't responding waits")
    }

    @Test func rowsTellVoiceOverAboutTheirStoppedPage() {
        let tab = AxoCore.Tab(spaceID: UUID(), url: URL(string: "https://example.com/")!, sortKey: SortKey.initial)
        #expect(TabRow.stateDescription(isLoading: false, isDimmed: false, problem: .crashed(errorCode: 5))
                == "Page stopped working")
        #expect(TabRow.stateDescription(isLoading: false, isDimmed: false, problem: .unresponsive)
                == "Page isn’t responding")
        #expect(TabRow.stateDescription(isLoading: false, isDimmed: false,
                                        media: PageMedia(isPlayingAudio: true), problem: .outOfMemory)
                == "Page stopped working, Playing audio")
        #expect(TabRow(tab: tab, favicon: nil, problem: .unresponsive).problem == .unresponsive)
    }

    @Test func thePageSaysWhatHappenedPlainly() {
        #expect(PageProblem.crashed(errorCode: 11).details == "Error code: 11")
        #expect(PageProblem.crashed(errorCode: nil).details == nil, "WebKit gives no code, so no Show Details")
        #expect(PageProblem.outOfMemory.details == "Error code: Out of Memory")
        #expect(PageProblem.unresponsive.details == nil)
        #expect(PageProblem.outOfMemory.message.contains("memory"))
    }

    @Test func surprisedAxoIsDrawnFromTheBoardsOutlines() {
        for outline in [SurprisedAxo.gills, SurprisedAxo.head] {
            // The board crops its drawing to its frame, as the view does.
            #expect(!outline.isEmpty)
            #expect(AxoOutline.viewBox.intersects(outline.boundingRect), "Got \(outline.boundingRect)")
        }
        // Scaled to fit the frame it's given: the board's frame becomes the view's.
        let frame = CGRect(x: 0, y: 0, width: 690, height: 330)
        let drawn = AxoOutline(path: SurprisedAxo.gills).path(in: frame)
        #expect(drawn.boundingRect == SurprisedAxo.gills.boundingRect.offsetBy(dx: -40, dy: -40))
    }
}

/// What the model announced, kept in a class so the announce closure can record it.
@MainActor
private final class ProblemAnnouncements {
    var messages: [String] = []
}
