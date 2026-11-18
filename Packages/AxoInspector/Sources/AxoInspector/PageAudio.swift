import AxoWeb
import WebKit

/// Sound in web pages (#71): whether a page plays it, and muting it. `WKWebView` offers both
/// only through private API, so like the rest of AxoInspector each call is checked at runtime;
/// if a macOS update removes them, WebKit pages simply report no sound and can't be muted.
///
/// Uses `WKWebView._isPlayingAudio` (private, key-value observable), `_mediaMutedState`, and
/// `_setPageMuted:` with `_WKMediaAudioMuted` (1).
@MainActor
public final class PageAudio: WebKitPageAudio {
    private static let isPlayingKey = "_isPlayingAudio"
    private static let mutedStateKey = "_mediaMutedState"
    private static let setMuted = NSSelectorFromString("_setPageMuted:")
    /// `_WKMediaMutedState`'s audio bit.
    private static let audioMuted: UInt = 1 << 0

    public init() {}

    /// Whether this macOS has the private calls; without them, don't set ``PageAudio`` at all.
    public static var isAvailable: Bool {
        let webView = WKWebView.self
        return webView.instancesRespond(to: NSSelectorFromString(isPlayingKey))
            && webView.instancesRespond(to: NSSelectorFromString(mutedStateKey))
            && webView.instancesRespond(to: setMuted)
    }

    public func isPlayingAudio(in webView: WKWebView) -> Bool {
        guard webView.responds(to: NSSelectorFromString(Self.isPlayingKey)) else { return false }
        return (webView.value(forKey: Self.isPlayingKey) as? Bool) ?? false
    }

    public func isMuted(in webView: WKWebView) -> Bool {
        (mutedState(of: webView) & Self.audioMuted) != 0
    }

    public func setMuted(_ muted: Bool, in webView: WKWebView) {
        guard webView.responds(to: Self.setMuted) else { return }
        // Keep the other bits (capture muting), changing only the audio one.
        var state = mutedState(of: webView)
        if muted { state |= Self.audioMuted } else { state &= ~Self.audioMuted }
        typealias SetMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        let function = unsafeBitCast(webView.method(for: Self.setMuted), to: SetMuted.self)
        function(webView, Self.setMuted, state)
    }

    public func observe(_ webView: WKWebView, changed: @escaping @MainActor () -> Void) -> AnyObject? {
        guard webView.responds(to: NSSelectorFromString(Self.isPlayingKey)) else { return nil }
        return Observer(webView: webView, keyPath: Self.isPlayingKey, changed: changed)
    }

    private func mutedState(of webView: WKWebView) -> UInt {
        guard webView.responds(to: NSSelectorFromString(Self.mutedStateKey)) else { return 0 }
        return (webView.value(forKey: Self.mutedStateKey) as? NSNumber)?.uintValue ?? 0
    }

    /// Observes a private key path by name, which `observe(_:)` with a Swift key path can't.
    @MainActor private final class Observer: NSObject {
        private weak var webView: WKWebView?
        private let keyPath: String
        private let changed: @MainActor () -> Void

        init(webView: WKWebView, keyPath: String, changed: @escaping @MainActor () -> Void) {
            self.webView = webView
            self.keyPath = keyPath
            self.changed = changed
            super.init()
            webView.addObserver(self, forKeyPath: keyPath, options: [], context: nil)
        }

        // WKWebView posts its key-value notifications on the main thread.
        override nonisolated func observeValue(
            forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
        ) {
            MainActor.assumeIsolated { changed() }
        }

        isolated deinit {
            webView?.removeObserver(self, forKeyPath: keyPath)
        }
    }
}
