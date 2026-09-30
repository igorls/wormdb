# WormDB on WebAssembly

WormDB runs in a browser. `zig build wasm -Dtarget=wasm32-wasi` produces the module a page (or
any WASI host) can load and call. This document records what that artifact contains, what it
deliberately does not, and why — so nobody rediscovers the constraints from a wall of compiler
errors.

## Build and run

```sh
zig build wasm       -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall   # -> zig-out/bin/wormdb_ffi.wasm
zig build wasm-smoke -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall   # run the FFI checks against it
```

**No atomics feature, no shared memory, no cross-origin isolation.** `-Dcpu=baseline` is the
configuration; the module is single-threaded and instantiates with ordinary (unshared) memory, so
a page needs no `SharedArrayBuffer` and therefore no COOP/COEP headers. This is the recommended
browser configuration and the one the smoke tests exercise.

Two artifact shapes exist and they are not interchangeable:

- `zig build wasm` emits the FFI entry points as exports: **19 exports — `memory`, `_start`, and 17
  `wormdb_*` functions** (measured from the built module, not counted by hand). A host cannot link an
  archive, so it needs the exports. Note the `_start` is present even though the module is built with
  `entry = .disabled`: it comes from the libc startup objects, not from a `main` in the FFI root.
- `zig build ffi` emits a **static archive** for linking into a native (or iOS) embedding.

The FFI is **static** on wasm. There is no `dlopen`-style shared library for wasm: a `-dynamic`
build needs position-independent objects and the wasm crt/libc objects are not built that way.
This mirrors iOS, which also static-links.

## Running it in a page

`scripts/wasi-shim.mjs` is the whole host interface. It needs no `wasi_snapshot_preview1`
polyfill: a ~100-line shim implements the clock, RNG, write and exit, and returns `ENOSYS` for
everything else. That last part is deliberate — an accidental filesystem call fails loudly instead of
appearing to work.

The in-memory path is genuinely filesystem-free. `wormdb_open` with `PersistenceMode.none` does
not even create the data directory, so the engine touches only `clock_time_get`, `random_get`,
`fd_write` and `proc_exit`. Verified in a real browser: four keys set and read back through
`wormdb_set`/`get`/`delete`, and three WORM records appended with `wormdb_append_log_verify`
returning `rc=0, count=3, last_seq=3` and a chain whose `prev_event_hash` links each record to
its predecessor.

## Two constraints, not one

They look like the same problem and are not, which is why gating one import at a time never
finished:

1. **The graph.** `src/lib.zig` re-exports `server`, whose tcp and gateway modules import
   `cluster`, which imports meshguard, whose membership lock lowers to `memory.atomic.wait32`.
   No amount of shimming fixes this: the dependency has to not be there.
2. **64-bit atomics.** Zig exposes no 64-bit atomic operations on wasm **at all** — not even
   with the atomics feature. So `std.atomic.Value(u64)` is a compile error there, independent of
   the wait instructions. The type is used for the HLC timestamp, the proof-log generation and
   the publish counter.

`compat.narrow_atomics` covers (1)'s wait instructions, `compat.narrow_u64_atomics` covers (2),
and `compat.wasm_target` excludes the socket and cluster graph outright.

## The reduced root

The wasm target compiles **`src/wasm_root.zig`**, not `src/lib.zig`. It never imports `server`,
`cluster`, or anything under them. `src/lib.zig` and the native public API are unchanged.

The procedure registry for this root is **`src/procedures/wasm_registry.zig`**, an explicit
allowlist. A procedure is available only if it is named there. **Zig cannot inspect another
module's imports at comptime**, so there is no language-level check: what enforces the allowlist is
`scripts/check-wasm-allowlist.zig`, run as a build step by `zig build wasm`, `wasm-smoke` and `ffi`
on a wasm target, which reads the allowlisted files and fails the build naming the file and line if
one imports the cluster or socket-bearing graph ungated. The list of files it scans is maintained by
hand, so a NEW file that reaches cluster is caught only once it is added to that list — the guard is
a strong check over a reviewed set, not a proof over the whole graph. Procedures that need clustering are **absent**
rather than stubbed: asking for one returns "unknown procedure", which is honest. Where the
shared `context.zig` still needs a `Cluster` type, `compat.ClusterStub` stands in and **every
method refuses** (`error.ClusterUnsupportedOnThisTarget`) — a no-op `replicateWrite` would report
a replication that never happened, and a zeroed `identityPublicKey` would look like a real
identity.

