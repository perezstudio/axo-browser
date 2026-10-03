# AxoIntegration

App Intents, Focus filters, Handoff, Spotlight, passkeys, Screen Time, and Translation.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore

## Public API

- **`DefaultBrowser`** (`@MainActor`): `isDefault` says whether Axo handles http and https links, and `makeDefault()` asks macOS to make Axo the default for both, plus HTML files. macOS confirms the change in its own dialog, so call it only when the person chooses to. The `NSWorkspace` calls are injected, and tests use fakes so they never change the real default browser.

The rest of this package (App Intents, Focus filters, Handoff, Spotlight, passkeys, Screen Time, Translation) comes in Milestone 6.

## Testing

```bash
swift test
```
