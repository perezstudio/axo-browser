import WebKit

/// Picture in picture for web video, which `WKWebView` on macOS only offers through a private
/// preference. Like the rest of AxoInspector, the call is checked at runtime, so if a macOS
/// update removes it, videos simply don't offer picture in picture.
@MainActor
public enum PictureInPicture {
    /// Lets videos in web views made with `configuration` enter picture in picture, from their
    /// controls or `requestPictureInPicture()`. Returns whether it could.
    ///
    /// Uses `WKPreferences._allowsPictureInPictureMediaPlayback` (private).
    @discardableResult
    public static func enable(in configuration: WKWebViewConfiguration) -> Bool {
        WebInspector.set(
            true,
            key: "allowsPictureInPictureMediaPlayback",
            setter: "_setAllowsPictureInPictureMediaPlayback:",
            on: configuration.preferences
        )
    }
}
