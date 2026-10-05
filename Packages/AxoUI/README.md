# AxoUI

SwiftUI browser chrome: windows, sidebar, command bar, settings, and the mascot.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore, AxoWeb, GRDBQuery

**Platforms:** macOS 27 and iOS 27. `BrowserModel` and its logic (tabs, Spaces, folders, splits, the command bar, translation, and so on) are shared. The Mac chrome (`BrowserWindow`, the sidebar, toolbar, commands, Settings, Downloads, the Extensions window, and mini windows) is inside `#if os(macOS)`; iPhone and iPad get their own chrome. Printing and the file chooser are Mac only, and Print Page isn't offered on iOS. The model tests run on both platforms (the Downloads row tests are Mac only).

## Public API

- **`BrowserWindow(model:)`**: the window. The sidebar has the address field at the top (like Arc) and the Space's tabs below. Rows show the site's favicon, or a globe when there isn't one. Tabs can be dragged to reorder and closed from the context menu. The toolbar has back, forward, reload/stop, and New Tab, plus a Downloads button once there's a download. It opens a popover with progress, Cancel, Show in Finder, and Clear. A find bar opens above the page (it searches as you type, with next, previous, and Done), a loading bar runs along the top of the page, and a tab waking from hibernation shows its snapshot until the page reloads.
- **Command bar (⌘T, the + button, and the empty state):** a panel over the page lists, in order, "Go to…" or "Search for…" for the typed text, matching open tabs in this Space (pinned ones included; Axo has no separate bookmarks), matching actions, then history from the FTS5 index (skipping pages already open). ↑ and ↓ move the highlight, Return runs it, and Esc closes. `CommandRanking` builds the rows; `BrowserModel` holds `commandQuery`, `commandResults`, and `commandSelection`, and runs them. Page changes record history: a new URL counts as a visit, a later title only updates it.
- **Developer tools:** the Develop menu has Show Web Inspector (⌥⌘I, which opens or closes it) and Show JavaScript Console (⌥⌘C). The Extensions window has Inspect Background Page. `developerTools` (a `DeveloperToolsProviding`) is supplied by the app from AxoInspector. When the built-in inspector isn't available, Axo suggests Safari's Develop menu.
- **Installing and managing extensions:** File › Install Extension… opens a `.crx` file or an unpacked folder, and an install prompt ("Add “Name”?" with what it can do) adds it or cancels. View › Show Extensions (⇧⌘E) lists this Space's profile's extensions, with an on/off switch, site access ("On all requested sites" or "Only when you click it"), what each can do, load errors, and Remove. Requests for more access appear in the page prompt queue as "Allow “Name” more access?". `extensionManagement` (an `ExtensionManaging`) is supplied by the app.
- **Extensions:** `extensionToolbar` (an `ExtensionToolbarProviding`, supplied by the app from AxoExtensions) puts extension buttons in the toolbar, each with its icon and badge. VoiceOver reads the badge too. `presentExtensionPopup(_:extensionID:)` shows WebKit's popover under the button, through a `PopoverAnchor`. `onTabEvent` reports `TabEvent`s (opened, closed, activated, changed, Space changed) for the app to forward to extensions. Closing a pinned tab isn't a close, since the tab stays.
- **Default browser and incoming links:** `BrowserModel.openExternalURL(_:)` opens a link from another app in a mini window (see below), and links that arrive during launch open once Axo is ready. `defaultBrowser` (a `DefaultBrowserSetting`, supplied by the app from AxoIntegration) feeds `isDefaultBrowser` and `makeDefaultBrowser()`. If the person declines macOS's dialog, nothing else is shown. The Axo menu and the command bar offer "Make Axo Your Default Browser" only when it isn't already the default.
- **Handoff:** the window offers its page to the person's other devices as a web browsing activity (`handoffURL`, http and https pages only, unless `isHandoffEnabled` is off). `continueBrowsing(_:)` opens pages handed off from another device, or chosen in Spotlight, as tabs. It only accepts web pages, because another device decides the address.
- **Shortcuts:** `showSpaceForIntent`, `openForIntent`, `showTabForIntent`, and `saveCurrentTab(to:pinned:)` carry out Shortcuts actions. Each brings the window forward where it changes what's shown.
- **Focus:** `applyFocusSpace(_:)` shows a Focus filter's Space, remembers the one shown before (the first one, if Focuses change back to back), and returns to it when the Focus ends. Spaces that no longer exist are ignored.
- **Site customizations:** Customize This Site… (in the View menu and the Site Settings popover) opens an editor for the current site, picking the customization that applies even if it's off, or a new one for the domain without "www.".
  - **The editor:** a domain, an on/off switch, CSS and JavaScript editors, Delete, Save (⌘S), and Save and Reload (⌘R).
  - **Settings pane:** Site Customizations lists every site to turn off, edit, or delete, plus Add Site….
  - **Applying:** the model observes the store and passes the customizations to the pool (`setSiteCustomizations`).
