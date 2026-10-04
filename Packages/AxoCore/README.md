# AxoCore

Profiles, Spaces, folders, tabs, windows, and the TabStore.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoPersistence, GRDB

## Public API

- **Records:** `Profile`, `Space`, `Tab` (with `isPinned`, `homeURL`, `lastActiveAt`, `archivedAt`, and `hasLeftHome`), and `Favicon` (a site icon keyed by lowercased host; `Favicon.key(for:)`) are plain `Codable` GRDB records. They hold persisted state only, never live web views.
- **`ExtensionStore`** (`tabStore.extensions`) records the installed extensions per profile (`WebExtensionRecord`: ID, name, version, folder, unpacked, enabled, site access, and approved optional permissions). Updates keep the enabled state, site access, and approvals. Also `setSiteAccess` and `addGrantedOptional`.
- **`HistoryStore`** (`tabStore.history`): `recordVisit(to:title:profileID:at:)` records http(s) pages only, one row per profile and URL. `importItems(_:profileID:)` merges another browser's history in one transaction: visit counts add up, the later visit time wins, and an imported title fills in a missing one. Also `updateTitle`, `recent`, `clear`, and `search(_:profileID:limit:)`, which matches every word as a prefix through FTS5 and ranks by relevance plus visit frequency and recency. `HistoryItem` is the record. Profiles never see each other's history.
- **Split views (`TabSplit`):** two to four tabs (`maximumPanes`) shown together, `horizontal` (side by side) or `vertical` (stacked).
  - **Membership:** a tab joins through `splitID`, and `splitSortKey` orders the panes.
  - **One row:** a split's tabs share their section and folder, and sit together in the sidebar. The first of them in sidebar order stands for the split.
  - **Operations:**
    - `addToSplit(_:with:)` makes or extends a split (throws `splitFull`). The tab moves next to the split, and joining a pinned split pins it.
    - `removeFromSplit`, `separateSplit`, `setSplitOrientation`, `splits(in:)`, and `observeSplits(in:)`.
  - **Keeping a split together:** pinning, unpinning, or moving any of its tabs (`setPinned`, `moveTab`, `movePinnedItem`) takes the others along. Archiving or deleting a tab takes it out of its split, and a split left with one tab ends.
- **`SitePermissionStore`** (`tabStore.sitePermissions`) saves the person's answers to sites asking for the camera, microphone, or location (`SitePermission`, with `Kind` and `Decision`), per profile and origin (such as `https://meet.example.com`). `decision`, `decisions(origin:profileID:)`, `setDecision(_:for:origin:profileID:)` (`nil` forgets, so the site asks again), and `reset(origin:profileID:)`.
- **`SortKey`:** fractional sort keys. `SortKey.between(lower, upper)` returns a key strictly between two neighbors (`nil` means the start or end of the list), so a move updates a single row. Order by `(sortKey, id)` so duplicate keys after a sync merge stay stable.
- **`TabStore`:** the async API over the sidebar model.
  - `TabStore.openOnDisk(at:)` and `TabStore.makeInMemory()` open the database, so callers above AxoCore never import AxoPersistence.
  - Spaces: `spaces()`, `observeSpaces()`, `createSpace(name:profileID:)` (added after the others), `renameSpace(id:to:)`, and `deleteSpace(id:)`. Deleting a Space deletes its tabs, keeps its profile, and refuses to delete the last Space.
  - Profiles: `profiles()`, `createProfile(name:)`, `renameProfile(id:to:)`, and `deleteProfile(id:)`, which refuses while a Space uses the profile.
  - `bootstrap()` returns the first Space, creating a default profile and Space on first launch.
  - `openTab(id:url:title:in:at:)` (pass an `id` to keep a page that was already showing, such as a promoted Peek), `moveTab(id:to:)`, `updateTab(id:url:title:)`, and `closeTab(id:)` write off the main actor.
  - `TabPosition` is `.start`, `.end`, or `.after(tabID)`, within the tab's section. Pinned tabs come first, and each section has its own order. Anchoring across sections throws `anchorInDifferentSection`.
  - Folders (`Folder` and `PinnedItem`): `folders(in:)`, `observeFolders(in:)`, `createFolder(named:in:parent:)`, `renameFolder`, `setFolderExpanded`, `deleteFolder` (its contents move up a level, in order), and `movePinnedItem(_:into:after:)`, which moves a pinned tab or folder to any level (pinning unpinned tabs) and refuses folder cycles. Folders and pinned tabs at one level share an order.
  - Pinning: `setPinned(_:tabID:)` (pinning records the current page as `homeURL`), `setHomeURL(_:tabID:)`, and `resetPinnedTab(id:)`.
  - Archiving: `archiveTab(id:at:)`, `archiveInactiveTabs(lastActiveBefore:keeping:at:)` (unpinned tabs in every Space), `archivedTabs(in:)` (newest first), `restoreTab(id:at:)`, and `markActive(id:at:)`. `deleteTab(id:)` removes a tab for good.
  - `saveFavicon(_:for:)` and `favicons(forHosts:)` store and read site icons. URLs without a host, such as `file:` and `about:` pages, have no icon.
  - Importing (`ImportedItem`, `ImportedSpace`): `importSpaces(_:at:)` adds Spaces after the existing ones with their pinned tabs (home URL = their URL), folders, and unpinned tabs (folders flattened, active as of the import), and `importPinned(_:into:at:)` adds items at the end of a Space's pinned section. Each is one transaction, so a failure adds nothing. AxoImport builds the items from other browsers' data.
  - `observeTabs(in:)` streams a Space's tab list after every change. `TabStore.tabsRequest(in:)` is the same query for GRDBQuery.

## Testing

```bash
swift test
```
