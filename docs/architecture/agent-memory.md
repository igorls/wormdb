# Agent Memory Procedures

WormDB includes `mem_*` stored procedures for AI-agent memory systems. They combine document text, metadata, embeddings, vector search, WORM defaults, and pub/sub events into one in-database workflow.

For the end-to-end demo notes, see [Agent Memory Demo](/AGENT_MEMORY_DEMO).

## Procedure Surface

| Procedure | Purpose |
| --------- | ------- |
| `mem_init <ns> <embedder_id> <metric> [vector_only=true]` | Predeclare a memory namespace, embedder, metric, and optional vector-only mode |
| `mem_add <ns> <doc_id> <text> <embedding> [meta_json] [worm] [embedder_id]` | Add one memory chunk plus embedding |
| `mem_add <ns> <doc_id> <embedding> [meta_json] [worm] [embedder_id]` | Add one vector-only memory row |
| `mem_get <ns> <doc_id>` | Fetch document text joined with metadata |
| `mem_query <ns> <embedding> <k> [lambda] [min_score] [snippet_chars]` | Search and return enriched memories |
| `mem_stats <ns>` | Return count, dimension, HNSW, and config state |
| `mem_drop <ns>` | Delete memory namespace data |
| `mem_reset_index <ns> <new_embedder_id>` | Drop vector/BQ/HNSW state while preserving document bodies |
| `mem_capabilities` | Return a self-describing adapter capability block |

## Key Layout

```text
mem:<ns>:<id>              document body, WORM by default
mem:<ns>:<id>:meta         metadata JSON
vec:mem:<ns>:<id>          raw embedding bytes
bq:vec:mem:<ns>:<id>       quantized companion
__meta:mem:<ns>:config     {"embedder_id":"...","metric":"...","vector_only":false,"created_at":...}
```

Chunking lives on the client. `mem_add` indexes one chunk; applications that have long documents or conversations should split them and call `mem_add` with derived IDs.

## Vector-Only Mode

`mem_init <ns> <embedder_id> <metric> vector_only=true` creates a namespace for sidecar layouts where document bodies live outside WormDB. In this mode, `mem_add` uses the shorter form `<ns> <doc_id> <embedding> [meta_json] [worm] [embedder_id]`, writes `vec:*`, `bq:*`, and optional metadata, and intentionally skips `mem:<ns>:<id>` document bodies.

`mem_query` returns hits as `[{id, score, ts, meta}]` with no `doc` field, and `mem_get` rejects with a deterministic `vector_only` error. Dim and metric freezing still happen through the normal vector namespace.

## Embedder Enforcement

`mem_init` pins an `embedder_id` and metric for a namespace. `mem_add` can take an optional `embedder_id` assertion. When a namespace config exists, a mismatch is rejected before any state changes.

This protects against same-dimension model swaps, which a dimension check alone cannot catch. To intentionally change embedders:

```bash
bun run apps/bun/src/bin/client.ts EXEC mem_reset_index notes openai/text-embedding-3-small
```

`mem_reset_index` preserves doc bodies, drops vector/BQ/HNSW state, rewrites the config, and expects clients to re-embed and re-add vectors. Because `mem_add` defaults vectors to WORM, the reset intentionally aborts if WORM-protected vector or BQ keys would be left behind under the old embedder. Use non-WORM memory vectors when planned embedder rotation is part of the workflow, or use `mem_drop` for a hard reset that reports skipped WORM keys.

## Query Path

`mem_query` uses HNSW when the memory namespace has an index and falls back to brute-force when the index is absent. It intentionally skips the general BQ prefilter because `mem_init` eagerly prepares HNSW and the memory query result must be joined with document text and metadata.

The optional `lambda` argument applies temporal decay with the same one-week time constant used by vector search. `min_score` filters weak matches, and `snippet_chars` controls how much document text is returned per hit.

## Events

Successful `mem_add` publishes the document ID to:

```text
mem:<ns>:added
```

Pub/sub is best-effort and not replayed. Durable event logs should also be written as WORM keys if replay matters.

## Failure Model

`mem_add` validates and writes the vector first, then writes the document body and metadata. This avoids permanently sealing an orphaned WORM document when vector validation fails. If a later WORM document write fails after the vector lands, the procedure returns a clear error and `mem_drop` is the cleanup path.

`mem_drop` is best-effort for WORM data. It drops the HNSW index, attempts durable deletes for document, vector, BQ, and config keys, and reports `skipped_worm` plus `errors` in the JSON response.