## What the wasm artifact has

- the key/value engine: put, get, scan, transfer, increment, delete
- WAL durability, **with a caveat the code states plainly**: on a single-threaded build the
  group-commit thread is not started and the producer writes directly instead of queueing. The
  durability of that path is NOT asserted here: `drainOnce` writes with `writeAll(...) catch {}`
  and never sets the sync-failure flag, so a failed write or sync is swallowed rather than reported
  (this is pre-existing behaviour, not a wasm-specific problem, and the threaded path shares the
  swallowing). Treat the wasm WAL as unproven for durability purposes until that is fixed.
- snapshots and the storage engine
- the vector index: insert, search, delete, stats, rebuild
- the append log and its verification
- the memory/introspection procedures
- the event bus

### The allowlist, exactly

The reduced root allows **26 procedures** (measured from `src/procedures/wasm_registry.zig`):
`append_log_append`, `append_log_verify`, `chat_history`, `chat_send`, `increment`, `kv_get`,
`kv_put`, `kv_stats`, `mem_capabilities`, `mem_drop`, `mem_health`, `mem_range`, `mem_reset_index`,
`mem_stats`, `mem_verify`, `scan`, `transfer`, `vdelete`, `vinsert`, `vnsdrop`, `vrabitq`,
`vreindex`, `vsearch`, `vsearch_local_raw`, `vsim`, `vstats`.

