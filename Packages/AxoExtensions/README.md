# AxoExtensions

`WKWebExtensionController` per profile, CRX install, and the `WKWebExtensionTab` and `WKWebExtensionWindow` adapters.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore, AxoWeb (the `AxoExtensions` target); nothing (the `AxoCRX` target)

## Targets

### AxoCRX (standalone, meant to be open sourced early)

No Axo or third-party dependencies.

- **`CRXPackage(_:)`** parses a CRX3 file and verifies it. It reads the protobuf `CrxFileHeader`, finds the RSA proof whose key hashes to the signed `crx_id`, and verifies its RSA-SHA256 signature over `"CRX3 SignedData\0"`, the length, the signed header data, and the archive (Security framework). Other proofs, such as the Chrome Web Store's, are allowed. CRX2 files and ECDSA-only developer signatures are rejected.
  - `extensionID` and `CRXPackage.extensionID(forPublicKey:)` use Chrome's ID scheme: the first 16 bytes of SHA-256 of the key, written in letters a–p.
- **`ZipArchive.extract(_:to:sizeLimit:)`** handles stored and deflate entries (Compression framework). It verifies each entry's CRC-32, refuses paths that escape the destination, symlinks, encrypted entries, and Zip64, and caps the expanded size (512 MB by default).
- **`ExtensionManifest.read(fromExtensionAt:)`** checks `manifest.json` (a byte-order mark is fine): name, version, and manifest version 2 or 3.

### AxoExtensions

- **`ExtensionInstaller(root:)`** installs extensions per profile under `root/<profile ID>/<extension ID>`.
  - `install(crx:for:)` verifies the package, extracts it to a staging folder, checks the manifest, then moves or replaces the installed copy. A failed install leaves nothing behind.
  - `inspectUnpacked(at:)` checks a developer-mode folder, which is used in place with Chrome's path-derived ID.
  - `installedExtensions(for:)` lists installs, and `uninstall(_:for:)` removes them (it never deletes unpacked folders).
