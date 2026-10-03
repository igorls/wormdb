# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

WormDB is a distributed key-value store written in **Zig 0.16**, with a WORM (write-once-read-many) mode, pub/sub event streaming, encrypted clustering, and a co-located vector-search engine. The server is a single static binary; the Bun/TypeScript code under `apps/` is reference clients and tooling, not part of the server.

## Build, Test, Run

**Linux** is the primary target and the only platform with clustering and the io_uring/epoll backends. **Windows** is supported for single-node use (threadpool backend; no clustering) — see [docs/WINDOWS.md](docs/WINDOWS.md). Requires **Zig 0.16+** and **libsodium**. `deps/lib/libsodium.so` is linked on Linux; `deps/lib/windows-x86_64/libsodium.a` (static MinGW) on Windows. [build.zig](build.zig)'s `linkSodium` branches on target OS.

Platform-specific code is centralized: OS branching lives in [src/core/compat.zig](src/core/compat.zig) (time, socket I/O, `setNoDelay`), with Linux-only backends gated in [src/server/mod.zig](src/server/mod.zig) and cluster/WireGuard calls comptime-gated in [src/cluster/node.zig](src/cluster/node.zig). Prefer adding to `compat.zig` over reaching into `std` directly.

```bash
# First-time setup — meshguard (required), libwtf/msquic (QUIC only) are git submodules.
# deps/meshguard is empty until you do this; the build will fail without it.
git submodule update --init --recursive

zig build                       # debug build of zig-out/bin/wormdb
zig build -Doptimize=ReleaseSmall   # production binary (~45KB)
zig build -Dquic=true           # opt-in QUIC/WebTransport gateway (needs prebuilt deps/msquic + deps/libwtf)
zig build run -- --port 6389 --data ./data   # build + run with args after `--`
```

### Tests

```bash
zig build test                  # full Zig suite — src/lib.zig refAllDecls walks every module's tests
zig test src/vector/distance.zig    # single vector module (vector/* tests are self-contained, no libsodium link)
cd apps/bun && bun test         # TypeScript client tests (mocked sockets, no running server needed)
zig run src/vector/bench.zig -O ReleaseFast -lc   # vector search microbench
```

There is no single-test-by-name runner for Zig here; isolate by passing one file to `zig test`. Modules that pull in `storage`/`cluster`/crypto need libsodium linked (`-L deps/lib -lsodium`), so prefer `zig build test` for those.

## Architecture

`src/lib.zig` is the module root; `src/main.zig` is the executable (arg parsing, config load, wiring, backend selection). Everything is composed in `startServer()` in [src/main.zig](src/main.zig) — read that function to see how Store, EventBus, Cluster, NamespaceRegistry, Server, and the gateways connect.

Module map (each is a directory with `mod.zig`):

- **core** — `types.zig` (Entry/Command/Response/CommandId), `config.zig` (JSON config + CLI override schema), `compat.zig` (Zig-0.16 std shims: Io, Mutex, net, time, randomBytes).
- **storage** — `store.zig` is a **256-shard** `StringHashMap`, sharded by `FNV1a(key) & 255`; each shard has its own mutex plus a sorted key index (same `*Entry` objects), so prefix scans/counts are O(log n) range seeks rather than full-shard walks — every mutation must go through `shardPutLocked`/`shardRemoveLocked` (or `Store.deleteUnsafe`) to keep the two views in sync. `wal.zig` is an append-only WAL with per-record CRC32. Snapshots use magic `WDBSNAP1`; **v2** appends an HNSW trailer (`WDBHNSW2`) so vector graphs persist alongside KV.
- **protocol** — `wire.zig` is the WormWire binary codec. Client connections open with magic `0x57 0x57` ("WW"); replication connections use `0x57 0x52` ("WR"). Frames are `[1B id/code][4B big-endian len][payload]`, 16 MiB max. Raw `nc`/`telnet` is rejected.
- **server** — `executor.zig` is the transport-agnostic command dispatcher (used by all backends). Three interchangeable backends, chosen by `--backend`: `tcp.zig` (threadpool, default, thread-per-connection), `uring.zig` (io_uring), `epoll.zig`. `gateway.zig` is a WebSocket bridge for browsers; `quic_gateway.zig` is compile-time gated behind `-Dquic`. `auth.zig` validates Ed25519 SCT tokens (per-gateway enforcement).
- **event** — `bus.zig`, prefix-matched pub/sub channels. `SUB vec:` catches every `vec:*` event.
- **cluster** — `node.zig` embeds meshguard for SWIM gossip discovery, failure detection, and encrypted (ChaCha20-Poly1305) replication over WireGuard tunnels. No central coordinator. Holds persistent `PeerConnection`s; new peers trigger an anti-entropy full-state sync.
- **procedures** — compiled-in `EXEC` handlers (see below).
- **vector** — `distance.zig` (SIMD AVX2/NEON cosine/dot/L2 + Hamming + binary quantization), `hnsw.zig` (graph index), `index.zig` (`NamespaceIndex` + `NamespaceRegistry`, per-namespace), `metric.zig`, `topk.zig` (bounded min-heap), `rabitq.zig` (1-bit quantization).