- **iCloud pane:** Settings has an iCloud pane when the app sets `BrowserModel.iCloudSync` (a `SyncControlling`, backed by AxoSync in the app). It has a switch for syncing Spaces, folders, and pinned tabs (on by default), notes what stays on the Mac, and shows `SyncStatus` in plain words, with Sync Now while syncing.
- **Changes from elsewhere:** the window follows its Space when it changes outside the window, such as from iCloud: renames show, and if the Space is deleted the window moves to the first Space (`followShownSpace()`).
- **Link routing and Settings:** `SettingsView` is Axo's Settings window (⌘,). Its Link Routing pane lists the rules, each with a Space picker and Delete, plus Add Domain… (a sheet) and Add App… (an Open panel in /Applications).
  - **Routing:** `openExternalURL(_:sourceApp:)` opens a link that matches a rule as a tab in the rule's Space, switching to it. Other links open in a mini window.
  - **Model:** `addDomainRoute` and `addAppRoute` return a plain message if the rule can't be added. `setRouteSpace`, `deleteRoute`, and `linkRoutes` (observed) cover the rest.
  - **Showing the window:** `showBrowserWindow` (set by the app) brings the browser window forward, reopening it if it was closed, when a routed link or Open in Axo adds a tab.
- **Mini windows:** each link from another app opens in its own small window (`MiniWindow`, shown by `MiniWindowController`, an AppKit window hosting SwiftUI), using the current Space's profile.
  - **Open in Axo** (⌘O) moves the page into the current Space as a tab with the same ID, so it doesn't reload, and closes the window. Closing the window lets the page go.
  - New-window links inside a mini window stay in it, and its pages count as history.
  - `presentMiniWindow` and `dismissMiniWindow` are replaceable, so tests don't open real windows.
- **Peek:** in a pinned tab, a plain click on a link to another site, or a link that opens a new window, opens the page in Peek instead of leaving the pinned page. Peek is a card over the page, and new-window links inside it stay in it.
  - **Leaving Peek:** Open as Tab (⌘↩), Open in Split View next to the pinned tab, or close it (Esc, the close button, or clicking outside). Switching tabs also closes it.
  - **Not saved:** Peek's tab isn't saved. Promoting it inserts a tab with the same ID, so the page carries over without reloading. Its pages still count as history.
  - **Model:** `peek`, `openPeek`, `closePeek`, `promotePeek(inSplit:)`, and `handleLinkClick`. The Close Peek menu item owns Esc, so Esc works even while Peek's page has focus.
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
- **Translation:** View › Translate Page (and the command bar) reads the page's text, detects its language (NaturalLanguage), and asks for a translation session into `translationTarget` (the person's preferred language) by setting `translationConfiguration`. `PageTranslationTask` runs SwiftUI's `.translationTask` on the page column, so macOS can offer to download languages there, and hands the texts to `completeTranslation(with:)`. A bar above a translated page names the languages and offers Show Original (`showOriginalPage()`). Pages already in the target language aren't translated, and loading another page drops the translation.
- **Summaries:** a toolbar button (and View › Summarize Page, and the command bar) shows a popover with a summary from `pageSummarizer` (a `PageSummarizing`, supplied by the app from AxoIntegration's `PageSummarizer`). `pageSummary` is loading, ready, or failed with a plain reason. Without a summarizer, the button and commands are hidden.
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
