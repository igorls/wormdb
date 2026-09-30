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

- `zig build wasm` emits a **reactor** with the FFI entry points as exports (19 exports, `memory`
  and 18 `wormdb_*` functions; no `_start`). A host cannot link an archive, it needs the exports.
- `zig build ffi` emits a **static archive** for linking into a native (or iOS) embedding.

The FFI is **static** on wasm. There is no `dlopen`-style shared library for wasm: a `-dynamic`
build needs position-independent objects and the wasm crt/libc objects are not built that way.
This mirrors iOS, which also static-links.

## Running it in a page

`examples/browser-wormdb/` is a working page. It needs no `wasi_snapshot_preview1` polyfill: a
~100-line shim implements the clock, RNG, write and exit, and returns `ENOSYS` for everything
else. That last part is deliberate — an accidental filesystem call fails loudly instead of
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
allowlist. A procedure is available only if it is named there, and a comptime check fails the
build if an allowlisted procedure reaches cluster. Procedures that need clustering are **absent**
rather than stubbed: asking for one returns "unknown procedure", which is honest. Where the
shared `context.zig` still needs a `Cluster` type, `compat.ClusterStub` stands in and **every
method refuses** (`error.ClusterUnsupportedOnThisTarget`) — a no-op `replicateWrite` would report
a replication that never happened, and a zeroed `identityPublicKey` would look like a real
identity.

## What the wasm artifact has

- the key/value engine: put, get, scan, transfer, increment, delete
- WAL durability. On a single-threaded build the group-commit thread is not started and the
  producer writes directly, fsyncing each record and fencing later writes after an uncertain
  sync. That is the same guarantee the threaded path gives, not a reduced one.
- snapshots and the storage engine
- the vector index: insert, search, delete, stats, rebuild
- the append log and its verification
- the memory/introspection procedures
- the event bus

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

1. **`if (comptime X) return;` is not a terminator for analysis.** `std.Thread.spawn` is a
   `@compileError` in single-threaded mode, and it fires from *being analysed*, not from being
   reached. Only moving the call into an `else`-branch keeps it out of the build, which is how
   `NamespaceIndex.enableAsyncMode` is written.
2. **`std.Thread.join` carries the same asm.** Its wasm path contains `memory.atomic.wait32`.
   Joining only happens in a multi-threaded build, so the two join sites in `storage/wal.zig` and
   `vector/index.zig` are guarded on `single_threaded` as well. That guard was the actual last
   blocker, and it is not a wait site one would search for.
3. **A no-op filesystem call still needs a filesystem.** `wormdb_open` created the data directory
   unconditionally, including for `PersistenceMode.none`. Harmless natively, fatal for a host that
   has no filesystem: it forces the page to implement one. Skipped when the mode is `.none`.

Ruled out and recorded so it is not retried: there is **no non-atomic `Io` completion mode** in
Zig 0.16. `Threaded.futexWaitUncancelable` lowers to the asm unconditionally, the wait sits in
`waitForCancelWithSignaling`, and the wasm branch asserts the atomics feature.

## The WASI surface the host must provide

Measured from the built module, so the JS-side shim size is known rather than guessed:

- **31 imports**, all from `wasi_snapshot_preview1`: `args_get`, `args_sizes_get`, `clock_res_get`,
  `clock_time_get`, `fd_*` (fdstat, filestat, pread, pwrite, read, write, seek, prestat, sync,
  readdir, close…), `path_*` (create_directory, filestat, link, open, readlink, remove_directory,
  rename, symlink, unlink_file…), `random_get`, `proc_exit`, `poll_oneoff`, `sched_yield`.
- **Exports**: `memory` and 18 `wormdb_*` functions (`open`, `open_sync`, `close`, `set`,
  `set_worm`, `get`, `get_meta`, `scan_prefix`, `delete`, `exec`, `append_log`,
  `append_log_verify`, `proof_build_mmr_bundle`, `proof_verify_bundle`, `mmr_proof_verify`,
  `free`, `version`). No `_start` — this is a reactor.

There is no bespoke host interface. Only four of those imports are reachable on the in-memory
path (`clock_time_get`, `random_get`, `fd_write`, `proc_exit`); the rest exist for the
persistent modes and are stubbed to `ENOSYS`, so a deployment that has no filesystem finds out
immediately rather than silently. `wormdb_open_sync` is among the exports, which is the symbol
hosts like Meshrooms look up by name.

## Not yet done

- **Persistent modes on wasm.** Only `PersistenceMode.none` is exercised end to end. The WAL and
  snapshot paths compile and their WASI imports are present, but nothing has run them against a
  real WASI filesystem, so their durability claims are unverified on this target.
- **Firefox and OPFS**, and the cold-open timing gates the Meshrooms spike branch defines. The
  demo has been run in Chrome (and headlessly) only.
- **The vector index and the cluster-free procedures beyond key/value and the append log.**
  They are in the reduced root and on the allowlist, but the browser run has not touched them.
