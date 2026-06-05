# Backlog (PM Managed)

## Priority Legend

- P0 = critical correctness/data safety
- P1 = core feature completion
- P2 = quality/performance hardening

## Items

| ID | Priority | Title | Status | Work Package | Notes |
|---|---|---|---|---|---|
| A-001 | P0 | Fix store/WAL memory ownership and crash | Done | [WP-001](./work-packages/WP-001-memory-safety-and-ownership.md) | Approved in REVIEW-001 |
| A-002 | P1 | Wire replication into write path | Done | [WP-002](./work-packages/WP-002-write-path-replication-hook.md) | Approved in REVIEW-002 |
| A-003 | P1 | Implement snapshot + WAL truncation | Done | [WP-003](./work-packages/WP-003-snapshot-and-wal-truncation.md) | Approved in REVIEW-003 |
| A-004 | P1 | Implement real SUB/UNSUB per connection | Done | [WP-004](./work-packages/WP-004-server-subscription-wiring.md) | Approved in REVIEW-004 |
| A-005 | P2 | Improve TCP read buffer framing correctness | Done | [WP-005](./work-packages/WP-005-tcp-read-buffer-framing.md) | Approved in REVIEW-005 |
| A-006 | P2 | Handle oversized single-line commands safely | Done | [WP-006](./work-packages/WP-006-oversized-line-safety.md) | Approved in REVIEW-006 |
| A-007 | P2 | Improve startup failure diagnostics | Done | [WP-007](./work-packages/WP-007-startup-and-connectivity-diagnostics.md) | Approved in REVIEW-007 |
| A-008 | P1 | Binary protocol framing over TCP (WormWire v1) | Done | [WP-008](./work-packages/WP-008-binary-protocol-framing.md) | Approved in REVIEW-008 |
| A-010 | P1 | AtomicAssets serving — read AA segment + first faceted endpoint | Done | [WP-010](./work-packages/WP-010-atomicassets-serving.md) | Approved in REVIEW-010 — serves GET /atomicassets/v1/assets?owner from the frozen segment, validated on the 88.8M-asset WAX-testnet segment |
| A-011 | P1 | AtomicAssets live freshness overlay (port aa_live.rs spine into the engine) | Done | [WP-011](./work-packages/WP-011-atomicassets-live-overlay.md) | Approved in REVIEW-011 — KV overlay (aa:f: forward override + aa:o: add-set) + aa_mint/aa_transfer/aa_burn EXEC procedures + re-validation-spine byOwner; integration-tested mint/transfer/burn → byOwner tracks each. SHiP feed + rem-sets + other dimensions are follow-ups |
| A-012 | P1 | AtomicAssets SHiP feed — decode chain deltas, call aa_mint/transfer/burn | Draft | TBD | the live applier; lightapi-ship-feed is the template. Unblocks live HTTP validation deferred from WP-011 |
