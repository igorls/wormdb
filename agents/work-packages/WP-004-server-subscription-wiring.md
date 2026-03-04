# WP-004: Server-Side SUB/UNSUB Wiring

- ID: A-004
- Priority: P1
- Status: Ready
- Owner: Execution Agent
- Reviewer: PM

## Objective

Implement real per-connection subscription and unsubscription behavior in the TCP server so `SUB` and `UNSUB` commands are functional rather than placeholder acknowledgements.

## Problem Statement

Current server acknowledges `SUB` and `UNSUB` but does not register client callbacks with `EventBus`, so subscribed clients do not receive published events.

## In Scope

- `src/server/tcp.zig`
- `src/event/bus.zig` (only if minimal API tweaks required)
- tests in changed files

## Out of Scope

- Durable subscriptions
- Cross-node subscription propagation
- Protocol redesign

## Requirements

1. Track subscriptions per connection (`channel -> sub_id`).
2. `SUB <channel>` registers callback through `EventBus.subscribe`.
3. `UNSUB <channel>` removes callback through `EventBus.unsubscribe`.
4. On connection close, auto-unsubscribe remaining subscriptions.
5. Preserve existing response format and protocol commands.

## Implementation Constraints

- Keep thread safety and avoid global mutable state without locking.
- Minimal surgical edits; no unrelated refactors.

## Acceptance Criteria

- `zig test src/lib.zig` passes.
- Add tests (where practical) showing:
  - subscriber receives `PUB` messages,
  - `UNSUB` stops delivery,
  - disconnect cleanup reduces subscriber count.

## Suggested Approach

1. Introduce per-connection context in `handleConnection` for active subscriptions.
2. Implement write callback that emits `>EVENT ...` to that connection stream.
3. Ensure cleanup in deferred connection teardown path.

## Validation Commands

```bash
zig test src/lib.zig
```

## Deliverables

- Code changes in scoped files.
- Execution note on lifecycle and cleanup semantics.
- Validation output summary.
