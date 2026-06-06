# WP-012: Generic core — decouple domain (Antelope/Light-API/AtomicAssets) code from the engine

## Objective

WormDB's engine **core** (storage, config, server, protocol, `core/`) must be domain-agnostic: it should
know about KV shards, WAL, mmap'd segments, postings, and the gateway — **not** about Antelope names,
Light-API tables, or AtomicAssets. All blockchain/domain knowledge belongs in the **procedure/domain
layer** (`src/procedures/*`, `src/atomicassets/*`, a new `src/lightapi/*`, a new `src/antelope/*`). Core
depends on nothing domain-specific; domains (and the composition root `main.zig`) depend on core.

This makes the engine a clean substrate that can host Light-API + AtomicAssets + chain-v1 + future domains
without core edits, and keeps the codebase honest about the layering (the directory tree shows engine vs
plug-in). It also unblocks the multi-segment registry already flagged in REVIEW-010.

## The leaks (audit, 2026-06-05)

1. **Typed per-domain segment slots** — `storage/store.zig` has `lightapi_segment` + `atomicassets_segment`
   fields + `attachLightApiSegment`/`attachAtomicAssetsSegment`; `core/config.zig` + `main.zig` mirror them
   (`--lightapi-segment`/`--atomicassets-segment`). Core storage knows two domains by name; can't host an
   Nth without new typed fields.
2. **`Segment.TableId` enum** — `storage/segment.zig` (the engine storage type) **enumerates Light-API
   tables** (`balances`/`accinfo`/`perms`/`pub_keys`/`top_ram`/…) and `lookup`/`has`/`keyCount` are typed on
   it. The deepest leak: the core API itself names blockchain tables. (AA already side-steps it with
   `@enumFromInt`.)
3. **Antelope codecs in `core/`** — `core/name.zig` (Antelope `name`↔u64) + `core/keyenc.zig` (EOS/`PUB_K1_`
   key rendering), re-exported by `core/mod.zig` → the `core` namespace publishes Antelope primitives.
4. **Light-API config types in core** — `core/config.zig` defines `LightApiNetwork`/`LightApiConfig` and
   `WormDBConfig.lightapi`; `main.zig` carries `seedLightApi`/`buildChainBlock` (cc32d9 chain blocks).

The procedure **bodies** are correctly contained — the leak is in store/segment/config/main, not the procs.
This predates AA (Light-API introduced the codecs, the config types, and the first typed slot); AA followed
that precedent. Fixing it now, before more AA endpoints, keeps the base robust.

## Design

- **Named segment registry** (kills leak 1): `Store` holds a small fixed registry
  (`attachSegment(name, *Segment)` / `segment(name) ?*const Segment`) keyed by an opaque caller-chosen
  string. Procedures look up "their" segment by a name they own (`store.segment("atomicassets")`). Config:
  generic `segments: []SegmentMount{name, path}`; CLI `--segment name=path` (repeatable). `main.zig` opens +
  attaches in a loop with domain-neutral startup logging. (Back-compat aliases `--lightapi-segment`/
  `--atomicassets-segment` retained in the composition root only.)
- **Generic segment table-id API** (kills leak 2): `Segment.lookup/has/keyCount` take an opaque `u32`
  table id (bounds-checked). The `TableId` enum moves OUT of core into the domains: AA already owns its ids
  in `atomicassets/binfmt.zig`; add `src/lightapi/tables.zig` for Light-API's 0..=10. Core storage tests use
  raw integer ids (no Antelope codec dependency).
- **Antelope codecs out of core** (kills leak 3): move `name.zig` + `keyenc.zig` → `src/antelope/`, add
  `antelope/mod.zig`, drop the `core/mod.zig` re-exports, update importers, expose `wormdb.antelope`.
- **Light-API config out of core** (kills leak 4): move `LightApiNetwork`/`LightApiConfig` →
  `src/lightapi/config.zig`; add a generic `core.config.loadTyped(comptime T, path)` so the domain parses
  its own config section (core has zero domain types); move `seedLightApi`/`buildChainBlock` →
  `src/lightapi/seed.zig`; `main.zig` (composition root) wires it.

## Stages (each `zig build` + `zig build test` gated)

- **A. Segment registry** — store + config + main + the ~10 call sites reading the typed slots.
- **B. Generic table-id API** — segment.zig signatures + `lightapi/tables.zig` + AA/LA call sites + core tests.
- **C. Antelope codecs** → `src/antelope/` + import updates + core/mod cleanup + lib.zig export.
- **D. Light-API config + seed** → `src/lightapi/` + `loadTyped` + main rewire.

## Acceptance Criteria

- `grep -E 'lightapi|atomicassets|antelope|eosio|name\.encode' src/storage src/core src/server src/protocol`
  returns only domain-neutral hits (comments may reference examples, but no domain **types/fields/enums/
  imports** in core).
- `Store` has no domain-named fields; `Segment.lookup/has/keyCount` take `u32`; `core/` imports no domain
  module.
- Light-API serving (all `lightapi_*` endpoints) and AtomicAssets serving (`byOwner` + apply) are unchanged
  behaviorally — `zig build test` green, including the existing segment/lightapi/AA tests (migrated).
- A second/third segment can be attached by name with no core change.

## Out of scope (follow-ups)

The segment range/scan iterator, the `atomicdata` attribute decoder, and the additional AA read endpoints
(the feature-matrix gaps) — this WP is purely the core/domain decoupling, no new serving features.
