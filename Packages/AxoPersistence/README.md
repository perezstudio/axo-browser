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

Record types for these tables live in AxoCore. Foreign keys are enforced. Schema changes are new, versioned migrations registered in `AppDatabase.migrator`. Never edit a migration that has shipped.

## Testing

```bash
swift test
```
