import Testing
import WebKit

/// Every AxoInspector suite makes web views, so they run one at a time, each web view with a data
/// store of its own: on CI's virtual Mac, the picture in picture test's page sometimes never
/// loaded while other suites' web views shared WebKit's default data store and its processes.
@Suite(.serialized)
@MainActor
enum WebKitSuites {}

extension WKWebViewConfiguration {
    /// A configuration with a non-persistent data store of its own, so a test's page shares no
    /// web process with another test's.
    static func isolated() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
}
