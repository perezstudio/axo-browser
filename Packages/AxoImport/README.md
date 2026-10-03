# AxoImport

Brings Spaces, pinned tabs, bookmarks, and history over from Arc and Google Chrome.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoCore, GRDB (to read Chromium's SQLite history)

## Public API

- **`BrowserImporter(store:applicationSupport:)`** finds browsers and imports from them. `applicationSupport` is `~/Library/Application Support` by default. Tests pass a folder of fixtures.
  - `availableSources()` returns `.arc` if `Arc/StorableSidebar.json` exists, then `.chrome(profile)` for each Chrome profile in `Google/Chrome/Local State`. If Chrome is installed but its profile list can't be read, it offers the `Default` profile, and reading that reports the error.
  - `preview(_:)` returns `Counts` (Spaces, pinned tabs, favorites, open tabs, bookmarks, history pages) without changing anything.
  - `importData(from:parts:currentSpace:)` imports the chosen `Parts`:
    - **Arc** (`.spaces`, plus optional `.favorites`, `.openTabs`, `.history`):
      - Each Arc Space becomes an Axo Space after the existing ones, with its pinned tabs and folders. Split views become their tabs.
      - Spaces on Arc's default profile use the current Axo profile. Each other Arc profile gets a new Axo profile named "Arc <profile name>", so Spaces stay separated as they were. If writing the Spaces fails, those profiles are removed again.
      - Favorites (Arc's Top Apps) go in a "Favorites" folder at the top of the first Space of their profile.
      - Open tabs come in unpinned and archive on the usual schedule from the time of import.
      - History comes from each Arc profile's Chromium `History` file under `User Data`, into the matching Axo profile.
    - **Chrome** (`.bookmarks`, `.history`):
      - Bookmarks become pinned tabs in an "Imported from Chrome" folder at the end of the current Space's pinned section. The bookmarks bar comes first, then "Other Bookmarks" and "Mobile Bookmarks" when they aren't empty. Axo has no separate bookmark store, so pinned tabs serve as bookmarks.
      - History goes into the current Space's profile.
  - Cookies, logins, and passwords aren't imported. Importing twice adds the items twice.
- **`ArcSidebar(data:from:)`** reads `StorableSidebar.json`.
  - Arc stores lists as alternating IDs and objects. Each Space's `containerIDs` names its pinned and unpinned containers.
  - Item kinds are `tab` (`savedURL`, `savedTitle`, or a custom `title`), `list` (a folder), `splitView`, and `itemContainer`. Unknown kinds, such as easels, are skipped.
  - `topAppsContainerIDs` pairs each profile (`{"default": true}` or `{"custom": {"_0": {"directoryBasename": …}}}`) with its favorites container.
- **`ChromeBookmarks.folder(named:from:url:)`** reads a Chrome `Bookmarks` file into one `ImportedItem` folder.
- **`ChromiumHistory`** reads a Chromium `History` database: `pages(at:limit:)` (newest first) and `pageCount(at:limit:)`.
  - It reads a copy of the file (and its `-wal`), since the browser may hold it open.
  - Only visible http(s) pages are read, at most `pageLimit` (50,000) per file.
  - Chromium times are microseconds since 1601.
- **`ChromiumProfile.profiles(inLocalState:)`** lists a Chromium browser's profiles from `Local State`, `Default` first.
- **`ImportError`**: `notFound`, `unreadable` (usually because macOS didn't allow access), and `unrecognizedFormat`, with plain messages. A missing optional file, such as a profile without history, counts as nothing to import.

The writes go through AxoCore: `TabStore.importSpaces(_:at:)`, `TabStore.importPinned(_:into:at:)`, and `HistoryStore.importItems(_:profileID:)`. Each one is a single transaction.

## Privacy

Chrome's data folder is protected by macOS, so the first Chrome import shows macOS's prompt asking whether Axo may access data from other apps. Arc's sidebar file isn't protected the same way. Nothing is read until the person opens the Import sheet.

## Testing

```bash
swift test
```

Tests build fake Arc and Chrome data in a temporary folder: sidebar JSON, `Local State`, `Bookmarks`, and Chromium-format `History` databases (through GRDB). They never read the real browsers' files.
