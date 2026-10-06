# WebKit gaps

Limitations in `WKWebView` and `WKWebExtension` that block or shape Axo features. Each entry has what Axo needs, what happens instead, a minimal reproduction, and what Axo does in the meantime, so it can be filed on bugs.webkit.org.

## Web notifications have no public API

- **Found:** October 2026, macOS 27 SDK (Xcode 27).
- **Need:** let sites show notifications (`Notification.requestPermission()`, `new Notification(…)`, the Push API) after the person allows them.
- **What happens:** `WKUIDelegate` has no public method for notification permission, and there's no public way to receive a page's notifications. The WebKit headers in the macOS 27 SDK mention none. Safari uses private WebKit API for this.
- **Reproduction:** in any `WKWebView`, run `Notification.requestPermission().then(console.log)`. No delegate method is called, and the result is never `"granted"`.
- **For now:** Axo doesn't support web notifications. The Milestone 4 item "camera, mic, location, and notification permissions" can't fully land without a public API.

## Geolocation permission delegate needs a `CLLocationManager`

- **Found:** October 2026, macOS 27 SDK (Xcode 27), Axo not sandboxed, Hardened Runtime on. **Worked around** in the same month.
- **Need:** decide geolocation access per site with `webView(_:requestGeolocationPermissionFor:initiatedBy:)`, which is public as of macOS 27.
- **What happens:** if the app has never created a `CLLocationManager`, `navigator.geolocation.getCurrentPosition` never calls the delegate and never settles. Neither callback runs, even with `{ timeout: 2000 }`, and macOS shows no prompt. Once the app creates a `CLLocationManager` and calls `requestWhenInUseAuthorization()`, WebKit calls the delegate right away, even while macOS's answer is still undetermined. This was checked in the signed app with a localhost page. Whether creating the manager is enough without requesting authorization is still unconfirmed. After the first experiment, macOS's answer was no longer undetermined, so the second run couldn't tell.
- **Reproduction:**
  1. Set a `WKUIDelegate` that implements the geolocation method and logs when it's called.
  2. Load a secure-context page (`http://localhost/…`) that runs:
     ```js
     navigator.geolocation.getCurrentPosition(
       () => document.title = "ok",
       (e) => document.title = "error " + e.code,
       { timeout: 2000 })
     ```
  3. Without a `CLLocationManager` in the app, the delegate is never called. With one, plus `requestWhenInUseAuthorization()`, it is called.
