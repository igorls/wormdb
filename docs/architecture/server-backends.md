# Server Backends

WormDB's transport layer is decoupled from command execution. The `--backend` flag selects which IO strategy handles TCP connections, while the same executor processes commands identically regardless of the choice.

## Available Backends

### `threadpool` (default)

A worker-pool model where each connection is handled by a dedicated thread. This is the most portable and debuggable option — stack traces are straightforward, each connection has its own execution context, and there are no platform-specific kernel requirements.

**Best for**: general use, development, any platform, maximum compatibility.

### `epoll`

A single-threaded event loop using Linux's `epoll` API. All connections are multiplexed on one thread, which avoids thread creation overhead and context switching. The tradeoff is that a slow command blocks all other connections until it completes.

**Best for**: high connection counts with fast commands, predictable Linux deployments.

### `io_uring`

Uses Linux's `io_uring` interface for asynchronous IO submission and completion. This provides the lowest syscall overhead — reads, writes, and accepts are batched through the submission/completion ring pair instead of individual syscalls.

**Best for**: latency-sensitive, high-throughput Linux setups on kernels 5.6+.

## Selection

```bash
./zig-out/bin/wormdb --backend threadpool --port 6389 --data ./data
./zig-out/bin/wormdb --backend epoll --port 6389 --data ./data
./zig-out/bin/wormdb --backend uring --port 6389 --data ./data
```

::: tip
Start with `threadpool`. Profile your actual workload with the scripts in `scripts/` before switching. The backend affects only IO handling — command semantics, response format, and durability behavior are identical across all three.
:::

## Decision Guide

| Factor        | threadpool                   | epoll                                 | io_uring                  |
| ------------- | ---------------------------- | ------------------------------------- | ------------------------- |
| Platform      | Any                          | Linux                                 | Linux 5.6+                |
| Connections   | Good (bounded by pool size)  | Excellent (epoll scales to thousands) | Excellent                 |
| Latency       | Moderate (context switching) | Low (no thread overhead)              | Lowest (batched syscalls) |
| Debugging     | Easy (one thread per conn)   | Harder (state machine)                | Harder (async completion) |
| Slow commands | Other connections unaffected | Blocks the event loop                 | Depends on implementation |
