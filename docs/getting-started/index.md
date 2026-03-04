# What is WormDB?

WormDB is a distributed key-value store written from scratch in Zig. It's designed around a single idea: **some data should never be changed after it's written**.

Financial ledgers, audit trails, compliance records, sensor logs — in all of these domains, the ability to silently overwrite history is a liability. WormDB makes immutability a first-class primitive. When you write a key with the WORM flag, it's sealed permanently. No overwrites, no deletes, no exceptions.

## Why Zig?

Zig gives WormDB explicit control over memory allocation, no hidden allocators, no garbage collection pauses, and no runtime surprises. Every allocation is visible, every error is handled, and the compiled binary is a single ~2 MB static executable with zero dependencies beyond `libsodium` for cluster identity.

## Key Capabilities

**Embedded Procedures** — Instead of round-tripping commands over the network for multi-key operations, WormDB compiles Zig procedures directly into the server binary. Procedures like `increment` and `transfer` acquire shard locks, read/write multiple keys atomically, and return results — all in a single network call.

**Binary Protocol** — WormWire v1 is a purpose-built binary protocol. Every frame carries a 1-byte command ID, a 4-byte big-endian length, and the payload. No text parsing, no ambiguity about delimiters, no wasted bytes.

**Mesh Clustering** — Nodes find each other through SWIM gossip over UDP and replicate writes over persistent TCP connections using the same WormWire framing. No external coordinator (ZooKeeper, etcd) is needed.

**Pluggable Backends** — The transport layer is swappable between a thread pool, `epoll`, or `io_uring` — each sharing the same command executor, so your choice of backend never changes command semantics.

## What's in These Docs

| Section                                        | What You'll Find                                                   |
| ---------------------------------------------- | ------------------------------------------------------------------ |
| [Quick Start](/getting-started/quick-start)    | Build, run, and verify a local instance in 5 minutes               |
| [Clients & Commands](/getting-started/clients) | Using the reference client, command examples, and response formats |
| [Architecture](/architecture/)                 | Runtime layers, data model, and design rationale                   |
| [Operations](/operations/)                     | Persistence modes, cluster deployment, troubleshooting             |
| [Protocol](/protocol/)                         | WormWire v1 frame format and command reference                     |
| [Reference](/reference/cli/)                   | CLI flags and status field definitions                             |

## Prerequisites

- **Zig 0.15+** — the build toolchain
- **libsodium** — used for cluster node identity generation
- **Bun** — runs the reference client and admin UI
