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
| A-013 | P1 | Generic core — decouple domain (Antelope/Light-API/AtomicAssets) from the engine | Done | [WP-012](./work-packages/WP-012-generic-core-domain-decoupling.md) | Approved in REVIEW-012 — named segment registry + generic u32 table-id Segment API + Antelope codecs → src/antelope + Light-API config → src/lightapi; core/storage/server/protocol carry no domain types/imports. Build+test green per stage; boot + live dispatch verified |
| A-014 | P2 | Generic gateway route registry — domains contribute routes via the manifest | Draft | TBD | next increment of the manifest inversion: fold the gateway's hard-coded /atomicassets + /api routes (and WS methods) into Domain.routes so the gateway is generic too. Currently the AA route is a string→execProc ref (works, no import) |
| A-015 | P1 | AtomicAssets extracted to its own package (wormdb-domain-atomicassets) | Done | [WP-013](./work-packages/WP-013-domain-modularization.md) | Domain manifest interface (procedures/domain.zig) + registry.registerDomains startup inversion; AA code moved to the sibling repo, consumed via src/atomicassets symlink sharing the engine's wormdb module (the build.zig.zon path-dep hits Zig's root-diamond — deferred to a core-lib split). In-tree src/atomicassets + procedures/atomicassets_* DELETED. zig build+test green both repos; startup logs the composed domain |