- **`InstalledExtension.load()`** creates a `WKWebExtension`, so WebKit validates the files.
- **`ExtensionManager`** (`@MainActor`, `@Observable`) runs extensions.
  - **Controllers:** one `WKWebExtensionController` per profile, with persistent storage keyed by the profile ID (`persistent: false` for tests) and the profile's website data store. It attaches each controller to new web views through `WebViewPool.configureWebView`.
  - **Lifecycle:** `install(crx:for:)`, `installUnpacked(at:for:)`, `setEnabled(_:extensionID:profileID:)`, `uninstall(_:profileID:)`, and `loadExtensions(for:)` keep the files, the database records (`ExtensionStore`), and the loaded contexts in step. `loadErrors` reports extensions that can't load.
  - **Each context:**
    - `uniqueIdentifier` is the Chrome extension ID (so `browser.runtime.id` matches Chrome), and `baseURL` is the stable `webkit-extension://<id>/` (so the extension's storage survives relaunches).
    - `isInspectable` is on.
    - The requested permissions and all requested match patterns are granted, as Chrome does at install. Optional permissions are not granted.

- **Tabs and windows for extensions (`chrome.tabs`, `chrome.windows`):** the app implements `ExtensionBrowsing` (the current profile, the window's tabs, the active tab, open, activate, and close). `ExtensionTab` and `ExtensionWindow` adapt it to `WKWebExtensionTab` and `WKWebExtensionWindow`, with one stable object per tab. Clicking a toolbar button grants `activeTab` for that tab. Only the controller of the profile the window shows sees the window.
  - The app reports events with `tabDidOpen`, `tabDidClose`, `tabDidActivate(_:previous:)`, `tabDidChange`, and `windowDidChangeSpace`.
  - A `WKWebExtensionControllerDelegate` opens tabs for extensions, reports the window, and shows popups.
- **Toolbar:** `toolbarActions(for:tabID:)` returns each loaded extension's title, icon, badge, and enabled state, and is observable through `actionsRevision`. `performAction(extensionID:profileID:tabID:)` clicks the button, and `onPresentPopup` hands WebKit's ready-made `NSPopover` (`action.popupPopover`) to the app to show.

Known WebKit gap: `runtime.onInstalled` doesn't fire (see `docs/webkit-gaps.md`).

- **User agent:** extension popups and background pages use AxoWeb's `UserAgent`, the same Safari-style user agent as tabs.
- **`configureExtensionWebViews`** adjusts the configuration of web views WebKit creates for extensions (popups and background pages). The app uses it to turn on developer tools. Set it before controllers are created.
- **Compatibility (`ExtensionCompatibility`):** extensions installed from a CRX (never unpacked developer folders) get `axo-compat.js`, run before their background code through a wrapper (`axo-background.js`: an ES module importing it and the original worker, `importScripts` for a classic worker, or a first entry in Manifest V2's scripts). It adds what WebKit lacks to the namespaces' shared prototypes (WebKit ignores changes to its namespace objects themselves, and replacing the `chrome` and `browser` globals stops events from reaching the background): a stand-in `chrome.notifications`, `webNavigation` events that never fire, an empty `storage.managed`, and `declarativeNetRequest` rule updates retried without headers WebKit rejects. `apply(to:)` runs each time a packed extension loads, so installs from before it get it too. See `docs/webkit-gaps.md`.
- **Problems:** `problem(for:profileID:)` says why an extension isn't working in plain words: it couldn't load, or its background couldn't start (with the exception that stopped it, not the messages it only logged). The Extensions window shows it.
- **Tabs extensions see:** the window lists the sidebar's tabs, then every other live page of the profile (favorites, Peek, mini windows, other Spaces' open pages). Every page with a web view is announced with `didOpenTab` through the pool's live tab events (`WebViewPool.addLiveTabObserver`), so its content scripts can message the extension; WebKit rejects messages from pages it wasn't told about with "Tab not found".
- **Chrome Web Store:** `WebStoreDownloader` downloads an extension by ID through Google's update service (`downloadURL(for:)`) and checks that it's a signed CRX3 package for that same ID before returning it (`WebStoreError` otherwise). Its fetch is injected, so tests never use the network. `ExtensionManager.prepareWebStoreInstall(_:for:)` downloads and then prepares the install like a `.crx` file.
- **Install prompt:** `prepareInstall(from:for:)` verifies and saves a `.crx` file or an unpacked folder *turned off*, and returns an `InstallSummary` describing what it can do. Then `confirmInstall` turns it on, or `uninstall` removes it if the person declines. Updating an installed extension keeps it on.
- **Site access:** `setSiteAccess(.all / .click, …)` grants the requested sites, or denies them so the extension reaches a page only through `activeTab` when its button is clicked. The choice is saved and reapplied at load.
- **Optional permissions:** when an extension calls `permissions.request`, the controller delegate asks `onPermissionRequest` with a `PermissionRequest` (extension name and plain-language lines). Approvals are saved (`grantedOptional`) and restored at load. `grantedDescription(for:profileID:)` describes what a loaded extension can do now.
- **`PermissionDescriptions`** turns WebKit permission names and match patterns into plain lines ("Read and change your data on all websites", "See your open tabs and their addresses", …), with the most significant first. Quiet permissions such as `storage` and `alarms` are left out.

## Real extensions

uBlock Origin Lite and Bitwarden, the Milestone 3 test targets, install and start in Axo (October 2026: uBOL 2026.930.1227 and Bitwarden 2026.9.3, both MV3):

- **uBlock Origin Lite:** loads with no errors. Its six default filter rulesets are turned on by its manifest and run as content-blocking rules. It doesn't use `runtime.onInstalled`.
- **Bitwarden:** loads, and its background script starts. It needs the Safari-style user agent to recognize the browser. It logs one error from its own fallback for `chrome.notifications`, which WebKit doesn't provide (see `docs/webkit-gaps.md`). It only uses `runtime.onInstalled` to show a welcome page, which Axo misses. Connecting to the Bitwarden desktop app (biometric unlock) needs native messaging, which Axo doesn't support yet.

`RealExtensionTests` checks this, but the `.crx` files aren't in the repo (they're GPL-licensed and large). To run it, download them into a folder. Set `AXO_REAL_EXTENSION_FILES` (`file.crx=chromeID`, comma-separated) to check other extensions; October 2026: 1Password 8.12, Todoist 12.21, Bitwarden, and uBOL all start with no errors through the compatibility script:

```bash
mkdir -p ~/axo-real-extensions
```

```bash
curl -L -o ~/axo-real-extensions/ubol.crx "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0&acceptformat=crx3&x=id%3Dddkjiahejlhfcafbddmgiahcphecmpfh%26uc"
```

```bash
curl -L -o ~/axo-real-extensions/bitwarden.crx "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0&acceptformat=crx3&x=id%3Dnngceckbapebfimnlniiiahkandclblb%26uc"
```

Then run the suite with `AXO_REAL_EXTENSIONS` set. It's skipped otherwise.

```bash
AXO_REAL_EXTENSIONS=~/axo-real-extensions swift test --filter RealExtensionTests
```

It verifies each package's Chrome Web Store signature and ID, installs it, loads its background content (giving up after 20 seconds), and prints what WebKit reports about it.

## Testing

```bash
swift test
```

Content scripts don't run on `file:` pages, so tests serve pages from `LoopbackWebServer` (127.0.0.1 only). The `AxoExtensionsTestSupport` target builds fixtures in code: zip archives (including malicious ones) and CRX3 files signed with freshly generated RSA keys. Its CRC-32 is independent of the code under test. It isn't a product.
