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
  - `addWebViewConfigurator(_:)` adds a function called, in order, with each new web view's configuration and profile. AxoExtensions uses it to attach the profile's extension controller, and the app uses it to turn on developer tools.
  - `load(_:in:)`, `goBack(in:)`, `goForward(in:)`, `reload(_:)`, and `stopLoading(_:)` drive a live tab.
  - `find(_:in:backwards:)` highlights and scrolls to the next or previous match (ignoring case, wrapping) and returns whether it found one. `clearFind(in:)` removes the highlight. WebKit's public API doesn't report match counts.
  - `printOperation(for:)` returns an `NSPrintOperation` for the page, titled with the page title and fit to the page width. Run it with `runModal(for:…)`: a synchronous `run()` hangs, because WebKit prints asynchronously.
  - `onLinkClick` asks the app about each link click in a page's main frame (`LinkClick`: tab, URL, source page, modifier keys, and `leavesSite`). Returning `true` takes the click and the page doesn't navigate. AxoUI uses it for Peek.
  - `onWebViewFocus` reports which tab's web view took keyboard focus (the pool's web views report `becomeFirstResponder`), so with several web views on screen the app knows which one the person is using.
  - `onPageChange` reports URL and title changes so the app can persist them with `TabStore`. `onOpenInNewTab` reports links that target a new window. `onFaviconChange` reports each page's icon after it loads.
- **Favicons:** after each load, the pool reads `<link rel="icon">` and `apple-touch-icon` candidates in an isolated content world, so page scripts can't interfere. It prefers SVG, then the smallest icon at least 64 px, and falls back to `/favicon.ico` for http(s) pages. It downloads with an ephemeral `URLSession` (no cookies, so icon fetches can't identify the user), rejects files over 512 KB, normalizes to a 64 px PNG, and caches by icon URL.
- **Page prompts:** the pool asks the app through async callbacks. Each request carries the asking frame's `PageOrigin` (with a `displayName` for people), and each callback has a safe default when it's `nil`.
  - `onPermissionRequest` handles camera, microphone, both, and location. It denies by default. Answers are saved through `permissionStore` (a `PermissionDecisionStore`; AxoUI backs it with the database), so a saved answer is used without asking. Without a store, answers are remembered per profile, origin, and kind until Axo quits (`rememberedPermission`, `forgetPermissionDecisions`).
  - `PageOrigin(url:)` gets the origin of an http(s) URL (a default port counts as none), and `serialized` writes it as text (`https://meet.example.com`).
  - `onJavaScriptDialog` handles `alert()`, `confirm()`, and `prompt()`. It cancels by default.
  - `onFileSelection` handles `<input type="file">`. It cancels by default.
  - Web notifications have no public WebKit API. The location delegate is only called once the app has its own `CLLocationManager` (see AxoIntegration's `LocationAuthorization` and `docs/webkit-gaps.md`).
- **Downloads:** `pool.downloads` is a `DownloadManager` (`@Observable`) holding `DownloadItem`s, newest first, with state, progress, and bytes.
  - **What downloads:** links with a `download` attribute, main-frame responses WebKit can't display, and responses with `Content-Disposition: attachment`. `pool.startDownload(_:in:)` downloads a URL directly.
  - **Where files go:** the folder passed to `DownloadManager(directory:)`, `~/Downloads` by default, with Finder-style unique names (`file 2.pdf`). Suggested names are sanitized so they can't escape the folder.
  - **Quarantine:** finished files get the quarantine attribute (agent "Axo", type web download, and the source URL for http(s)), so Gatekeeper checks them.
  - `onEnd` reports each download that stops (finished, failed, or cancelled), which the app announces to VoiceOver users.
  - `cancel(_:)` stops a download and removes the partial file. `remove(_:)` and `clearInactive()` edit the list but keep files.
- **Site customizations:** `setSiteCustomizations(_:)` turns per-site CSS and JavaScript into WebKit user scripts for every web view. New web views get them right away; live ones get them on their next page load.
  - **One script per site:** each customization gets its own scripts. Each script checks the page's host and steps aside for a more specific customization, so a syntax error in one site's code can't affect another.
  - **CSS:** added at document start, in every frame, in an isolated world (`AxoSiteCustomizations`).
  - **JavaScript:** runs at document end, in the page's world, top frame only.
  - **Page policies:** user scripts aren't subject to a page's Content Security Policy.
  - **Replacing scripts:** Axo adds no other user scripts, so updating live web views replaces all of theirs.
- **Fullscreen:** the pool turns on `WKPreferences.isElementFullscreenEnabled`, which is off by default, so videos and pages can use the Fullscreen API. Picture in picture needs a private preference, so the app turns it on through AxoInspector's `PictureInPicture`.
- **`UserAgent`** sets the user agent for every tab (and, through AxoExtensions, every extension page): WebKit's default plus `Version/<macOS major.minor> Safari/605.1.15`, like Safari. A plain `WKWebView` leaves that out, which breaks sites and extensions that detect the browser from it (Bitwarden's background script fails to start without it).
- **`WebTabState`** (`@Observable`) mirrors a live tab's URL, title, loading state, progress, and back and forward availability, plus `restoringSnapshot`. Get it with `pool.state(for:)`.
- **`WebViewHost`** is the SwiftUI view that mounts a tab's pooled web view and reports its visibility to the pool. `WebViewContainer` sizes the web view with its autoresizing mask, not Auto Layout, because the docked Web Inspector shrinks the web view's frame to make room. Constraints would stretch the page back over it.

AxoWeb doesn't touch the database. The app layer connects pool callbacks to `TabStore`.

## Not yet

Download history is in memory only, and interrupted downloads can't be resumed yet. Snapshots live in memory only, so tabs restored after a relaunch have none. A web view that was never laid out (zero size) can't be snapshotted, so it hibernates without a picture.

## Testing

```bash
swift test
```

The tests load local HTML files with non-persistent data stores and download into temporary folders, so they never touch the network, the user's website data, or `~/Downloads`. Download links in tests use `data:` URLs, because browsers ignore `download` on cross-origin links and every `file:` URL is its own origin.
