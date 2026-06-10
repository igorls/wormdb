# ChaCha20-Poly1305 backend benchmark — libsodium vs std.crypto

Benchmark gate for [meshguard#102](https://github.com/igorls/meshguard/issues/102):
should Linux default to libsodium (AVX2 8-block assembly) or `std.crypto`?

Harness: [bench/chacha_backend_bench.zig](chacha_backend_bench.zig). Raw AEAD
encrypt/decrypt, best of 5 rounds, ~1 GiB processed per cell. libsodium is loaded
at runtime via `dlopen` (no link-time dependency), so the same binary runs on
no-sodium and sodium hosts.

Run: `zig run bench/chacha_backend_bench.zig -O ReleaseFast -lc`
(set `LD_LIBRARY_PATH`/`DYLD_LIBRARY_PATH` if libsodium isn't on the default loader path).

## Results (throughput; `sodium/std` = libsodium speedup, avg of enc+dec)

### Linux x86_64, AVX2 — i7-11700K, std built `-mcpu=x86_64_v3`, libsodium.so.23 (runtime AVX2)
*The decisive row. std.crypto gets its AVX2 path; libsodium gets its 8-block AVX2 assembly.*

| payload | std MB/s | sodium MB/s | sodium/std |
|--------:|---------:|------------:|:----------:|
| 64 B (gossip)   |  278 |  260 | **0.93×** (std faster) |
| 256 B           |  524 |  660 | 1.26× |
| 1400 B (MTU)    |  620 | 1213 | **1.96×** |
| 8 KB            |  688 | 2027 | 2.95× |
| 64 KB (GSO)     |  721 | 2100 | 2.91× |

### Linux x86_64, baseline — same box, std built `-mcpu=baseline` (no AVX2), libsodium runtime AVX2
*Represents a generic/portable/container build where std.crypto is NOT AVX2-vectorized.*

| payload | std MB/s | sodium MB/s | sodium/std |
|--------:|---------:|------------:|:----------:|
| 64 B   |  272 |  263 | 0.97× |
| 256 B  |  382 |  664 | 1.74× |
| 1400 B |  434 | 1203 | 2.77× |
| 8 KB   |  444 | 1865 | 4.20× |
| 64 KB  |  438 | 1872 | 4.27× |

### macOS ARM64 — Apple M5, libsodium 1.0.22 (NEON), both NEON
*meshguard already uses std.crypto here; included as the ARM data point.*

| payload | std MB/s | sodium MB/s | sodium/std |
|--------:|---------:|------------:|:----------:|
| 64 B   | 172 | 319 | 1.85× |
| 256 B  | 442 | 560 | 1.27× |
| 1400 B | 533 | 684 | 1.28× |
| 8 KB   | 616 | 732 | 1.19× |
| 64 KB  | 622 | 736 | 1.18× |

## Reading the data

1. **x86_64 AVX2 is libsodium's strong case**: ~2× at MTU, ~3× at bulk. This is
   the WireGuard transport data path and GSO batches — a real, material delta
   (>> the issue's 20–30% "materially faster" threshold).
2. **Gossip-sized frames (64 B) get nothing from libsodium** — it's actually
   ~3–7% *slower* on x86_64, because FFI/dispatch overhead outweighs the
   assembly. SWIM control traffic should use std.crypto regardless of backend.
3. **ARM64 advantage is modest** (~1.2–1.3× at MTU/bulk), large only for tiny
   frames. Keeping std.crypto the ARM default (as today) is well-supported.
4. **std.crypto is not slow in absolute terms**: ~620 MB/s at MTU with AVX2 =
   ~5 Gbps single-core; libsodium ~1.2 GB/s = ~9.7 Gbps single-core.

## The gap this microbench does NOT close

The issue's decision rule is explicitly about **end-to-end mesh throughput**, and
warns: *"If the delta is large only in microbenchmarks but disappears in
end-to-end networking (syscall/data movement dominates), default to std.crypto."*

This harness measures **raw AEAD only** — not the tunnel packet path
(header/padding/nonce/replay-window) and not E2E mesh throughput where per-packet
`sendto`/`recvfrom` syscalls and data movement compete with crypto. At MTU,
std.crypto already sustains ~5 Gbps/core; whether a real tunnel is crypto-bound
at that rate determines whether libsodium's 2× raw win survives end-to-end.

**To finalize the default strictly per the rule, the tunnel-path / E2E bench
(issue workloads 2 and 3) still needs to run.** This microbench establishes the
*ceiling* of the libsodium advantage; E2E will show how much of it is realizable.

## Provisional recommendation

`-Dcrypto-backend=auto` → **std.crypto as the default everywhere; libsodium an
explicit, tested opt-in accelerator** (`-Dcrypto-backend=sodium`), auto-selected
on Linux only when explicitly requested/linked.

Rationale:
- It achieves #102's primary goal (libsodium off the critical build path) while
  std.crypto's ~5 Gbps/core at MTU covers the large majority of mesh deployments,
  where the network/syscall path — not ChaCha — is the limiter.
- libsodium's 2–3× raw win is preserved for genuinely crypto-bound, multi-Gbps
  single-tunnel users, as an opt-in.
- Gossip-sized control traffic is *faster* on std.crypto, so nothing is lost there.

If the pending E2E bench shows the tunnel data path is genuinely crypto-bound at
target throughput, escalate to `auto` defaulting to libsodium **on Linux x86_64
only**, while still guaranteeing `-Dcrypto-backend=std` is fully supported/tested
(the no-sodium acceptance criteria).

## Prerequisite, independent of the default decision

meshguard's `-Dno-sodium` does not currently reach the source: `tunnel.zig` and
`main.zig` select the backend from `builtin.os.tag` alone and never read the build
option (no `build_options` module is created). So `-Dno-sodium=true` on Linux
skips linkage but still compiles the sodium path → unresolved symbols. Whichever
default is chosen, that wiring must be fixed first for any of this to be testable.
