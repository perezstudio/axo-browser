# AxoPersistence

The single GRDB database: migrations, records, and the FTS5 search index.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** GRDB

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
| `v6-extensions` | `webExtension` (installed extensions per profile with folder and enabled state; → profile, cascade) |
| `v5-history` | `historyItem` (→ profile, cascade; unique per profile and URL) and `historyItem_ft`, an FTS5 index over title and URL kept in sync by triggers |
| `v4-folders` | `folder` (→ space, cascade; `parentID` → folder, cascade) and `tab.folderID` (→ folder, set null) |
| `v3-pinned-home-and-activity` | adds `tab.homeURL` and `tab.lastActiveAt` (existing tabs count as active at migration time), and an index on `tab.archivedAt` |

Record types for these tables live in AxoCore. Foreign keys are enforced. Schema changes are new, versioned migrations registered in `AppDatabase.migrator`. Never edit a migration that has shipped.

## Testing

```bash
swift test
```
