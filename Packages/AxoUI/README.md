# AxoUI

SwiftUI browser chrome: windows, sidebar, command bar, settings, and the mascot.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore, AxoWeb, GRDBQuery

## Public API

- **`BrowserWindow(model:)`**: the window. The sidebar has the address field at the top (like Arc) and the Space's tabs below. Rows show the site's favicon, or a globe when there isn't one. Tabs can be dragged to reorder and closed from the context menu. The toolbar has back, forward, reload/stop, and New Tab, plus a Downloads button once there's a download. It opens a popover with progress, Cancel, Show in Finder, and Clear. A find bar opens above the page (it searches as you type, with next, previous, and Done), a loading bar runs along the top of the page, and a tab waking from hibernation shows its snapshot until the page reloads.
- **Pinned tabs and archive:** the sidebar shows a Pinned section above the Space's other tabs, each reorderable on its own. Context menus pin and unpin, and for pinned tabs offer "Go to Pinned Page" and "Pin This Page Instead". ⌘W archives an unpinned tab; on a pinned tab it unloads the tab and returns it to its home page. ⇧⌘T reopens the last closed tab, and ⇧⌘A shows the Space's archived tabs to restore. Unpinned tabs not shown for `archiveAfter` (12 hours) archive automatically, checked at launch and hourly.
- **Spaces:** a switcher at the bottom of the sidebar shows each Space's initial, with the current one filled, plus a button for a new Space. Each Space has a context menu to rename or delete it. The New Space sheet shares the current profile by default, or creates a separate profile with its own cookies and website data. ⌃1–⌃9 and ⌥⌘← / ⌥⌘→ switch Spaces (Spaces menu).
- **`BrowserModel`** (`@Observable`): the window's state. It holds every Space and the shown one (`selectSpace`, `createSpace(name:newProfileName:)`, `renameSpace`, `deleteSpace`; each Space remembers its selected tab, and `initialSpaceID` and `onSpaceChange` let the app reopen the last Space), its tabs (kept current through `TabStore.observeTabs(in:)`), the selected tab, and the selected tab's `WebTabState`. It connects `WebViewPool` callbacks to `TabStore`, so titles, URLs, and favicons persist and `target="_blank"` links open as a new tab after their source. `favicon(for:)` returns a tab's icon; icons load from the database for the sidebar's hosts, each host once.
- **Page prompts:** permission requests and JavaScript dialogs show one at a time as alerts that name the asking site ("Allow “meet.example.com” to use your camera?", "example.com says"). File inputs open an Open panel as a sheet. Closing a tab denies or cancels its pending prompts. `BrowserModel.currentPrompt`, `answerPermission(_:)`, and `answerDialog(_:)` drive them.
- **`BrowserCommands`**: menu items and shortcuts. ⌘T new tab, ⌘L open location, ⌘W close tab (or the window when no tab is open), ⌘P print, ⌘F find, ⌘G and ⇧⌘G find next and previous, ⌘R reload, ⌘[ back, ⌘] forward, ⌥⌘L show downloads. They reach the focused window's model through `FocusedValues.browserModel`.
- **`AddressInput`**: turns typed text into a URL. Text with a scheme loads as is, `example.com` gets `https://`, local hosts (`localhost`, `127.0.0.1`, `*.localhost`, `*.test`) get `http://`, and anything else becomes a search. The search engine is a DuckDuckGo placeholder until settings exist.

AxoUI uses `.defaultIsolation(MainActor.self)`. Mark pure logic such as `AddressInput` `nonisolated`.

## Testing

```bash
swift test
```

Model tests use an in-memory `TabStore`, non-persistent data stores, and local HTML files. UI flows are tested in the app's `AxoUITests` target.
