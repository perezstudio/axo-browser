import AxoCore
import AxoWebTestSupport
import CoreGraphics
import Foundation
import ImageIO
import Testing
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import AxoWeb

/// When the pool snapshots pages: as a tab is hidden, once per change, as Chrome does, rather than
/// when it hibernates (by then a hidden page may have stopped drawing).
@MainActor
struct SnapshotTimingTests {
    let engine = FakeEngine()
    let pool: WebViewPool
    let tab = Tab.testTab(url: URL(string: "https://example.com/")!)
    let profileID = UUID()

    init() {
        pool = WebViewPool.withFakeEngine(engine)
    }

    /// A shown and loaded tab whose page snapshots as a small image.
    private func shownPage() throws -> FakePage {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.snapshotImage = Self.image(width: 40, height: 30, red: 1, green: 0, blue: 0)
        page.navigate(to: tab.url, title: "Example")
        page.finishLoad()
        pool.beginShowing(tab.id)
        return page
    }

    private func hide(_ page: FakePage, expectingSnapshots count: Int) async throws {
        pool.endShowing(tab.id)
        try await settle()
        #expect(page.snapshotCount == count)
    }

    /// Waits until no snapshot is being taken.
    private func settle() async throws {
        try await waitUntil("the snapshot") { !pool.isSnapshotting(tab.id) }
    }

    @Test func hidingATabSnapshotsItAndHibernatingKeepsThatOne() async throws {
        let page = try shownPage()
        #expect(page.snapshotCount == 0, "Not while it's shown")

        try await hide(page, expectingSnapshots: 1)
        #expect(await pool.hibernate(tab.id))
        #expect(page.snapshotCount == 1, "Hibernating used the snapshot taken when the tab was hidden")
        let snapshot = try #require(pool.snapshot(for: tab.id))
        #expect(snapshot.starts(with: [0xFF, 0xD8]), "Stored as JPEG")
    }

    @Test func aTabShownAndHiddenAgainWithNoChangeIsntSnapshottedAgain() async throws {
        let page = try shownPage()
        try await hide(page, expectingSnapshots: 1)

        pool.beginShowing(tab.id)
        pool.endShowing(tab.id)
        #expect(!pool.isSnapshotting(tab.id))
        #expect(page.snapshotCount == 1)

        // A navigation, then a finished load, each make the snapshot out of date.
        pool.beginShowing(tab.id)
        page.navigate(to: URL(string: "https://example.com/next")!, title: "Next")
        try await hide(page, expectingSnapshots: 2)
        pool.beginShowing(tab.id)
        page.finishLoad()
        try await hide(page, expectingSnapshots: 3)
    }

    @Test func aPageThatChangesWhileItsSnapshotIsTakenIsSnapshottedAgain() async throws {
        let page = try shownPage()
        page.holdsSnapshots = true
        pool.endShowing(tab.id)
        try await waitUntil("the first snapshot to start") { page.snapshotCount == 1 }

        // The page loads again while that snapshot is being taken.
        page.finishLoad()
        page.answerHeldSnapshot()
        try await waitUntil("a second snapshot") { page.snapshotCount == 2 }
        page.answerHeldSnapshot()
    }

    @Test func aPageThatCantBeSnapshottedIsntAskedAgainAndAgain() async throws {
        let page = try shownPage()
        page.snapshotImage = nil
        try await hide(page, expectingSnapshots: 1)
        #expect(!pool.isSnapshotting(tab.id), "No retake for a page that didn't change")
    }

    @Test func aPageStillLoadingIsntSnapshottedWhenHidden() async throws {
        let page = try shownPage()
        try await hide(page, expectingSnapshots: 1)
        pool.beginShowing(tab.id)
        page.navigate(to: URL(string: "https://example.com/slow")!, title: "Slow")
        page.isLoading = true

        // Its picture would be blank or half drawn, replacing a good one.
        try await hide(page, expectingSnapshots: 1)
        // It finished loading while hidden, so hibernating snapshots it.
        page.finishLoad()
        #expect(await pool.hibernate(tab.id))
        #expect(page.snapshotCount == 2)
    }

    @Test func aFailedLoadMakesTheSnapshotOutOfDate() async throws {
        let page = try shownPage()
        try await hide(page, expectingSnapshots: 1)
        pool.beginShowing(tab.id)
        page.failLoad()
        try await hide(page, expectingSnapshots: 2)
    }