- **For now:** the app keeps a `CLLocationManager` from launch (AxoIntegration's `LocationAuthorization`), which doesn't prompt by itself. It calls `requestWhenInUseAuthorization()` after the person allows a site's location request in Axo. If a fresh install shows that WebKit also needs that request before it calls the delegate, Axo would have to request authorization earlier. Check this on a Mac where Axo's location access is undetermined.

## Picture in picture needs a private preference

- **Found:** October 2026, macOS 27 SDK (Xcode 27).
- **Need:** let web videos enter picture in picture from their controls or `requestPictureInPicture()`, as in Safari.
- **What happens:** in `WKWebView` on macOS, `document.pictureInPictureEnabled` is `true`, but `video.webkitSupportsPresentationMode('picture-in-picture')` is `false`, and there's no public setting to change it. (`allowsPictureInPictureMediaPlayback` on `WKWebViewConfiguration` exists only on iOS.) The private `WKPreferences._allowsPictureInPictureMediaPlayback` turns it on.
- **Reproduction:** load a page with `<video src="clip.mov" controls>` in a window and, after `loadedmetadata`, check `video.webkitSupportsPresentationMode('picture-in-picture')`.
- **For now:** AxoInspector's `PictureInPicture.enable(in:)` sets the private preference behind a `responds(to:)` check. Element fullscreen is public (`WKPreferences.isElementFullscreenEnabled`) but off by default, and AxoWeb turns it on.

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
- **For now:** Axo has no workaround. Extensions that only initialize in `onInstalled` may start without their defaults. Tests use top-level background code instead.
- **Impact on the test targets:** small. uBlock Origin Lite doesn't use `onInstalled`; its default rulesets are turned on in its manifest. Bitwarden only uses it to open its welcome page, which doesn't appear.

## `chrome.notifications` isn't supported

- **Found:** October 2026, macOS 27 SDK (Xcode 27), with Bitwarden 2026.9.3.
- **Need:** extensions show system notifications with `chrome.notifications.create` and react to clicks. Bitwarden uses them for alerts such as login requests from another device.
- **What happens:** `WKWebExtension` has no `notifications` API, so `chrome.notifications` is undefined even when the manifest requests the `notifications` permission. Bitwarden checks for it, switches to a fallback that reports "Notification clicked is not supported.", and keeps running. That message then appears in `WKWebExtensionContext.errors`.
- **Reproduction:** load an MV3 extension with `"permissions": ["notifications"]` whose background script runs `console.log(typeof chrome.notifications)`. It logs `undefined`.
- **For now:** extension notifications don't appear. Axo's compatibility script (`ExtensionCompatibility` in AxoExtensions) gives extensions installed from a CRX a stand-in `chrome.notifications`, so code that uses it keeps running. Axo could show real notifications later if WebKit adds a hook for them.
- **Effect on 1Password (8.12, October 2026):** unlike Bitwarden, 1Password reads `chrome.notifications.onClicked` at startup without checking, so its background script stops with `TypeError: undefined is not an object (evaluating 'chrome.notifications.onClicked')` and the extension doesn't work at all.

## `declarativeNetRequest` rejects custom header names

- **Need:** extensions add `modifyHeaders` rules that set their own request headers. Todoist sets `Doist-Platform` on requests to its servers.
- **What happens:** `declarativeNetRequest.updateSessionRules()` (and the dynamic and static rule paths) throws `Rule with id 1 is invalid. The header 'Doist-Platform' is not recognized.` WebKit only accepts a fixed list of header names in `requestHeaders` and `responseHeaders`; Chrome accepts any valid header name. Todoist 12.21 awaits this call at startup, so its background script stops and the extension doesn't work.
- **Reproduction:** load an MV3 extension with `"permissions": ["declarativeNetRequestWithHostAccess"]` and `"host_permissions": ["https://example.com/*"]` whose background script runs `chrome.declarativeNetRequest.updateSessionRules({ addRules: [{ id: 1, priority: 1, action: { type: "modifyHeaders", requestHeaders: [{ header: "X-Custom", operation: "set", value: "1" }] }, condition: { urlFilter: "example.com" } }] })`. It throws instead of adding the rule.
- **For now:** Axo's compatibility script retries `updateSessionRules` and `updateDynamicRules` without the rejected headers (dropping rules left with nothing to change), so such extensions start; the custom headers just aren't sent.

## Missing `webNavigation` events and `storage.managed`

- **Need:** extensions listen for `webNavigation.onCreatedNavigationTarget` (a link opening in a new tab), `onHistoryStateUpdated`, `onReferenceFragmentUpdated`, and `onTabReplaced`, and read `storage.managed` (settings an organization pushes). 1Password uses `onCreatedNavigationTarget` and `storage.managed.onChanged`; Todoist checks `onCreatedNavigationTarget.hasListener`.
- **What happens:** WebKit's `webNavigation` has only the core navigation events, and there's no `storage.managed`. Code that calls `addListener` on them throws `TypeError: undefined is not an object` and, at startup, stops the background script.
- **Reproduction:** in an MV3 background script with the `webNavigation` permission, `console.log(typeof chrome.webNavigation.onCreatedNavigationTarget, typeof chrome.storage.managed)` logs `undefined undefined`.
- **For now:** Axo's compatibility script supplies stand-ins that never fire (and an empty `storage.managed`).

## The `chrome` namespaces can't be patched in place

- **What happens:** WebKit's `chrome` (and `browser`, the same object) silently ignores `Object.defineProperty` for its built-in namespace names, and it can hand out a fresh namespace object (such as `chrome.storage`) at times, so members added to a namespace object can disappear. Each kind of namespace shares one prototype, though, and new members or replacement methods defined there do stick, including on namespace objects WebKit creates later.
- **For Axo:** the compatibility script patches the namespaces' prototypes and holds them for the life of the background.

## Replacing both `chrome` and `browser` silences every event

- **What happens:** WebKit looks up the `browser` or `chrome` global when it delivers an event to a background script. If both have been replaced (for example, with proxies of the originals), nothing is delivered: no `action.onClicked`, no `runtime.onMessage` replies, even for listeners added before the replacement. Replacing just one of them is fine. No error is reported anywhere.
- **Reproduction:** in an MV3 background with an `action` and no popup: `for (const name of ["chrome", "browser"]) Object.defineProperty(globalThis, name, { value: new Proxy(globalThis[name], {}), configurable: true }); chrome.action.onClicked.addListener(() => console.log("clicked"));` Clicking the action logs nothing; drop the loop and it logs.
- **For Axo:** an earlier version of the compatibility script wrapped both globals, so 1Password's toolbar button did nothing and popups couldn't reach their background. The script now leaves both globals alone (see above), and `ExtensionCompatibilityTests` checks that clicks and messages still arrive.

## Content script messages need `didOpenTab`

- **What happens:** a content script's `runtime.sendMessage` fails with `Tab not found` unless the app told the controller about that page's tab with `didOpenTab`. Listing the tab in `WKWebExtensionWindow.tabs(for:)` isn't enough.
- **For Axo:** `ExtensionManager` announces every page with a web view (sidebar tabs, favorites, Peek, mini windows) through the pool's live tab events. Not a WebKit bug, but undocumented.

## Passkeys need a managed entitlement

- **Found:** October 2026, macOS 27 SDK (Xcode 27).
- **Need:** let sites sign in and register with passkeys (WebAuthn `navigator.credentials.get` and `create`), as Safari does.
- **What happens:** in Axo's `WKWebView`, `PublicKeyCredential` exists, but `isUserVerifyingPlatformAuthenticatorAvailable()` and `isConditionalMediationAvailable()` both resolve `false`. `WKWebView` has no public WebAuthn hooks. Apple's API for third-party browsers is `ASAuthorizationWebBrowserPlatformPublicKeyCredentialProvider` and its related classes. It needs the managed entitlement `com.apple.developer.web-browser.public-key-credential`, which Apple grants on request per app ID. With it, the browser handles WebAuthn itself: it checks the origin and relying-party ID, builds the client data, calls AuthenticationServices, and returns the credential to the page. It's unclear whether WebKit would also turn on its own WebAuthn for a `WKWebView` app with that entitlement.
- **Reproduction:** on a secure page (`http://localhost`) in a plain `WKWebView`, run `await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`. It returns `false`.
- **For now:** Axo doesn't support passkeys on websites. Password manager extensions (Bitwarden) still work. The work is waiting on the entitlement request.
