# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

Axo is a native, lean, open source web browser for macOS (iPhone and iPad later), inspired by Arc's sidebar and Spaces model. It is built on WebKit and SwiftUI, runs Chrome extensions through `WKWebExtension`, ships built-in DevTools, and integrates deeply with Apple platforms.

The full plan, architecture, and reasoning behind every decision are in `docs/PLAN.md`. Read it before starting any milestone or making an architectural change. Brand assets and guidelines are in `docs/brand/`.

## Stack

- Swift 6 with strict concurrency enabled. No `@unchecked Sendable` or `nonisolated(unsafe)` without a comment explaining why it is safe.
- SwiftUI for browser chrome (windows, sidebar, command bar, settings).
- AppKit `WKWebView` for web content, hosted via `NSViewRepresentable`.
- Minimum deployment target: macOS 27, the latest release, to keep things simple and avoid availability checks. (`WKWebExtension` has been public since macOS 15.4.)
- Storage: SQLite through GRDB, with GRDBQuery for SwiftUI. One database for everything.
- Sync: CloudKit via `CKSyncEngine`.
- Distribution: notarized DMG with Sparkle updates. Not the Mac App Store.

## Project setup

- The Xcode project targets macOS only for now (`SUPPORTED_PLATFORMS = macosx`). iPhone and iPad targets come in Milestone 7.
- The app target uses Swift 6 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and approachable concurrency, so app code is main-actor isolated unless marked otherwise. Packages set their own isolation.
- App Sandbox is off and Hardened Runtime is on, because Axo ships directly rather than through the Mac App Store (see `docs/PLAN.md`).
- `Axo/Axo.entitlements` holds the Hardened Runtime entitlements for camera, microphone, and location, which pages can use after the person allows them. Add others (such as iCloud for AxoSync) there. Each device has a usage description in the target's `INFOPLIST_KEY_*` build settings; keep them accurate and plain.
- The `Axo` scheme is shared (`Axo.xcodeproj/xcshareddata`). `xcuserdata/` is gitignored, so scheme changes must go in the shared scheme.
- No linters or formatters are configured yet.
- `Axo/Info.plist` holds only keys the build settings can't express (the http and https URL types and the HTML document type that make Axo eligible as the default browser). Xcode merges it into the generated Info.plist, and the target's membership exception keeps it out of the copied resources.
- Never call `DefaultBrowser.makeDefault()` or `NSWorkspace.setDefaultApplication` in tests; it changes the user's real default browser. Tests use fakes, and UI testing mode doesn't set `defaultBrowser` at all.
- Open `Axo.xcworkspace`, not the project. The workspace lists the app project and every local package, which Xcode needs to run the package test targets. The `Axo` scheme uses the `Axo.xctestplan` test plan, which covers the app's unit and UI tests and every package's tests. Add new test targets to that plan.
- The app target links AxoUI, AxoCore, AxoWeb, AxoExtensions, AxoImport, AxoIntegration, and AxoSync directly. `BrowserImportBridge` (app target) connects AxoImport to AxoUI's Import sheet. `AppEnvironment` creates the `ExtensionManager` and loads every profile's extensions at launch. `ExtensionBridge` (app target) connects `BrowserModel` and `ExtensionManager`: tabs and events for extensions, plus toolbar buttons and popups for the UI.
- `.accessibilityValue` on a `Label` or `Text` replaces the text VoiceOver reads (SwiftUI `Text` exposes its string as the value). When adding a value for state, also set `.accessibilityLabel` to the title, as `TabRow` and folder rows do.
- `AccessibilityAuditTests` runs `performAccessibilityAudit` on every screen and fails on new issues. Add new screens to it. It ignores contrast, a few containers SwiftUI creates, and tooltip windows (help tags), which appear wherever the pointer rests and sometimes have no text yet; keep that filter narrow and commented. Leave the mouse alone while it runs.
- A split view's tabs show as one sidebar row, the split's first tab in sidebar order (`sidebarRowTab(for:)`). Code that lists sidebar rows or computes positions from them (moves, keyboard order) must skip the other tabs of a split (`isSplitFollower`).
- Selecting a tab starts loading its page, which briefly reports an empty title. Tests that select tabs and then check titles should compare URLs or file names instead.
- Esc (`onExitCommand`) doesn't reach SwiftUI while a web view has keyboard focus. Overlays over pages get Esc from a menu item's `.keyboardShortcut(.escape, modifiers: [])`, enabled only while they're open (see Close Peek).
- A modal overlay (`.accessibilityAddTraits(.isModal)`) hides the rest of the window from the accessibility tree. In UI tests, check the sidebar after it closes. Pinned rows don't have the `tabRow` identifier, because the Pinned section's identifier replaces it.
- App Intents live in AxoIntegration and reach the app through `IntentBridge.current`, not `@Dependency`, which doesn't resolve in unit tests. The app's `AxoAppIntents` (`AppIntentsPackage`) includes `AxoIntegrationIntents`, so the metadata processor extracts the package's intents into the app. Add new intent packages there. Siri and Spotlight phrases (`AxoShortcuts`, an `AppShortcutsProvider`) live in the app target. New window actions go through the `IntentWindow` protocol, which `BrowserIntentWindow` implements.
- iCloud sync (AxoSync) needs the iCloud entitlement, which needs a provisioning profile. Only the Release configuration signs with it (`Axo/Axo-Release.entitlements`, container `iCloud.com.perezstudio.Axo`, plus push notifications); Debug builds and tests use `Axo/Axo.entitlements` and don't sync. Keep the two files' other keys the same. `ICloudSyncController` (app target) only creates a `CloudKitSync` when `CloudKitSync.isAvailable` says the entitlement is there, never in UI testing. Sync tests use `FakeCloud`, never iCloud.
- Synced rows (profiles, Spaces, folders, pinned tabs) are tracked by triggers from migration `v12-sync`. A new column that should sync needs a new migration that updates the triggers, plus `SyncRecord.fieldNames` and `SyncStore`'s mapping. Tables that reference a Space must be handled in `SyncStore.finishFirstSync()`, which moves an untouched Space's rows.
- Screen Time usage recording (`WebViewPool.reportsScreenTimeUsage`) is off in tests and UI testing mode. Screen Time's view sits above each page and must never take clicks unless it's blocking; a `WebViewHostTests` hit test checks that.
- Spotlight indexing and Handoff are off in UI testing mode (the app doesn't start `SpotlightIndexer` and sets `isHandoffEnabled = false`), so test data never reaches the system index or the person's devices. Unit tests use a fake `SpotlightIndex`.
- Tell VoiceOver users about changes they can't see with `BrowserModel.announce`, which tests replace to record messages.
- Menu bar menus are always in the accessibility tree, so a UI test lookup like `app.menuItems["Move to Folder"]` can match both the menu bar and a context menu. Scope context menu lookups to `app.windows.firstMatch`.
- An `accessibilityIdentifier` on a container also replaces its children's identifiers. Add `.accessibilityElement(children: .contain)` to containers whose children need their own identifiers. In UI tests, SwiftUI `Text` exposes its string as the element's value, not its label, and a `.switch` toggle appears as a checkbox.
- Every tab and extension page uses AxoWeb's `UserAgent` (a Safari-style user agent). Don't create web view configurations that skip it; extensions such as Bitwarden detect the browser from it.
- `RealExtensionTests` (AxoExtensions) runs only with `AXO_REAL_EXTENSIONS` pointing at downloaded uBlock Origin Lite and Bitwarden `.crx` files (see the AxoExtensions README). Never commit those files; they're GPL-licensed.
- Import reads other browsers' real data from `~/Library/Application Support` except in UI testing mode, where it reads `AXO_UI_TESTING_IMPORT_ROOT` (a folder of fixtures) or an empty folder. Never let tests read the real Arc or Chrome files.
- The app keeps a `CLLocationManager` (`SystemLocationAuthorization`) from launch, outside UI testing, because WebKit doesn't ask Axo about pages' location requests without one. Never call `requestWhenInUseAuthorization` in tests; use `LocationManaging` fakes.
- Test windows made with `NSWindow(contentRect:…)` must set `isReleasedWhenClosed = false` before `close()`. Otherwise ARC over-releases them and a later test in the same process crashes.
- UI tests can preinstall an unpacked extension by setting `AXO_UI_TESTING_EXTENSION` to its folder (UI testing mode only). The app connects AxoIntegration to AxoUI through small adapters (such as `SystemDefaultBrowser`), so AxoUI doesn't depend on AxoIntegration.
- AxoPersistence, AxoCore, AxoSync, AxoWeb, and AxoUI build for iOS 27 too (iPhone and iPad come in Milestone 7). Keep AppKit out of shared code: use AxoWeb's `PlatformImage`, `PlatformView`, and `LinkModifiers`, AxoUI's `Image(platformImage:)` and `onExitCommandIfAvailable`, and put Mac-only code in `#if os(macOS)`. The Mac chrome in AxoUI is Mac only. Check the iOS build with `xcodebuild -scheme <Package> -destination 'generic/platform=iOS Simulator' build` in the package's folder; Every one of those packages' tests also runs on iOS with `-destination 'platform=iOS Simulator,name=iPhone 17' test`; tests that need AppKit go inside `#if os(macOS)`. iOS caught a real bug this way (snapshots stored at screen scale), so run them when changing shared code.
- The iOS app is the `AxoiOS` target (folder `AxoiOS/`, bundle ID `com.perezstudio.Axo.iOS`, iPhone and iPad), with UI tests in `AxoiOSUITests/`. Its shared `AxoiOS` scheme uses `AxoiOS.xctestplan` (the iOS UI tests plus the shared packages' tests on iOS). It links AxoUI, AxoCore, and AxoWeb, and its chrome is AxoUI's `MobileBrowserView`. It ships through the App Store, so it never links AxoInspector or uses private API. `AXO_UI_TESTING=1` gives it an in-memory database and non-persistent website data, like the Mac.
- Run iOS UI tests on a simulator nothing else is using, with their own build folder: `xcodebuild -workspace Axo.xcworkspace -scheme AxoiOS -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath <scratch folder> test -only-testing:AxoiOSUITests`. Other projects' test runs on a shared simulator, or a lock left by a killed run in the shared DerivedData, made runs hang. XCTest's default handler taps "Allow" on system alerts, so `AxoiOSUITests` adds a monitor that declines them. Failure screenshots and a screen recording are in the result bundle (`xcrun xcresulttool export attachments`).
- Favorites (`Favorite`, `tabStore.favorites`) belong to a profile, not a Space, and share the pool's ID space with tabs: a favorite made from a tab keeps the tab's ID, so its web view carries over. In `BrowserModel`, `selectedTabID` can be a favorite's ID; `selectedTab` is then nil, and `shownTab` is the page showing. Use `shownTab` for page features (address, translation, summaries, Handoff, site settings) and `selectedTab` for things only sidebar tabs can do (pin, move, split, archive).
- `AxoUI` uses `.defaultIsolation(MainActor.self)`. Other packages use the Swift 6 default (nonisolated); AxoWeb marks its types `@MainActor` explicitly.
- SwiftUI has its own `Tab` type. In files that import SwiftUI, write `AxoCore.Tab` for Axo's tab record.
- AxoWeb tests load local HTML files in real `WKWebView`s with `.nonPersistent()` data stores. Never load network URLs in tests. To test a script that only acts on a real site (such as the Chrome Web Store button), load HTML with `loadHTMLString(_:baseURL:)` and that site's URL as the base: the page gets the address and origin without any network request. Downloads from the store go through `WebStoreDownloader`, whose fetch tests replace.
- Extension content scripts don't run on `file:` pages. Tests that need them use `LoopbackWebServer` from `AxoExtensionsTestSupport`, which serves on 127.0.0.1 only.
- UI tests launch the app with the `AXO_UI_TESTING=1` environment variable (in-memory database, non-persistent website data, temporary downloads folder) and the `-ApplePersistenceIgnoreState YES` argument (no restored window state). Pages come from `data:` URLs. Reuse the `launchApp()` helper in `AxoUITests`. Tests that launch the app themselves call `AxoUITests.bringToFront(app)` after `launch()`. Each test case's `tearDown` quits Axo. Otherwise the next launch quits the old instance first, and macOS moving focus afterwards can take focus away from the new one, so keystrokes fail with "not foreground".
- Overlays and fields that need keyboard focus must live inside a split view column (sidebar or page), not on the `NavigationSplitView` itself or in toolbar items; focus doesn't reach those. The command bar is an overlay on the page column for this reason.
- A `TextField` commits its value again on Return, calling its binding's setter with the same text. Setters that reset state (such as the command bar's highlight) must ignore unchanged values.
- The address field lives at the top of the sidebar or, with Settings › General › Navigation bar set to "Above the page", in the page column's toolbar (`NavigationBarPlacement`, read with `@AppStorage`). ⌘L focuses it in either place through `addressFocusRequest`; `testNavigationBarPlacement` proves the toolbar case. (An early attempt on an older macOS couldn't focus a toolbar-hosted `TextField` with `@FocusState`; if that comes back, the test will catch it.)
- The app sets `defaultAppStorage` on its windows and Settings. In UI testing mode that's a separate store emptied at launch, so tests that change settings never touch the person's own. Read new settings with `@AppStorage`, not `UserDefaults.standard`.
- Settings reopens on the last pane used, so UI tests select the pane they need first.
- Never use `XCUIApplication.open(_:)` in UI tests. It hands the link to a new Axo process launched outside testing mode, which opens the person's real database. In UI testing mode, the app has a Testing menu whose "Open Link from Another App" sends `AXO_UI_TESTING_EXTERNAL_URL` (from `AXO_UI_TESTING_SOURCE_APP`) through `openExternalURL`. Use `launchApp(externalLink:)` and `sendExternalLink(in:)`.
- Links from other apps arrive through SwiftUI's `onOpenURL`. The sending app comes from the Apple Event being handled at that moment (`LinkSource`). Don't install a Get URL Apple Event handler: it stops SwiftUI from opening a window when a link launches Axo.
- The browser `WindowGroup` has the ID `"browser"`, so `BrowserWindowOpener` can reopen it through `openWindow`. The Settings scene shows `SettingsView`.
- The app's database lives at `~/Library/Application Support/Axo/Axo.sqlite`. The last Space shown is remembered in `UserDefaults` under `lastSpaceID` (not in UI testing).
- UI tests share user defaults (`com.perezstudio.Axo`) with the person's own Axo, so state like WebKit's "inspector starts docked" carries over. Override what a test depends on with launch arguments (an argument domain doesn't change saved values), as `makeApp()` does for the inspector.
- Never pin pooled web views with Auto Layout constraints. The docked Web Inspector resizes the web view's frame, and constraints made the page draw over the inspector (`WebViewContainer` uses an autoresizing mask). `testWebInspectorOpens` checks the inspector's pixels in a window screenshot, not just the accessibility tree.
- To look at the UI, attach `XCTAttachment(screenshot: app.windows.firstMatch.screenshot())` in a UI test and export it from the result bundle. It captures only Axo's window and doesn't need accessibility access. Don't screen-capture the desktop, which can include the user's other windows. `Axo.xctestplan` turns off XCTest's automatic screen recordings and screenshots (`systemAttachmentLifetime` and `uiTestingScreenshotsLifetime` set to `keepNever`), because on the Mac they capture the whole display, other apps included. Keep it that way; the iOS plan's recordings show only the simulator.
- Printing can't be tested automatically: WebKit print operations hang when run synchronously and need a window to run modally. Test the operation's configuration and check the print sheet by hand.
- Developer tools: the app adds a `WebViewPool` configurator and sets `ExtensionManager.configureExtensionWebViews` to `WebInspector.enableDeveloperTools`, so pages, popups, and background pages can be inspected. The same pool configurator turns on picture in picture (`PictureInPicture.enable`, also private API in AxoInspector). The bridge falls back to `isInspectable` (Safari's Develop menu) when the private inspector isn't available.
- Don't use ⌥ with dead-key letters (E, I, N, U, `) in new shortcuts. On US layouts ⌥N, for example, starts a dead key, and ⌥⌘N never fired, so New Folder uses ⌃⌘N instead. ⌥⌘I (Show Web Inspector, the macOS convention) does work; its UI test proves it.
- macOS window tabbing is off (`NSWindow.allowsAutomaticWindowTabbing = false`), because Axo's tabs live in the sidebar.
- Translation and summaries: the `TranslationSession` that `.translationTask` hands out isn't `Sendable`, so `PageTranslationTask` uses it in a nonisolated function and passes only strings to the main actor. UI tests never translate (macOS may show a language download sheet), and they use `UITestingPageSummarizer` instead of the on-device model, whose answers vary.
- Printing triggers macOS's Local Network prompt (printer discovery), and pages can reach local devices through WebKit's network process. `NSLocalNetworkUsageDescription` explains both. Keep it accurate if network behavior changes.

## Dependencies

Approved third-party dependencies (all MIT-licensed). Ask before adding anything else.

| Package | Version | Used by |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1+ | AxoPersistence (database, migrations), AxoCore (record types), AxoImport (reading Chromium history) |
| [GRDBQuery](https://github.com/groue/GRDBQuery) | 0.11.0+ | AxoUI |

The lockfile is `Axo.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Per-package `Package.resolved` files are gitignored.

## Package layout

The app is split into local Swift packages in `Packages/`. Respect the dependency direction; AxoCore depends on nothing above it. Each package has its own `Package.swift`, `README.md`, and test target (`<Name>Tests`, except AxoUI's, which is `AxoUIPackageTests` so it doesn't clash with the app's `AxoUITests`).

| Package | Owns | Depends on |
| --- | --- | --- |
| AxoUI | SwiftUI chrome, windows, sidebar, command bar, settings, mascot | AxoCore, AxoWeb, GRDBQuery |
| AxoCore | Profiles, Spaces, folders, tabs, windows, TabStore | AxoPersistence, GRDB |
| AxoWeb | Web view pool, `NSViewRepresentable` host, delegates, downloads, permissions, hibernation, Screen Time over each page | AxoCore |
| AxoExtensions | `WKWebExtensionController`, CRX install, tab and window adapters. Its `AxoCRX` target (CRX3 verification, safe zip extraction, manifest checks) has no dependencies so it can be open sourced on its own | AxoCore, AxoWeb |
| AxoInspector | All private WebKit API (Web Inspector, picture in picture) | AxoWeb |
| AxoPersistence | GRDB database, migrations, FTS5 search index | GRDB |
| AxoSync | `CKSyncEngine` sync of profiles, Spaces, folders, and pinned tabs | AxoPersistence, GRDB |
| AxoImport | Importing from Arc (sidebar JSON, Chromium history) and Chrome (bookmarks, history) | AxoCore, GRDB |
| AxoIntegration | Default browser, location, App Intents, Focus filters, Spotlight, on-device page summaries, passkeys | AxoCore |

## Hard rules

These come from deliberate decisions in `docs/PLAN.md`. Do not change them without asking.

1. **Do not use SwiftData or Core Data.** All persistence goes through GRDB in AxoPersistence.
2. **SwiftUI never creates or destroys `WKWebView`s.** The web view pool in AxoWeb owns their lifecycle; SwiftUI only chooses which one is mounted. Do not use SwiftUI's `WebView` or `WebPage`.
3. **Persisted models never hold live runtime state.** GRDB records are plain `Codable` structs (URL, title, sort key, archive date). The pool maps tab IDs to live web views separately.
4. **Private WebKit API lives only in AxoInspector**, behind runtime checks (`responds(to:)` and similar) so a macOS update degrades gracefully instead of crashing. No private API anywhere else.
5. **Ordering uses fractional `sortKey` strings**, never integer indexes, so a move updates one row and sync merges stay clean.
6. **One `WKWebsiteDataStore(forIdentifier:)` per profile.** Never share data stores between profiles.
7. **Schema changes go through `DatabaseMigrator`** as new, versioned migrations. Never edit a migration that has shipped.
8. **No secrets or signing configuration in the repo.** The codebase will be open sourced by the end of 2028.
9. **Keep dependencies minimal and license-compatible** with MPL-2.0 (the likely project license; the final license is still TBD). Ask before adding any new dependency.

## Conventions

- Prefer `async`/`await` and actors over callbacks and locks. UI-facing state is `@MainActor`.
- Database writes happen off the main actor through `DatabasePool`; reads in views use `ValueObservation` or GRDBQuery.
- When a model both writes and observes, treat each `ValueObservation` value as a change signal and re-read current state. A value observed before the model's own write can arrive after it and briefly undo it (this made a folder test flaky).
- Every package has a test target. See "Testing, docs, and verification" below.
- Use SF Symbols, standard AppKit and SwiftUI controls, and system conventions. Axo should feel like Apple could have shipped it.
- Accessibility is not optional: every control needs a label, and every feature must work with the keyboard and VoiceOver.

## Testing, docs, and verification

### Every change ships with tests

- All new or changed behavior, in every package and the app target, ships with tests in the same change. No exceptions for "small" or "UI-only" changes.
- Logic in packages gets unit tests in that package's test target. Pay extra attention to AxoCore, AxoPersistence (including migrations), AxoExtensions (CRX parsing especially), and AxoSync.
- UI flows (sidebar, command bar, Spaces, settings) get UI tests in `AxoUITests`. Use accessibility identifiers, which the accessibility rules above already require.
- Bug fixes start with a test that fails without the fix.
- Use Swift Testing (`import Testing`, `@Test`, `#expect`) for new tests. Keep XCTest for UI tests and performance tests.
- If something really can't be tested automatically (for example a private WebKit API that only works in a signed build), say so and explain how it was checked by hand.

### Every change keeps the docs current

Update docs in the same change as the code they describe. Docs that no longer match the code count as a bug.

- `docs/PLAN.md`: when a milestone's status changes, or when the work departs from the plan or adds to it. Departures from the plan still need approval first (see "Hard rules").
- `CLAUDE.md`: when a convention, command, package, or dependency changes, or when you learn something future sessions need to know.
- `docs/webkit-gaps.md`: when you hit a `WKWebExtension` or WebKit limitation (see "Working style").
- Package READMEs: when a package's public API, setup, or purpose changes. This matters most for the packages meant to be open sourced.
- Doc comments (`///`): on every public and package-level type and function, kept in sync when signatures or behavior change.
- User-facing copy, such as settings, onboarding, and permission text: follow "Brand and copy" below.

### Build once the change is complete

Don't build after every edit. Finish the whole change (code, tests, and docs), then build and verify once:

```bash
xcodebuild -workspace Axo.xcworkspace -scheme Axo -destination 'platform=macOS' build
```

Fix every error and new warning, then rebuild until it is clean. An earlier build is fine when you need compiler feedback to continue, such as checking an unfamiliar API, but it isn't required.

When you change a local package, `swift test` in that package's directory covers its build, so a separate `swift build` isn't needed.

### Tests and checks before calling a change done

Never say a change is done, fixed, or working until all of these pass:

1. The build above succeeds with no new warnings.
2. The full test suite passes:
   ```bash
   xcodebuild -workspace Axo.xcworkspace -scheme Axo -destination 'platform=macOS' test
   ```
   When you change a local package, also run `swift test` in that package's directory.
   The `xcodebuild test` run builds as well, so step 1's build and this run can happen back to back.
3. Any linters or formatters set up for the repo pass.
4. The docs touched by the change are updated, as described above. When you report the change, say which docs you updated, or why none needed updating.

If any of these fail, the change is not done. Report what failed and include the relevant output. Do not skip, disable, or weaken a test to get it to pass.

## Performance

"Lean" is a core promise, so watch these on every change that touches web views, tabs, or search:

- Cold launch time, idle window memory, memory per hibernated tab, energy impact with 20 tabs, and command bar query latency.
- Never keep a `WKWebView` alive for a tab that is not visible past the hibernation timeout.
- Command bar queries must stay fast on every keystroke; use the FTS5 index, not in-memory filtering of history.

## Brand and copy

- Colors: Raspberry `#9B2A5C`, Blush `#FFEEF3`, Axolotl Pink `#FF9EC2`, Ink `#1C1B1F`, Stone `#9A9A9E`, Paper `#F4EEF1`. Pink is an accent in the UI, never a large surface that competes with web pages.
- In-app UI text uses the system font (SF Pro). Nunito is for marketing and the wordmark only.
- Logo and icon files: `docs/brand/axo-logo.svg` (full color), `docs/brand/axo-logo-mono.svg` (single color, `currentColor`), `docs/brand/axo-app-icon.svg` (app icon source).
- The Axo character (happy, sleepy, surprised) appears only in empty and status states, never in settings or permission prompts.
- Voice: warm, not cutesy. Friendly in onboarding and empty states; plain and direct in errors, privacy, and permissions.

## Working style

- Follow the milestone order in `docs/PLAN.md`. Each milestone should be usable as a daily driver before starting the next.
- When a `WKWebExtension` limitation blocks a feature, note it in `docs/webkit-gaps.md` with a minimal reproduction, so it can be filed on bugs.webkit.org.
- Keep the open-sourceable packages (CRX installer, WebExtension tab and window adapters, hibernation manager) free of app-specific dependencies.
- When unsure about a decision the plan doesn't cover, ask rather than guess.
