# AxoUI

SwiftUI browser chrome: windows, sidebar, command bar, settings, and the mascot.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore, AxoWeb, GRDBQuery

## Public API

- **`BrowserWindow(model:)`**: the window. The sidebar has the address field at the top (like Arc) and the Space's tabs below. Rows show the site's favicon, or a globe when there isn't one. Tabs can be dragged to reorder and closed from the context menu. The toolbar has back, forward, reload/stop, and New Tab, plus a Downloads button once there's a download. It opens a popover with progress, Cancel, Show in Finder, and Clear. A find bar opens above the page (it searches as you type, with next, previous, and Done), a loading bar runs along the top of the page, and a tab waking from hibernation shows its snapshot until the page reloads.
- **Command bar (⌘T, the + button, and the empty state):** a panel over the page lists, in order, "Go to…" or "Search for…" for the typed text, matching open tabs in this Space (pinned ones included; Axo has no separate bookmarks), matching actions, then history from the FTS5 index (skipping pages already open). ↑ and ↓ move the highlight, Return runs it, and Esc closes. `CommandRanking` builds the rows; `BrowserModel` holds `commandQuery`, `commandResults`, and `commandSelection`, and runs them. Page changes record history: a new URL counts as a visit, a later title only updates it.
- **Developer tools:** the Develop menu has Show Web Inspector (⌥⌘I, which opens or closes it) and Show JavaScript Console (⌥⌘C). The Extensions window has Inspect Background Page. `developerTools` (a `DeveloperToolsProviding`) is supplied by the app from AxoInspector. When the built-in inspector isn't available, Axo suggests Safari's Develop menu.
- **Installing and managing extensions:** File › Install Extension… opens a `.crx` file or an unpacked folder, and an install prompt ("Add “Name”?" with what it can do) adds it or cancels. View › Show Extensions (⇧⌘E) lists this Space's profile's extensions, with an on/off switch, site access ("On all requested sites" or "Only when you click it"), what each can do, load errors, and Remove. Requests for more access appear in the page prompt queue as "Allow “Name” more access?". `extensionManagement` (an `ExtensionManaging`) is supplied by the app.
- **Extensions:** `extensionToolbar` (an `ExtensionToolbarProviding`, supplied by the app from AxoExtensions) puts extension buttons in the toolbar, each with its icon and badge. VoiceOver reads the badge too. `presentExtensionPopup(_:extensionID:)` shows WebKit's popover under the button, through a `PopoverAnchor`. `onTabEvent` reports `TabEvent`s (opened, closed, activated, changed, Space changed) for the app to forward to extensions. Closing a pinned tab isn't a close, since the tab stays.
- **Default browser and incoming links:** `BrowserModel.openExternalURL(_:)` opens a link from another app as a new tab in the current Space, and links that arrive during launch open once the window is ready. `defaultBrowser` (a `DefaultBrowserSetting`, supplied by the app from AxoIntegration) feeds `isDefaultBrowser` and `makeDefaultBrowser()`. If the person declines macOS's dialog, nothing else is shown. The Axo menu and the command bar offer "Make Axo Your Default Browser" only when it isn't already the default.
- **Split view:**
  - **Making one:** Add Split View (⌃⇧=, Tabs menu, or the command bar) opens the command bar to pick an open tab or a page to show next to the current tab. A tab's context menu also has "Add to Split View".
  - **Sidebar:** the split is one row with each tab's icon and their titles. VoiceOver reads it as "Split view: …".
  - **Page column:** shows the panes side by side or stacked (`HSplitView` / `VSplitView`, resizable), with an accent outline on the focused pane. Clicking a pane focuses it (`WebViewPool.onWebViewFocus`), and the toolbar and address field follow it.
  - **Commands:** Remove Tab from Split View, Separate Split View, and Stack Panes / Show Panes Side by Side. Closing a pane keeps the rest of the split.
  - **Model:** `selectedSplit`, `panes(of:)`, `addToSplit`, `beginSplitWithNewTab`, and `sidebarRowTab(for:)`, which gives the tab whose row stands for a split.
- **Keyboard and VoiceOver:** everything the sidebar's mouse gestures and context menus do has a menu command, and the commands act on the selected sidebar row (`selectedSidebarItem`). Folder rows are selectable (`selectedFolderID`); selecting one keeps the current page showing.
  - **Model:** `KeyboardAccess.swift` has `selectSidebarItem`, `selectTab(offsetBy:)` (visible order, skipping collapsed folders), `togglePinSelectedTab`, `moveSelectedItem(by:)` and `moveSelectedItem(toFolder:)`, `renameSelectedFolder`, `deleteSelectedFolder`, `beginNewFolder`, `beginRenameSpace`, `beginDeleteSpace`, and `focusPage()`. `focusPage()` returns focus to the page after the command bar, find bar, or address field.
  - **VoiceOver:**
    - Rows have Move Up and Move Down actions, and folders have Expand and Collapse.
    - Command bar rows have a default action, and the bar is modal.
    - Download rows offer Cancel and Show in Finder as actions.
    - Sheets name themselves with a header.
    - Esc closes the find bar from any of its controls, and closes the Archived Tabs and Extensions sheets.
  - **Announcements:** `announce` (replaceable in tests) speaks:
    - closing, reopening, pinning, moving, and reordering tabs
    - switching and deleting Spaces
    - the highlighted command bar row
    - "No matches"
    - downloads finishing or failing
    - import results
