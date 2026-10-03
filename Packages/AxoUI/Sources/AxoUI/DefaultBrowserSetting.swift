/// Reads and changes whether Axo is the default web browser.
///
/// AxoIntegration's `DefaultBrowser` provides the real implementation; the app connects them.
/// Tests use fakes, so they never change the real default browser.
@MainActor
public protocol DefaultBrowserSetting {
    /// Whether Axo opens http and https links.
    var isDefault: Bool { get }
    /// Asks macOS to make Axo the default. macOS confirms with the person; this throws if they
    /// decline or the change fails.
    func makeDefault() async throws
}
