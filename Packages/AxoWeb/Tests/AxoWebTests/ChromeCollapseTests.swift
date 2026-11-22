import AxoCore
import AxoWebTestSupport
import CoreGraphics
import Foundation
import Testing
@testable import AxoWeb

/// The iPhone's bar shrinking while a page is read and coming back (#182).
@MainActor
struct ChromeCollapseTests {
    @Test func scrollingDownShrinksAndUpOrTheTopGrows() {
        var collapse = ChromeCollapse()
        func step(_ offset: CGFloat) -> (changed: Bool, compact: Bool) {
            let changed = collapse.scrolled(to: offset)
            return (changed, collapse.isCompact)
        }
        #expect(step(30) == (false, false), "Near the top it stays")
        #expect(step(60) == (false, false), "Not far enough down yet")
        #expect(step(200) == (true, true), "Down past the threshold")
        #expect(step(600) == (false, true), "Further down: no change")
        #expect(step(580) == (false, true), "A little back up: still small")
        #expect(step(540) == (true, false), "Back up past the threshold")
        #expect(step(800) == (true, true))
        #expect(step(10) == (true, false), "The top always shows it")
    }

    @Test func expandingCountsFromWhereThePageIs() {
        var collapse = ChromeCollapse()
        collapse.scrolled(to: 500)
        #expect(collapse.isCompact)
        collapse.expand(at: 500)
        #expect(!collapse.isCompact)
        let soon = collapse.scrolled(to: 520)
        #expect(!soon, "Not straight back to small")
        let later = collapse.scrolled(to: 560)
        #expect(later)
    }

    @Test func thePoolFlagsATabsPageAndATapExpandsIt() throws {
        let engine = FakeEngine()
        let pool = WebViewPool(engine: engine)
        let tab = Tab(spaceID: UUID(), url: URL(string: "https://example.com/")!, sortKey: SortKey.initial)
        let page = try #require(pool.page(for: tab, profileID: UUID()) as? FakePage)
        let state = try #require(pool.state(for: tab.id))

        page.scroll(to: 400)
        #expect(state.prefersCompactChrome)
        pool.expandChrome(for: tab.id)
        #expect(!state.prefersCompactChrome)
        page.scroll(to: 20)
        #expect(!state.prefersCompactChrome)
    }
}
