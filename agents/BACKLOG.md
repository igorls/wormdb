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
| A-013 | P1 | Generic core — decouple all serving domains from the engine | Done | (records moved out with the domain packages) | Named segment registry, generic u32 table-id Segment API, domain manifest interface (procedures/domain.zig) + registerDomains/registerRoutes/registerWsMethods startup inversion; all domain code lives in external packages — the engine repo carries no domain types, imports, or names |
| A-014 | P1 | Prepare repository for public release | Done | [WP-014](./work-packages/WP-014-public-release-preparation.md) | Approved in [REVIEW-014](./reviews/REVIEW-014-public-release-preparation.md); source preparation delivered in PR #94; visibility and post-publication settings remain owner actions |
| A-015 | P2 | Refresh public website and README | Review | [WP-015](./work-packages/WP-015-public-launch-site.md) | Approved in [REVIEW-015](./reviews/REVIEW-015-public-launch-site.md); required CI and Pages verification gate delivery |
| A-016 | P0 | Fix priority security findings | Review | [WP-016](./work-packages/WP-016-security-priority-fixes.md) | Approved in REVIEW-016; Windows/Linux unit and live checks passed on current main integration; deployment and hosted checks pending |
| A-017 | P0 | Integrate synchronous FFI for Meshrooms | Review | [WP-017](./work-packages/WP-017-meshrooms-sync-integration.md) | Combined engine passed Windows/Linux unit and live checks; exact consumer artifact qualification and merge pending |
