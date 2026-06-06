# REVIEW-012: WP-012 Generic core — decouple domain code from the engine

- Date: 2026-06-05
- Work Package: [WP-012](../work-packages/WP-012-generic-core-domain-decoupling.md)
- Reviewer: PM
- Outcome: Approved (one follow-up flagged: gateway route registry)

## Scope Check

- In-scope: the four core/domain leaks — typed segment slots, the `Segment.TableId` enum, the Antelope
  codecs in `core/`, and the Light-API config types in `core/config.zig`.
- New domain modules created: `src/antelope/{name,keyenc,mod}.zig` (moved out of core), `src/lightapi/
  {tables,config,seed,mod}.zig`.
- No new serving features (the range/scan iterator, attribute decoder, extra endpoints stay out of scope).
- Light-API + AtomicAssets serving behavior unchanged.

## What changed (by stage)

- **A. Named segment registry.** `Store` lost `lightapi_segment`/`atomicassets_segment` + their attach
  methods; gained a generic fixed registry (`attachSegment(name, *Segment)` / `segment(name)`). `config`
  gained `segments: []SegmentMount{name, path}`; `main` opens+attaches in a domain-neutral loop with
  `--segment name=path` (repeatable) and back-compat aliases `--lightapi-segment`/`--atomicassets-segment`
  (kept only in the composition root). The ~12 call sites now use `store.segment("lightapi"|"atomicassets")`.
- **B. Generic table-id API.** `Segment.lookup/has/keyCount` take an opaque bounds-checked `u32`; the
  `TableId` enum is gone from core storage. Light-API ids moved to `src/lightapi/tables.zig` (mirroring AA's
  `binfmt.zig`); AA call sites dropped `@enumFromInt`. Core storage tests use raw `u32` ids + `u64` keys
  (no Antelope codec dependency).
- **C. Antelope codecs out of core.** `git mv core/{name,keyenc}.zig → antelope/`; `core/mod.zig` re-exports
  dropped; 11 importers repointed to `../antelope/...`; `wormdb.antelope` exposed.
- **D. Light-API config out of core.** `LightApiNetwork`/`LightApiConfig` + `seedLightApi`/`buildChainBlock`
  moved to `src/lightapi/{config,seed}.zig`; core gained a generic `config.loadTyped(comptime T, path)` so a
  domain parses its own JSON section; `main` is the composition root that loads networks + calls
  `lightapi.seed.run`. The dead `buildChainBlock` was dropped (it was defined but never called).

## Validation Evidence

- `zig build` + `zig build test` pass after **each** stage (A, B, C, D) and at the end.
- Acceptance grep (`lightapi|atomicassets|antelope|eosio|name.encode|TableId` over `src/core src/storage
  src/server src/protocol`): no domain **types/fields/enums/imports** remain. Residual hits are only:
  (a) comment examples (e.g. SegmentMount doc says `"lightapi"`/`"atomicassets"`), (b) test payload strings
  (`"eosio.token\tWAX…"` as a blob value), (c) the gateway's string-based route dispatch (see follow-up).
- Dependency direction verified: nothing under `core/`, `storage/`, `server/`, `protocol/` imports a domain
  module; `core/config.loadTyped` is type-generic (the lightapi domain passes its own `File` type in).
- **Boot smoke test** (built exe): clean startup — the generic segment loop parsed `--segment
  atomicassets=<path>`, attached by name, logged the open failure *by name*, and continued; `la_networks`
  load + `seed.run` no-op'd with no config; both listeners came up.
- **Live gateway dispatch** (same exe): `/api/networks` → `[]` (HTTP 200), `/api/usercount/eos` → `0` (200)
  — the Light-API procs run and `store.segment("lightapi")` resolves through the new registry. The 404s
  (`/api/balances/...`, `/atomicassets/v1/assets`) are the no-segment paths (proc returns null/err → 404),
  not regressions.

## Code Quality Assessment

- The registry is allocation-free (small fixed array, linear scan over ≤8 entries); `attachSegment` replaces
  on duplicate name and warns past capacity; `segment()` is `*const Store` so procedures call it on their
  `*Store`. Segment name slices are string literals / process-lifetime config strings — outlive the store.
- `main.zig` segment lifetimes: `opened_segs` is a heap array of `?Segment` freed (closed) in a `defer` at
  the end of `startServer`; `attachSegment` stores `&opened_segs[idx].?`, stable for the run. CLI mounts are
  folded into `cfg.segments` via an owned slice before `startServer`.
- `Segment.lookup/has/keyCount` now bounds-check `table >= MAX_TABLES` (the old enum made out-of-range
  unrepresentable; the `u32` API needs the guard — added).
- `config.loadTyped(T)` keeps core domain-free while still letting a domain parse its own section from the
  shared file (`ignore_unknown_fields`), with the same leaky-string lifetime contract as before.

## Follow-up flagged (not a WP-012 regression)

- **Gateway route registry (WP-013 candidate).** `src/server/gateway.zig::route()` still hard-codes the
  Light-API (`/api/...`) and AtomicAssets (`/atomicassets/v1/...`) URL→procedure mappings + per-route path-
  param extraction. This is domain knowledge in the server layer, but it is **string-based dispatch**, not
  type/enum/import coupling — so it does not violate WP-012's acceptance bar (no domain types in core). Making
  it generic needs a route-table abstraction domains register into (with per-route param extraction), which
  is a distinct architectural change with real regression surface on the live HTTP path. Recommended as its
  own package rather than folded in here.

## Decision

- Approved. Core is now domain-agnostic at the type level; a 3rd/Nth segment attaches by name with no core
  edit; Antelope/Light-API/AtomicAssets knowledge lives only in `src/antelope`, `src/lightapi`,
  `src/atomicassets`, and `src/procedures`. Next: WP-013 (generic gateway route registry) if desired, then
  back to the AA feature-matrix gaps (segment range/scan iterator, attribute decoder, more endpoints).
