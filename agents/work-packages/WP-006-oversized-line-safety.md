# WP-006: Handle Oversized Single-Line Commands Safely

- ID: A-006
- Priority: P2
- Status: Ready
- Owner: Execution Agent
- Reviewer: PM

## Objective

Prevent read-loop stalls or undefined behavior when a client sends a command line longer than the fixed TCP read buffer without a newline terminator.

## Problem Statement

The current server read path uses a fixed 4096-byte buffer and newline framing. If a single command line exceeds buffer capacity before newline, behavior may degrade (infinite buffering attempts, dropped semantics, or ambiguous parser handling).

## In Scope

- `src/server/tcp.zig`
- tests in `src/server/tcp.zig`

## Out of Scope

- Protocol redesign
- Switching to streaming parser or dynamic unbounded buffers
- Throughput optimizations

## Requirements

1. Detect oversized un-terminated line condition deterministically.
2. Return explicit protocol error to client (e.g., `-ERR request too large`) and recover connection state.
3. Ensure server does not panic, deadlock, or spin.
4. Preserve existing behavior for valid commands and framing.
5. Add focused regression tests for oversized-line scenario.

## Implementation Constraints

- Keep fixed-size buffer design.
- Keep thread-per-connection architecture.
- Minimal surgical changes.

## Acceptance Criteria

- `zig test src/lib.zig` passes.
- New tests verify:
  - oversized line is rejected,
  - connection can continue processing subsequent valid commands,
  - normal small commands unaffected.

## Suggested Approach

1. In read loop, before read, detect `buffered_len == read_buf.len` with no newline consumed.
2. Emit `-ERR request too large\r\n` and clear buffer state to resume processing.
3. Optionally consume/discard until newline to avoid splitting oversized command into fragments.
4. Keep parser and protocol interfaces unchanged.

## Validation Commands

```bash
zig test src/lib.zig
```

## Deliverables

- Code changes in scoped files.
- Regression tests and short execution note describing recovery behavior.
