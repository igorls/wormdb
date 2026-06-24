# Agent-memory primitives

> End-to-end: how WormDB's `mem_*` procedures behave, what the in-repo
> showcase validates, and what a production adapter looks like on top of them.

This document is the design-level narrative. For a runnable quickstart, see
[`examples/agent-memory/README.md`](../examples/agent-memory/README.md).

---

## What this is

Seven stored procedures, compiled into the server binary, that turn WormDB's
existing primitives (KV + vectors + pub/sub + WORM) into a cohesive
agent-memory surface. Every call is one network round-trip. Every write
goes through the same WAL + replication path the rest of the server uses.

| Procedure          | Purpose                                                        |
| ------------------ | -------------------------------------------------------------- |
| `mem_init`         | Optionally pre-declare a namespace's embedder, metric, and mode |
| `mem_add`          | Atomic: doc + metadata + embedding + event, in one EXEC        |
| `mem_meta_set`     | Update metadata for an existing memory without re-embedding     |
| `mem_bulk_add`     | Backfill embeddings + metadata through one vector batch        |
| `mem_get`          | Single-doc fetch with metadata join                            |
| `mem_query`        | HNSW → brute-force fallback, joined with doc + metadata        |
| `mem_range`        | Timestamp-window scan returning ids, timestamps, and metadata  |
| `mem_stats`        | Counts, dim, HNSW state, config                                 |
| `mem_verify`       | Drift report for docs, vectors, BQ, and HNSW                    |
| `mem_drop`         | Scan-delete everything under a namespace (doc, meta, vec, BQ)   |
| `mem_reset_index`  | Drop vec/BQ/HNSW for a namespace and switch its embedder id     |
| `mem_capabilities` | Self-describing capability block for adapter discovery         |

## Key layout

Strict conventions — every adapter talks to the same physical layout:

```
mem:<ns>:<id>             doc body            (WORM by default)
mem:<ns>:<id>:meta        metadata JSON       (mutable passthrough)
vec:mem:<ns>:<id>         embedding (f32 LE)  (via applyVinsert)
bq:vec:mem:<ns>:<id>      BQ companion        (written by applyVinsert)
__meta:mem:<ns>:config    { embedder_id, metric, vector_only, created_at }
```

Two consequences worth noticing:

- `vstats vec:mem:` gives cross-namespace stats on memory-originated
  vectors without touching other `vec:*` namespaces used outside the
  memory subsystem.
- `mem:<ns>:` covers *both* docs and `:meta` entries in a single prefix
  scan — handy for `mem_range`, `mem_stats`, and `mem_drop`, which is
  why `doc_keys` in the stats output is labelled as a raw count rather
  than "docs".

Metadata can be updated without touching the vector. The stable low-level
contract is a direct mutable `SET mem:<ns>:<id>:meta <json>`; the ergonomic
stored-procedure wrapper is `EXEC mem_meta_set <ns> <id> <json>`.
`mem_meta_set` validates that `mem:<ns>:<id>` exists, then durably writes the
metadata key. The JSON is stored as caller-supplied bytes, matching `mem_add`.

## What counts as atomic

`mem_add` has deliberate ordering:

1. **Pre-check** dim against the frozen namespace dim (via `expectedDim()`).
   Rejects mismatched vectors before any write. Critical under WORM —
   a bad vector there would be permanent and invisible to HNSW's
   stage-2 refine.
2. **Vector first** via `applyVinsert`: store + BQ + HNSW + event
   emission + cluster replication.
3. **Doc body** (WORM if requested).
4. **Metadata** (always mutable).
5. **Publish** to `mem:<ns>:added`.

`mem_bulk_add <ns> <count> [id embedding meta_json]×N` is the backfill
variant for sidecar-style migrations. It validates the entire batch
before writing, uses WormDB's native bulk vector path for vector/BQ/HNSW
work, writes metadata durably, and emits one `mem:<ns>:added.bulk`
event with the JSON id list.

Steps 2–5 are not transactional. If the vector lands but the doc write
fails (WORM violation on the doc key, say), the vector is an orphan
searchable by `mem_query` but `mem_get` returns null for that id.
`mem_drop` cleans up. The ordering was chosen so the common failure
case — dim or metric mismatch — fails fastest, before any state change.

