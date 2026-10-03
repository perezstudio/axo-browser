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
  - `configureWebView` is called with each new web view's configuration and profile, which is how AxoExtensions attaches the profile's extension controller.
  - `load(_:in:)`, `goBack(in:)`, `goForward(in:)`, `reload(_:)`, and `stopLoading(_:)` drive a live tab.
  - `find(_:in:backwards:)` highlights and scrolls to the next or previous match (ignoring case, wrapping) and returns whether it found one. `clearFind(in:)` removes the highlight. WebKit's public API doesn't report match counts.
  - `printOperation(for:)` returns an `NSPrintOperation` for the page, titled with the page title and fit to the page width. Run it with `runModal(for:…)`: a synchronous `run()` hangs, because WebKit prints asynchronously.
  - `onPageChange` reports URL and title changes so the app can persist them with `TabStore`. `onOpenInNewTab` reports links that target a new window. `onFaviconChange` reports each page's icon after it loads.
- **Favicons:** after each load, the pool reads `<link rel="icon">` and `apple-touch-icon` candidates in an isolated content world, so page scripts can't interfere. It prefers SVG, then the smallest icon at least 64 px, and falls back to `/favicon.ico` for http(s) pages. It downloads with an ephemeral `URLSession` (no cookies, so icon fetches can't identify the user), rejects files over 512 KB, normalizes to a 64 px PNG, and caches by icon URL.
- **Page prompts:** the pool asks the app through async callbacks. Each request carries the asking frame's `PageOrigin` (with a `displayName` for people), and each callback has a safe default when it's `nil`.
  - `onPermissionRequest` handles camera, microphone, both, and location. It denies by default. Answers are remembered per profile, origin, and kind until Axo quits (`rememberedPermission`, `forgetPermissionDecisions`).
  - `onJavaScriptDialog` handles `alert()`, `confirm()`, and `prompt()`. It cancels by default.
  - `onFileSelection` handles `<input type="file">`. It cancels by default.
  - Web notifications have no public WebKit API, and the location delegate isn't called in practice. See `docs/webkit-gaps.md`.
- **Downloads:** `pool.downloads` is a `DownloadManager` (`@Observable`) holding `DownloadItem`s, newest first, with state, progress, and bytes.
  - **What downloads:** links with a `download` attribute, main-frame responses WebKit can't display, and responses with `Content-Disposition: attachment`. `pool.startDownload(_:in:)` downloads a URL directly.
  - **Where files go:** the folder passed to `DownloadManager(directory:)`, `~/Downloads` by default, with Finder-style unique names (`file 2.pdf`). Suggested names are sanitized so they can't escape the folder.
  - **Quarantine:** finished files get the quarantine attribute (agent "Axo", type web download, and the source URL for http(s)), so Gatekeeper checks them.
  - `cancel(_:)` stops a download and removes the partial file. `remove(_:)` and `clearInactive()` edit the list but keep files.
- **`WebTabState`** (`@Observable`) mirrors a live tab's URL, title, loading state, progress, and back and forward availability, plus `restoringSnapshot`. Get it with `pool.state(for:)`.
- **`WebViewHost`** is the SwiftUI view that mounts a tab's pooled web view and reports its visibility to the pool.

AxoWeb doesn't touch the database. The app layer connects pool callbacks to `TabStore`.

## Not yet

Permission answers aren't saved across launches yet (site settings come in Milestone 4). Download history is in memory only, and interrupted downloads can't be resumed yet. Snapshots live in memory only, so tabs restored after a relaunch have none. A web view that was never laid out (zero size) can't be snapshotted, so it hibernates without a picture.

## Testing

```bash
swift test
```

The tests load local HTML files with non-persistent data stores and download into temporary folders, so they never touch the network, the user's website data, or `~/Downloads`. Download links in tests use `data:` URLs, because browsers ignore `download` on cross-origin links and every `file:` URL is its own origin.
