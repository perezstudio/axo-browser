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
struct FindAndPrintTests {
    let pages: TestPages
    let pool = WebViewPool.forTesting()
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
    }

    private func loadedTab(title: String, body: String) async throws -> Tab {
        let tab = Tab.testTab(url: try pages.page(title, body: body))
        pool.webView(for: tab, profileID: profileID).frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        try await waitUntil("page \(title)") {
            pool.state(for: tab.id).map { !$0.isLoading && $0.title == title } ?? false
        }
        return tab
    }

    private func selectedText(in tab: Tab) async throws -> String {
        let webView = try #require(pool.liveWebView(for: tab.id))
        let value = try await webView.callAsyncJavaScript("return String(window.getSelection())", contentWorld: .page)
        return value as? String ?? ""
    }

    // MARK: Find

    @Test func findsTextIgnoringCaseAndSelectsTheMatch() async throws {
        let tab = try await loadedTab(title: "Axolotls", body: "<p>The Axolotl regenerates.</p>")

        #expect(await pool.find("axolotl", in: tab.id))
        #expect(try await selectedText(in: tab) == "Axolotl")
    }

    @Test func reportsWhenThereIsNoMatch() async throws {
        let tab = try await loadedTab(title: "Short", body: "<p>Nothing to see.</p>")
        #expect(await pool.find("salamander", in: tab.id) == false)
        #expect(await pool.find("", in: tab.id) == false)
        #expect(await pool.find("see", in: UUID()) == false, "A tab that isn't live finds nothing")
    }

    @Test func findsForwardAndBackwardAndWraps() async throws {
        let tab = try await loadedTab(title: "Repeats", body: "<p id='a'>echo one</p><p id='b'>echo two</p>")
        let webView = try #require(pool.liveWebView(for: tab.id))
        func matchParent() async throws -> String {
            let value = try await webView.callAsyncJavaScript(
                "return window.getSelection().anchorNode.parentElement.id", contentWorld: .page
            )
            return value as? String ?? ""
        }

        #expect(await pool.find("echo", in: tab.id))
        #expect(try await matchParent() == "a")
        #expect(await pool.find("echo", in: tab.id))
        #expect(try await matchParent() == "b")
        #expect(await pool.find("echo", in: tab.id), "Wraps to the top")
        #expect(try await matchParent() == "a")
        #expect(await pool.find("echo", in: tab.id, backwards: true), "Wraps to the bottom going backwards")
        #expect(try await matchParent() == "b")
    }

    @Test func clearingFindRemovesTheHighlight() async throws {
        let tab = try await loadedTab(title: "Clear", body: "<p>highlight me</p>")
        #expect(await pool.find("highlight", in: tab.id))

        await pool.clearFind(in: tab.id)

        #expect(try await selectedText(in: tab) == "")
    }

    // MARK: Print

    #if os(macOS)
    @Test func printOperationShowsThePanelAndIsTitledWithThePage() async throws {
        let tab = try await loadedTab(title: "Receipt", body: "<p>Total: 3 axolotls</p>")

        let operation = try #require(pool.printOperation(for: tab.id))

        #expect(operation.showsPrintPanel)
        #expect(operation.jobTitle == "Receipt")
        #expect(operation.printInfo.horizontalPagination == .fit)
        #expect(operation.view?.frame.size == CGSize(width: 800, height: 600))
        #expect(pool.printOperation(for: UUID()) == nil)
    }
    #endif
}
