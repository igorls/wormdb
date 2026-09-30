# WormDB on WebAssembly

`zig build ffi -Dtarget=wasm32-wasi` produces a WebAssembly module of the engine. This document
records what that artifact contains, what it deliberately does not, and why — so nobody
rediscovers the constraints from a wall of compiler errors.

## Build

```sh
zig build ffi -Dtarget=wasm32-wasi -Dcpu=baseline+atomics
```

The atomics feature is required: the engine's lock and futex primitives lower to
`memory.atomic.wait32` / `atomic.notify`, which wasm only has with it. Browsers ship it.
Building without the feature also compiles — the primitives become inert (see below) — but that
configuration is not exercised by the smoke test.

The FFI is **static** on wasm. There is no `dlopen`-style shared library for wasm: a `-dynamic`
build needs position-independent objects and the wasm crt/libc objects are not built that way.
This mirrors iOS, which also static-links.

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

## Building it: which configuration, and why the obvious choice does not work

**The no-atomics build does not compile.** `zig build ffi -Dtarget=wasm32-wasi` fails with
`instruction requires: atomics` (3 errors); `-Dcpu=baseline+atomics` succeeds (0 errors). This is
counter-intuitive, because a single-threaded database should not need atomics at all, so the
reason is recorded here.

The wait is **not** in WormDB's own locks. Every lock in the reduced graph is already inert on a
wasm target. It is `std.Io.Threaded`'s operation-completion path:
`Thread.futexWaitUncancelable(&num_completed.raw, ...)` at `std/Io/Threaded.zig:618` and `:782`.
Zig 0.16's blocking `Io` waits for I/O completion that way, and `Threaded.futexWaitUncancelable`
lowers to `memory.atomic.wait32` on wasm unconditionally — there is no non-atomic variant to
select (checked: the wait sits in `waitForCancelWithSignaling`, and no alternate completion mode
is exposed). So any build that uses blocking `std.Io` for file I/O compiles that path.

The three routes, none of them free:

1. **Ship the `+atomics` build with SHARED memory.** Then `wait32` is valid. Cost: a shared
   memory needs `SharedArrayBuffer`, which the page can only obtain under cross-origin isolation
   (COOP/COEP). That constrains every cross-origin load on the hosting page.
   Measured: the artifact does contain atomic operations — 11,316 occurrences of the atomic
   opcode prefix (0xFE) — so instantiating it with unshared memory would trap on first
   contention rather than degrade.
2. **Keep the no-atomics build and remove the engine's blocking `Io` dependency** for file I/O,
   replacing it with direct WASI file calls. This is the "host-import shim" in its real form and
   it touches storage, not just the FFI.
3. **A non-blocking or single-threaded `Io` completion mode** that never waits. Ruled out for
   Zig 0.16 as shipped (see above).

Until one of these is chosen and implemented, the buildable configuration is route 1, and that is
the only one documented as working. Do not read this as a recommendation of shared memory for the
browser deployment — that trade-off belongs to the deployment, not to the database.

## The WASI surface the host must provide

Measured from the built module, so the JS-side shim size is known rather than guessed:

- **33 imports**, all from `wasi_snapshot_preview1`: `args_get`, `args_sizes_get`, `environ_get`,
  `environ_sizes_get`, `clock_res_get`, `clock_time_get`, `fd_*` (fdstat, filestat, pread,
  pwrite, read, write, seek, prestat, close, renumber, readdir…), `path_*` (create_directory,
  filestat, open, remove, rename…), `random_get`, `proc_exit`, `poll_oneoff`, `sched_yield`.
- **Exports**: `memory` and `_start`.

So a WASI-capable host (wasmtime, or a bun/node WASI host) needs nothing beyond the standard
preview1 imports; there is no bespoke host interface. That is a smaller shim than the phrase
"host-import shim" suggests, but it is the whole of the file-I/O dependency in route 2 above.

## Not yet done

- The smoke test exercising allowlisted procedures end to end through the reduced root.
- Verifying the no-atomics build (the inert path) rather than only the atomics one.
- A browser-side harness: instantiating the module, and the WASM-4 qualification gates
  (Firefox/OPFS, cold open) that the Meshrooms spike branch defines.
