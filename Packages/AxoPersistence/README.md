# AxoPersistence

The single GRDB database: migrations, records, and the FTS5 search index.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** GRDB

**Platforms:** macOS 27 and iOS 27 (iPhone and iPad). Its tests run on both.

## Public API

- `AppDatabase`: wraps Axo's one SQLite database and runs every migration when it opens.
  - `AppDatabase.openOnDisk(at:)` opens a `DatabasePool` (WAL mode) at a file URL, creating the folder if needed.
  - `AppDatabase.makeInMemory()` creates an empty, migrated in-memory database for tests and previews.
  - `writer` exposes the GRDB `DatabaseWriter` for reads, writes, and `ValueObservation`.

## Schema

| Migration | Tables |
| --- | --- |
| `v1-profiles-spaces-tabs` | `profile`, `space` (→ profile, cascade), `tab` (→ space, cascade) |
| `v2-favicons` | `favicon` (site icons as 64 px PNGs, keyed by host) |
| `v12-sync` | iCloud sync bookkeeping: `syncChange` (local changes to profiles, Spaces, folders, and pinned tabs not yet sent, kept by triggers), `syncApplying` (set while changes from iCloud are written, so the triggers skip them), `syncRecordMetadata` (CloudKit system fields), `syncParkedRecord` (records waiting for a parent), `syncSetting` (engine state and the first-sync flag) |
| `v11-site-customizations` | `siteCustomization` (custom CSS and JavaScript for a domain and its subdomains; unique per domain; on by default) |
| `v10-link-routes` | `linkRoute` (rules sending links from other apps to a Space by source app or domain; unique per kind and value; → space, cascade) |
| `v9-tab-splits` | `tabSplit` (split views: Space and orientation; → space, cascade), plus `tab.splitID` (→ tabSplit, set null) and `tab.splitSortKey` (pane order) |
| `v8-site-permissions` | `sitePermission` (the person's camera, microphone, and location answers per profile, origin, and kind; → profile, cascade) |
| `v7-extension-access` | adds `webExtension.siteAccess` (`all` or `click`) and `grantedOptional` (a JSON array of approved optional permissions and patterns) |
| `v6-extensions` | `webExtension` (installed extensions per profile with folder and enabled state; → profile, cascade) |
| `v5-history` | `historyItem` (→ profile, cascade; unique per profile and URL) and `historyItem_ft`, an FTS5 index over title and URL kept in sync by triggers |
| `v4-folders` | `folder` (→ space, cascade; `parentID` → folder, cascade) and `tab.folderID` (→ folder, set null) |
| `v3-pinned-home-and-activity` | adds `tab.homeURL` and `tab.lastActiveAt` (existing tabs count as active at migration time), and an index on `tab.archivedAt` |

Record types for these tables live in AxoCore. Foreign keys are enforced. Schema changes are new, versioned migrations registered in `AppDatabase.migrator`. Never edit a migration that has shipped.

## Testing

```bash
swift test
```
