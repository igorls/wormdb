# REVIEW-005: WP-005 TCP Read Buffer Framing Correctness

- Date: 2026-03-01
- Work Package: [WP-005](../work-packages/WP-005-tcp-read-buffer-framing.md)
- Reviewer: PM (Copilot)
- Outcome: Approved

## Scope Check

- In-scope files only: Yes (`src/server/tcp.zig` and tests)
- Requirements covered: Yes
- Scope violations: None

## Validation Evidence

- Command: `zig test src/lib.zig`
- Result: `All 26 tests passed.`

## Code Quality Assessment

- Correctness: Framing logic now tracks buffered bytes explicitly and preserves tails.
- Regression coverage: Added tests for split, batched, and mixed read scenarios.
- Compatibility: Protocol syntax/responses unchanged.
- Risk note: Oversized single-line commands without newline still rely on fixed buffer limits.

## Findings

1. Introduced `buffered_len` model in read loop with deterministic compaction.
2. Added `processReadBuffer` and tests to verify boundary cases.
3. Eliminated previous ambiguity in scan range (`0..bytes_read` vs buffered window).

## Decision

- Final decision: Approved
- Next candidate: harden oversized-line handling (new backlog item)
