import Foundation
import Testing
import WebKit
@testable import AxoInspector

extension WebKitSuites {
    @MainActor
    struct PageAudioTests {
        @Test func theRuntimeHasThePrivateCalls() {
            // If a macOS update removes them, this fails first, and WebKit pages lose only sound.
            #expect(PageAudio.isAvailable)
        }

        @Test func mutingAPageIsReported() {
            let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration.isolated())
            let audio = PageAudio()
            #expect(!audio.isMuted(in: webView))
            #expect(!audio.isPlayingAudio(in: webView))
            audio.setMuted(true, in: webView)
            #expect(audio.isMuted(in: webView))
            audio.setMuted(false, in: webView)
            #expect(!audio.isMuted(in: webView))
        }

        @Test func observingStopsWhenReleased() {
            let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration.isolated())
            #expect(webView.observationInfo == nil)
            var observation = PageAudio().observe(webView) {}
            #expect(observation != nil)
            #expect(webView.observationInfo != nil, "It observes the web view")
            observation = nil
            // Releasing it removes the observer; one left behind would outlive it and crash.
            #expect(webView.observationInfo == nil)
        }
    }
}
