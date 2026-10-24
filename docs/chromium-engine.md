# Chromium engine on the Mac

Decided in October 2026: the Mac app moves from WebKit to a Chromium fork. iPhone and iPad stay on WebKit. This document is the design; `docs/PLAN.md` tracks progress.

## Why

Two reasons, both from daily use:

- **Extension gaps.** `WKWebExtension` lacks Chrome-only APIs (`chrome.debugger`, `chrome.offscreen`, `sidePanel`, `identity`, parts of `declarativeNetRequest`), native messaging needs Axo's own host plumbing, and the Chrome Web Store doesn't install into WebKit. Chromium has all of this already (see `docs/webkit-gaps.md` for the gaps hit so far).
- **Site compatibility.** Some sites break or behave differently in WebKit. Chromium is what most sites are tested against.

The trade is the one `docs/PLAN.md` always named: more memory and energy, a larger app, and less of WebKit's native feel, in return for extensions and sites that just work.

## What stays on WebKit

- **iPhone and iPad.** Apple allows other engines on iOS only through BrowserEngineKit, and only in the EU. The iOS app ships through the App Store and keeps `WKWebView`.
- **The Mac, until Chromium is ready.** WebKit stays the Mac's engine, behind the same seam, until Chromium reaches parity (Phase 4 below). It's the fallback while the work is in progress.

So AxoWeb always has two engines, and everything above it must not care which one runs.

## Layers

```
Axo app (SwiftUI, AxoUI, AxoCore…)           never sees an engine type
  └─ AxoWeb: WebViewPool, WebEngine, EnginePage
       ├─ WebKitEngine     iOS and iPad; the Mac until Phase 4
       └─ ChromiumEngine   the Mac ── AxoChromium Swift package
                                       └─ AxoEngine.xcframework   prebuilt, versioned
                                            (Objective-C API, built from the axo-chromium repo)
```

### 1. The seam in AxoWeb

`WebViewPool` keeps its tab-ID API (load, back, forward, find, print, hibernate, permissions, downloads). Inside, it talks to two protocols:

- **`WebEngine`** makes pages for a profile and owns per-profile website data (clear it, delete it) and per-site customizations.
- **`EnginePage`** is one tab's page: its view, URL, title, loading state, navigation, find, snapshot, JavaScript in an isolated world, downloads, printing, and an opaque history value for hibernation. It reports events (page changes, link clicks, new-tab requests, permission requests, dialogs, file pickers, downloads, focus) to a `EnginePageDelegate`, which the pool implements.

Downloads go through `DownloadManager` and `DownloadItem`, which engines drive (choose a destination, report progress, finish, fail), so the downloads list doesn't know which engine made a download.

WebKit-only features stay reachable through `WebKitEngine` and small pool extensions (`liveWebView(for:)`, `dataStore(for:)`, `addWebViewConfigurator(_:)`), used only by AxoExtensions and AxoInspector, which are themselves WebKit only. Nothing in AxoUI uses them.

### 2. `AxoEngine.xcframework`: the swap point

The Swift side never imports Chromium headers. It links one binary framework with a small, stable Objective-C API:

- profiles: create, open, clear data, delete
- pages: create for a profile, get the `NSView`, navigate, events, find, snapshot, print, run a script in an isolated world, save and restore history
- extensions: list, install, enable, remove, toolbar actions, popups, permission prompts
- DevTools: open, close, dock

The `AxoChromium` Swift package wraps that API as a `ChromiumEngine` that conforms to `WebEngine`, and points at the framework with `.binaryTarget(url:checksum:)`.

**Updating Chromium** means rebuilding the framework at the new version, publishing it with the same API, and bumping the version and checksum in `AxoChromium`. No app code changes. When the API itself must change, its version number changes too, and `AxoChromium` checks it at launch.

This also means contributors build Axo without a Chromium checkout (over 100 GB, hours to build).

### 3. The `axo-chromium` repository

A separate repository, because Chromium's tools (`depot_tools`, `gclient`, `gn`, `siso`) and checkout size don't belong next to an Xcode project. It follows the layout Brave uses to keep a fork cheap to update:

| Path | Holds |
| --- | --- |
| `CHROMIUM_VERSION` | The one pinned Chromium release (a full version number, `MAJOR.MINOR.BUILD.PATCH`) |
| `axo/` | All of Axo's C++ and Objective-C++: the framework's API, the profile and page bridge, the hidden tab model, and the UI delegates. Built as its own GN targets. Almost everything lives here. |
| `chromium_src/` | Files that override single Chromium files without patching them |
| `patches/` | Numbered patches to Chromium, each with a header saying why it exists and what would remove it |
| `scripts/` | Fetch, apply patches, build, package the framework and Chromium's helper apps, publish |

Rules that keep updates cheap:

