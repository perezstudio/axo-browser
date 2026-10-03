import AppKit
import WebKit

/// Axo's built-in Web Inspector.
///
/// This is the only code in Axo that uses private WebKit API. Every private call is guarded by a
/// runtime check, so if a macOS update removes or renames something, the call returns `false`
/// and nothing crashes. The public `isInspectable` route (Safari's Develop menu) keeps working
/// as a fallback either way.
///
/// Private API used, all present in macOS 27:
/// - `WKPreferences._developerExtrasEnabled` adds Inspect Element to web views' context menus.
/// - `WKWebView._inspector` returns a `_WKInspector` with `show`, `showConsole`, `close`,
///   `isVisible`, `attach` (dock in the window), and `detach` (separate window).
/// - `WKWebExtensionContext._backgroundWebView` gives an extension's background page.
@MainActor
public enum WebInspector {
    // MARK: Turning developer tools on

    /// Turns on developer tools for web views made from `configuration`: Inspect Element in the
    /// context menu (private API) and inspection from Safari's Develop menu (public API).
    ///
    /// - Returns: Whether the built-in inspector could be enabled. When it couldn't, only the
    ///   Safari route is available.
    @discardableResult
    public static func enableDeveloperTools(in configuration: WKWebViewConfiguration) -> Bool {
        set(true, key: "developerExtrasEnabled", setter: "_setDeveloperExtrasEnabled:", on: configuration.preferences)
    }

    /// Lets Safari's Develop menu inspect `webView`. Public API, the fallback when the built-in
    /// inspector isn't available.
    public static func allowSafariInspection(of webView: WKWebView) {
        webView.isInspectable = true
    }

    // MARK: Showing and hiding

    /// Opens the inspector for `webView`. Returns whether it could.
    @discardableResult
    public static func show(_ webView: WKWebView) -> Bool {
        perform("show", onInspectorOf: webView)
    }

    /// Opens the inspector on its JavaScript console. Returns whether it could.
    @discardableResult
    public static func showConsole(_ webView: WKWebView) -> Bool {
        perform("showConsole", onInspectorOf: webView)
    }

    /// Closes the inspector. Returns whether it could.
    @discardableResult
    public static func close(_ webView: WKWebView) -> Bool {
        perform("close", onInspectorOf: webView)
    }

    /// Opens the inspector if it's closed, closes it if it's open. Returns whether it could.
    @discardableResult
    public static func toggle(_ webView: WKWebView) -> Bool {
        isVisible(webView) ? close(webView) : show(webView)
    }

    /// Whether the inspector for `webView` is open. `false` if Axo can't tell.
    public static func isVisible(_ webView: WKWebView) -> Bool {
        bool("isVisible", of: inspector(of: webView))
    }

    /// Docks the inspector in the browser window. Returns whether it could.
    @discardableResult
    public static func dock(_ webView: WKWebView) -> Bool {
        perform("attach", onInspectorOf: webView)
    }

    /// Moves the inspector to its own window. Returns whether it could.
    @discardableResult
    public static func undock(_ webView: WKWebView) -> Bool {
        perform("detach", onInspectorOf: webView)
    }

    // MARK: Extensions

    /// An extension's background page, if it's loaded and Axo can reach it.
    public static func backgroundWebView(of context: WKWebExtensionContext) -> WKWebView? {
        object("_backgroundWebView", of: context) as? WKWebView
    }

    // MARK: Guarded private calls
    //
    // These take plain objects so tests can check that missing API degrades gracefully.

    static func inspector(of webView: NSObject) -> NSObject? {
        object("_inspector", of: webView)
    }

    static func perform(_ selectorName: String, onInspectorOf webView: NSObject) -> Bool {
        guard let inspector = inspector(of: webView) else { return false }
        let selector = NSSelectorFromString(selectorName)
        guard inspector.responds(to: selector) else { return false }
        inspector.perform(selector)
        return true
    }

    static func object(_ getterName: String, of object: NSObject) -> NSObject? {
        guard object.responds(to: NSSelectorFromString(getterName)) else { return nil }
        return object.value(forKey: getterName) as? NSObject
    }

    static func bool(_ getterName: String, of object: NSObject?) -> Bool {
        guard let object, object.responds(to: NSSelectorFromString(getterName)) else { return false }
        return (object.value(forKey: getterName) as? Bool) ?? false
    }

    static func set(_ value: Bool, key: String, setter: String, on object: NSObject) -> Bool {
        // Key-value coding finds `_setKey:` setters, but would throw for an unknown key, so
        // check the setter exists first.
        guard object.responds(to: NSSelectorFromString(setter)) else { return false }
        object.setValue(value, forKey: key)
        return true
    }
}
