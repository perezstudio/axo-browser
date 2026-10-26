# AxoWeb

The page pool, the browser engine seam (`WebEngine`, `EnginePage`) with WebKit behind it, the `NSViewRepresentable` host, downloads, permissions, and hibernation.

Part of [Axo](../../CLAUDE.md), a native browser for macOS, iPhone, and iPad. See `docs/PLAN.md` for the architecture and `docs/chromium-engine.md` for why the engine is behind a protocol.

**Depends on:** AxoCore

**Platforms:** macOS 27 and iOS 27. `PlatformImage` and `PlatformView` are `NSImage`/`NSView` on the Mac and `UIImage`/`UIView` on iPhone and iPad, and `LinkModifiers` is Axo's own set of modifier keys for link clicks. Printing (`printOperation(for:)`) and download quarantine are Mac only. Tests that use AppKit drawing or windows (favicons, the host's layout, focus, printing, quarantine) run on the Mac only; the rest run on both.

## Engines

The pool never touches a browser engine directly. It talks to two protocols, so the Mac can move to a Chromium fork while iPhone and iPad stay on WebKit (`docs/chromium-engine.md`):

- **`WebEngine`** makes empty pages for a profile (`makePage(profileID:)`), applies site customizations, and clears or deletes a profile's website data.
- **`EnginePage`** is one tab's page: its `view`, URL, title, loading state, history, navigation, find, `callJavaScript(_:arguments:in:)` in a named isolated world, `snapshot(width:)`, downloads, printing, `close()`, an opaque `interactionState` for hibernation, and `exitFullscreen()`. It reports events (including `setsFullscreen` and `didOpen`, an `OpenedPage`, from engines that leave those to Axo) to a `EnginePageDelegate`, which the pool implements for each live tab.
- **`WebKitEngine`** and **`WebKitPage`** are the WebKit implementation: one `WKWebView` per page, and one `WKWebsiteDataStore(forIdentifier: profileID)` per profile by default (pass `makeDataStore:` to override it, for example with `.nonPersistent()` in tests). The page is its web view's navigation and UI delegate. Content worlds are kept by name, because WebKit makes a fresh world once the last `WKContentWorld` for a name is released.
- **WebKit-only access:** `pool.webKitEngine`, `liveWebView(for:)`, `webView(for:profileID:)`, `dataStore(for:)`, `addWebViewConfigurator(_:)`, and `removeDataStore` reach WebKit directly, for AxoExtensions, AxoInspector, and tests. They return `nil`, do nothing, or stop with a precondition failure on another engine. AxoUI never uses them.
- **Windows and engine events.** Some engines have a window model of their own: Chromium's extension APIs see a window's tabs. `WebEngine.setWindowPages(_:active:profileID:)` (a no-op by default, and for WebKit) receives the pages of the window's tabs, and the engine reports tabs it changed on its own (`chrome.tabs.create`, `chrome.tabs.remove`) to its `WebEngineDelegate`, which the pool is. A popup window the engine opens on its own (`chrome.windows.create`) reaches the pool's `onEnginePopupWindow`.
- **`AxoWebTestSupport`** (a library product) has `FakeEngine` and `FakePage`, an engine with no browser behind it, for testing the pool and its callers without WebKit.

## Public API

