# WP-005: TCP Read Buffer Framing Correctness

- ID: A-005
- Priority: P2
- Status: Ready
- Owner: Execution Agent
- Reviewer: PM

## Objective

Fix command framing in TCP server read loop so partial lines, multiple lines per read, and carried-over bytes are handled correctly and deterministically.

## Problem Statement

Current read loop logic in `src/server/tcp.zig` can mis-handle buffered offsets when reads are partial or when leftovers from previous reads exist, leading to incorrect command boundaries.

## In Scope

- `src/server/tcp.zig`
- tests in `src/server/tcp.zig` and adjacent module tests if needed

## Out of Scope

- Protocol format changes
- Async I/O redesign
- Throughput optimization beyond correctness

## Requirements

1. Preserve existing protocol command syntax and responses.
2. Correctly process:
   - single partial command split across reads,
   - multiple full commands in one read,
   - mixture of full + partial commands across reads.
3. Never drop buffered unread bytes between read iterations.
4. Keep thread-per-connection model unchanged.
5. Add focused regression tests for framing scenarios.

## Implementation Constraints

- Minimal, surgical changes in current server architecture.
- Avoid introducing heavy abstractions.

## Acceptance Criteria

- `zig test src/lib.zig` passes.
- New tests demonstrate correct behavior for the three framing scenarios above.
- Manual inspection confirms `read_idx` and scanning window logic are coherent.

## Suggested Approach

1. Track `buffered_len` representing valid bytes in read buffer.
2. Read into `read_buf[buffered_len..]` and set total `end = buffered_len + bytes_read`.
3. Scan `read_buf[0..end]` for newlines; process complete lines.
4. Move unconsumed tail to buffer start and set next `buffered_len` accordingly.

## Validation Commands

```bash
zig test src/lib.zig
```

## Deliverables

- Code changes in scoped files.
- Regression tests and a short execution note on edge cases handled.
