import AxoCore
import Foundation
import Testing
@testable import AxoWeb

/// Parsing pages' colors and choosing toolbar contrast (#107).
struct PageColorTests {
    @Test func parsesTheFormsEnginesReturn() {
        #expect(PageColor(css: "#9b2a5c") == PageColor(red: 155 / 255, green: 42 / 255, blue: 92 / 255))
        #expect(PageColor(css: "#FFF") == .white)
        #expect(PageColor(css: "rgb(255, 0, 0)") == PageColor(red: 1, green: 0, blue: 0))
        #expect(PageColor(css: "rgba(0, 0, 255, 0.25)") == PageColor(red: 0, green: 0, blue: 1, alpha: 0.25))
        #expect(PageColor(css: "rgb(0 128 0 / 50%)") == PageColor(red: 0, green: 128 / 255, blue: 0, alpha: 0.5))
        #expect(PageColor(css: " RGB(10%, 20%, 30%) ") == PageColor(red: 0.1, green: 0.2, blue: 0.3))
    }

    @Test func rejectsWhatItCantRead() {
        for css in ["", "red", "#12", "#gggggg", "rgb(1, 2)", "hsl(0, 100%, 50%)", "color(display-p3 1 0 0)", "rgb(a, b, c)"] {
            #expect(PageColor(css: css) == nil, "\(css)")
        }
    }

    @Test func picksTheThemeColorForTheAppearance() {
        let colors = PageColors(themeColors: [
            (color: "#111111", media: "(prefers-color-scheme: dark)"),
            (color: "#eeeeee", media: "(prefers-color-scheme:light)"),
            (color: "#888888", media: ""),
        ], topColor: "rgb(1, 2, 3)")
        #expect(colors.color(isDark: true) == PageColor(css: "#111111"))
        #expect(colors.color(isDark: false) == PageColor(css: "#eeeeee"))
    }

    @Test func fallsBackToThePlainThemeColorThenThePageTop() {
        let plain = PageColors(themeColors: [
            (color: "#111111", media: "(prefers-color-scheme: dark)"),
            (color: "#888888", media: "screen"),
        ], topColor: "rgb(1, 2, 3)")
        #expect(plain.color(isDark: true) == PageColor(css: "#111111"))
        #expect(plain.color(isDark: false) == PageColor(css: "#888888"), "A query not about the scheme counts as plain")

        let top = PageColors(themeColors: [], topColor: "rgb(1, 2, 3)")
        #expect(top.color(isDark: false) == PageColor(css: "rgb(1, 2, 3)"))
        #expect(PageColors(themeColors: [], topColor: nil).color(isDark: false) == nil)
    }

    @Test func ignoresMostlySeeThroughColors() {
        let colors = PageColors(themeColors: [(color: "rgba(255, 0, 0, 0.2)", media: "")], topColor: "rgba(0, 0, 0, 0)")
        #expect(colors.color(isDark: false) == nil)
        #expect(PageColors(themeColors: [(color: "rgba(255, 0, 0, 0.6)", media: "")], topColor: nil).themeColor != nil)
    }
}

#if os(macOS)
/// Reading a real page's colors.
@MainActor
struct PageColorLoadingTests {
    let pages: TestPages
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
    }

    private func load(_ html: String, named name: String) async throws -> (WebViewPool, Tab, URL) {
        let url = pages.directory.appending(path: name)
        try html.write(to: url, atomically: true, encoding: .utf8)
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: url)
        // Sized like a page in a window, so there's something at its top.
        pool.webView(for: tab, profileID: profileID).frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        return (pool, tab, url)
    }

    @Test func readsThemeColorsAfterThePageLoads() async throws {
        let (pool, tab, _) = try await load("""
            <!doctype html><title>Themed</title>
            <meta name="theme-color" content="#9B2A5C">
            <meta name="Theme-Color" media="(prefers-color-scheme: dark)" content="rgb(28, 27, 31)">
            <meta name="theme-color" content="not a color">
            """, named: "themed.html")
        try await waitUntil("page colors") { pool.state(for: tab.id)?.pageColors != nil }
        let colors = try #require(pool.state(for: tab.id)?.pageColors)
        #expect(colors.themeColor == PageColor(css: "#9b2a5c"))
        #expect(colors.darkThemeColor == PageColor(red: 28 / 255, green: 27 / 255, blue: 31 / 255))
        #expect(colors.lightThemeColor == nil)
    }

    @Test func fallsBackToTheColorAtThePagesTop() async throws {
        let (pool, tab, _) = try await load("""
            <!doctype html><title>Top</title>
            <body style="margin:0"><header style="height:80px;background:rgb(10, 120, 200)">Header</header>
            <main style="height:2000px;background:white">Body</main></body>
            """, named: "top.html")
        try await waitUntil("page colors") { pool.state(for: tab.id)?.pageColors != nil }
        let colors = try #require(pool.state(for: tab.id)?.pageColors)
        #expect(colors.themeColor == nil)
        #expect(colors.topColor == PageColor(red: 10 / 255, green: 120 / 255, blue: 200 / 255))
    }

    @Test func pagesCantBreakTheLookup() async throws {
        // It runs in Axo's own world, so a page replacing DOM methods changes nothing.
        let (pool, tab, _) = try await load("""
            <!doctype html><title>Hostile</title>
            <meta name="theme-color" content="#123456">
            <script>
            Document.prototype.querySelectorAll = () => { throw new Error('nope') };
            HTMLCanvasElement.prototype.getContext = () => null;
            </script>
            """, named: "hostile-colors.html")
        try await waitUntil("page colors") { pool.state(for: tab.id)?.pageColors != nil }
        #expect(pool.state(for: tab.id)?.pageColors?.themeColor == PageColor(css: "#123456"))
    }
}
#endif
