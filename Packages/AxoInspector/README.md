# AxoInspector

All private WebKit API (the Web Inspector, picture in picture, and pages' sound), behind runtime checks, with the public `isInspectable` route as the inspector's fallback.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoWeb

## Public API

`WebInspector`, `PictureInPicture`, `PageAudio`, and `WebContentProcess` (`@MainActor`) are the only code in Axo that uses private WebKit API. Every private call is checked with `responds(to:)` first, so a macOS update that removes or renames one makes the call return `false` instead of crashing.

| Function | Uses |
| --- | --- |
| `enableDeveloperTools(in:)` | `WKPreferences._developerExtrasEnabled` (Inspect Element in context menus) |
| `show`, `showConsole`, `close`, `toggle`, `isVisible` | `WKWebView._inspector` (`_WKInspector`) |
| `dock`, `undock` | `_WKInspector.attach` and `detach` |
| `backgroundWebView(of:)` | `WKWebExtensionContext._backgroundWebView` |
| `PictureInPicture.enable(in:)` | `WKPreferences._allowsPictureInPictureMediaPlayback` (videos offer picture in picture; off in `WKWebView` on macOS otherwise) |
| `PageAudio` (AxoWeb's `WebKitPageAudio`, set as `WebKitEngine.audio`) | `WKWebView._isPlayingAudio` (key-value observed by name), `_mediaMutedState`, and `_setPageMuted:` with the audio bit, for tab rows' speaker and Mute Tab (#71). `PageAudio.isAvailable` checks all three; without them, WebKit pages report no sound |
| `WebContentProcess.identifier(of:)`, `end(for:)` | `WKWebView._webProcessIdentifier`, so UI testing mode's Testing menu can end the shown page's process as a crash would (#75); never used outside UI testing mode |
| `allowSafariInspection(of:)` | public `isInspectable`, the fallback (Safari's Develop menu) |

All were present in macOS 27 when checked in October 2026, except `_WKInspector.isAttached`, which Axo doesn't use.

## Testing

```bash
swift test
```

The picture-in-picture test plays `Tests/AxoInspectorTests/Resources/clip.mov`, a one-second 64 × 64 silent clip made for it.
