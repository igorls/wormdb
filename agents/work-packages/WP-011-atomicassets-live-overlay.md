# WP-011: AtomicAssets live freshness overlay (serve the chain head, not just a frozen snapshot)

## Objective

Make the AtomicAssets `assets-by-owner` endpoint serve the **chain head**: apply live mint / transfer /
burn deltas on top of the immutable AA segment so reads reflect current ownership, not the snapshot the
segment was built from. This is the WormDB-native port of the freshness model proven in hyperion-tools
`aa_live.rs` (the standalone Rust prototype), adapted to WormDB's KV-overlay-over-segment idiom — the same
two-tier pattern Light-API already uses (`bal:`/`acci:` KV keys shadow the frozen Light-API segment).

## Design — WormDB-native overlay (rides WAL/snapshot/replication)

The Rust prototype kept the overlay in-RAM (HashMaps + roaring sets) because it was a separate process.
Inside WormDB the overlay belongs in the **KV tier**: it is durable (WAL + snapshot), replicated, and
crash-recoverable for free, and it reuses the existing "present KV key shadows the segment" merge.

**The invariant (the re-validation spine, from aa_live.rs):** the *forward record* is the sole arbiter of
an asset's current owner. The base BY_OWNER posting only PROPOSES candidate asset_ids; a candidate is
yielded only if the live forward view confirms it still has that owner and isn't burned. So a transferred-
out or burned asset needs no posting surgery — it is dropped at read because its forward override says so.

**Overlay key scheme (KV tier):**
- `aa:f:<asset_id>` — the asset's **forward override**. Value = the asset forward blob (same byte layout as
  the segment FWD record; `value[0]` = version byte `1`) for a live asset, or a single `0x00` byte for a
  **tombstone** (burned). Absent → fall through to the base FWD. Shadows base FWD(11) per asset.
- `aa:o:<owner>` — the **overlay add-set** for an owner: the asset_ids added to this owner *since the base*
  (mints + transfer-ins), packed `[u64 × n]`. Small (only deltas since the last rebuild; base assets stay
  in the segment posting). Removals are handled by the re-validation spine, not a rem-set, for page reads.

Why no rem-set / no per-dim roaring here: for `assets-by-owner` *page* reads, the forward override makes
removals fall out automatically (validate-on-read), so the minimal correct overlay is `aa:f:` + `aa:o:`.
Exact counts, the other dimensions (collection/schema/template/data-attr), cursor-over-overlay, and the
rem-sets are follow-up packages.

**Apply via atomic EXEC procedures** (leverages WormDB's multi-key atomicity — the `transfer.zig` strength):
- `EXEC aa_mint <asset_id> <owner> <collection> <schema> <template_id> <block_num> <template_mint>` →
  set `aa:f:<id>` = live blob; append `<id>` to `aa:o:<owner>`.
- `EXEC aa_transfer <asset_id> <new_owner>` → resolve the current record (override → else base FWD), write
  `aa:f:<id>` = same record with owner=new_owner, append `<id>` to `aa:o:<new_owner>`, and remove it from
  `aa:o:<old_owner>` if it was an overlay add. Locks `aa:f:<id>` + both `aa:o:` keys (≤3 shards) and uses
  `setDurable` (WAL + replicate).
- `EXEC aa_burn <asset_id>` → set `aa:f:<id>` = tombstone (`0x00`); remove from its owner's add-set.

(`aa_setdata` / facet moves don't affect `assets-by-owner` and are deferred.)

**Merged `byOwner` read:** candidates (desc) = base BY_OWNER posting head ∪ `aa:o:<owner>` ids, deduped;
for each, resolve the current owner (override → else base FWD), drop if tombstoned or owner ≠ requested;
emit newest-first up to limit. Point reads / future endpoints resolve the same way via a shared helper.

## Implementation Plan

1. `src/atomicassets/overlay.zig` — key formatting (`aa:f:`/`aa:o:`), forward-override encode/decode
   (live blob vs `0x00` tomb), add-set ops (parse `[u64]`, append, remove), and the byte helpers. Pure;
   unit-tested.
2. `src/procedures/atomicassets_apply.zig` — `aa_mint` / `aa_transfer` / `aa_burn` procedures (atomic,
   `setDurable`). Register in `registry.zig`.
3. `src/procedures/atomicassets_assets.zig` — a shared `currentOwner(store, id)` resolver (override → base)
   and update `byOwner` to merge base head + `aa:o:` add-set with validation.
4. Tests: a fixture segment + apply a mint/transfer/burn sequence and assert `byOwner` reflects each
   (transferred asset moves owners, burned asset disappears, mint appears newest-first).

## Acceptance Criteria

- After `EXEC aa_transfer <id> <B>`, `byOwner(A)` no longer lists `<id>` and `byOwner(B)` does.
- After `EXEC aa_burn <id>`, `byOwner(owner)` no longer lists `<id>` and a point read of it is gone.
- After `EXEC aa_mint <id> <owner> ...`, `byOwner(owner)` lists `<id>` first (largest id) with the right
  collection/schema/template.
- Light-API + the frozen AA read path are unchanged when no overlay keys are present.

## Validation

- `zig build` + `zig build test` pass (new overlay + apply + merged-read tests).
- Manual: load the Jungle4 AA segment, apply a synthetic transfer via `EXEC aa_transfer`, and confirm the
  HTTP `assets-by-owner` for both owners changes accordingly.

Out of scope (follow-ups): the SHiP feed that decodes chain deltas and calls these apply procedures (the
Light-API `lightapi-ship-feed` is the template); exact counts + rem-sets; the other faceted dimensions +
cursor-over-overlay; `setdata`/facet moves; online compaction / rebase (an offline segment rebuild drops
the overlay, exactly as Light-API rebases today).