## Dim + metric freeze

Namespaces freeze two invariants on first use:

- **Metric** — frozen when the namespace's HNSW index is created (either
  explicitly via `mem_init` or lazily on the first `mem_add`).
- **Dimension** — frozen on the first vector actually inserted
  (see [`src/vector/index.zig`](../src/vector/index.zig) `NamespaceIndex.dim`).

Both are checked before every subsequent insert. Mismatches return
`error.MetricMismatch` / `error.DimensionMismatch` from `applyVinsert`
and surface as clear client-facing errors. Dim derivation on snapshot
restore pulls from the first resolvable vector, so freeze state survives
restarts without a format bump.

## Embedder identity

Stored in `__meta:mem:<ns>:config` as part of a small JSON blob:

```json
{ "embedder_id": "text-embedding-3-large", "metric": "cosine", "decay_tau_hours": 168, "created_at": 1780000000 }
```

`mem_init` writes this eagerly and is idempotent-if-matching —
re-initing with the same embedder + metric + mode is a no-op, a different
embedder, metric, or `vector_only` setting errors. `mem_add` reads it to
pick the metric for `applyVinsert`; if config is absent, cosine is the default.

Embedder enforcement is opt-in per insert: clients that need strict
guarantees call `mem_init` before adds and pass the configured
`embedder_id` assertion to `mem_add`. Mixing embedders with different
output dimensions is still caught by dim-freeze; same-dimension swaps
are caught when the caller provides that assertion.

`mem_verify` goes further than `mem_stats` for reconciliation. It compares
document, vector, and BQ IDs and returns bounded lists for `orphan_vectors`,
`orphan_docs`, and `missing_bq`, which is the shape sidecar clients need when
WormDB drifts from their canonical row store.

## Query path

`mem_query` dispatches in two stages:

- **HNSW** when the namespace has a registered index with matching metric.
  Stage-1 beam of `k × 10` → stage-2 exact refine with the query's
  metric, optional metadata filter, and optional temporal decay.
- **Brute-force** prefix scan as the fallback. Triggered on cold start
  (post-restart before `vreindex`) or when no index has been created yet.
  Metadata filters are applied during this scan before top-K admission.

Unlike general `vsearch`, `mem_query` skips the BQ prefilter. For memory
namespaces the HNSW index is eagerly created by `mem_init`, so the only
HNSW-absent case is post-restart — and for that case brute-force is
simpler than BQ and runs correctly on every namespace.

Returned shape:

```json
[
  { "id": "...", "score": 0.87, "ts": 1780000000,
    "doc": "possibly-truncated text...", "meta": {...} },
  ...
]
```

Vector-only namespaces use `mem_init ... vector_only=true` and the shorter
`mem_add <ns> <id> <embedding> [meta_json] [worm] [embedder_id]` form. They
skip document-body writes, keep vectors/BQ/metadata, return query hits without
a `doc` field, and make `mem_get` return a clear vector-only error.

Five query-time knobs:

- **`lambda`** (0–1): blends raw similarity with exponential temporal
  decay. `lambda=0` is pure similarity,
  `lambda=1` is pure recency, in between trades off.
- **`decay_tau_hours`**: exponential time constant. `mem_query` accepts
  this after `snippet_chars`; if omitted, it uses the namespace config
  from `mem_init`, then the 168-hour default.
- **`min_score`**: filters results below a threshold.
- **`snippet_chars`**: caps doc text returned per hit. `0` = full text,
  `-1` = omit doc entirely (useful when the caller already has it and
  only wants scores). Default 512. Matters under realistic session
  sizes where multi-KB docs would otherwise blow p95 latency on the
  enrichment path.
- **`filter`**: server-side predicate over top-level metadata fields or
  synthetic `ts`. Supports `=`, `<`, `<=`, `>=`, `>`, `AND`, and
  `IN (...)`, for example:

  ```text
  filter='privacy_level<=1 AND sourceType IN ("chat","note")'
  ```

## What the showcase validates

