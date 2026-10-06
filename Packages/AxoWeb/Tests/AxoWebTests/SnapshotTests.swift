#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct SnapshotTests {
    let pages: TestPages
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
    }

    private func loadedTab(_ title: String, in pool: WebViewPool) async throws -> Tab {
        let tab = Tab.testTab(url: try pages.page(title, body: "<h1 style='background:#9B2A5C;height:200px'>\(title)</h1>"))
        // Hidden tabs keep the size they had on screen; give this one a real size too.
        pool.webView(for: tab, profileID: profileID).frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        try await waitUntil("page \(title)") {
            pool.state(for: tab.id).map { !$0.isLoading && $0.title == title } ?? false
        }
        return tab
    }

    @Test func hibernatingKeepsASmallJPEGSnapshot() async throws {
        let pool = WebViewPool.forTesting()
        let tab = try await loadedTab("Snap", in: pool)

        #expect(await pool.hibernate(tab.id))

        let data = try #require(pool.snapshot(for: tab.id))
        #expect(data.starts(with: [0xFF, 0xD8]), "Snapshots are stored as JPEG")
        let image = try #require(PlatformImage(data: data))
        #expect(image.size.width <= PageSnapshot.width)
        #expect(image.size.width > 0)
    }

    @Test func wakingShowsTheSnapshotUntilThePageLoads() async throws {
        let pool = WebViewPool.forTesting()
        let tab = try await loadedTab("Restore", in: pool)
        await pool.hibernate(tab.id)

        _ = pool.webView(for: tab, profileID: profileID)
        let state = try #require(pool.state(for: tab.id))
        #expect(state.restoringSnapshot != nil)
        #expect(pool.snapshot(for: tab.id) == nil, "The snapshot moves to the live tab when it wakes")

        try await waitUntil("restored page") { state.restoringSnapshot == nil }
        #expect(state.title == "Restore")
    }

    @Test func newTabsHaveNoRestoringSnapshot() throws {
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: try pages.page("Fresh"))
        _ = pool.webView(for: tab, profileID: profileID)
        #expect(pool.state(for: tab.id)?.restoringSnapshot == nil)
    }

    @Test func hibernatingAVisibleOrMissingTabDoesNothing() async throws {
        let pool = WebViewPool.forTesting()
        let tab = try await loadedTab("Visible", in: pool)
        pool.beginShowing(tab.id)

        #expect(await pool.hibernate(tab.id) == false)
        #expect(await pool.hibernate(UUID()) == false)
        #expect(pool.isLive(tab.id))
    }

    @Test func showingATabWhileItsSnapshotIsTakenKeepsItLive() async throws {
        let pool = WebViewPool.forTesting()
        let tab = try await loadedTab("Race", in: pool)

        async let hibernated = pool.hibernate(tab.id)
        pool.beginShowing(tab.id)

        #expect(await hibernated == false)
        #expect(pool.isLive(tab.id))
        #expect(!pool.isHibernated(tab.id))
    }
}
