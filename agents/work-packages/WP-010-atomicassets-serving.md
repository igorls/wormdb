# WP-010: AtomicAssets Serving — read an AA segment + serve the first faceted endpoint

## Objective

Make WormDB serve **AtomicAssets** state the way it already serves Light-API: from a frozen, externally
built `.wseg` segment, via compiled `EXEC` procedures + the gateway, with no application tier. This package
delivers the first end-to-end slice — WormDB reads an AtomicAssets segment and serves `assets-by-owner`
(page 1) from the frozen segment — and lays the table/segment foundation the rest of the AA surface builds on.

This is the production path agreed with the project owner: AtomicAssets served **inside** WormDB (one WormDB
serving Light-API + AtomicAssets + chain-v1 state), mirroring the Light-API precedent. The Rust
`aa-server`/`aa_live` in hyperion-tools remains the maintained **standalone** alternative + the porting spec.

## Motivation / why it's more than Light-API

Light-API is point-lookup ("everything about account X"). AtomicAssets is **faceted** — filter by a
dimension (owner / collection / schema / template / data-attr), then page/sort. The hyperion-tools Rust
prototype (`aa_live.rs`) proved the model end to end (faceted reads, live overlay, compaction, cursor
pagination, all measured at WAX 232M scale). This package begins porting that model into WormDB's Zig engine,
starting with the read path over the frozen segment (no live overlay yet — that is a follow-up package).

## Blocking facts found in the engine (must fix first)

- **`MAX_TABLES = 16`** (`segment.zig:42`) and `open()` does `if (table_id >= MAX_TABLES) continue` — so a
  table whose id is ≥ 16 is **silently dropped**. The AtomicAssets segment built by hyperion-tools
  (`crates/wseg-build/src/aa_tables.rs`) uses table ids **11..=21**, so ids 16..21 (`SCHEMAS`, `SORTED_ID`,
  `TMPL_FWD`, `COLL_FWD`, `SORTED_TMPL`) are unreadable today. `lookup`/`has`/`keyCount` index
  `tables[@intFromEnum(table)]`, so a table id must be `< MAX_TABLES` to be addressable at all.
- **One segment slot.** `store.lightapi_segment: ?*const Segment` (`store.zig:68`) is a single typed
  pointer; there is no second slot/registry for another domain.

## AtomicAssets `.wseg` table layout (from hyperion-tools `aa_tables.rs` / `aa_binfmt.rs`)

Same `WSEG0001` format; table ids 11..=21, all keyed by a `u64`:

| id | table | key | blob |
|---|---|---|---|
| 11 | FWD (asset forward) | `asset_id` u64 | `version(1) owner(u64) coll(u64) schema(u64) template_id(i32) block_num(u32) template_mint(u32) immutable-attrs mutable-attrs` |
| 12 | BY_OWNER | `name::encode(owner)` | hybrid posting list of asset_ids |
| 13 | BY_COLL | `name::encode(collection)` | hybrid posting |
| 14 | BY_SCHEMA | `fnv1a64(coll \0 schema)` | hybrid posting |
| 15 | BY_TMPL | `template_id` u64 | hybrid posting |
| 16 | DATA_ATTR | `fnv1a64(coll \0 schema \0 field \0 value)` | hybrid posting |
| 17 | SCHEMAS | `fnv1a64(coll \0 schema)` | `u16 nfields, (type_tag u8, name_len u8, name)…` |
| 18 | SORTED_ID | sentinel 0 | `u32 count, u64×count` (asset_ids DESC) |
| 19 | TMPL_FWD | `template_id` u64 | template immutable attrs (stored once) |
| 20 | COLL_FWD | `name::encode(collection)` | (reserved; builder does not emit it yet) |
| 21 | SORTED_TMPL | sentinel 0 | `(u32 mint, u64 asset_id)×n` sorted by (mint, asset_id) |

**Hybrid posting blob** (`aa_binfmt.rs`): `[u8 format][u32 full_count]` then format 0 RAW (`u64×count`,
ascending; tail = largest = newest) **or** format 1 ROARING (`[u32 head_n][u64×head_n top-K DESC][roaring
bytes]`). For **page-1 (newest-first)** only the head is needed — the largest ids are the RAW tail or the
ROARING head, both stored uncompressed — so page-1 needs **no roaring decoder**.

