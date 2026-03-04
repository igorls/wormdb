# REVIEW-004: WP-004 Server-Side SUB/UNSUB Wiring

- Date: 2026-03-01
- Work Package: [WP-004](../work-packages/WP-004-server-subscription-wiring.md)
- Reviewer: PM (Copilot)
- Outcome: Approved

## Scope Check

- In-scope files only: Yes (`src/server/tcp.zig` and tests)
- Requirements covered: Yes
- Scope violations: None

## Validation Evidence

- Command: `zig test src/lib.zig`
- Result: `All 23 tests passed.`

## Code Quality Assessment

- Correctness: `SUB` and `UNSUB` now use real EventBus subscribe/unsubscribe calls.
- Lifecycle: Connection context tracks subscriptions and cleans up on disconnect.
- Safety: Writes to stream are serialized via connection write mutex.
- Compatibility: Protocol responses remain unchanged (`+OK` and `>EVENT` format).

## Findings

1. Per-connection `channel -> sub_id` tracking is implemented.
2. Duplicate `SUB` for same channel is idempotent per connection.
3. Deferred teardown unsubscribes all remaining subscriptions.

## Decision

- Final decision: Approved
- Next package: [WP-005](../work-packages/WP-005-tcp-read-buffer-framing.md)
