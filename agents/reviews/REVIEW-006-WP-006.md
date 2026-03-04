# REVIEW-006: WP-006 Oversized Single-Line Command Safety

- Date: 2026-03-01
- Work Package: [WP-006](../work-packages/WP-006-oversized-line-safety.md)
- Reviewer: PM (Copilot)
- Outcome: Approved

## Scope Check

- In-scope files only: Yes (`src/server/tcp.zig` and tests)
- Requirements covered: Yes
- Scope violations: None

## Validation Evidence

- Command: `zig test src/lib.zig`
- Result: `All 29 tests passed.`

## Code Quality Assessment

- Correctness: Oversized line condition is detected deterministically when buffer fills without newline.
- Recovery: Connection enters discard-until-newline mode and resumes normal processing afterwards.
- Safety: No panic/deadlock/spin observed in tests; fixed-buffer architecture retained.
- Compatibility: Existing valid command framing behavior preserved.

## Findings

1. Added explicit oversized-line error path (`-ERR request too large\r\n`).
2. Added discard mode to avoid treating oversized fragments as valid commands.
3. Added regression tests for oversized-line rejection + recovery.

## Decision

- Final decision: Approved
- Next candidate: improve runtime startup diagnostics for non-zero exits