The full registry also exposes these, and the wasm root OMITS them. The first group cannot work
here; the second is **unlisted, not impossible** — a deliberate omission because nothing has proven
they are cluster-free on this target, and an unlisted procedure fails honestly ("unknown
procedure") whereas a wrongly-listed one would misbehave at runtime:

| Omitted | Why |
| --- | --- |
| `cluster_presence`, `vsearch_cluster`, `trust_grant`, `trust_revoke`, `trust_fold` | need cluster/meshguard |
| `append_log_witness*` (4), `append_log_claim*` (5), `append_log_mmr_proof`, `append_log_mmr_verify`, `append_log_proof_bundle`, `append_log_proof_verify`, `append_log_checkpoint`, `auth_mint_scoped`, `proof_prefix_root`, `mem_init`, `mem_add`, `mem_bulk_add`, `mem_meta_set`, `mem_get`, `mem_query`, `std` | unverified on wasm; adding one means proving it does not reach the socket or cluster graph |

That distinction matters: "absent because it needs a cluster" and "absent because nobody has checked
it yet" are different claims, and only the first is a property of the target.

## What it does not have, and why

| Absent | Why |
| --- | --- |
| the server (tcp, epoll, gateway, QUIC) | POSIX socket code; a wasm embedding is a library, not a server, and it is the edge that drags cluster in |
| cluster procedures (`vsearch_cluster`, `cluster_presence`) | need cluster, which needs meshguard's sockets and locks |
| trust procedures (`trust_grant`, `trust_revoke`, `trust_fold`) | reach `cluster/org_trust` |
| replication (`replicateWrite` and friends) | mesh transport; browser rooms use WebRTC, and "MeshGuard in the browser" is a later step |
| QUIC / WebTransport gateway | requires MsQuic, a C dependency with no wasm target |
| clustering of the vector index | peers would have to run against a cluster that does not exist here |

## Why a single-threaded database needed `single_threaded`, and three traps

A single-threaded build still reached `instruction requires: atomics` for a long time. The reason
is not WormDB's own locks — all of them are already inert on a wasm target — but that the wait is
emitted from *anywhere the atomic-wait asm appears*, and Zig's asm is not guarded the way the
comments suggest.

Setting `.single_threaded = true` on the wasm modules (the build.zig form of `-fsingle-threaded`)
is necessary: with it, `builtin.single_threaded` is comptime true and the `std.Io.Threaded`
completion path is not analysed. Three traps sit on top of it:

1. **`std.Thread.spawn` is a `@compileError` in single-threaded mode, and it fires from being
   ANALYSED, not from being reached** — so a call that can never execute still breaks the build.
   An earlier version of this section claimed `if (comptime X) return;` does not stop that analysis.
   **That was wrong, and it was settled by experiment rather than argument:** with `comptime x =
   true`, an `export fn` whose body is `if (comptime x) return; T.noSuchMethod();` COMPILES, while
   the same body with `x = false` fails — so the early return does suppress analysis of what follows
   it, and both spellings (early return, or an `else`-branch) keep the spawn out. The claim is
   corrected here because it contradicted `storage/wal.zig` and the `compat` locks, which rely on
   exactly the pattern it said did not work.
   The experiment used an invalid METHOD CALL as the probe, and an earlier attempt used an invalid
   free-function call, which proves nothing: a function that is never referenced is not analysed at
   all. The probe has to be reachable, which is why the final one was `export`ed and paired with a
   `false` control that fails as expected.
2. **`std.Thread.join` carries the same asm.** Its wasm path contains `memory.atomic.wait32`.
   Joining only happens in a multi-threaded build, so the two join sites in `storage/wal.zig` and
   `vector/index.zig` are guarded on `single_threaded` as well. That guard was the actual last
   blocker, and it is not a wait site one would search for.
3. **A no-op filesystem call still needs a filesystem.** `wormdb_open` created the data directory
   unconditionally, including for `PersistenceMode.none`. Harmless natively, fatal for a host that
   has no filesystem: it forces the page to implement one. Skipped when the mode is `.none`.

`std.Io.Threaded` has **no separate non-atomic mode, because `single_threaded` IS the switch.**
With it set, `futexWaitInner` is unreachable (its first line is `if (builtin.single_threaded)
unreachable;`, ahead of the `isWasm()` wait32 asm), so the wait is never emitted. The traps were
never a missing mode — they were code analysed *outside* that guard: `std.Thread.spawn`, which is a
`@compileError` in single-threaded mode merely by being analysed, and `std.Thread.join`, whose wasm
path contains the same atomic-wait asm. Reading this as "single-threaded does not work" would be
the opposite of the finding.

## The WASI surface the host must provide

Measured from the built module, so the JS-side shim size is known rather than guessed:

- **31 imports**, all from `wasi_snapshot_preview1`: `args_get`, `args_sizes_get`, `clock_res_get`,
  `clock_time_get`, `fd_*` (fdstat, filestat, pread, pwrite, read, write, seek, prestat, sync,
  readdir, close…), `path_*` (create_directory, filestat, link, open, readlink, remove_directory,
  rename, symlink, unlink_file…), `random_get`, `proc_exit`, `poll_oneoff`, `sched_yield`.
- **Exports**: `memory`, `_start`, and **17** `wormdb_*` functions: `open`, `open_sync`, `close`,
  `set`, `set_worm`, `get`, `get_meta`, `scan_prefix`, `delete`, `exec`, `append_log`,
  `append_log_verify`, `proof_build_mmr_bundle`, `proof_verify_bundle`, `mmr_proof_verify`, `free`,
  `version`.

There is no bespoke host interface. Only four of those imports are reachable on the in-memory
path (`clock_time_get`, `random_get`, `fd_write`, `proc_exit`); the rest exist for the
persistent modes and are stubbed to `ENOSYS`, so a deployment that has no filesystem finds out
immediately rather than silently. `wormdb_open_sync` is among the exports, which is the symbol
hosts look up by name.

## Not yet done

- **Persistent modes on wasm.** Only `PersistenceMode.none` is exercised end to end. The WAL and
  snapshot paths compile and their WASI imports are present, but nothing has run them against a
  real WASI filesystem, so their durability claims are unverified on this target.
- **Firefox and OPFS**, and any cold-open timing budget for a hosting page. The module has been
  run in Chrome (and headlessly) only.
- **The vector index and the cluster-free procedures beyond key/value and the append log.**
  They are in the reduced root and on the allowlist, but the browser run has not touched them.