## Architecture (this package)

Phase A — **read** (the foundation):
- Raise `MAX_TABLES` (16 → 32) so AA's 11..21 (and future chain-v1 ids) are addressable. Cheap: the
  `tables` array of optionals grows by ~16 slots (~hundreds of bytes per attached segment).
- Add a second segment to the store: `atomicassets_segment: ?*const Segment` + `attachAtomicAssetsSegment`,
  a `--atomicassets-segment <path>` flag, config field, open/attach/close in `main.zig`, help text, and a
  startup log of the AA table key counts. (A unified multi-segment *registry* replacing both hard-coded
  slots is the immediate follow-up package — kept out of scope here to keep the change reviewable and
  zero-risk to Light-API.)

Phase B — **decode + serve** (`src/atomicassets/` + a procedure):
- `src/atomicassets/binfmt.zig`: port the minimal read subset — `postingHead(blob, n)` (RAW tail / ROARING
  head → up to n largest ids, DESC) and `decodeAsset(blob)` → `{ owner, collection, schema, template_id,
  block_num, template_mint }` (attrs deferred to a later package).
- `src/procedures/atomicassets_assets.zig`: `EXEC atomicassets_assets_by_owner <owner> [limit]` → look up
  BY_OWNER(12) by `name.encode(owner)` → `postingHead(limit≤100)` → for each asset_id `FWD(11)` lookup +
  `decodeAsset` → assemble a JSON array `[{asset_id, owner, collection_name, schema_name, template_id,
  template_mint}, …]` (names via `name.decode`). Register in `registry.zig` + `mod.zig`.

Phase C — **gateway** (`src/server/gateway.zig`):
- Route `GET /atomicassets/v1/assets?owner=<acct>&limit=<n>` → `EXEC atomicassets_assets_by_owner`. This
  requires **parsing the query string** (currently dropped at `gateway.zig:350`) — at minimum `owner` and
  `limit`. Keep it minimal and additive; do not touch the `/api/...` (Light-API) routes.

Out of scope (follow-up packages): the live faceted overlay (roaring add/rem + tombstones + two-phase
apply), online compaction / hot-swap, cursor pagination, full eosio-contract-api asset shape (resolved
`data` via the atomicdata attr decode), AtomicMarket, the multi-segment registry, the unified SHiP feed.

## Implementation Plan

1. `src/storage/segment.zig` — `MAX_TABLES` 16 → 32; add a test that a table with id 21 round-trips
   (open → `has` → `lookup`), proving ids ≥ 16 are now addressable.
2. `src/storage/store.zig` — add `atomicassets_segment: ?*const Segment = null` + `attachAtomicAssetsSegment`.
3. `src/core/config.zig` — add `atomicassets_segment: ?[]const u8 = null` to `WormDBConfig`.
4. `src/main.zig` — `--atomicassets-segment <path>` arg parse + open/attach/close (mirroring the Light-API
   block) + help line + a startup `std.log.info` of the AA table key counts.
5. (Phase B) `src/atomicassets/binfmt.zig` + `src/procedures/atomicassets_assets.zig` + registry wiring.
6. (Phase C) `src/server/gateway.zig` route + query-string parse.

## Acceptance Criteria

- `MAX_TABLES` raised; a segment table with id ≥ 16 round-trips in a Zig test.
- `wormdb --atomicassets-segment <aa.wseg>` opens the segment, attaches it, and logs non-zero key counts
  for FWD(11) and BY_OWNER(12) on a real AtomicAssets segment (e.g. the WAX-testnet `.wseg`).
- `EXEC atomicassets_assets_by_owner <owner>` returns a JSON array of that owner's newest assets from the
  frozen segment; `GET /atomicassets/v1/assets?owner=<acct>` returns the same.
- Light-API serving is unchanged (no regression in `lightapi_*` procs or `/api/...` routes).

## Validation

- `zig build` (Windows single-node build here) and `zig build test` pass.
- Manual: run the server against a real AA `.wseg` and confirm the startup log + an `EXEC
  atomicassets_assets_by_owner` query returns the expected owner's assets, cross-checked against the
  hyperion-tools `aa-probe`/`eosio-contract-api` for the same owner.