- **`WebViewPool`** (`@MainActor`) owns every page. Nothing else creates or destroys one. `WebViewPool(engine:…)` takes any engine; `WebViewPool(makeDataStore:…)` makes a WebKit one.
  - `setWindowTabs(_:selected:profileID:)` tells the engine which tabs the window shows (the Space's, in sidebar order) and which is selected; only live tabs are passed on. `onEngineOpenedPage` (an `EngineOpenedPage`: the page, its profile, and the tab before it in the window), `onEngineClosedTab`, and `onEngineActivatedTab` report the engine's own changes as tabs. Without an `onEngineOpenedPage` handler, an engine-opened page closes. `adopt(_:as:profileID:)` makes an engine-opened page a tab's live page without reloading it.
  - `page(for:profileID:)` returns a tab's page, creating it (loads `tab.url`) or waking it from hibernation (restores `interactionState`, so back and forward history survive). `livePage(for:)` returns it only if it's live.
  - `clearWebsiteData(for:)` removes a profile's cookies, caches, and site data. `removeWebsiteData(for:)` discards a deleted profile's pages and deletes its data for good through the engine (WebKit's `removeDataStore`, which tests replace; WebKit crashes if that removal runs off the main thread, so it's `@MainActor`).
  - `beginShowing(_:)` / `endShowing(_:)` count where a tab is on screen. Visible tabs never hibernate.
  - `hibernate(_:)`, `hibernateIdleTabs()`, and `startHibernationTimer()` discard hidden pages after `Configuration.hibernationTimeout` (30 minutes by default). Hibernating is `async`: it first captures a 640 pt JPEG of the page (`snapshot(for:)`). If the tab is shown or closed during the capture, it stays live.
  - When a hibernated tab wakes, its `WebTabState.restoringSnapshot` holds that picture until the restored page finishes loading.
  - `discard(_:)` forgets a closed tab.
  - `addWebViewConfigurator(_:)` (WebKit only) adds a function called, in order, with each new web view's configuration and profile. AxoExtensions uses it to attach the profile's extension controller, and the app uses it to turn on developer tools.
  - `load(_:in:)`, `goBack(in:)`, `goForward(in:)`, `reload(_:)`, and `stopLoading(_:)` drive a live tab.
  - `find(_:in:backwards:)` highlights and scrolls to the next or previous match (ignoring case, wrapping) and returns whether it found one. `clearFind(in:)` removes the highlight. WebKit's public API doesn't report match counts.
  - `printOperation(for:)` returns an `NSPrintOperation` for the page, titled with the page title and fit to the page width. Run it with `runModal(for:…)`: a synchronous `run()` hangs, because WebKit prints asynchronously.
  - `onLinkClick` asks the app about each link click in a page's main frame (`LinkClick`: tab, URL, source page, modifier keys, and `leavesSite`). Returning `true` takes the click and the page doesn't navigate. AxoUI uses it for Peek.
  - `onWebViewFocus` reports which tab's page took keyboard focus (WebKit's pooled web views report `becomeFirstResponder`), so with several pages on screen the app knows which one the person is using.
  - `onPageChange` reports URL and title changes so the app can persist them with `TabStore`. `onOpenInNewTab` reports links that target a new window. `onPageOpened` reports a page another opened, already loading and connected to its opener (Chromium), and `onPageFullscreen` a page asking to fill the screen; `exitFullscreen(_:)` takes it back out. A page's view can move from one `WebViewHost` to another; the old container leaves it in the new one. `onContextMenu` gets right-clicks (a `PageContextMenu`: what was clicked, extensions' items, and actions) from engines that leave the menu to Axo, which is Chromium; WebKit draws its own. `onFaviconChange` reports each page's icon after it loads.
