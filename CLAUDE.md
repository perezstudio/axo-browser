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
- No entitlements file yet. Add one when a capability needs it, such as iCloud for AxoSync.
- The `Axo` scheme is shared (`Axo.xcodeproj/xcshareddata`). `xcuserdata/` is gitignored, so scheme changes must go in the shared scheme.
- No linters or formatters are configured yet.
- Open `Axo.xcworkspace`, not the project. The workspace lists the app project and every local package, which Xcode needs to run the package test targets. The `Axo` scheme uses the `Axo.xctestplan` test plan, which covers the app's unit and UI tests and every package's tests. Add new test targets to that plan.
- The app target links only `AxoUI`; other packages come in through it or get linked when the app needs them directly.
- `AxoUI` uses `.defaultIsolation(MainActor.self)`. Other packages use the Swift 6 default (nonisolated).

## Dependencies

Approved third-party dependencies (all MIT-licensed). Ask before adding anything else.

| Package | Version | Used by |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1+ | AxoPersistence |
| [GRDBQuery](https://github.com/groue/GRDBQuery) | 0.11.0+ | AxoUI |

The lockfile is `Axo.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Per-package `Package.resolved` files are gitignored.

## Package layout

The app is split into local Swift packages in `Packages/`. Respect the dependency direction; AxoCore depends on nothing above it. Each package has its own `Package.swift`, `README.md`, and test target (`<Name>Tests`, except AxoUI's, which is `AxoUIPackageTests` so it doesn't clash with the app's `AxoUITests`).

| Package | Owns | Depends on |
| --- | --- | --- |
| AxoUI | SwiftUI chrome, windows, sidebar, command bar, settings, mascot | AxoCore, AxoWeb, GRDBQuery |
| AxoCore | Profiles, Spaces, folders, tabs, windows, TabStore | AxoPersistence |
| AxoWeb | Web view pool, `NSViewRepresentable` host, delegates, downloads, permissions, hibernation | AxoCore |
| AxoExtensions | `WKWebExtensionController`, CRX install, tab and window adapters | AxoCore, AxoWeb |
| AxoInspector | All private Web Inspector API | AxoWeb |
| AxoPersistence | GRDB database, migrations, FTS5 search index | GRDB |
| AxoSync | `CKSyncEngine` mapping for Spaces, folders, pinned tabs | AxoPersistence |
| AxoIntegration | App Intents, Focus filters, Handoff, Spotlight, passkeys, Screen Time, Translation | AxoCore |

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
