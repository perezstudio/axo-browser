# AxoIntegration

Default browser, location services, App Intents (Focus filters and Shortcuts actions), Focus filters, Handoff, Spotlight, passkeys, Screen Time, and Translation.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore

## Public API

- **`DefaultBrowser`** (`@MainActor`): `isDefault` says whether Axo handles http and https links, and `makeDefault()` asks macOS to make Axo the default for both, plus HTML files. macOS confirms the change in its own dialog, so call it only when the person chooses to. The `NSWorkspace` calls are injected, and tests use fakes so they never change the real default browser.

- **`LocationAuthorization`** (`@MainActor`) keeps a `CLLocationManager` for the app's lifetime. WebKit doesn't call the geolocation delegate until the app has one. `requestIfNeeded()` asks macOS for location access only while it hasn't asked before. Axo calls it after the person allows a site's location request, so the macOS prompt follows something they chose. The manager is injected (`LocationManaging`), so tests never prompt.

- **Focus filters:** `SpaceFocusFilter` (a `SetFocusFilterIntent`) shows a chosen Space while a Focus is on. When the Focus ends, the system runs it again with no Space, and Axo goes back to the Space it showed before.
  - **Spaces for the system:** `SpaceEntity` and `SpaceQuery` (find by ID, by name, or suggested in sidebar order) expose Spaces to Focus and Shortcuts.
  - **`IntentBridge.current`:** the app sets it at launch with its store and an `IntentWindow`, which the app implements over its window model. Intents throw `IntentBridgeError.notReady` without it. App Intents' `@Dependency` only resolves inside a real intent run, so unit tests couldn't use it.
  - **Registering:** `AxoIntegrationIntents` is the package's `AppIntentsPackage`. The app lists it in its own package (`AxoAppIntents`), so the intents' metadata ships in the app.

- **Shortcuts actions** (App Intents). `TabEntity` and `TabQuery` find tabs by ID, or by title and address across Spaces.
  - **Open in Axo** opens a URL, optionally in a Space.
  - **Show Space** switches to a Space.
  - **Find Tabs** returns matching tabs from every Space.
  - **Show Tab** jumps to a tab.
  - **Get Current Tab** returns the tab on screen.
  - **Save Tab to Space** copies the current page into a Space, pinned by default.
  - **Opening Axo:** actions that change the window set `openAppWhenRun`. Failures throw `IntentBridgeError` with plain messages.

The rest of this package (App Intents, Focus filters, Handoff, Spotlight, passkeys, Screen Time, Translation) comes in Milestone 6.

## Testing

```bash
swift test
```
