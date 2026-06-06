# WP-013: Domain modularization — domains as their own packages/repos

## Objective

Make a serving domain (starting with AtomicAssets) a **true module** living in its own repository,
composed into WormDB at build time — so the engine ships no domain code and an operator (or another
repo) can add/remove a domain without touching the core. Builds directly on WP-012, which removed all
domain *types* from the core; this WP removes the static *registration* of a domain from the core.

## What shipped (AtomicAssets)

- **`src/procedures/domain.zig`** — the `Domain` manifest interface a domain exposes (`name`,
  `segment_names`, `table_id_lo/hi`, `procedures: []const Entry`). Minimal first cut; routes/WS/seed
  hooks come with the gateway inversion (A-014). `Entry`/`ProcFn` are the exact ABI `registry`
  already dispatches.
- **`src/procedures/registry.zig`** — dropped the `atomicassets_*` imports + table entries; added
  `registerDomains(procs)` — a startup-set slice of external-domain procedures that `lookup()`
  consults after the comptime built-ins. The engine core now imports no AtomicAssets code.
- **`src/main.zig` (composition root)** — imports the domain via `src/atomicassets` (a symlink to the
  package's `src/`, like `deps/meshguard`) and calls `registerDomains(atomicassets.manifest.procedures)`
  at startup. Switched the engine import from `@import("lib.zig")` (a file-import copy) to the named
  `@import("wormdb")` module so main and the domain share ONE engine instance (otherwise their
  `Domain`/`Entry`/`Ctx` types belong to different module instances and don't match).
- **`build.zig`** — share a single `build_options` module across all modules (per-module copies
  collide once main routes through the named `wormdb` module).
- **Deleted** `src/atomicassets/{binfmt,overlay,mod}.zig` and `src/procedures/atomicassets_{assets,
  apply}.zig` — they now live only in `wormdb-domain-atomicassets`.

The domain package (`wormdb-domain-atomicassets`) builds + tests standalone against the core `wormdb`
module (its own `build.zig.zon` path-deps `../wormdb`) and exports `pub const manifest`.

## Key learnings (Zig module/package mechanics)

- **The "diamond".** Consuming the domain via `build.zig.zon` + `b.dependency` fails: the domain
  depends back on `../wormdb` (the build root), so Zig sees `wormdb` as both the root and a
  dependency-of-a-dependency and refuses (`file exists in modules 'root' and '...wormdb'`). A package
  that depends back on the root engine can't be a normal dependency. The clean fix is to split the
  engine into a **core-lib package** that both the domains and the server (exe) depend on — deferred.
- **The workaround that works now:** symlink the package's `src/` into the engine at `src/<domain>`
  and import its `manifest` as a plain file in the exe module, with the exe using the **named**
  `wormdb` module — so the domain shares the exe's single engine instance (types match, no diamond).
  This mirrors how `meshguard` is wired.
- **One `build_options`** — `addOptions().createModule()` per module yields distinct instances that
  conflict once composed; create it once and share.

## Acceptance Criteria

- Engine core (`lib.zig`, `registry.zig`) imports no AtomicAssets code; `src/atomicassets/*` +
  `src/procedures/atomicassets_*` deleted. ✓
- `zig build` + `zig build test` green in WormDB; the domain package builds + tests standalone. ✓
- The AtomicAssets EXEC procedures (`atomicassets_assets_by_owner`, `aa_mint/transfer/burn`) resolve
  at runtime via `registerDomains`; startup logs `Composed domain 'atomicassets': 4 procedures …`. ✓
- Light-API + the gateway dispatch unchanged. ✓ (gateway AA route is a string→`execProc` ref.)

## Out of scope (follow-ups)

- **A-014:** fold the gateway's hard-coded `/atomicassets` + `/api` routes (and WS methods) into the
  `Domain` manifest so the gateway is generic too (per-route param extraction).
- Split the engine into a core-lib package so domains can be consumed via `b.dependency` (pinned
  releases) instead of the `src/` symlink.
- Repeat the extraction for Light-API; publish `antelope` as a shared library package.