- **Favicons:** after each load, the pool reads `<link rel="icon">` and `apple-touch-icon` candidates in an isolated content world, so page scripts can't interfere. It prefers SVG, then the smallest icon at least 64 px, and falls back to `/favicon.ico` for http(s) pages. It downloads with an ephemeral `URLSession` (no cookies, so icon fetches can't identify the user), rejects files over 512 KB, normalizes to a 64 px PNG, and caches by icon URL.
- **Page prompts:** the pool asks the app through async callbacks. Each request carries the asking frame's `PageOrigin` (with a `displayName` for people), and each callback has a safe default when it's `nil`.
  - `onPermissionRequest` handles camera, microphone, both, and location. It denies by default. Answers are saved through `permissionStore` (a `PermissionDecisionStore`; AxoUI backs it with the database), so a saved answer is used without asking. Without a store, answers are remembered per profile, origin, and kind until Axo quits (`rememberedPermission`, `forgetPermissionDecisions`).
  - `PageOrigin(url:)` gets the origin of an http(s) URL (a default port counts as none), and `serialized` writes it as text (`https://meet.example.com`).
  - `onJavaScriptDialog` handles `alert()`, `confirm()`, and `prompt()`. It cancels by default.
  - `onFileSelection` handles `<input type="file">`. It cancels by default.
  - Web notifications have no public WebKit API. The location delegate is only called once the app has its own `CLLocationManager` (see AxoIntegration's `LocationAuthorization` and `docs/webkit-gaps.md`).
- **Downloads:** `pool.downloads` is a `DownloadManager` (`@Observable`) holding `DownloadItem`s, newest first, with state, progress, and bytes.
  - **Engines report:** an engine's page asks its delegate for an item when a download starts (`DownloadManager.begin(sourceURL:sourceTabID:cancel:)`), then calls `chooseDestination(suggestedFilename:expectedLength:)`, `reportProgress`, `reportFinished()`, or `reportFailed(_:)` on it. Reports after a download stops are ignored. WebKit's `WKDownload`s are adapted inside `WebKitEngine`.
  - **What downloads:** links with a `download` attribute, main-frame responses WebKit can't display, and responses with `Content-Disposition: attachment`. `pool.startDownload(_:in:)` downloads a URL directly.
  - **Where files go:** the folder passed to `DownloadManager(directory:)`, `~/Downloads` by default, with Finder-style unique names (`file 2.pdf`). Suggested names are sanitized so they can't escape the folder.
  - **Quarantine:** finished files get the quarantine attribute (agent "Axo", type web download, and the source URL for http(s)), so Gatekeeper checks them.
  - `onEnd` reports each download that stops (finished, failed, or cancelled), which the app announces to VoiceOver users.
  - `cancel(_:)` stops a download and removes the partial file. `remove(_:)` and `clearInactive()` edit the list but keep files.
- **Site customizations:** `setSiteCustomizations(_:)` hands per-site CSS and JavaScript to the engine. WebKit turns them into user scripts for every web view. New web views get them right away; live ones get them on their next page load.
  - **One script per site:** each customization gets its own scripts. Each script checks the page's host and steps aside for a more specific customization, so a syntax error in one site's code can't affect another.
  - **CSS:** added at document start, in every frame, in an isolated world (`AxoSiteCustomizations`).
  - **JavaScript:** runs at document end, in the page's world, top frame only.
  - **Page policies:** user scripts aren't subject to a page's Content Security Policy.
  - **Replacing scripts:** Axo adds no other user scripts, so updating live web views replaces all of theirs.
- **Page text** (for translation and summaries), read and changed in an isolated world (`AxoPageText`), so pages can't see or interfere:
  - `pageTextSegments(in:limit:)` returns the page's visible text nodes in order, skipping scripts, styles, code, form fields, and editable areas.
  - `replacePageText(_:in:)` swaps in new texts for those nodes, one each, keeping their surrounding whitespace, and `restorePageText(in:)` puts the originals back.
  - `readablePageText(in:limit:)` returns the page's text as one string, with whitespace collapsed.
- **Screen Time:** each `WebViewContainer` holds an `STWebpageController` above its page.
  - **Usage:** it reports the page's URL (followed through the tab's `WebTabState`) so Screen Time can count usage, keeping each profile's history separate (`profileIdentifier` is the profile ID).
  - **Limits:** when a site is over its limit or blocked by a parent, it shows Screen Time's block screen. Otherwise clicks go straight through to the page.
  - **Turning off recording:** `WebViewPool.reportsScreenTimeUsage` (on by default) is off in tests and UI testing, so test pages never count as the person's usage. Blocking still applies.
- **Fullscreen:** the WebKit engine turns on `WKPreferences.isElementFullscreenEnabled`, which is off by default, so videos and pages can use the Fullscreen API. Picture in picture needs a private preference, so the app turns it on through AxoInspector's `PictureInPicture`.
- **`UserAgent`** sets the user agent for every tab (and, through AxoExtensions, every extension page): WebKit's default plus `Version/<macOS major.minor> Safari/605.1.15`, like Safari. A plain `WKWebView` leaves that out, which breaks sites and extensions that detect the browser from it (Bitwarden's background script fails to start without it).
- **`WebTabState`** (`@Observable`) mirrors a live tab's URL, title, loading state, progress, and back and forward availability, plus `restoringSnapshot`. Get it with `pool.state(for:)`.
- **`WebViewHost`** is the SwiftUI view that mounts a tab's pooled page and reports its visibility to the pool. `WebViewContainer` (`mountedView`) sizes the page's view with its autoresizing mask, not Auto Layout, because the docked Web Inspector shrinks the web view's frame to make room. Constraints would stretch the page back over it.

AxoWeb doesn't touch the database. The app layer connects pool callbacks to `TabStore`.

## Not yet

Download history is in memory only, and interrupted downloads can't be resumed yet. Snapshots live in memory only, so tabs restored after a relaunch have none. A web view that was never laid out (zero size) can't be snapshotted, so it hibernates without a picture.

## Testing

```bash
swift test
```

`WebEngineTests` check the pool's own logic on `FakeEngine`. The other tests load local HTML files with non-persistent data stores and download into temporary folders, so they never touch the network, the user's website data, or `~/Downloads`. Download links in tests use `data:` URLs, because browsers ignore `download` on cross-origin links and every `file:` URL is its own origin.
