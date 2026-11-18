import Foundation
import WebKit

/// The process a web view's page runs in, so UI tests can end it and check what Axo shows for a
/// crashed page (#75). WebKit offers no public way to end it, or to learn which process it is.
///
/// Uses `WKWebView._webProcessIdentifier` (private), checked at runtime like the rest of
/// AxoInspector: without it, there's no identifier and nothing to end.
@MainActor
public enum WebContentProcess {
    private static let identifierSelector = NSSelectorFromString("_webProcessIdentifier")

    /// The page's web content process, or nil when this macOS doesn't say or there's none yet.
    public static func identifier(of webView: WKWebView) -> pid_t? {
        guard webView.responds(to: identifierSelector) else { return nil }
        typealias Identifier = @convention(c) (AnyObject, Selector) -> pid_t
        let function = unsafeBitCast(webView.method(for: identifierSelector), to: Identifier.self)
        let identifier = function(webView, identifierSelector)
        return identifier > 0 ? identifier : nil
    }

    /// Ends the page's web content process, as a crash would, so WebKit reports it to the page's
    /// navigation delegate. For UI testing mode only. Returns whether it did.
    @discardableResult
    public static func end(for webView: WKWebView) -> Bool {
        guard let identifier = identifier(of: webView) else { return false }
        return kill(identifier, SIGKILL) == 0
    }
}