- Prefer `axo/` code, then `chromium_src/` overrides, then GN arguments. A patch is the last resort, and the smaller `patches/` stays, the cheaper each update.
- Track Chrome's **Extended Stable** channel (a new milestone every eight weeks, with security fixes backported) rather than the four-week stable channel, halving the rebases.
- Ship Chromium security releases within days. Those are version bumps that rarely touch patches.
- A CI job builds against Chrome Beta, so breakage shows up a release early.

### Building on `//chrome`, not just `//content`

Electron embeds only Chromium's content layer and its extension support is partial, which would bring back the gaps this move is meant to fix. `chrome.tabs`, Chrome Web Store installs, native messaging, `declarativeNetRequest`, and `sidePanel` live in Chromium's `//chrome` layer, so Axo builds on `//chrome` and replaces Chrome's Views interface with SwiftUI.

## Hard parts

- **The hidden tab model.** Chrome's extension APIs read tabs from `Browser` and `TabStripModel`. `axo/` keeps hidden ones that mirror Axo's windows, Spaces, tabs, splits, and favorites, so `chrome.tabs.query` agrees with the sidebar. This is the largest piece of work and the biggest risk.
- **Chrome's own UI.** Permission bubbles, extension install prompts, autofill, and dialogs are drawn by Chrome's Views code. Each is either routed to SwiftUI through the framework's API or allowed to show as a Chrome popup, decided one at a time. This is where patches tend to grow.
- **Site compatibility needs licenses.** Protected video (Netflix, Spotify) needs Widevine, which needs an agreement with Google; apply early, it takes a while. H.264 and AAC need `proprietary_codecs` and `ffmpeg_branding="Chrome"`, which have their own licensing questions. Safe Browsing needs Google API keys, which never go in the repo.
- **Packaging.** Chromium runs its GPU, renderer, and utility processes from helper apps inside Axo's bundle. Each needs signing, Hardened Runtime, and the JIT entitlements V8 needs. The app grows by roughly 200 MB, and Sparkle updates grow with it.
- **Existing data.** Cookies and website data in WebKit's data stores can't move to Chromium's profiles. Tabs, Spaces, history, and everything else in Axo's database are unaffected.

## What changes per package

| Package | Change |
| --- | --- |
| AxoWeb | Gains the `WebEngine` seam (Phase 0). WebKit moves behind it as `WebKitEngine`. |
| AxoChromium (new) | `ChromiumEngine`, wrapping `AxoEngine.xcframework`. Mac only. |
| AxoExtensions | WebKit only. On the Mac, Chromium's extension system replaces it; the Extensions window and toolbar talk to the engine instead. Kept for a possible iOS extension story. |
| AxoInspector | WebKit only. Chromium's DevTools replace it on the Mac; iOS never uses private API, so it goes away after Phase 4. |
| AxoUI, AxoCore | Engine-neutral already, apart from a few calls Phase 0 removes. |
| AxoPersistence, AxoSync, AxoImport, AxoIntegration | Unchanged. |

Hard rules 2 (the pool owns pages), 4 (private WebKit API), and 6 (one data store per profile) get rewritten for an engine-neutral pool when Chromium lands: one Chromium profile per Axo profile replaces one `WKWebsiteDataStore` per profile.

## Phases

| Phase | Scope | Done when |
| --- | --- | --- |
| **0** | The `WebEngine` seam in AxoWeb, with WebKit behind it, no raw web views in AxoUI, and a fake engine for tests. No Chromium. | Every test passes on the Mac and iOS with `WebKitEngine`, and the pool's own tests run on the fake engine. |
| **1** | `axo-chromium` skeleton: build the pinned Chromium, a minimal framework API (profile, page, view, navigation, events), and `AxoChromium` rendering one tab behind a debug setting. | A page loads in a Chromium tab in Axo. |
| **2** | The hidden tab model and extensions. Bitwarden and uBlock Origin Lite pass `RealExtensionTests`, native messaging works, and the Chrome Web Store installs. | The extensions people use daily work. |
| **3** | Permissions, downloads, dialogs, DevTools, Widevine, notarization, helper apps, Sparkle. Measure launch, memory, and energy against the WebKit build. | Daily-driver parity with the WebKit Mac app. |
| **4** | One full Chromium update through the process above, to prove it. Then Chromium becomes the Mac's engine, and WebKit, AxoExtensions, and AxoInspector leave the Mac. | The Mac ships on Chromium. |

## Open questions

- [ ] Name and hosting of the `axo-chromium` repository, and where CI builds the framework (Chromium needs a large Apple silicon machine)
- [ ] When to apply for a Widevine license
- [ ] Which Chrome UI popups to keep as Views and which to route to SwiftUI
- [ ] Whether to tell people their website data won't carry over, or try importing cookies
