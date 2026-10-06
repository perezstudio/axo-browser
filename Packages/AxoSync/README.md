# AxoSync

iCloud sync of profiles, Spaces, folders, and pinned tabs through `CKSyncEngine`.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoPersistence, GRDB (tests also use AxoCore)

**Platforms:** macOS 27 and iOS 27 (iPhone and iPad). Its tests run on both.

## What syncs

| Record | Fields |
| --- | --- |
| Profile | name (website data and logins stay on each device) |
| Favorite | profile, home page, title, sort key |
| Space | profile, name, sort key, color, icon |
| Folder | Space, parent folder, name, sort key (expanded state stays local) |
| Tab (pinned only) | Space, folder, home page, title, sort key |

Open tabs, history, extensions, settings, and website data don't sync. A pinned tab keeps the page it's showing on each device; only its home page and place sync. Unpinning a tab removes it from other devices.

## Public API

- **`SyncStore`** is the database side, with no CloudKit in it, so tests drive it with a fake cloud.
  - **Local changes:** triggers from migration `v12-sync` record every change to a synced row in `syncChange`, whatever wrote it. `pendingChanges()` and `observePendingChanges()` list them. `outgoingRecord(for:)` builds the `SyncRecord` to send (stamped with the change's time and the last CloudKit system fields), or `nil` when the row is gone. `didSave`, `didDelete`, and `dropSaveIfRowIsGone` settle them.
  - **Changes from iCloud:** `applyRemoteChanges(saved:deleted:)` writes them inside one transaction, flagged in `syncApplying` so the triggers don't send them back. A record whose parent hasn't arrived (a tab before its Space) waits in `syncParkedRecord` and is retried whenever changes arrive.
  - **Conflicts:** per record, the later change wins: a record's `modifiedAt` against the pending local change's time (`resolveConflict(with:)`). Deletions from iCloud always apply. An edit to a record another device deleted creates it again (`recordWasMissingOnServer`).
  - **First sync:** until `finishFirstSync()` runs after the first fetch, local changes wait. If the device's only Space is untouched (not from iCloud, no pinned tabs or folders) and iCloud has Spaces, its open tabs, splits, and link rules move into the first synced Space, and the empty Space and its unused profile are removed. Then everything is queued to send. Its website data stays on disk.
  - **Resets:** `markEverythingChanged()` and `resetSyncMetadata()` (which keeps the sidebar).
- **`CloudKitSync`** runs a `CKSyncEngine` over the private database, in one zone (`Axo`). Record names are `<Type>.<lowercase UUID>`, so a record ID alone says what it is.
  - `isAvailable(containerIdentifier:)` checks the iCloud entitlement (on iOS it's `false` for now, since iOS has no public way to read entitlements; the iOS app will decide this when it gets iCloud). Create a `CloudKitSync` only when it's true: CloudKit stops the app without it.
  - `start()`, `stop()`, and `syncNow()`. `onSynced` reports each finished fetch or send.
  - **Accounts:** signing out keeps the sidebar and forgets the iCloud bookkeeping. Signing in or switching accounts runs the first sync again. If the zone is deleted (from another device or iCloud settings), this device's sidebar becomes the copy in iCloud.

## Testing

```bash
swift test
```

`SyncStoreTests` syncs two in-memory databases through `FakeCloud`, which follows CloudKit's rules for change tags. `CloudKitMappingTests` builds `CKRecord`s locally. Nothing reaches iCloud. Syncing with real iCloud needs a Release build signed with the container (see `CLAUDE.md`), so it's checked by hand.
