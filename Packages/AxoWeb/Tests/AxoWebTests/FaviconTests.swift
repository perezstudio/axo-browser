import AppKit
import AxoCore
import Foundation
import Testing
import WebKit
@testable import AxoWeb

@MainActor
struct FaviconTests {
    let pages: TestPages
    let profileID = UUID()

    init() throws {
        pages = try TestPages()
    }

    /// Writes a solid-color PNG of the given size and returns its file URL.
    private func png(named name: String, width: Int, height: Int) throws -> URL {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(red: 0.61, green: 0.16, blue: 0.36, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = pages.directory.appending(path: name)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func candidate(_ href: String, rel: String = "icon", sizes: String = "", type: String = "") -> FaviconLoader.Candidate {
        .init(href: href, rel: rel, sizes: sizes, type: type)
    }

    // MARK: Loading from a page

    @Test func reportsTheDeclaredIconAfterThePageLoads() async throws {
        let icon = try png(named: "icon.png", width: 128, height: 128)
        let page = try pages.page("Iconic", body: "")
        try "<!doctype html><title>Iconic</title><link rel='icon' href='\(icon.lastPathComponent)'>"
            .write(to: page, atomically: true, encoding: .utf8)
        let pool = WebViewPool.forTesting()
        let tab = Tab.testTab(url: page)
        var reports: [(Tab.ID, URL, Data)] = []
        pool.onFaviconChange = { reports.append(($0, $1, $2)) }

        _ = pool.webView(for: tab, profileID: profileID)
        try await waitUntil("favicon") { !reports.isEmpty }

        let report = try #require(reports.first)
        #expect(report.0 == tab.id)
        #expect(report.1 == page)
        let image = try #require(NSBitmapImageRep(data: report.2))
        #expect(image.pixelsWide == FaviconLoader.iconSize)
        #expect(image.pixelsHigh == FaviconLoader.iconSize)
    }

    @Test func pagesCannotSeeTheLookupScript() async throws {
        // The lookup runs in its own content world, so a page that replaces DOM APIs can't break it.
        let icon = try png(named: "safe.png", width: 32, height: 32)
        let page = pages.directory.appending(path: "hostile.html")
        try """
        <!doctype html><title>Hostile</title><link rel='icon' href='\(icon.lastPathComponent)'>
        <script>Document.prototype.querySelectorAll = () => { throw new Error('nope') }</script>
        """.write(to: page, atomically: true, encoding: .utf8)
        let pool = WebViewPool.forTesting()
        var reports = 0
        pool.onFaviconChange = { _, _, _ in reports += 1 }

        _ = pool.webView(for: Tab.testTab(url: page), profileID: profileID)
        try await waitUntil("favicon") { reports > 0 }
    }

    @Test func inlineSVGIconsAreRasterized() async throws {
        let svg = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='8' fill='%239B2A5C'/%3E%3C/svg%3E"
        let page = pages.directory.appending(path: "svg.html")
        try "<!doctype html><title>SVG</title><link rel=\"icon\" href=\"\(svg)\">"
            .write(to: page, atomically: true, encoding: .utf8)
        let pool = WebViewPool.forTesting()
        var reports: [Data] = []
        pool.onFaviconChange = { _, _, data in reports.append(data) }

        _ = pool.webView(for: Tab.testTab(url: page), profileID: profileID)
        try await waitUntil("SVG favicon") { !reports.isEmpty }
        #expect(NSBitmapImageRep(data: reports[0])?.pixelsWide == FaviconLoader.iconSize)
    }

    // MARK: Choosing an icon

    @Test func prefersScalableIconsThenTheSmallestAtLeast64Pixels() {
        let page = URL(string: "https://example.com/a")!
        let small = candidate("https://example.com/16.png", sizes: "16x16")
        let medium = candidate("https://example.com/64.png", sizes: "32x32 64x64")
        let huge = candidate("https://example.com/1024.png", sizes: "1024x1024")
        let svg = candidate("https://example.com/icon.svg", type: "image/svg+xml")

        #expect(FaviconLoader.bestIconURL(from: [small, medium, huge], pageURL: page)?.lastPathComponent == "64.png")
        #expect(FaviconLoader.bestIconURL(from: [small, medium, svg], pageURL: page)?.lastPathComponent == "icon.svg")
        #expect(FaviconLoader.bestIconURL(from: [small, candidate("https://example.com/t.png", rel: "apple-touch-icon")], pageURL: page)?.lastPathComponent == "t.png")
    }

    @Test func iconURLsKeepTheirPercentEscapes() throws {
        let href = "data:image/svg+xml,%3Csvg viewBox='0 0 16 16'%3E%3C/svg%3E"
        let url = try #require(FaviconLoader.iconURL(from: href))
        #expect(url.absoluteString == "data:image/svg+xml,%3Csvg%20viewBox='0%200%2016%2016'%3E%3C/svg%3E")
        #expect(FaviconLoader.iconURL(from: "https://example.com/icon.png")?.absoluteString == "https://example.com/icon.png")
    }

    @Test func fallsBackToFaviconICOForWebPagesOnly() {
        let web = URL(string: "https://example.com/path/page?q=1#top")!
        #expect(FaviconLoader.bestIconURL(from: [], pageURL: web)?.absoluteString == "https://example.com/favicon.ico")
        #expect(FaviconLoader.bestIconURL(from: [candidate("")], pageURL: web)?.absoluteString == "https://example.com/favicon.ico")
        #expect(FaviconLoader.bestIconURL(from: [], pageURL: URL(string: "file:///tmp/page.html")!) == nil)
        #expect(FaviconLoader.bestIconURL(from: [], pageURL: URL(string: "about:blank")!) == nil)
    }

    // MARK: Normalizing

    @Test func normalizesAnyImageToASquarePNG() throws {
        let wide = try Data(contentsOf: png(named: "wide.png", width: 100, height: 50))
        let normalized = try #require(FaviconLoader.normalize(wide))
        let bitmap = try #require(NSBitmapImageRep(data: normalized))
        #expect(normalized.starts(with: [0x89, 0x50, 0x4E, 0x47]), "Output is PNG")
        #expect(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 64)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(FaviconLoader.normalize(Data("not an image".utf8)) == nil)
        #expect(FaviconLoader.normalize(Data()) == nil)
    }

    @Test func downloadsRejectOversizedFiles() async throws {
        let big = pages.directory.appending(path: "big.bin")
        try Data(count: FaviconLoader.maximumDownloadSize + 1).write(to: big)
        #expect(await FaviconLoader.download(big) == nil)
        let ok = try png(named: "ok.png", width: 16, height: 16)
        #expect(await FaviconLoader.download(ok) != nil)
    }
}
