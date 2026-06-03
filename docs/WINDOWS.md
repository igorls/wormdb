# Windows Support

WormDB builds and runs natively on Windows (single-node). This page covers the
build, what works, the limitations, and what a clustering port would take.

## TL;DR

| Capability | Windows | Notes |
| --- | --- | --- |
| KV store (GET/SET/DEL) | ✅ | |
| WORM immutability | ✅ | |
| Pub/Sub event bus | ✅ | |
| Stored procedures (`EXEC`) | ✅ | |
| Vector search (SIMD/HNSW/BQ) | ✅ | AVX2 path; HNSW recall test passes |
| WAL + snapshot persistence | ✅ | |
| WebSocket gateway | ✅ | |
| Server backend | threadpool only | `io_uring`/`epoll` are Linux-only |
| QUIC/WebTransport gateway | ⛔ (untested) | opt-in `-Dquic`; MsQuic supports Windows but unverified here |
| Clustering / replication | ⛔ | meshguard's kernel WireGuard is Linux-only — see below |

## Prerequisites

- **Zig 0.16+**. The native target resolves to `x86_64-windows-gnu` (MinGW ABI).
- **libsodium** — a static MinGW build is vendored at
  `deps/lib/windows-x86_64/libsodium.a`; [build.zig](../build.zig) links it
  (plus `advapi32`/`bcrypt` for libsodium's CSPRNG and `ws2_32` for Winsock) for
  Windows targets. No system install or `sodium.h` header is required.
- **meshguard** sources at `deps/meshguard` (the same submodule used on Linux).
  Cluster code is compiled but inert on Windows.

## Build & run

```powershell
zig build                       # debug build → zig-out\bin\wormdb.exe
zig build -Doptimize=ReleaseSmall
zig build test                  # full unit suite (126/126 pass on Windows)

zig-out\bin\wormdb.exe --port 6389 --data .\data
```

The threadpool backend is the default and the only one available on Windows; a
`--backend uring|epoll` request logs a warning and transparently falls back to
threadpool.

## How the port works

Almost all platform-specific code is funnelled through
[src/core/compat.zig](../src/core/compat.zig). The Windows-relevant pieces:

- **Time** — `nowMs`/`nowNs` use `std.Io.Timestamp.now(.real / .awake)` (the
  cross-platform 0.16 clock vtable) instead of `std.c.clock_gettime`.
- **Socket I/O** — `net.Stream.read`/`writeAll` keep the raw POSIX path on
  Linux but route through the `std.Io` net vtable on Windows, because Winsock
  `SOCKET`s are not CRT file descriptors (so `std.posix.read`/`write` are
  invalid on them, and `std.posix.recv`/`send` don't exist in this Zig).
- **TCP_NODELAY** — `setNoDelay` calls `std.posix.setsockopt` on Linux and
  Winsock `setsockopt` (via `@extern("ws2_32")`) on Windows; the POSIX one is a
  hard `@compileError` on Windows.
- **Backends** — `uring.zig`/`epoll.zig` (which call `std.os.linux` directly)
  are gated behind `os.tag == .linux` in [server/mod.zig](../src/server/mod.zig)
  and collapse to empty namespaces elsewhere; [main.zig](../src/main.zig) only
  references them inside `comptime`-Linux blocks.
- **libsodium** — [server/auth.zig](../src/server/auth.zig) now binds libsodium
  with `extern "c"` declarations instead of `@cImport("sodium.h")`, so no header
  is needed on any platform.
- **Cluster** — the meshguard WireGuard/netlink and `getaddrinfo` calls in
  [cluster/node.zig](../src/cluster/node.zig) are `comptime`-gated to Linux;
  main.zig logs and runs single-node when `--cluster` is requested on Windows.

## Clustering on Windows — investigation

Clustering is **not** available on Windows today. The blocker is narrow but real:
wormdb calls meshguard's **kernel** WireGuard interface
(`wireguard.Config.setup`/`teardown`, implemented via Linux netlink in
`wg_config.zig`). meshguard gates that module to Linux only.

What's encouraging is that meshguard already ships most of a cross-platform
mesh:

- **Discovery (SWIM)** and **gossip encryption** (ChaCha20-Poly1305 over UDP) are
  not OS-gated — they already work on Windows.
- A **userspace WireGuard** stack exists and is not OS-gated: `noise.zig` (the
  handshake), `device.zig`, `tunnel.zig`, `crypto.zig`.
- A **Wintun** backend exists (`net/wintun.zig`) — it loads `wintun.dll` at
  runtime and does ring-buffer packet I/O — plus Windows interface config
  (`net/wincfg.zig`).

The one wormdb-specific wrinkle: replication is **plain WormWire over TCP**,
encrypted only by the WireGuard tunnel via mesh-IP routing (see
`PeerConnection.connect` in node.zig — it dials `real_addr orelse mesh_ip` with
no application-layer crypto). The existing `real_addr` "Docker fallback" already
sends replication in cleartext when no tunnel is up.

### Three ways to get there

1. **Userspace WireGuard + Wintun** — switch wormdb from `WgConfig.setup`
   (kernel) to meshguard's userspace `Device`/`Tunnel` driving a Wintun adapter.
   Gives full Linux parity (mesh-IP overlay + WG encryption). Cost: ship a signed
   `wintun.dll`, adapter creation needs admin, and wormdb has to own the
   userspace device lifecycle it currently delegates to the kernel. The
   meshguard pieces exist but need Windows validation. **Effort: medium–high.**
2. **App-layer encrypted replication over real addresses** — add
   ChaCha20-Poly1305 framing (keyed from the mesh identity meshguard already
   manages) to wormdb's replication stream and connect peer-to-peer over real
   addresses, skipping the TUN device entirely. No driver, no admin, fully
   portable — and it closes the existing cleartext `real_addr` gap on *every*
   platform. Cost: a wormdb-side replication protocol change + key wiring.
   **Effort: medium**, self-contained in wormdb.
3. **Plaintext over real addresses** — what the current Windows gating would do
   if cluster mode were enabled: discovery and replication function, but
   replication is unencrypted. Only acceptable on a fully trusted network; not a
   sane shipping default.

**Recommendation:** option 2 is the most portable and also hardens the existing
fallback; option 1 is the route to full Linux feature parity if the mesh-IP
overlay is required.
