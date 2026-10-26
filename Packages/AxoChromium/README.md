# AxoChromium

The Chromium engine for Axo's Mac app: a `ChromiumEngine` that conforms to AxoWeb's `WebEngine`, so the page pool can run tabs on Chromium instead of WebKit.

Part of [Axo](../../CLAUDE.md). See `docs/chromium-engine.md` for the design and its phases. The engine itself is built by the private `axo-chromium` fork.

**Depends on:** AxoCore, AxoWeb

**Platforms:** macOS 27 only. iPhone and iPad stay on WebKit.

## How it reaches Chromium

Axo never links the engine. The framework is around 500 MB, and only machines that built the fork have it. So:

- **`AxoEngineAPI`** is a header-only target, `include/AxoEngineProtocols.h`. It's an exact copy of the fork's `axo/public/AxoEngineProtocols.h`: Objective-C protocols, marked `NS_SWIFT_UI_ACTOR`, which the framework's classes adopt. Keep the two files identical. `AXO_ENGINE_API_VERSION` says which version the header describes.
- **`ChromiumFramework`** loads the framework from the app's Frameworks folder (`Chromium Framework.framework`, next to Chromium's helper apps) with `dlopen`. `load(from:)` looks the classes up by name and returns `ChromiumEngineClasses`, or a `ChromiumFrameworkError`: not embedded, failed to load, a missing class, or an API version mismatch. `classes(lookingUp:)` is the lookup on its own, for tests.
- **`ChromiumFramework.makeApplication()`** creates `NSApp` as the engine's `AXOApplication`. Chromium requires that class, so it must run before anything else touches `NSApp`. The app does this in its `AxoMain` entry point.

## Public API

- **`ChromiumEngine`** (`@MainActor`, a `WebEngine`):
  - `start()` runs Chromium on a later turn of the main run loop, as a run-loop callout. Chromium's loop runs nested inside that call until the app quits. A main-queue block there would stall the main queue, and the main actor with it.
  - `state` (`notStarted`, `starting`, `ready`, `failed`) and `onStateChange` report progress.
  - `makePage(profileID:)` works before the engine is ready. Those pages show an empty view and remember the URL or history they were asked to load. They attach to Chromium once it is ready; pages closed before then never attach.
  - `clearWebsiteData(for:)` and `removeWebsiteData(for:)` go to the engine's profiles. Deleting profiles isn't supported by the engine yet, so `removeWebsiteData` throws. Before the engine is ready, both do nothing.
  - `setSiteCustomizations(_:)` is ignored until the engine supports them (Phase 3).
- **Windows.** `setWindowPages(_:active:profileID:)` puts the pages into the profile's `AXOWindow`, made on first use, which is what Chrome's extension APIs see as the window. Lists sent before the engine is ready apply once it is. The window's events (a tab Chrome opened, closed, or activated) reach the pool through the engine's `delegate`; a page Chrome opened is wrapped in a new `ChromiumPage` for the pool to adopt. Moves aren't passed on yet: placing an extension's move among Axo's pinned tabs, folders, and splits needs its own design.
- **Extensions** (`ChromiumExtensions.swift`): `extensions(profileID:)`, `setExtension(_:enabled:profileID:)`, `uninstallExtension(_:profileID:)`, `loadUnpackedExtension(at:profileID:)`, `installPackage(at:profileID:)` (a `.crx`, through Chrome's installer, enabled with its permissions; ask the person first), `toolbarButtons(profileID:page:)` (`ChromiumToolbarButton`: title, badge, icon, popup), and `performExtensionAction(_:profileID:page:)`, which returns a `ChromiumExtensionPopup` (its view, title, preferred size, and resize and close callbacks) or `nil` when the extension handled the click. `onExtensionsChange` reports a profile's extension or button changes, and `onExtensionPopupRequest` hands over a popup an extension opened itself (`chrome.action.openPopup`, API version 9). `init`'s `nativeMessagingHostFolders` adds folders to find native messaging hosts in, after Chromium's own (API version 10). Extensions' popup windows reach the delegate as `engine(_:didOpenPopupWindowWith:size:profileID:)` (API version 11). `extensionCommands(profileID:)` and `performExtensionCommand(_:extensionID:profileID:page:)` list and run extensions' keyboard shortcuts, and key presses a page doesn't use go to `ChromiumPage.handleUnusedKeyEvent`, the app's main menu by default (API version 12). `onExtensionPrompt` hands over what Chrome would ask in its own dialogs (`ChromiumExtensionPrompt`: permissions, install, uninstall, screen capture), and `setWindowsActive(_:)` follows the app becoming active (API version 13). Right-clicks reach the page delegate as a `PageContextMenu` (`ChromiumContextMenu`, API version 14). `onExtensionSidePanelOpen` hands over extensions' side panels (`ChromiumExtensionSidePanel`, API version 15). `ChromiumExtension.usesUserScripts` and `userScriptsAllowed`, with `setUserScriptsAllowed(_:extensionID:profileID:)`, are Chrome's Allow User Scripts switch (API version 16). `setBookmarks(_:profileID:)` gives a profile's engine its bookmarks (AxoCore's `BookmarkTree`), once the profile is in use, and `onBookmarkChange` reports extensions' changes as AxoCore's `BookmarkChange` (`ChromiumBookmarks.swift`, API version 17). The engine keeps its own copy of history, for visited links and extensions; `onHistoryChange` reports what changes it without a page visit (`ChromiumHistoryChange`: a visit an extension added, deleted pages, or everything deleted), for Axo's history (API version 18). Clearing website data keeps history; a deletion of a range of visits carries the range (API version 19). `init`'s `isEphemeral` starts the engine for tests (a stand-in keychain and no background requests), and `additionalArguments` passes Chromium switches for debugging (API version 19). Clearing and removing a profile's data wait for the engine to be ready, and a removed profile is never loaded again. Download observers are kept until the download ends, not with their page, since a download outlives its tab. Pages ask for the camera and microphone, files, dialogs, and full screen through the page delegate, and pages they open arrive wrapped as `ChromiumPage`s in an `OpenedPage` (API version 20). All are empty or do nothing until the engine is ready.
- **`ChromiumPage`** (internal) is the `EnginePage`:
  - It maps `AXOPageDelegate` events to `EnginePageDelegate`: state, loads, focus, link clicks (`AXOLinkModifiers` uses the same bits as `LinkModifiers`), new tabs, permissions, dialogs and file pickers.
  - It reports downloads to the pool's `DownloadItem`s through a `DownloadObserver`.
  - Until the engine supports them (Phase 3): find returns `false`, scripts throw, snapshots and saved history are `nil` (a hibernated tab reloads its URL), and printing prints the view.

## Testing

```bash
swift test
```

The tests run against fake engine classes written in Swift against the same protocols, so they need neither Chromium nor the framework. The fakes are the `AxoChromiumTestSupport` product, which depends only on `AxoEngineAPI` so that the app's tests can link it without a second copy of AxoChromium; each test target builds `ChromiumEngineClasses` from them. They're serialized because the fakes keep class-level state, like the real framework. The app's opt-in `ChromiumEngineUITests` covers the real engine.
