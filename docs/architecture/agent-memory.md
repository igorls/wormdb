# Agent Memory Procedures

WormDB includes `mem_*` stored procedures for AI-agent memory systems. They combine document text, metadata, embeddings, vector search, WORM defaults, and pub/sub events into one in-database workflow.

For the end-to-end demo notes, see [Agent Memory Demo](/AGENT_MEMORY_DEMO).

## Procedure Surface

| Procedure | Purpose |
| --------- | ------- |
| `mem_init <ns> <embedder_id> <metric>` | Predeclare a memory namespace, embedder, and metric |
| `mem_add <ns> <doc_id> <text> <embedding> [meta_json] [worm] [embedder_id]` | Add one memory chunk plus embedding |
| `mem_get <ns> <doc_id>` | Fetch document text joined with metadata |
| `mem_query <ns> <embedding> <k> [lambda] [min_score] [snippet_chars]` | Search and return enriched memories |
| `mem_range <ns> <since_ms> <until_ms> [limit] [filter]` | Scan memories by document timestamp |
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
__meta:mem:<ns>:config     {"embedder_id":"...","metric":"...","created_at":...}
```

Chunking lives on the client. `mem_add` indexes one chunk; applications that have long documents or conversations should split them and call `mem_add` with derived IDs.

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

`mem_range` is a timestamp-window workaround for timeline views. It scans `mem:<ns>:` document keys, skips `:meta` companions, sorts by document timestamp ascending, and returns `[{id, ts, meta}]`. `limit` defaults to 100; `0` means no response cap. The optional filter slot is reserved for the shared predicate parser tracked in #2.

## Events

Successful `mem_add` publishes the document ID to:

```text
mem:<ns>:added
```

Pub/sub is best-effort and not replayed. Durable event logs should also be written as WORM keys if replay matters.

## Failure Model

`mem_add` validates and writes the vector first, then writes the document body and metadata. This avoids permanently sealing an orphaned WORM document when vector validation fails. If a later WORM document write fails after the vector lands, the procedure returns a clear error and `mem_drop` is the cleanup path.

`mem_drop` is best-effort for WORM data. It drops the HNSW index, attempts durable deletes for document, vector, BQ, and config keys, and reports `skipped_worm` plus `errors` in the JSON response.
