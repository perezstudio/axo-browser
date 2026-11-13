import AxoCore
import CoreGraphics
import Foundation
import Testing
@testable import AxoWeb

/// Parsing pages' colors and picking one for the toolbar (#107).
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
        for css in ["", "red", "#12", "#gggggg", "rgb(1, 2)", "hsl(0, 100%, 50%)", "color(display-p3 1 0 0)", "rgb(a, b, c)", "rgb(nan, 0, 0)", "rgb(0, inf, 0)", "rgba(0, 0, 0, nan)"] {
            #expect(PageColor(css: css) == nil, "\(css)")
        }
    }

    @Test func picksTheThemeColorForTheAppearance() {
        let colors = PageColors(themeColors: [
            (color: "#111111", media: "(prefers-color-scheme: dark)"),
            (color: "#eeeeee", media: "(prefers-color-scheme:light)"),
            (color: "#888888", media: ""),
        ], topColor: PageColor(css: "rgb(1, 2, 3)"))
        #expect(colors.color(isDark: true) == PageColor(css: "#111111"))
        #expect(colors.color(isDark: false) == PageColor(css: "#eeeeee"))
    }

    @Test func fallsBackToThePlainThemeColorThenThePageTop() {
        let plain = PageColors(themeColors: [
            (color: "#111111", media: "(prefers-color-scheme: dark)"),
            (color: "#888888", media: "screen"),
        ], topColor: PageColor(css: "rgb(1, 2, 3)"))
        #expect(plain.color(isDark: true) == PageColor(css: "#111111"))
        #expect(plain.color(isDark: false) == PageColor(css: "#888888"), "A query not about the scheme counts as plain")

        let top = PageColors(themeColors: [], topColor: PageColor(css: "rgb(1, 2, 3)"))
        #expect(top.color(isDark: false) == PageColor(css: "rgb(1, 2, 3)"))
        #expect(PageColors(themeColors: [], topColor: nil).color(isDark: false) == nil)
    }

    @Test func averagesTheTopRowsOfASnapshot() throws {
        // 100 rows: the top 10 orange, the rest white, so only the top edge counts.
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 50, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [240 / 255, 120 / 255, 0, 1])!)
        context.fill(CGRect(x: 0, y: 90, width: 50, height: 10)) // y counts up, so this is the top
        let image = try #require(context.makeImage())
        let color = try #require(PageColors.topEdgeColor(of: image, widthInPoints: 50))
        #expect(abs(color.red - 240 / 255) < 0.02 && abs(color.green - 120 / 255) < 0.02 && color.blue < 0.02, "\(color)")

        let clear = try #require(CGContext(data: nil, width: 50, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let clearImage = try #require(clear.makeImage())
        #expect(PageColors.topEdgeColor(of: clearImage, widthInPoints: 50) == nil, "A see-through top says nothing")
    }

    @Test func readsOnlyTheTopPointsOfAWindowShapedSnapshot() throws {
        // A 320-point snapshot of a wide window at 2x: 640 by 400 pixels, with a thin dark header
        // (6 points) over a white page. Averaging a deeper band would give a muddy grey.
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.1, 0.1, 0.1, 1])!)
        context.fill(CGRect(x: 0, y: 388, width: 640, height: 12))
        let image = try #require(context.makeImage())
        let color = try #require(PageColors.topEdgeColor(of: image, widthInPoints: 320))
        #expect(abs(color.red - 0.1) < 0.02 && abs(color.green - 0.1) < 0.02 && abs(color.blue - 0.1) < 0.02, "\(color)")
    }

    @Test func ignoresMostlySeeThroughColors() {
        let colors = PageColors(themeColors: [(color: "rgba(255, 0, 0, 0.2)", media: "")], topColor: PageColor(css: "rgba(0, 0, 0, 0)"))
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
        pool.readsPageColors = true
        let tab = Tab.testTab(url: url)
        // Sized like a page in a window, so there's something at its top.
        pool.webView(for: tab, profileID: profileID).frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        // Colors are read for shown pages.
        pool.beginShowing(tab.id)
        return (pool, tab, url)
    }

    @Test func readsThemeColorsAfterThePageLoads() async throws {
        let (pool, tab, _) = try await load("""
            <!doctype html><title>Themed</title>
            <meta name="theme-color" media="(max-width: 10px)" content="rgb(255, 0, 0)">
            <meta name="theme-color" content="#9B2A5C">
            <meta name="Theme-Color" media="(prefers-color-scheme: dark)" content="rgb(28, 27, 31)">
            <meta name="theme-color" content="not a color">
            <meta name="theme-color" media="(prefers-color-scheme: light)" content="#010203">
            """, named: "themed.html")
        try await waitUntil("page colors") { pool.state(for: tab.id)?.pageColors != nil }
        let colors = try #require(pool.state(for: tab.id)?.pageColors)
        #expect(colors.themeColor == PageColor(css: "#9b2a5c"), "A width query that doesn't match is left out")
        #expect(colors.darkThemeColor == PageColor(red: 28 / 255, green: 27 / 255, blue: 31 / 255))
        // The lookup's own placeholder color is still a color a page can choose.
        #expect(colors.lightThemeColor == PageColor(css: "#010203"))
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
        let top = try #require(colors.topColor)
        #expect(abs(top.red - 10 / 255) < 0.04 && abs(top.green - 120 / 255) < 0.04 && abs(top.blue - 200 / 255) < 0.04, "\(top)")
    }

    @Test func takesTheColorThePageDrawsNotItsStyles() async throws {
        // A transparent header over a picture, on a dark body: the styles behind the top edge
        // name the body's black, but the page draws the picture's orange there.
        let (pool, tab, _) = try await load("""
            <!doctype html><title>Picture</title>
            <body style="margin:0;background:rgb(10, 10, 10)">
            <div style="position:absolute;top:0;left:0;right:0;height:300px;background-image:linear-gradient(rgb(240, 120, 0), rgb(240, 120, 0))"></div>
            <header style="position:absolute;top:0;left:0;right:0;height:60px">Menu</header>
            </body>
            """, named: "picture.html")
        try await waitUntil("page colors") { pool.state(for: tab.id)?.pageColors != nil }
        let top = try #require(pool.state(for: tab.id)?.pageColors?.topColor)
        #expect(top.red > 0.8 && abs(top.green - 120 / 255) < 0.08 && top.blue < 0.1, "\(top)")
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
