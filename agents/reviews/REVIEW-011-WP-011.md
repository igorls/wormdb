# REVIEW-011: WP-011 AtomicAssets live freshness overlay — serve the chain head

- Date: 2026-06-05
- Work Package: [WP-011](../work-packages/WP-011-atomicassets-live-overlay.md)
- Reviewer: PM
- Outcome: Approved

## Scope Check

- In-scope files only: Yes — `src/atomicassets/overlay.zig` (new), `src/atomicassets/mod.zig` (export),
  `src/procedures/atomicassets_apply.zig` (new), `src/procedures/registry.zig` (register aa_mint/transfer/burn),
  `src/procedures/atomicassets_assets.zig` (merged `byOwner` + integration test).
- Requirements covered: Yes — live mint/transfer/burn applied to a KV overlay over the frozen AA segment;
  `assets-by-owner` reflects current ownership via the re-validation spine.
- Scope violations: None. SHiP feed wiring, exact counts/rem-sets, the other faceted dimensions,
  cursor-over-overlay, and `setdata`/facet moves were explicitly deferred (not started).
- Light-API regression: None — `lightapi_*` procedures and `/api/...` routes untouched; the overlay merge is
  a no-op when no `aa:f:`/`aa:o:` keys exist (getCopy → null → base segment, identical to WP-010).

## Validation Evidence

- `zig build` and `zig build test` pass. (The lone random-seeded vector "failed command" line is pre-existing,
  reproduced on the clean tree — unrelated.)
- New unit tests (`overlay.zig`): forward-override tomb vs live blob (decode round-trip + `withOwner` keeps
  non-owner fields); add-set append/remove/contains with dedup.
- New integration test (`atomicassets_assets.zig`, "byOwner reflects live mint/transfer/burn via the overlay"):
  builds a 2-table AA segment (alice owns 1000,1001; bob owns 2000), attaches it to a real Store (WAL +
  snapshot paths), then drives the actual EXEC procedures through `Ctx` + `setDurable` and asserts each
  acceptance criterion:
  - `aa_transfer 1000 bob` → `byOwner(alice)` drops 1000 (keeps 1001); `byOwner(bob)` lists 2000 **and** 1000,
    newest-first (2000 before 1000).
  - `aa_burn 1001` → `byOwner(alice)` is exactly `{"success":true,"data":[]}` (1000 moved, 1001 tombstoned).
  - `aa_mint 3000 alice newcol newsch 9 200 1` → `byOwner(alice)` surfaces 3000 with `collection_name:newcol`.
- Live HTTP validation against the Jungle4 segment (WP-011 "Validation" line) is **deferred to the SHiP-feed
  package**: it requires rebuilding the multi-GB AA segment from the WSL snapshot, and the apply path goes
  through the same `execProc` → registry → procedure mechanism that WP-010 already validated live with
  byte-parity vs jungle4.api.atomicassets.io. The in-process integration test drives the real procedure
  functions + Store + WAL + segment, so the spine is proven deterministically. Recorded as follow-up.

## Code Quality Assessment

- The re-validation spine is implemented exactly as specified: `ov.currentAsset(store, a, id)` is the sole
  arbiter (override `aa:f:` → else base FWD(11); null on tomb/unknown), and `byOwner` validates every
  candidate (base posting head ∪ `aa:o:` add-set) through it, so transferred-out/burned assets fall out with
  no posting surgery. This matches the hyperion-tools `aa_live.rs` model.
- Durability is correct: applies use `setDurable` (WAL + replicate); the overlay rides the existing KV tier,
  so it is crash-recoverable and replicated for free — the same two-tier idiom Light-API's `bal:`/`acci:`
  keys already use. The single-writer SHiP-feed assumption (getCopy read + setDurable write, no held lock
  across the pair) is documented in `atomicassets_apply.zig`.
- The tombstone marker (`0x00`) cannot collide with a live asset blob (version byte is `1`); `withOwner`
  rewrites only owner@offset1 and preserves all other fields + attrs; `encodeAssetCore` mints a 41-byte
  core record with empty attr lists. All byte offsets match the segment FWD layout / `aa_binfmt.rs`.

## Known Limitations (documented, follow-up)

- Page-1 over-scan: `byOwner` scans the base posting head capped at `MAX_LIMIT` (100). An owner with >100
  base assets whose newest 100 were all transferred out could under-fill page 1 (older still-owned assets
  sit past the head). The add-set covers transfer-ins exactly; only this base-tail edge is affected. Cursor
  pagination + exact rem-sets (queued) remove it. Acceptable for the page-1 minimal endpoint.

## Decision

- Final decision: Approved.
- Next candidates (priority order): (1) the SHiP feed that decodes chain deltas (AA `transfer`/`mint`/`burn`
  actions + table deltas) and calls these apply procedures — the Light-API `lightapi-ship-feed` is the
  template; (2) more read endpoints (by collection/schema/template, `data:*` filters) merged through the same
  overlay + cursor-over-overlay; (3) exact counts + rem-sets; (4) full eosio-contract-api asset shape; (5) the
  unified multi-segment registry replacing the two typed slots.
