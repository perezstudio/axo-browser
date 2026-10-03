import Foundation
import WebKit

/// The user agent Axo's web views report.
///
/// A plain `WKWebView` leaves `Version/… Safari/…` out of its user agent, so sites and extensions
/// that detect the browser from it don't recognize Axo at all. Bitwarden's background script, for
/// one, fails to start. Axo reports itself as Safari on the running macOS version, which matches
/// the engine it runs.
public enum UserAgent {
    /// The text WebKit appends to its user agent, such as `Version/27.0 Safari/605.1.15`.
    public static var applicationName: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(version.majorVersion).\(version.minorVersion) Safari/605.1.15"
    }

    /// Sets Axo's user agent on a web view configuration.
    @MainActor
    public static func apply(to configuration: WKWebViewConfiguration) {
        configuration.applicationNameForUserAgent = applicationName
    }
}
