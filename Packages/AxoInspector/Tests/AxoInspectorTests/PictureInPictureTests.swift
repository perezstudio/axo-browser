import Foundation
import Testing
import WebKit
@testable import AxoInspector

extension WebKitSuites {
    @MainActor
    struct PictureInPictureTests {
        /// Whether a video in a web view made with `configuration` reports picture-in-picture support.
        private func videoSupportsPictureInPicture(_ configuration: WKWebViewConfiguration, folder: URL) async throws -> Bool {
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let webView = WKWebView(frame: window.contentView!.bounds, configuration: configuration)
            window.contentView?.addSubview(webView)
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            webView.loadFileURL(folder.appending(path: "video.html"), allowingReadAccessTo: folder)
            // Only a guard against hangs: other tests' web views share the main thread, so a load can
            // take many seconds on a busy machine.
            let deadline = ContinuousClock.now + .seconds(60)
            // The title, not the end of loading: on CI's virtual Mac the page stays loading while
            // its video does, which can be never there. The script below waits for the video
            // itself, with its own limit.
            while webView.title != "Video" {
                try #require(ContinuousClock.now < deadline, "The page didn't load")
                try await Task.sleep(for: .milliseconds(25))
            }
            let supported = try await webView.callAsyncJavaScript("""
                const video = document.querySelector('video');
                await Promise.race([
                    new Promise(resolve => video.readyState >= 1 ? resolve() : video.addEventListener('loadedmetadata', resolve, { once: true })),
                    new Promise((_, reject) => setTimeout(() => reject(new Error('no metadata')), 5000)),
                ]);
                return video.webkitSupportsPresentationMode('picture-in-picture');
                """, contentWorld: .page)
            return try #require(supported as? Bool)
        }

        @Test func videosOfferPictureInPictureOnlyWhenTurnedOn() async throws {
            let folder = FileManager.default.temporaryDirectory.appending(path: "AxoPiPTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A one-second 64 × 64 silent H.264 clip made for these tests.
            let clip = try #require(Bundle.module.url(forResource: "clip", withExtension: "mov"))
            try FileManager.default.copyItem(at: clip, to: folder.appending(path: "clip.mov"))
            try "<!doctype html><title>Video</title><video src='clip.mov' controls muted></video>"
                .write(to: folder.appending(path: "video.html"), atomically: true, encoding: .utf8)

            #expect(try await videoSupportsPictureInPicture(WKWebViewConfiguration.isolated(), folder: folder) == false,
                    "Off by default in WKWebView")

            let configuration = WKWebViewConfiguration.isolated()
            #expect(PictureInPicture.enable(in: configuration))
            #expect(try await videoSupportsPictureInPicture(configuration, folder: folder))
        }
    }
}
