# AxoInspector

All private WebKit API (the Web Inspector and picture in picture), behind runtime checks, with the public `isInspectable` route as the inspector's fallback.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoWeb

## Public API

`WebInspector` and `PictureInPicture` (`@MainActor`) are the only code in Axo that uses private WebKit API. Every private call is checked with `responds(to:)` first, so a macOS update that removes or renames one makes the call return `false` instead of crashing.

| Function | Uses |
| --- | --- |
| `enableDeveloperTools(in:)` | `WKPreferences._developerExtrasEnabled` (Inspect Element in context menus) |
| `show`, `showConsole`, `close`, `toggle`, `isVisible` | `WKWebView._inspector` (`_WKInspector`) |
| `dock`, `undock` | `_WKInspector.attach` and `detach` |
| `backgroundWebView(of:)` | `WKWebExtensionContext._backgroundWebView` |
| `PictureInPicture.enable(in:)` | `WKPreferences._allowsPictureInPictureMediaPlayback` (videos offer picture in picture; off in `WKWebView` on macOS otherwise) |
| `allowSafariInspection(of:)` | public `isInspectable`, the fallback (Safari's Develop menu) |

All were present in macOS 27 when checked in October 2026, except `_WKInspector.isAttached`, which Axo doesn't use.

## Testing

```bash
swift test
```

The picture-in-picture test plays `Tests/AxoInspectorTests/Resources/clip.mov`, a one-second 64 × 64 silent clip made for it.