[`examples/agent-memory/client/bench.ts`](../examples/agent-memory/client/bench.ts)
runs each `mem_*` procedure over the wire, then cross-checks HNSW
output against a brute-force ground truth computed on the client.
On a dev laptop with 500 synthetic 128-dim docs and 50 queries:

```
ingest   ~1100 docs/s   (single-connection keep-alive socket)
query    p50=0.8ms  p95=1.1ms  p99=1.3ms
recall@10 ≈ 0.88        (hash-embedder ties; real embedders >0.99)
```

The recall-below-1 signal is hash-embedder artifact, not an HNSW bug —
random word bags produce many tied scores. Run the bench against an
Ollama-backed or API-backed embedder and the recall cleanly clears 0.99.

## Adapter shape for production

A WormWire client wrapping the seven procedures is ~200 lines and
translates directly to any of the common memory-service contracts.
The shape of a thin adapter:

```ts
class MemoryAdapter {
  initialize(embedder_id, metric, opts)  → mem_init
  ingest(doc_id, text, embedding, meta)  → mem_add
  ingestMany(rows)                       → mem_bulk_add
  get(doc_id)                            → mem_get
  retrieve(query_emb, k, opts)           → mem_query
  range(since_ms, until_ms, limit)        → mem_range
  stats()                                → mem_stats
  reset()                                → mem_drop
  capabilities()                         → mem_capabilities
}
```

The showcase's [`client/mem.ts`](../examples/agent-memory/client/mem.ts)
is an example of this shape. Language choice is unconstrained —
the wire protocol is small enough that any language with TCP + binary
framing can talk to it; there is no WormDB client library dependency
in the contract itself.

## Design decisions worth knowing

- **Chunking lives on the client.** `mem_add` indexes one chunk at a
  time. Systems that think in "sessions" or "documents" chunk on their
  side and call `mem_add` N times with derived ids. This keeps the Zig
  core free of any chunking policy.
- **`mem_init` is optional.** Lazy freezing on first `mem_add` works —
  `mem_init` up front just makes fail-fast on metric/embedder mismatch
  possible instead of discovering it much later.
- **Metadata is an opaque JSON passthrough.** The server stores and
  returns whatever the client sent. Malformed JSON in → malformed JSON
  out. Validating is the client's job. This is intentional — the server
  does not need to understand metadata to do its job, and schema policy
  belongs in the adapter.
- **Namespace and doc-id validators are strict.** Only `[A-Za-z0-9._/-]`
  accepted for namespaces, doc-ids, and embedder-ids. Rejects `:`
  (which would collide with key-layout separators), quotes (which would
  need escape handling in config JSON), and control characters. 64-byte
  cap on namespaces, 256-byte cap on doc-ids.

## Limitations + follow-ups

- **HNSW is a derived serving index.** Snapshot v2 persists the graph,
  tombstones, and RaBitQ params. On startup, memory namespaces are also
  rebuilt from WAL-replayed `vec:mem:<ns>:` keys using
  `__meta:mem:<ns>:config`, so normal `mem_add` ingest recovers without
  a manual `vreindex`.
- **No partial-failure rollback** in `mem_add`. Vector-first ordering
  means the common failure case (dim mismatch) fails cleanly before any
  write, but vector-lands-then-doc-fails leaves an orphan. `mem_drop`
  is the recovery.
- **Embedder enforcement is opt-in per call.** `mem_init` pins the
  embedder id; `mem_add` will reject a mismatch *only when the caller
  passes the optional 7th arg* (the asserted `embedder_id`). Callers
  that don't assert keep the old behavior — same-dim model swaps go
  through unchallenged. To switch a namespace to a new embedder, run
  `mem_reset_index <ns> <new_embedder_id>` — drops vec/BQ/HNSW state,
  rewrites the config, and preserves `mem:<ns>:*` doc bodies so the
  client can re-embed and `mem_add` with new vectors.
- **Privacy tiers are not modeled.** Namespace isolation is the only
  access boundary. Cross-namespace ACLs or per-doc privacy tiers are
  out of scope for v1 — they need a primitive design that doesn't
  exist yet.
- **The hash-embedder is a placeholder.** Fine for CI and exercising
  the pipeline; useless for semantic similarity. Production adapters
  wire to Ollama or an API embedder.
