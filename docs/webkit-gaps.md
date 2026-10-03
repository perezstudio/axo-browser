# WebKit gaps

Limitations in `WKWebView` and `WKWebExtension` that block or shape Axo features. Each entry has what Axo needs, what happens instead, a minimal reproduction, and what Axo does in the meantime, so it can be filed on bugs.webkit.org.

## Web notifications have no public API

- **Found:** October 2026, macOS 27 SDK (Xcode 27).
- **Need:** let sites show notifications (`Notification.requestPermission()`, `new Notification(…)`, the Push API) after the person allows them.
- **What happens:** `WKUIDelegate` has no public method for notification permission, and there's no public way to receive a page's notifications. The WebKit headers in the macOS 27 SDK mention none. Safari uses private WebKit API for this.
- **Reproduction:** in any `WKWebView`, run `Notification.requestPermission().then(console.log)`. No delegate method is called, and the result is never `"granted"`.
- **For now:** Axo doesn't support web notifications. The Milestone 4 item "camera, mic, location, and notification permissions" can't fully land without a public API.

## Geolocation permission delegate isn't called

- **Found:** October 2026, macOS 27 SDK (Xcode 27), Axo not sandboxed, Hardened Runtime on.
- **Need:** decide geolocation access per site with `webView(_:requestGeolocationPermissionFor:initiatedBy:)`, which is public as of macOS 27.
- **What happens:** `navigator.geolocation.getCurrentPosition` never calls the delegate and never settles. Neither the success nor the error callback runs, even with `{ timeout: 2000 }`, and macOS shows no location prompt. This happens in a `swift test` process and in the signed app, which has `NSLocationUsageDescription`, `NSLocationWhenInUseUsageDescription`, and the `com.apple.security.personal-information.location` entitlement.
- **Unconfirmed guess:** WebKit may wait for Core Location authorization that only the app can request, before it consults the delegate.
- **Reproduction:**
  1. Set a `WKUIDelegate` that implements the geolocation method and logs when it's called.
  2. Load a secure-context page (`http://localhost/…` or `file:`) that runs:
     ```js
     navigator.geolocation.getCurrentPosition(
       () => document.title = "ok",
       (e) => document.title = "error " + e.code,
       { timeout: 2000 })
     ```
  3. The delegate is never called and the title never changes.
- **For now:** `WebViewPool` implements the delegate and remembers answers per site. That logic is unit tested through `decidePermission`. Next step is to check whether requesting Core Location authorization from the app changes the behavior; if not, file a WebKit bug.

## `runtime.onInstalled` doesn't fire

- **Found:** October 2026, macOS 27 SDK (Xcode 27).
- **Need:** extensions do first-run setup in `chrome.runtime.onInstalled` (default settings, welcome pages, filter lists), as Chrome fires it when an extension is installed or updated.
- **What happens:** after `WKWebExtensionController.load(_:)`, the background service worker starts and `runtime.onStartup` fires, but `runtime.onInstalled` never does. This holds with persistent and non-persistent controller configurations, with and without a custom `uniqueIdentifier` and `baseURL`, and after `loadBackgroundContent`.
- **Reproduction:**
  1. Create an MV3 extension with `"permissions": ["tabs"]`, a `background.service_worker`, and this background script:
     ```js
     chrome.runtime.onInstalled.addListener(d => chrome.tabs.create({ url: "https://example.com/installed-" + d.reason }));
     chrome.runtime.onStartup.addListener(() => chrome.tabs.create({ url: "https://example.com/startup" }));
     ```
  2. Load it into a new `WKWebExtensionController(configuration: .nonPersistent())` whose delegate records `openNewTabUsing` calls, granting the requested permissions.
  3. Only `…/startup` is requested; `…/installed-install` never is.
- **For now:** Axo has no workaround. Extensions that only initialize in `onInstalled` may start without their defaults. Tests use top-level background code instead. Check real extensions (uBlock Origin Lite, Bitwarden) for impact in the test-targets work.

