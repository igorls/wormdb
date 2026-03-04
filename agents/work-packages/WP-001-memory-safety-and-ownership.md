# WP-001: Fix Store/WAL Memory Safety and Ownership

- ID: A-001
- Priority: P0
- Status: Ready
- Owner: Execution Agent
- Reviewer: PM

## Objective

Eliminate memory leaks and crash-level ownership bugs in the core storage path while preserving current behavior (WAL-first write durability and WORM semantics).

## Problem Statement

Current tests indicate allocator leaks and a segmentation fault in store update/delete paths. Existing ownership appears inconsistent between hash map key ownership and `Entry` ownership.

## In Scope

- `src/storage/store.zig`
- `src/storage/wal.zig`
- storage-related tests in same files

## Out of Scope

- Cluster replication implementation
- Snapshot feature implementation
- Protocol redesign

## Requirements

1. Define a single clear ownership model for key/value memory.
2. Remove double-free risks in update/delete/replay/deinit flows.
3. Ensure `Wal.appendSet` ownership contract is explicit and correctly used.
4. Keep external API behavior unchanged (`Store.set/get/delete`).
5. Update/extend tests to cover update + delete + replay ownership safety.

## Implementation Constraints

- Minimal surgical changes; no broad refactors.
- Preserve existing public types and command semantics.
- Do not introduce unrelated features.

## Acceptance Criteria

- `zig test src/lib.zig` passes without leaks or segfaults.
- Existing WORM tests still pass.
- New/updated tests cover:
  - overwrite existing key,
  - delete existing key,
  - replay WAL with repeated key updates.

## Suggested Approach

1. Decide whether `Entry` owns key/value exclusively.
2. Ensure map keys reference the same owned memory without independent free.
3. On replacement, remove old map entry before freeing old data.
4. Remove redundant key duplication around WAL append/store set interaction.
5. Add tests reproducing previous crash path.

## Validation Commands

```bash
zig test src/lib.zig
```

## Deliverables

- Code changes in scoped files.
- Short execution note listing root cause and fix.
- Validation output summary.
