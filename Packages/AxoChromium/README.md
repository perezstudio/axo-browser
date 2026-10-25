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
- **`ChromiumPage`** (internal) is the `EnginePage`:
  - It maps `AXOPageDelegate` events to `EnginePageDelegate`: state, loads, focus, link clicks (`AXOLinkModifiers` uses the same bits as `LinkModifiers`), new tabs, permissions, dialogs and file pickers.
  - It reports downloads to the pool's `DownloadItem`s through a `DownloadObserver`.
  - Until the engine supports them (Phase 3): find returns `false`, scripts throw, snapshots and saved history are `nil` (a hibernated tab reloads its URL), and printing prints the view.

## Testing

```bash
swift test
```

The tests run against fake engine classes written in Swift against the same protocols (`FakeEngineClasses.swift`), so they need neither Chromium nor the framework. They're serialized because the fakes keep class-level state, like the real framework. The app's opt-in `ChromiumEngineUITests` covers the real engine.
