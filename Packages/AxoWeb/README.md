# AxoWeb

The web view pool, the `NSViewRepresentable` host, navigation and UI delegates, downloads, permissions, and hibernation.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore

## Public API

- **`WebViewPool`** (`@MainActor`) owns every `WKWebView`. Nothing else creates or destroys one.
  - `webView(for:profileID:)` returns a tab's web view, creating it (loads `tab.url`) or waking it from hibernation (restores `interactionState`, so back and forward history survive).
  - Each profile gets one website data store, `WKWebsiteDataStore(forIdentifier: profileID)` by default, shared by its tabs. Pass `makeDataStore:` to override it, for example with `.nonPersistent()` in tests.
  - `beginShowing(_:)` / `endShowing(_:)` count where a tab is on screen. Visible tabs never hibernate.
  - `hibernate(_:)`, `hibernateIdleTabs()`, and `startHibernationTimer()` discard hidden web views after `Configuration.hibernationTimeout` (30 minutes by default). Hibernating is `async`: it first captures a 640 pt JPEG of the page (`snapshot(for:)`). If the tab is shown or closed during the capture, it stays live.
  - When a hibernated tab wakes, its `WebTabState.restoringSnapshot` holds that picture until the restored page finishes loading.
  - `discard(_:)` forgets a closed tab.
  - `load(_:in:)`, `goBack(in:)`, `goForward(in:)`, `reload(_:)`, and `stopLoading(_:)` drive a live tab.
  - `onPageChange` reports URL and title changes so the app can persist them with `TabStore`. `onOpenInNewTab` reports links that target a new window. `onFaviconChange` reports each page's icon after it loads.
- **Favicons:** after each load, the pool reads `<link rel="icon">` and `apple-touch-icon` candidates in an isolated content world, so page scripts can't interfere. It prefers SVG, then the smallest icon at least 64 px, and falls back to `/favicon.ico` for http(s) pages. It downloads with an ephemeral `URLSession` (no cookies, so icon fetches can't identify the user), rejects files over 512 KB, normalizes to a 64 px PNG, and caches by icon URL.
- **`WebTabState`** (`@Observable`) mirrors a live tab's URL, title, loading state, progress, and back and forward availability, plus `restoringSnapshot`. Get it with `pool.state(for:)`.
- **`WebViewHost`** is the SwiftUI view that mounts a tab's pooled web view and reports its visibility to the pool.

AxoWeb doesn't touch the database. The app layer connects pool callbacks to `TabStore`.

## Not yet

Downloads, permission prompts, find in page, and printing are still to come in Milestone 1. Snapshots live in memory only, so tabs restored after a relaunch have none. A web view that was never laid out (zero size) can't be snapshotted, so it hibernates without a picture.

## Testing

```bash
swift test
```

The tests load local HTML files with non-persistent data stores, so they never touch the network or the user's website data.
