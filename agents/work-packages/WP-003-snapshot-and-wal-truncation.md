# WP-003: Snapshot and WAL Truncation

- ID: A-003
- Priority: P1
- Status: Ready
- Owner: Execution Agent
- Reviewer: PM

## Objective

Implement a minimal snapshot mechanism and WAL truncation policy so restart time and disk growth remain bounded.

## Problem Statement

`Config` exposes `snapshot_path` and `max_wal_size`, but current store only replays append-only WAL with no compaction/truncation.

## In Scope

- `src/storage/store.zig`
- `src/storage/wal.zig` (if helper APIs are needed)
- `src/core/types.zig` (only if strictly necessary)
- tests in changed files

## Out of Scope

- Advanced compaction scheduling
- Incremental snapshots
- Distributed snapshot coordination

## Requirements

1. Add snapshot write/read path for full in-memory state.
2. On startup, restore snapshot first, then replay WAL entries newer than snapshot boundary (or replay empty WAL after truncation strategy).
3. Introduce WAL size check using `max_wal_size` and trigger snapshot+truncate when threshold exceeded.
4. Preserve WORM semantics and existing command behavior.
5. Keep implementation simple and deterministic.

## Implementation Constraints

- Minimal invasive changes.
- Use existing config fields (`snapshot_path`, `max_wal_size`).
- Avoid introducing background threads in this package.

## Acceptance Criteria

- `zig test src/lib.zig` passes.
- Added tests proving:
  - snapshot restore works,
  - WAL can be truncated after snapshot,
  - state remains correct across restart.

## Suggested Approach

1. Define snapshot format (length-prefixed entries with flags/timestamp).
2. Add `Store.writeSnapshot()` + `Store.loadSnapshot()` helpers.
3. Trigger snapshot in write path when WAL exceeds configured threshold.
4. After successful snapshot, reset/truncate WAL file safely.

## Validation Commands

```bash
zig test src/lib.zig
```

## Deliverables

- Code and tests in scoped files.
- Execution note with snapshot format and truncate semantics.
