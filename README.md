# WormDB

A fast, distributed key-value store built in Zig. Encrypted replication, zero-config scaling, single static binary.

- **WORM mode** — Write-Once-Read-Many for immutable audit trails
- **WormWire protocol** — Binary framing over TCP, zero-copy capable
- **Pub/Sub streaming** — Real-time event channels with subscription management
- **Encrypted clustering** — P2P replication via meshguard (SWIM gossip + ChaCha20-Poly1305)
- **Org trust foundation** — meshguard certificate model, with WormDB-side enforcement wiring in progress
- **Vector search** — SIMD-accelerated (AVX2/NEON) with BQ prefilter and HNSW graph index; per-namespace cosine/dot/L2
- **Stored procedures** — Server-side transactional ops via `EXEC`, compiled into the binary

## Quick Start

```bash
# Fetch in-tree dependencies
git submodule update --init --recursive

# Build (requires Zig 0.16+, libsodium)
zig build -Doptimize=ReleaseSmall

# Run tests
zig build test

# Start server
./zig-out/bin/wormdb --port 6389 --data ./data
```

### Connect with the Bun Client

```bash
# Basic operations
bun run apps/bun/src/bin/client.ts SET mykey "hello world"
bun run apps/bun/src/bin/client.ts GET mykey
bun run apps/bun/src/bin/client.ts SET audit-log entry-001 WORM
bun run apps/bun/src/bin/client.ts STATUS

# Admin UI (http://localhost:8099)
UI_PORT=8099 WORMDB_PORT=6389 bun run apps/bun/src/bin/ui.ts
```

> **Note:** WormDB uses the WormWire binary protocol. Raw `nc`/`telnet` connections are not supported. Use the Bun client or any WormWire-compatible client.

## WormWire Protocol

All client connections use the **WormWire** binary framing protocol. Connections must begin with the magic bytes `0x57 0x57` ("WW"). The server rejects connections without the magic handshake.

### Frame Structure

```
Connection:  [ 0x57 0x57 ]                                        (once, on connect)
Request:     [ 1B Command ID ] [ 4B Payload Length (BE) ] [ payload... ]
Response:    [ 1B Response Code ] [ 4B Payload Length (BE) ] [ payload... ]
```

### Commands

| ID     | Command        | Payload                                                                     |
| ------ | -------------- | --------------------------------------------------------------------------- |
| `0x01` | GET            | `[4B key_len] [key]`                                                        |
| `0x02` | SET            | `[1B flags] [4B key_len] [key] [4B val_len] [value]`                        |
| `0x03` | DEL            | `[4B key_len] [key]`                                                        |
| `0x04` | STATUS         | _(empty)_                                                                   |
| `0x05` | CLUSTER STATUS | _(empty)_                                                                   |
| `0x06` | SUB            | `[4B channel_len] [channel]`                                                |
| `0x07` | UNSUB          | `[4B channel_len] [channel]`                                                |
| `0x08` | PUB            | `[4B channel_len] [channel] [4B msg_len] [message]`                         |
| `0x09` | EXEC           | `[4B proc_len] [proc_name] [4B arg_count] [ [4B arg_len] [arg] ... ]`       |
| `0x0A` | CLUSTER PEERS  | _(empty)_                                                                   |
| `0x0B` | SAVE           | _(empty — manual snapshot flush)_                                           |
| `0x0C` | AUTH           | `[4B token_len] [token]`                                                     |
| `0x0D` | VINSERT        | `[key] [vector] [1B flags] [namespace] [metric] [8B timestamp]`              |
| `0x0E` | VDELETE        | `[key] [namespace]`                                                          |
| `0x0F` | VBULKINSERT    | `[namespace] [metric] [1B flags] [4B count] [ [key] [vector] [8B ts] ... ]` |

### Response Codes

| Code   | Meaning | Payload                                 |
| ------ | ------- | --------------------------------------- |
| `0x00` | OK      | _(empty)_                               |
| `0x01` | VALUE   | Data (GET result or STATUS diagnostics) |
| `0x02` | NULL    | _(empty — key not found)_               |
| `0x03` | ERR     | UTF-8 error string                      |
| `0x04` | EVENT   | Unsolicited pub/sub push                |

In the native vector commands, `key`, `vector`, `namespace`, and `metric` are normal WormWire length-prefixed byte fields: `[4B len] [bytes]`. The vector flags byte uses bit `0x01` for WORM and bit `0x02` to request async HNSW construction. All multi-byte integers use **big endian** (network byte order). Maximum payload: **16 MiB**.

## Clustering

