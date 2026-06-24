# Vector Search

WormDB now ships a co-located vector engine beside the key-value store. Vector writes use the same durable command path as normal KV writes, while HNSW and quantized data are serving structures derived from the stored `vec:*` records.

For the long implementation notes and roadmap, see [Vector Search Deep Dive](/VECTOR_SEARCH) and [RaBitQ Implementation](/RABITQ_IMPLEMENTATION).

## What Is Implemented

| Capability | Status | Notes |
| ---------- | ------ | ----- |
| Native vector wire commands | Implemented | `VINSERT`, `VDELETE`, `VBULKINSERT` |
| Procedure wrappers | Implemented | `vinsert`, `vsearch`, `vsim`, `vstats`, `vreindex`, `vrabitq`, `vdelete`, `vnsdrop` |
| Metrics | Implemented | Per-namespace `cosine`, `dot`, or `l2`; frozen on first insert |
| HNSW graph | Implemented | Per-namespace in-memory ANN index, persisted in snapshot v2 |
| Binary quantization | Implemented | `bq:*` companion keys for prefiltering |
| RaBitQ | Implemented | `EXEC vrabitq`; supports `mode=bq` and `mode=bq_rerank` query modes |
| Replication apply path | Implemented | Native vector frames update store, BQ, and HNSW on peers |

## Key Layout

```text
vec:<namespace>:<id>      raw f32 bytes used directly by the server
bq:vec:<namespace>:<id>   BQ or RaBitQ companion bytes
__meta:<namespace>:count  local per-node insert counter
__meta:vecns:<namespace>  persisted metric config for restart rebuild
```

The server treats vector payloads as raw bytes and interprets them as `f32` values. On the supported little-endian targets, clients should pack embeddings as little-endian `f32` bytes. Vector inserts are WORM by default in the native Bun client helpers and the procedure layer. Non-WORM vectors can be deleted, but deletes tombstone HNSW nodes until the namespace is rebuilt.

## Procedure Surface

```text
EXEC vinsert <key> <vector_bytes> [<worm>] [<namespace>] [<metric>]
EXEC vsearch <query_key> <top_k> [<namespace>] [<metric>] [<decay>] [<mode>] [<decay_tau_hours>]
EXEC vsim <key_a> <key_b> [<metric>]
EXEC vstats [<namespace>]
EXEC vreindex [<namespace>] [<metric>]
EXEC vrabitq [<namespace>] [<seed>]
EXEC vdelete <key> [<namespace>]
EXEC vnsdrop <namespace> [<purge>]
```

`vsearch` dispatches in this order:

1. HNSW when a matching namespace index exists.
2. RaBitQ/BQ prefilter when quantized companions are present and the requested mode supports it.
3. Brute-force exact scan as the fallback and when `mode=exact`.

The optional decay argument is a weight in `[0, 1]` that blends similarity with recency; `decay_tau_hours` controls the exponential time constant and defaults to 168. Explicit modes are `auto`, `exact`, `bq`, and `bq_rerank`. RaBitQ-estimator dispatch is wired for `l2` and `cosine`; `dot` queries fall back to the exact scan when RaBitQ params are installed.

## Native Wire Commands

Client libraries can bypass `EXEC` and use the native command IDs:

| Command | When to use |
| ------- | ----------- |
| `VINSERT` | One vector insert with explicit timestamp |
| `VDELETE` | Delete/tombstone a non-WORM vector |
| `VBULKINSERT` | Batch inserts that share namespace, metric, and flags |

See [Command Reference](/protocol/commands) for the payload layouts.

## Recovery And Rebuilds

Snapshot format v2 appends a `WDBHNSW2` trailer with HNSW graph state, tombstones, timestamps, and RaBitQ parameters. WAL replay after the latest snapshot restores durable `vec:*` keys. Namespaces written through `VINSERT`, `VBULKINSERT`, or the `vinsert` procedure also persist `__meta:vecns:<namespace>`, so startup can rebuild their HNSW graphs from recovered KV using the original metric.

Run:

```bash
bun run apps/bun/src/bin/client.ts EXEC vreindex vec:articles:
```

Use `vreindex` after raw `SET` ingest, manual recovery from old data that lacks `__meta:vecns:*`, or suspected index corruption.

## Current Limits

- `vsearch` is local-node only. Vector writes replicate, but search does not scatter to peers and merge top-K results yet.
- Namespace metric changes require dropping the namespace index first with `vnsdrop`.
- WORM vectors cannot be deleted; `vnsdrop <namespace> 1` skips WORM entries during best-effort purges.
