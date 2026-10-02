# AxoUI

SwiftUI browser chrome: windows, sidebar, command bar, settings, and the mascot.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore, AxoWeb, GRDBQuery

## Public API

- **`BrowserWindow(model:)`**: the window. The sidebar has the address field at the top (like Arc) and the Space's tabs below. Tabs can be dragged to reorder and closed from the context menu. The toolbar has back, forward, reload/stop, and New Tab. A loading bar runs along the top of the page.
- **`BrowserModel`** (`@Observable`): the window's state. It holds the Space, its tabs (kept current through `TabStore.observeTabs(in:)`), the selected tab, and the selected tab's `WebTabState`. It connects `WebViewPool` callbacks to `TabStore`, so titles and URLs persist and `target="_blank"` links open as a new tab after their source.
- **`BrowserCommands`**: menu items and shortcuts. ⌘T new tab, ⌘L open location, ⌘W close tab, ⌘R reload, ⌘[ back, ⌘] forward. They reach the focused window's model through `FocusedValues.browserModel`.
- **`AddressInput`**: turns typed text into a URL. Text with a scheme loads as is, `example.com` gets `https://`, local hosts (`localhost`, `127.0.0.1`, `*.localhost`, `*.test`) get `http://`, and anything else becomes a search. The search engine is a DuckDuckGo placeholder until settings exist.

AxoUI uses `.defaultIsolation(MainActor.self)`. Mark pure logic such as `AddressInput` `nonisolated`.

## Testing

```bash
swift test
```

Model tests use an in-memory `TabStore`, non-persistent data stores, and local HTML files. UI flows are tested in the app's `AxoUITests` target.