WormDB clusters use [meshguard](https://github.com/igorls/meshguard) for peer discovery (SWIM gossip), failure detection, and encrypted replication. No central coordinator required.

### Standalone

```bash
wormdb --port 6389 --data ./data
```

### Multi-Node Cluster

```bash
# Seed node
wormdb --port 6389 --data ./data1 --cluster myapp --gossip-port 51821

# Join nodes
wormdb --port 6390 --data ./data2 --cluster myapp --seed 10.0.0.1:51821
wormdb --port 6391 --data ./data3 --cluster myapp --seed 10.0.0.1:51821
```

### Org Trust (MeshGuard)

WormDB embeds meshguard for identity, SWIM gossip, and WireGuard tunnel setup. The current WormDB CLI runs the embedded cluster path in open mode; org-trust certificate issuance and enforcement lives in meshguard and is the next WormDB-side configuration surface to wire through.

MeshGuard's standalone CLI flow is:

```bash
# One-time: create org keypair
meshguard org-keygen
# → cluster-org.key (secret)  +  cluster-org.pub (share with seeds)

# Mint certificate for a new node
meshguard org-sign ./data2/identity.pub --name node-2

# Trust the org on a meshguard node
meshguard trust cluster-org.pub --org
```

### Docker Compose

```yaml
services:
  node1:
    image: wormdb:latest
    ports:
      - "16379:6389"
      - "51821:51821/udp"
    command: --cluster wormdb-cluster --gossip-port 51821

  node2:
    image: wormdb:latest
    ports:
      - "16380:6389"
      - "51822:51822/udp"
    command: --cluster wormdb-cluster --seed node1:51821 --gossip-port 51822
    depends_on:
      - node1
```

```bash
docker build -t wormdb:latest .
docker compose up -d
```

## Vector Search

Approximate-nearest-neighbor search over embeddings, co-located with the KV store. Every write is durable and replicated through the same WormWire path; a per-namespace HNSW graph accelerates the query path.

### Quickstart

```bash
# Insert (vector_bytes = raw little-endian f32 array; WORM by default)
bun run apps/bun/src/bin/client.ts EXEC vinsert doc-1 <bytes> 1 vec: cosine

# Search — top-10, optional temporal-decay weight, optional mode
bun run apps/bun/src/bin/client.ts EXEC vsearch query-key 10 vec: cosine 0 auto

# Bulk rebuild HNSW (use after restart, mixed SET-ingest, or replication catch-up)
bun run apps/bun/src/bin/client.ts EXEC vreindex vec:

# Pairwise similarity
bun run apps/bun/src/bin/client.ts EXEC vsim doc-1 doc-2 cosine

# Namespace stats
bun run apps/bun/src/bin/client.ts EXEC vstats vec:
```

### Dispatch hierarchy

`vsearch` auto-selects the fastest path that fits the namespace:

1. **HNSW graph** when the namespace has a registered index with a matching metric. Stage-1 traversal (ef = K × 10) → stage-2 exact refine with the user's metric and optional temporal decay.
2. **Binary-quantized prefilter** when no HNSW is available but `bq:*` hashes exist (every `vinsert` writes one — 1 bit per dimension, 32× compression). Hamming-ranks into a top-M pool, refines with exact distances.
3. **Brute-force** as the floor. Also the forced path when `mode=exact`.

Key layout:

```
vec:<namespace>:<id>         → raw f32 bytes (the embedding)
bq:vec:<namespace>:<id>      → 1-bit-per-dim BQ hash
__meta:<namespace>:count     → per-node insert counter (local, not replicated)
```

The HNSW graph is a serving index derived from the durable `vec:*` entries. Snapshot format v2 persists the graph, tombstones, and RaBitQ parameters when a snapshot is written; `vreindex` still rebuilds the graph from KV entries after raw `SET` ingest, WAL-only catch-up since the last snapshot, or manual recovery.

### Per-namespace metric

A namespace's distance metric is captured on its first `vinsert` and frozen. Queries under the same metric hit the HNSW fast path; queries under a different metric fall through to BQ (which is metric-agnostic — stage-2 re-ranks with whatever metric the query asked for).

```
EXEC vinsert doc-1 <bytes> 1 vec:articles:  cosine   # creates ns, metric=cosine
EXEC vinsert p-1   <bytes> 1 vec:products:  l2       # creates ns, metric=l2
EXEC vsearch q-vec 10 vec:articles:  cosine          # HNSW fast path
EXEC vsearch q-vec 10 vec:articles:  l2              # BQ fallback (metric mismatch)
```

### Temporal decay

All three procedures accept an optional decay weight λ ∈ [0, 1]. Final score is `(1 − λ)·similarity + λ·exp(−age_hours / 168)` — exponential decay with a 1-week time constant (half-life ≈ 116h). Useful for AI-agent memory stores where recency matters.

### Pub/sub on vector inserts

Every successful `vinsert` publishes the inserted key to `<namespace>inserted`:

```
SUB vec:articles:inserted
# stream: >EVENT vec:articles:inserted\r\nvec:articles:doc-1\r\n
```

Subscribe at any prefix to filter by namespace breadth — `SUB vec:` catches every vector insert across the server.

### Measured performance

Microbench (`zig run src/vector/bench.zig -O ReleaseFast -lc`), AVX2, single thread, N=50K vectors, K=10, cosine metric:

| Dim  | Brute-force cosine | BQ prefilter + refine |
| ---- | ------------------:| ---------------------:|
| 384  |     220 QPS        |      **3,520 QPS** (16×) |
| 768  |     115 QPS        |      **2,440 QPS** (21×) |
| 1536 |      59 QPS        |      **1,210 QPS** (20×) |

HNSW recall@10 = 1.000 on a rigorous brute-force ground-truth check (400 random 48-dim vectors, 20 queries, ef=100). Inner-loop cosine throughput is ~13 GFLOP/s — ~23 % of AVX2 f32 FMA peak.

### Current limitations

- **Cluster-wide search is not scatter-gather yet**: vector writes replicate through native WormWire vector frames, but `vsearch` answers from the local node. A distributed coordinator that fans out to peers and merges top-K results is still planned.
- **Index restore is snapshot-bound**: snapshot v2 restores HNSW/RaBitQ state, but WAL replay after the most recent snapshot does not replay vector-index mutations. Run `EXEC vreindex <namespace>` after large raw ingests or recovery from an old snapshot.
- **Deletes are tombstone-based**: `VDELETE`/`EXEC vdelete` tombstone non-WORM vectors in HNSW and remove store entries. WORM-default vectors remain immutable; use `EXEC vnsdrop <namespace> 1` only for best-effort namespace purges where skipped WORM entries are acceptable.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                          WormDB                              │
├──────────────┬──────────────┬────────────┬───────────────────┤
│ TCP Server   │ Protocol     │ Store      │ EventBus          │
│ (thread/conn)│ (WormWire v1)│ (Map+WAL)  │ (pub/sub)         │
├──────────────┴──────────────┴────────────┴───────────────────┤
│                      Cluster Layer                           │
│  ┌───────────┐  ┌──────────────┐  ┌────────────────────┐    │
│  │ meshguard │  │ SWIM Gossip  │  │ Encrypted           │    │
│  │ (Ed25519) │  │ (discovery)  │  │ Replication (E2E)   │    │
│  └───────────┘  └──────────────┘  └────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### Components

| Component      | File                           | Description                                              |
| -------------- | ------------------------------ | -------------------------------------------------------- |
| **Types**      | `src/core/types.zig`           | Entry, Command, Response, CommandId                      |
| **Config**     | `src/core/config.zig`          | Store, Server, and Cluster configuration                 |
| **WAL**        | `src/storage/wal.zig`          | Write-Ahead Log with CRC32 integrity                     |
| **Store**      | `src/storage/store.zig`        | In-memory HashMap + WAL persistence                      |
| **Wire**       | `src/protocol/wire.zig`        | WormWire binary codec (read/write frames)                |
| **EventBus**   | `src/event/bus.zig`            | Pub/sub channel management                               |
| **Server**     | `src/server/tcp.zig`           | TCP server (thread-per-connection)                       |
| **Cluster**    | `src/cluster/node.zig`         | meshguard SWIM + encrypted replication                   |
| **Procedures** | `src/procedures/`              | Compiled-in EXEC handlers + Ctx (store/cluster/events)   |
| **Distance**   | `src/vector/distance.zig`      | SIMD cosine/dot/L2 + Hamming + binary quantization       |
| **HNSW**       | `src/vector/hnsw.zig`          | Hierarchical Navigable Small World graph index           |
| **Metric**     | `src/vector/metric.zig`        | Metric enum + per-metric distance functions              |
| **TopK**       | `src/vector/topk.zig`          | Bounded min-heap for O(N log K) top-K                    |
| **Index**      | `src/vector/index.zig`         | NamespaceIndex + NamespaceRegistry (per-namespace HNSW)  |

### WAL Format

```
┌──────────────────────────────────────────────────────────────┐
│ Record Header (13 bytes)                                     │
├──────────┬──────────┬────────────────────────────────────────┤
│ CRC32    │ Type     │ Length (u64)                           │
│ (4 bytes)│ (1 byte) │ (8 bytes)                              │
└──────────┴──────────┴────────────────────────────────────────┘
Payload:
  SET: [key_len:2][value_len:4][flags:1][timestamp:8][key][value]
  DEL: [key_len:2][key]
```

## Port Policy

| Port      | Purpose                       | Protocol |
| --------- | ----------------------------- | -------- |
| **6389**  | Client connections (WormWire) | TCP      |
| **51821** | Cluster gossip (SWIM)         | UDP      |

Default client port is `6389` (avoids Redis `6379` collision). Override with `--port`. Gossip port defaults to `51821` (WireGuard convention). Override with `--gossip-port`.

## Performance

- **Binary size**: 45KB (ReleaseSmall)
- **Docker image**: 37MB (Debian slim)
- **KV read**: O(1) in-memory lookup (single shard-mutex acquire)
- **KV write**: memory update + WAL append (+ cluster replication if enabled)
- **Vector cosine distance**: ~13 GFLOP/s single-threaded on AVX2 (~170ns for a 768-dim compare)
- **Vector search QPS** (50K vectors, K=10, single thread — see [`src/vector/bench.zig`](src/vector/bench.zig)):
  - 384-dim: 220 QPS brute-force → **3,520 QPS** with BQ prefilter
  - 768-dim: 115 QPS brute-force → **2,440 QPS** with BQ prefilter
  - 1536-dim: 59 QPS brute-force → **1,210 QPS** with BQ prefilter

## Development Status

### ✅ Implemented

- [x] Core KV store with HashMap + WAL persistence (CRC32)
- [x] WORM mode enforcement
- [x] TCP server (thread-per-connection)
- [x] WormWire binary protocol (v1)
- [x] Pub/Sub event bus
- [x] Bun reference client + admin UI
- [x] WebSocket gateway (browser-direct WormWire over WS)
- [x] QUIC/WebTransport gateway (libwtf + MsQuic, compile-time gated)
- [x] io_uring event loop + epoll fallback
- [x] Auth system (Ed25519 SCT tokens, per-gateway enforcement)
- [x] Docker containerization
- [x] meshguard cluster integration (SWIM + encrypted replication)
- [x] Stored procedures (`EXEC`) with replication + event-bus from the procedure context
- [x] KV procedures (`kv_put`, `kv_get`, `kv_stats`, `scan`, `transfer`, `increment`)
- [x] Chat procedures (`chat_send`, `chat_history`)
- [x] Memory procedures (`mem_init`, `mem_add`, `mem_get`, `mem_query`, `mem_stats`, `mem_drop`, `mem_capabilities`)
- [x] Vector search — SIMD distances, BQ prefilter, HNSW graph index, per-namespace metric
- [x] `vreindex` bulk rebuild for HNSW
- [x] Native vector wire commands (`VINSERT`, `VDELETE`, `VBULKINSERT`) with replication-aware apply paths
- [x] Snapshot format v2 for HNSW graphs, tombstones, and RaBitQ parameters
- [x] RaBitQ 1-bit quantization (`EXEC vrabitq`) with `bq` and `bq_rerank` query modes
- [x] Namespace drop and tombstone lifecycle (`vdelete`, `vnsdrop`)

### 🚧 In Progress

- [ ] WormDB-side org-trust configuration for meshguard certificates
- [ ] Protocol-level integration tests for pipelined commands with interleaved `EVENT` frames
- [ ] Live server integration tests for native vector wire commands and cluster anti-echo

### 📋 Planned

- [ ] Merkle-tree consistency checks across peers
- [ ] Cluster-wide vector scatter-gather search
- [ ] Web dashboard
- [ ] Backup/restore

## Testing

```bash
# Full suite (via build system)
zig build test

# Vector module tests — 89 cases: distance, topk, metric, hnsw, index
zig test src/vector/distance.zig
zig test src/vector/topk.zig
zig test src/vector/metric.zig
zig test src/vector/hnsw.zig
zig test src/vector/index.zig

# Vector search microbench (ReleaseFast)
zig run src/vector/bench.zig -O ReleaseFast -lc

# Local cluster smoke testing is being refreshed for WormWire-only clients.
# Until then, start nodes manually and verify with the Bun client commands above.

# Docker cluster test
docker compose up -d
docker compose -f docker-compose.bench.yml run --rm benchmark
```

## Dependencies

- **Zig 0.16+** — Language and build system
- **libsodium** — Crypto primitives (ChaCha20-Poly1305, Ed25519)
- **meshguard** — P2P mesh networking (SWIM gossip, encrypted messaging), vendored as `deps/meshguard`

## Troubleshooting

| Problem                       | Solution                                                         |
| ----------------------------- | ---------------------------------------------------------------- |
| Port already in use           | `wormdb --port <other-port>`                                     |
| Permission denied on data dir | Check `--data` directory permissions                             |
| Bun client connection refused | Verify `--host`/`--port` and that WormDB is running              |
| Node won't join cluster       | Verify seed address, gossip port reachability, and WireGuard permissions |

## License

MIT

---

Built with Zig for speed, simplicity, and reliability.
