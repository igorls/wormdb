# Performance Analysis Review — WormDB

## Project Context

WormDB is a high-performance key-value store written in Zig, with a binary protocol (WormWire) and a Bun/TypeScript client. It supports WORM (Write Once Read Many) semantics, pub/sub, stored procedures, and cluster replication.

The server currently has **3 backend implementations**:

1. **Thread pool** (`tcp.zig`) — 48 worker threads, blocking recv/send per connection
2. **io_uring** (`uring.zig`) — single-threaded event loop with io_uring SQE/CQE
3. **epoll** (`epoll.zig`) — single-threaded non-blocking I/O (Redis-style)

All 3 share a command executor (`executor.zig`). Binary protocol parsing is in `wire.zig`.

## Current Benchmark Results (8 connections, inflight=1, 128B values)

| Backend     | GET p50  | SET p50  | MIXED p50 | GET ops/s |
| ----------- | -------- | -------- | --------- | --------- |
| Thread Pool | **53μs** | **53μs** | **50μs**  | 120K      |
| io_uring    | 74μs     | 56μs     | 59μs      | 87K       |
| epoll       | 105μs    | 51μs     | 62μs      | 58K       |
| **Redis**   | **37μs** | **38μs** | **36μs**  | **183K**  |

**Gap to close: ~15μs on GET (53μs → 37μs), ~14μs on SET (53μs → 38μs).**

## Review Scope

Identify concrete optimizations that could close the ~15μs latency gap with Redis. Specific questions:

1. **Is the WormWire binary protocol too complex?** Redis uses RESP (text-based, `\r\n` delimited). WormWire uses a TLV binary framing (1B cmd + 4B len + payload). Is the parsing overhead measurable? Would a simpler framing or zero-allocation parse help?

2. **What is the overhead of the shared executor?** The `executor.execute()` function switches on all command variants. Could this be optimized (e.g., direct function pointer dispatch)?

3. **Are there unnecessary memory allocations on the hot path?** Redis avoids malloc on the hot path. Where are we allocating per-request?

4. **Is the client (Bun) a bottleneck?** The benchmark runs from Bun over TCP. Is there overhead in the TypeScript wire encoding/decoding that inflates the measured latency?

5. **What kernel/syscall optimizations are we missing?** Redis uses `writev` for multi-buffer responses, pre-forks workers, uses `SO_REUSEPORT`. What else?

6. **Should we pursue multi-core epoll/io_uring?** N event loops bound to N cores with `SO_REUSEPORT` — is this the path to beating Redis?

## Attached Context Packs

| File                | Contents                                                                                                                              | Token Estimate |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| `context_server.md` | Full Zig source: server backends (tcp/uring/epoll), executor, protocol (wire + text parser), storage, event bus, cluster, types, main | ~46K           |
| `context_client.md` | Bun/TypeScript client: wire protocol implementation, TCP client, benchmarking harness (CLI, runner, scenarios), tests                 | ~41K           |

## Focus Areas

1. **Protocol overhead** — Compare WormWire framing to RESP. Analyze parsing hot paths in both Zig (`wire.zig:readFrameZeroCopy`, `wire.zig:parseCommandPayloadZeroCopy`) and TypeScript (`wire.ts`). Identify unnecessary copies or allocations.

2. **Memory allocation on hot path** — Find every `alloc`/`dupe`/`allocPrint` call in the request-response cycle. Which can be replaced with stack buffers, arenas, or pre-allocated pools?

3. **Syscall efficiency** — Analyze the syscall pattern for each backend. How many syscalls per request-response cycle? Compare to Redis's pattern.

4. **Event loop design** — Evaluate the epoll and io_uring implementations. Are there design flaws causing the single-threaded bottleneck? Should we use multi-ring or multi-threaded event processing?

5. **Client-side overhead** — Analyze the Bun wire encoder/decoder. Is there TypeScript overhead inflating measured latency? Is the benchmark methodology sound?

6. **Missed optimizations** — Any other techniques Redis uses (or newer approaches) that we're not leveraging. Consider: `TCP_CORK`, `MSG_ZEROCOPY`, kernel bypass (`DPDK`/`XDP`), buffer pre-registration for io_uring, response caching.

## Output Format

For each finding, provide:

- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **File**: path and line numbers
- **Category**: which focus area
- **Description**: what the issue is
- **Impact**: estimated latency reduction (μs) if addressed
- **Suggested Fix**: concrete code-level recommendation

Group findings by severity. End with a summary: total counts, top 3 optimizations by impact, overall assessment of what's realistic to close the Redis gap.