### Write path

`SET`/`DEL` → `executor.execute` → `store.set`/`store.delete` (local commit is authoritative, WAL appended) → if a cluster is attached, `cluster.replicateWrite`/`replicateDelete` (failures are logged, never fail the client write). WORM violations surface as `error.WormViolation` → `ERR` response.

### Vector path

Writes go through the normal durable/replicated WormWire path (`VINSERT`/`VBULKINSERT` native frames, or `EXEC vinsert`). Key layout: `vec:<ns>:<id>` (raw f32), `bq:vec:<ns>:<id>` (1-bit-per-dim hash). `vsearch` auto-selects HNSW → BQ-prefilter → brute-force by what the namespace supports; metric is frozen on a namespace's first insert. The HNSW graph is a *serving index derived from durable `vec:*` entries* — WAL replay after the last snapshot does **not** replay index mutations, so run `EXEC vreindex <ns>` after raw `SET` ingest or recovery from an old snapshot. Search is **local-node only**; cluster scatter-gather is not implemented.

## Stored Procedures (`EXEC`)

Procedures are native Zig functions compiled into the binary, executed server-side under automatic shard locking — atomic multi-key ops in one round-trip. **There is a dedicated skill at [.agent/skills/wormdb-procedures/SKILL.md](.agent/skills/wormdb-procedures/SKILL.md) — read it before writing a procedure.**

Adding one touches three files:
1. `src/procedures/<name>.zig` — `pub fn execute(ctx: *Ctx) anyerror!Ctx.Result`
2. `src/procedures/registry.zig` — add the `@import` and a `PROCEDURES` table entry (name → fn)
3. `src/procedures/mod.zig` — add the `pub const` re-export

The `Ctx` API ([src/procedures/context.zig](src/procedures/context.zig)) handles args, locking, store access, and responses. Non-obvious hazards baked into this design:

- **`ctx.set()`/`ctx.setInt()` bypass the WAL** (they call `store.setUnsafe`). Procedure-written data is durable only at the next snapshot. Use `ctx.setDurable*` for WAL + replication.
- **`ctx.del()` bypasses the WORM check** and the WAL. `ctx.deleteDurable` enforces WORM and replicates.
- **Lock before read**, always. Use `lockKeys2` for two keys (deadlock-safe ordering). **Max 16 shard locks** per call — exceeding silently no-ops. Locks auto-release on return; never unlock manually.
- **`setDurable`/`deleteDurable` release all held shard locks during the store-write + replicate**, then re-acquire in ascending order. This is deliberate: `replicateWrite` can trigger an anti-entropy scan that locks every shard, which would deadlock against a held lock.
- **Scratch-buffer aliasing**: `ctx.fmt()` and `ctx.randomHex()` share one 512B buffer (each call overwrites the last); `ctx.setInt()`/`ctx.valueInt()` share a separate 32B buffer. Copy a result before producing another.

## Conventions

- **Zig 0.16 is young and the std API churns.** This code uses 0.16-isms (`std.process.Init` "Juicy Main", the new `std.Io` interface, `Module`-based linking in `build.zig`). `src/core/compat.zig` centralizes std shims — prefer it over reaching into `std` directly for IO/time/random/net/mutex so a single API break is patched in one place.
- Big-endian for all multi-byte wire integers. Payloads cap at 16 MiB.
- Default client port **6389** (deliberately not Redis 6379); gossip **51821** (UDP); WireGuard **51830**.
- Config is JSON (`./wormdb.json` by default, `--config` to override); CLI flags override file values. See `printHelp` in main.zig for the full flag list and `core/config.zig` for the schema.
- Bun client test files are `apps/bun/src/lib/*.test.ts`.

## Repo Workflow

This repo runs a **PM-led agent workflow** documented in [agents/README.md](agents/README.md): work packages live in `agents/work-packages/`, reviews in `agents/reviews/`, priorities in [agents/BACKLOG.md](agents/BACKLOG.md). Execution agents stay strictly in package scope (no unrelated refactors), run the package's listed validation commands, and don't mark work complete without passing them. Commit messages follow Conventional Commits (`feat(memory):`, `fix(memory):`, `docs(rabitq):`).
