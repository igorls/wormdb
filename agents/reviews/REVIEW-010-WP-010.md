# REVIEW-010: WP-010 AtomicAssets Serving — read AA segment + first faceted endpoint

- Date: 2026-06-05
- Work Package: [WP-010](../work-packages/WP-010-atomicassets-serving.md)
- Reviewer: PM
- Outcome: Approved

## Scope Check

- In-scope files only: Yes — `src/storage/segment.zig`, `src/storage/store.zig`, `src/core/config.zig`,
  `src/main.zig` (Phase A); `src/atomicassets/{binfmt,mod}.zig`, `src/lib.zig`,
  `src/procedures/{atomicassets_assets,registry}.zig` (Phase B); `src/server/gateway.zig` (Phase C).
- Requirements covered: Yes — WormDB reads an AtomicAssets `.wseg` and serves `assets-by-owner` (page-1)
  from the frozen segment over EXEC + HTTP.
- Scope violations: None. The faceted live overlay, full eosio-contract-api shape, more endpoints, and the
  multi-segment registry were explicitly deferred to follow-ups (not started).
- Light-API regression: None — the `/api/...` routes and `lightapi_*` procedures are unchanged.

## Validation Evidence

- `zig build` and `zig build test` pass. (The lone random-seeded vector "failed command" line is
  pre-existing — reproduced on the clean tree with my changes stashed.)
- New tests: `segment.zig` high-table-id (21) round-trip; `binfmt.zig` postingHead RAW + ROARING +
  decodeAsset; `atomicassets_assets.zig` proc integration (build a 2-table AA segment, attach, run
  `byOwner`, assert newest-first JSON + empty-data for an unknown owner).
- Real-segment startup (the 7.8 GB WAX-testnet AA segment):
  `AtomicAssets segment: ... assets=88844041 owners=14179 collections=5989` (matches hyperion-tools aa-live).
- Real-segment HTTP (`--port 6393 --gateway-port 6393`):
  - `GET /atomicassets/v1/assets?owner=maxisawesome&limit=3` →
    `{"success":true,"data":[{asset_id 1099515547141, collection maxylabtestn, schema cards,
    template 141968, mint 25}, {…mint 24}, {…mint 3}]}` — real data, newest-first, names decoded.
  - `GET ...?owner=zzzznobodyzz` → `{"success":true,"data":[]}`
  - `GET /atomicassets/v1/foo` → `404 Not Found`

## Code Quality Assessment

- Showstopper fixed correctly: `MAX_TABLES` 16→32 makes AA's table ids 11..21 addressable (was silently
  dropped at `table_id >= MAX_TABLES`). The `tables` array is indexed by table_id; headroom for LA + AA +
  chain-v1.
- Decode is byte-matched to the Rust builder (`aa_binfmt.rs`); page-1 reads the posting head only (RAW tail
  / ROARING head, both uncompressed) so no roaring decoder is pulled in.
- Serving mirrors the Light-API procedure/gateway pattern exactly (overlay-then-segment idiom is not needed
  yet — frozen read only).
- Distinct AA segment slot kept deliberately small (no registry) to avoid touching Light-API; the unified
  multi-segment registry is the next package.

## Decision

- Final decision: Approved.
- Next candidates (priority order): (1) the AtomicAssets faceted live overlay (roaring add/rem + tombstones
  + two-phase apply, ported from hyperion-tools `aa_live.rs`); (2) more read endpoints
  (by collection/schema/template, `data:*` attribute filters, cursor pagination); (3) full
  eosio-contract-api asset shape (resolved `data` via the atomicdata attribute decode); (4) the unified
  multi-segment registry replacing the two typed slots.
