# Agent-memory showcase

End-to-end example that exercises every `mem_*` procedure over the wire.
Ingests synthetic multi-turn sessions, queries them with temporal decay,
and measures recall@k against a brute-force ground truth.

## Prereqs

- A running WormDB server (`zig build && ./zig-out/bin/wormdb --port 6389`)
- Bun 1.3+

## Quick start

```bash
# Ingest the small hand-crafted session fixtures (8 sessions, ~32 chunks)
bun run examples/agent-memory/client/ingest.ts --ns demo --reset

# One-off query (uses the hash-embedder on both sides)
bun run examples/agent-memory/client/query.ts "cherry blossom kyoto" --ns demo -k 3
# → 0.8734  [s-alice-01/user]  I'm thinking about a trip to Kyoto in April.
#   0.7321  [s-alice-01/assistant]  April is cherry blossom season in Kyoto — expect crowds at...

# Recency-biased query (λ=0.4 leans toward newer sessions)
bun run examples/agent-memory/client/query.ts "rust programming" --ns demo --lambda 0.4

# Metadata-filtered query
bun run examples/agent-memory/client/query.ts "travel plans" --ns demo --filter 'persona="alice" AND role IN ("user","assistant")'

# Full bench: 2k synthetic docs, 200 queries, recall@10 vs brute force
bun run examples/agent-memory/client/bench.ts --n 2000 --queries 200
```

## What the demo exercises

| Piece                  | What runs                                               |
| ---------------------- | ------------------------------------------------------- |
| `mem_init`             | Freezes embedder id + metric on the namespace          |
| `mem_add`              | Atomic doc + meta + vector + event in one EXEC         |
| `mem_get`              | Single-key retrieval with meta join                    |
| `mem_query`            | HNSW → brute-force fallback, with filters, decay + snippets |
| `mem_stats`            | Namespace size, dim, HNSW state                         |
| `mem_drop`             | Cleanup for reset runs                                  |
| `mem_capabilities`     | Capability block (temporal decay, metrics, etc.)        |
| Dim-freeze safety      | Bench intentionally uses a fixed dim — attempts to     |
|                        | mix dims on the same namespace surface as errors       |
| Binary EXEC args       | Embeddings pass through as `Uint8Array` EXEC args       |

## Files

- `client/mem.ts` — typed wrapper around `EXEC mem_*`
- `client/ingest.ts` — ingests the session fixtures
- `client/query.ts` — one-shot retrieve
- `client/bench.ts` — throughput + latency + recall@10 harness
- `fixtures/embedder.ts` — deterministic FNV-1a hash-embedder (CI-friendly)
- `fixtures/sessions.ts` — eight synthetic multi-turn sessions across four personas

## Notes on the embedder

The hash-embedder is **not semantically meaningful**. Same text → same
vector, different texts → different vectors, but the geometry doesn't
track meaning the way a real model does. It exists so the demo and CI
can run without pulling an embedding model. Swap for Ollama or a managed
embedder in production; the contract (client passes raw f32 bytes) is
unchanged.

## What to look for

The bench emits a single JSON summary on stdout. The ones worth watching:

- **`ingest_rate_per_s`**: single-threaded Bun client over one keep-alive
  socket. A few hundred docs/s is typical on a dev laptop. The bottleneck
  is wire serialization, not the Zig server.
- **`query_ms.p95`**: HNSW path should stay well under brute-force
  equivalents. If it doesn't, check `stats.hnsw.nodes` — a zero here
  means the index didn't populate and queries fell back to brute force.
- **`recall@10`**: with the hash-embedder and the synthetic word-bag
  corpus, expect ~**0.85-0.95** — the embedder produces many tied
  scores, so brute-force vs HNSW ordering within a tie-band legitimately
  differs. A real embedder on real text gives clean >0.99 recall because
  the score distribution is spread out. **If recall drops below ~0.7,
  that's a genuine signal** — check metric freeze, dim freeze, and the
  stage-1 oversample factor.
