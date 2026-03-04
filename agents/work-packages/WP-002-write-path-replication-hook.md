# WP-002: Wire Replication Hook into Write Path

- ID: A-002
- Priority: P1
- Status: Ready
- Owner: Execution Agent
- Reviewer: PM

## Objective

Connect successful local writes (`SET` and `DEL`) to cluster replication hooks so clustered mode begins propagating mutations beyond a single node.

## Problem Statement

Cluster code defines replication methods, but server write handling currently updates only local store and does not invoke cluster replication logic.

## In Scope

- `src/server/tcp.zig`
- `src/main.zig`
- `src/cluster/node.zig` (only if needed for minimal API support)
- targeted tests in changed files (if present)

## Out of Scope

- Full network transport implementation in meshguard
- Consensus/quorum semantics
- Cross-node conflict resolution

## Requirements

1. Preserve standalone behavior when cluster is disabled.
2. In cluster mode, after successful local write:
   - invoke replication hook for `SET`
   - invoke replication hook for `DEL` (add hook if missing)
3. Keep operation ordering as local durability first, replication second.
4. If replication fails, return explicit server error without corrupting local state.
5. Keep command protocol unchanged.

## Implementation Constraints

- Minimal code changes and no protocol redesign.
- Do not claim strong consistency; this is best-effort replication hook wiring only.
- Avoid introducing deadlocks or long blocking sections around store mutexes.

## Acceptance Criteria

- Code compiles and tests pass: `zig test src/lib.zig`.
- Clear code path showing replication invocation for both `SET` and `DEL` in clustered mode.
- Standalone mode remains unaffected.

## Suggested Approach

1. Thread optional `Cluster` reference into `Server`.
2. On successful `SET`, call `cluster.replicateWrite(...)` if cluster exists.
3. Add `replicateDelete(...)` API to cluster (minimal stub acceptable) and call after successful local delete.
4. Map replication failures to explicit `-ERR` response while leaving local write committed.

## Validation Commands

```bash
zig test src/lib.zig
```

## Deliverables

- Code changes in scoped files.
- Execution note documenting ordering and failure semantics.
- Validation output summary.
