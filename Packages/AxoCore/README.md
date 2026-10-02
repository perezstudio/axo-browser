# AxoCore

Profiles, Spaces, folders, tabs, windows, and the TabStore.

Part of [Axo](../../CLAUDE.md), a native WebKit browser for macOS. See `docs/PLAN.md` for the architecture.

**Depends on:** AxoPersistence, GRDB

## Public API

- **Records:** `Profile`, `Space`, and `Tab` are plain `Codable` GRDB records. They hold persisted state only, never live web views.
- **`SortKey`:** fractional sort keys. `SortKey.between(lower, upper)` returns a key strictly between two neighbors (`nil` means the start or end of the list), so a move updates a single row. Order by `(sortKey, id)` so duplicate keys after a sync merge stay stable.
- **`TabStore`:** the async API over the sidebar model.
  - `bootstrap()` returns the first Space, creating a default profile and Space on first launch.
  - `openTab(url:title:in:at:)`, `moveTab(id:to:)`, `updateTab(id:url:title:)`, and `closeTab(id:)` write off the main actor.
  - `TabPosition` is `.start`, `.end`, or `.after(tabID)`.
  - `TabStore.tabsRequest(in:)` is the request to observe with `ValueObservation` or GRDBQuery.

## Testing

```bash
swift test
```
