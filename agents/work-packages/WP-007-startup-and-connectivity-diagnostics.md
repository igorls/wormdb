# WP-007: Startup and Connectivity Diagnostics

- ID: A-007
- Priority: P2
- Status: Ready
- Owner: Execution Agent
- Reviewer: PM

## Objective

Improve operator-facing diagnostics for non-zero exits at startup and common connectivity failures in CLI/UI tooling, while preserving existing behavior.

## Problem Statement

Recent runs show intermittent non-zero exits for `wormdb`, Bun client, and Bun UI with limited actionable context.

## In Scope

- `src/main.zig`
- `src/server/tcp.zig` (only if needed for propagated error context)
- `apps/bun/src/bin/client.ts`
- `apps/bun/src/bin/ui.ts`
- `README.md` (small troubleshooting notes only)

## Out of Scope

- Functional protocol redesign
- Deployment automation changes
- Auth/security feature changes

## Requirements

1. Keep project default WormDB port consistent at `6389` for server and Bun tools.
2. On startup failure, `wormdb` logs clear cause + remediation hints for common cases:
   - address already in use,
   - invalid bind/interface,
   - data directory/WAL permission issues.
3. Bun client surfaces clearer connection diagnostics (host/port + quick fix hint).
4. Bun UI startup/connectivity failures emit actionable stderr messages.
5. Preserve successful-path behavior and command protocol outputs.

## Implementation Constraints

- Minimal, surgical changes.
- No behavior changes for successful operations.

## Acceptance Criteria

- `zig build && zig test src/lib.zig` passes.
- `bun run apps/bun/src/bin/client.ts STATUS` on unreachable server prints actionable message and exits non-zero.
- README contains a concise troubleshooting section for startup/connectivity failures.

## Validation Commands

```bash
zig build && zig test src/lib.zig
bun run apps/bun/src/bin/client.ts STATUS
```

## Deliverables

- Code changes in scoped files.
- Brief execution note listing handled failure modes and sample messages.
