# REVIEW-008: WP-008 Binary Protocol Framing over TCP

- Date: 2026-03-01
- Work Package: [WP-008](../work-packages/WP-008-binary-protocol-framing.md)
- Reviewer: PM (Copilot)
- Outcome: Approved

## Scope Check

- In-scope files only: Yes (`src/core/types.zig`, `src/protocol/mod.zig`, `src/protocol/wire.zig`, `src/server/tcp.zig`, `apps/bun/src/lib/client.ts`)
- Requirements covered: Yes
- Scope violations: None

## Validation Evidence

- Command: `zig build && zig test src/lib.zig`
- Result: `All 31 tests passed.`
- Command: `bun run apps/bun/src/bin/client.ts --host 127.0.0.1 --port 6389 STATUS`
- Result: successful binary roundtrip response:

```text
keys=0
wal_size=0
cluster_enabled=0
```

## Code Quality Assessment

- Protocol compatibility: server enforces WormWire magic handshake for binary framing.
- Safety: oversized binary payload declarations are rejected before allocation.
- Correctness: command/response framing uses explicit big-endian length prefixes and typed command IDs.
- Migration: Bun client now initiates binary mode and decodes framed responses (including event frames).

## Findings

1. Added a dedicated `wire` protocol module for framed reads/writes with tests for roundtrip and payload guardrails.
2. Added binary-mode handling in TCP server with explicit non-WormWire handshake rejection.
3. Bun transport interoperates with binary server mode after unifying magic+frame into a single initial socket write.

## Decision

- Final decision: Approved
- Next candidate: add protocol-level integration tests for mixed pipelining with interleaved `EVENT` frames