- **Site Settings:** a button beside the address field (and View › Site Settings…) opens a popover for the current site, with Camera, Microphone, and Location each set to Ask, Allow, or Don't Allow, plus Reset. `BrowserModel` backs the pool's `permissionStore` with AxoCore's `SitePermissionStore` (`SitePermissionAdapter`), so answers survive restarts. A camera-and-microphone request saves an answer for each. `locationAuthorization` (a `LocationAuthorizing`, from AxoIntegration) asks macOS for location access the first time the person allows a site.
- **Importing:** File › Import from Another Browser… and the command bar open the Import sheet. It lists the browsers found (Arc, then each Chrome profile), shows what each has ("5 Spaces, with 141 pinned tabs", "1,273 pages of history"), lets the person turn parts off (Arc's Spaces can't be, since they're the import), notes that logins aren't imported, and reports what was imported. `browserImporter` (a `BrowserImporting`, supplied by the app from AxoImport) does the work. `ImportSession` holds the sheet's state, and `ImportCounts` describes parts in plain language.
- **Folders:** the Pinned section is a tree of expandable folders (expanded state is saved) and pinned tabs, reorderable at each level. Tab and folder context menus offer "Move to Folder" (indented by depth, with "New Folder…" and "Pinned (No Folder)"). Folders also have New Folder Inside, Rename, and Delete, which moves the contents up a level. ⌃⌘N creates a folder. `BrowserModel.pinnedTree` builds the tree; tabs whose folder is missing show at the top level.
- **Pinned tabs and archive:** the sidebar shows a Pinned section above the Space's other tabs, each reorderable on its own. Context menus pin and unpin, and for pinned tabs offer "Go to Pinned Page" and "Pin This Page Instead". ⌘W archives an unpinned tab; on a pinned tab it unloads the tab and returns it to its home page. ⇧⌘T reopens the last closed tab, and ⇧⌘A shows the Space's archived tabs to restore. Unpinned tabs not shown for `archiveAfter` (12 hours) archive automatically, checked at launch and hourly.
- **Spaces:** a switcher at the bottom of the sidebar shows each Space's initial, with the current one filled, plus a button for a new Space. Each Space has a context menu to rename or delete it. The New Space sheet shares the current profile by default, or creates a separate profile with its own cookies and website data. ⌃1–⌃9 and ⌥⌘← / ⌥⌘→ switch Spaces (Spaces menu).
- **`BrowserModel`** (`@Observable`): the window's state. It holds every Space and the shown one (`selectSpace`, `createSpace(name:newProfileName:)`, `renameSpace`, `deleteSpace`; each Space remembers its selected tab, and `initialSpaceID` and `onSpaceChange` let the app reopen the last Space), its tabs (kept current through `TabStore.observeTabs(in:)`), the selected tab, and the selected tab's `WebTabState`. It connects `WebViewPool` callbacks to `TabStore`, so titles, URLs, and favicons persist and `target="_blank"` links open as a new tab after their source. `favicon(for:)` returns a tab's icon; icons load from the database for the sidebar's hosts, each host once.
- **Page prompts:** permission requests and JavaScript dialogs show one at a time as alerts that name the asking site ("Allow “meet.example.com” to use your camera?", "example.com says"). File inputs open an Open panel as a sheet. Closing a tab denies or cancels its pending prompts. `BrowserModel.currentPrompt`, `answerPermission(_:)`, and `answerDialog(_:)` drive them.
- **`BrowserCommands`**: menu items and shortcuts. ⌘T new tab (command bar), ⌘L open location, ⌃⌘N new folder (inside the selected folder, if one is), ⌘W close tab (or the window when no tab is open), ⌘P print, ⌘F find, ⌘G and ⇧⌘G find next and previous, ⌘R reload, ⌘[ back, ⌘] forward, ⌥⌘L show or hide downloads. The **Tabs** menu has Next and Previous Tab (⌥⌘↓ and ⌥⌘↑), Pin or Unpin Tab (⌃⌘P), Go to Pinned Page, Pin This Page Instead, Move to Folder, Move Up and Move Down (⌥⇧⌘↑ and ⌥⇧⌘↓), Rename Folder…, Delete Folder, and Extension Buttons. The **Spaces** menu has New Space…, Rename Space…, and Delete Space…, plus switching. The app adds `SidebarCommands` (⌃⌘S). They reach the focused window's model through `FocusedValues.browserModel`.
- **`AddressInput`**: turns typed text into a URL. Text with a scheme loads as is, `example.com` gets `https://`, local hosts (`localhost`, `127.0.0.1`, `*.localhost`, `*.test`) get `http://`, and anything else becomes a search. The search engine is a DuckDuckGo placeholder until settings exist.

AxoUI uses `.defaultIsolation(MainActor.self)`. Mark pure logic such as `AddressInput` `nonisolated`.

## Testing

```bash
swift test
```

Model tests use an in-memory `TabStore`, non-persistent data stores, and local HTML files. UI flows are tested in the app's `AxoUITests` target.