    @Test func hibernatingWaitsForTheSnapshotBeingTaken() async throws {
        let page = try shownPage()
        page.holdsSnapshots = true
        pool.endShowing(tab.id)
        try await waitUntil("the snapshot to start") { page.snapshotCount == 1 }

        let hibernating = Task { await pool.hibernate(tab.id) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(pool.isLive(tab.id), "Still waiting for the snapshot")
        page.answerHeldSnapshot()
        #expect(await hibernating.value)
        #expect(page.snapshotCount == 1, "It used that snapshot")
        #expect(pool.snapshot(for: tab.id) != nil)
    }

    @Test func aTabClosedWhileItsSnapshotIsTakenStaysClosed() async throws {
        let page = try shownPage()
        page.holdsSnapshots = true
        pool.endShowing(tab.id)
        try await waitUntil("the snapshot to start") { page.snapshotCount == 1 }

        pool.discard(tab.id)
        page.answerHeldSnapshot()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!pool.isLive(tab.id))
        #expect(!pool.isHibernated(tab.id))
        #expect(pool.snapshot(for: tab.id) == nil)
    }

    @Test func aWokenTabIsSnapshottedWhenHiddenAgain() async throws {
        let page = try shownPage()
        try await hide(page, expectingSnapshots: 1)
        #expect(await pool.hibernate(tab.id))

        pool.page(for: tab, profileID: profileID)
        let woken = try #require(engine.pages.last)
        woken.snapshotImage = Self.image(width: 40, height: 30, red: 0, green: 1, blue: 0)
        pool.beginShowing(tab.id)
        woken.finishLoad()
        try await hide(woken, expectingSnapshots: 1)
    }

    @Test func aTabShownInTwoPlacesIsSnapshottedOnceBothHideIt() async throws {
        let page = try shownPage()
        pool.beginShowing(tab.id)

        pool.endShowing(tab.id)
        #expect(!pool.isSnapshotting(tab.id))
        #expect(page.snapshotCount == 0, "Still shown in the other place")
        try await hide(page, expectingSnapshots: 1)
    }

    @Test func aPageThatChangedWhileHiddenIsSnapshottedWhenItHibernates() async throws {
        let page = try shownPage()
        try await hide(page, expectingSnapshots: 1)

        page.navigate(to: URL(string: "https://example.com/later")!, title: "Later")
        #expect(await pool.hibernate(tab.id))
        #expect(page.snapshotCount == 2)
    }

    @Test func aTabNeverShownIsSnapshottedWhenItHibernates() async throws {
        pool.page(for: tab, profileID: profileID)
        let page = try #require(engine.pages.last)
        page.snapshotImage = Self.image(width: 40, height: 30, red: 0, green: 0, blue: 1)

        #expect(await pool.hibernate(tab.id))
        #expect(page.snapshotCount == 1)
        #expect(pool.snapshot(for: tab.id) != nil)
    }

    @Test func aFailedSnapshotKeepsTheOneBefore() async throws {
        let page = try shownPage()
        try await hide(page, expectingSnapshots: 1)
        page.snapshotImage = nil

        page.navigate(to: URL(string: "https://example.com/later")!, title: "Later")
        #expect(await pool.hibernate(tab.id))
        #expect(page.snapshotCount == 2)
        #expect(pool.snapshot(for: tab.id) != nil, "An older picture beats none")
    }

    @Test func aWokenTabKeepsItsSnapshotUntilItHasANewOne() async throws {
        let page = try shownPage()
        try await hide(page, expectingSnapshots: 1)
        #expect(await pool.hibernate(tab.id))

        // Woken, but hibernated again before it could be snapshotted (its engine can't now).
        pool.page(for: tab, profileID: profileID)
        try #require(engine.pages.last).snapshotImage = nil
        #expect(await pool.hibernate(tab.id))
        #expect(pool.snapshot(for: tab.id) != nil)
    }

    // MARK: Encoding

    @Test func snapshotsAreSmallJPEGsInSRGB() throws {
        // Display P3's red, which sRGB can't show: drawn into sRGB it's the purest red sRGB has.
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let wide = try #require(Self.cgImage(width: 1280, height: 800, red: 1, green: 0, blue: 0, space: p3))

        let data = try #require(PageSnapshot.jpegData(from: wide, maxWidth: 640))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 640)
        #expect(decoded.height == 400)
        let (red, green, blue) = try Self.centre(of: decoded)
        #expect(red >= 250 && green <= 10 && blue <= 10, "Got \(red), \(green), \(blue)")
    }

    @Test func smallImagesKeepTheirSize() throws {
        let small = try #require(Self.cgImage(width: 300, height: 200, red: 0, green: 1, blue: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!))
        let data = try #require(PageSnapshot.jpegData(from: small, maxWidth: 640))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 300)
    }

    // MARK: Images

    static func cgImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, space: CGColorSpace) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(colorSpace: space, components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func image(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> PlatformImage? {
        guard let cgImage = cgImage(width: width, height: height, red: red, green: green, blue: blue, space: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    /// The centre pixel of `image`, drawn into sRGB.
    static func centre(of image: CGImage) throws -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        }
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}
