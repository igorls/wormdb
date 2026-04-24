# WormDB Vector Search — Roadmap & Architecture

> Distributed WORM-native vector search in a single static binary.

---

## What We Have (Phase 1 — Complete)

Phase 1 delivers working brute-force vector search with SIMD-accelerated distance computation,
temporal decay scoring, binary quantization, and four procedures — all with zero changes to
the wire protocol, store engine, or snapshot format.

### Files

```
src/vector/
├── mod.zig              # Module re-exports
└── distance.zig         # SIMD distance functions (315 lines, 13 tests)

src/procedures/
├── vinsert.zig          # Insert vector (WORM by default) + BQ hash
├── vsearch.zig          # Brute-force ANN + temporal decay scoring
├── vsim.zig             # Pairwise similarity between two vectors
└── vstats.zig           # Vector namespace statistics
```

### Capabilities

| Feature | Status | Notes |
|---------|--------|-------|
| SIMD cosine similarity | ✅ | 8-wide f32 via `@Vector` (AVX2/NEON auto-dispatch) |
| SIMD dot product | ✅ | FMA-optimized |
| SIMD L2 distance | ✅ | Squared variant for ranking (avoids sqrt) |
| Binary quantization | ✅ | 1-bit per dimension, stored alongside vectors |
| Hamming distance | ✅ | `@popCount` of XOR — single-cycle on modern CPUs |
| Temporal decay scoring | ✅ | Exponential decay with configurable weight |
| WORM vector insert | ✅ | Immutable embeddings — write once, search forever |
| Namespace isolation | ✅ | Key prefix convention (`vec:<ns>:<id>`) |
| Vector statistics | ✅ | Count, dimensions, insert count per namespace |
| Byte ↔ f32 conversion | ✅ | Zero-copy interpretation of stored bytes |

### Usage

```bash
# Store embeddings (WORM by default)
EXEC vinsert doc-001 <f32_bytes>
EXEC vinsert doc-002 <f32_bytes> 1 vec:articles:

# Semantic search with temporal recency bias
EXEC vsearch query-vec 10 vec: cosine 0.3

# Compare two vectors directly
EXEC vsim vec:doc-001 vec:doc-002 cosine

# Check vector stats
EXEC vstats vec:articles:
```

### Limitations

- **O(N) scan** — searches all vectors in namespace on every query
- **No index structure** — every query recomputes distances from scratch
- **Single-node only** — no distributed scatter-gather yet
- **No filtered search** — can't combine metadata predicates with ANN
- **Practical ceiling** — good up to ~50K-100K vectors per namespace

---

## Phase 2 — HNSW Index + RaBitQ (Next)

**Goal**: Sub-millisecond approximate search on millions of vectors.

**Estimated effort**: 4-6 weeks

### 2.1 HNSW Graph Index

The Hierarchical Navigable Small World graph is the industry standard for in-memory ANN.
Every major vector database (Pinecone, Qdrant, Weaviate, Milvus) uses it.

#### Architecture

```
src/vector/
├── hnsw.zig             # HNSW graph construction + search
├── hnsw_node.zig        # Node structure (neighbors, level)
├── hnsw_params.zig      # Configuration (M, ef_construction, ef_search)
└── distance.zig         # (existing) — SIMD distance kernels
```

#### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Graph storage | Flat arrays per level, neighbor lists as fixed-size arrays | Cache-friendly, no pointer chasing |
| Max connections per layer (M) | 16 default, configurable | Sweet spot for recall vs. memory |
| ef_construction | 200 default | Higher quality graph, amortized over lifetime |
| ef_search | 64 default, configurable per query | Tunable recall/latency tradeoff |
| Level generation | Exponential distribution (1/ln(M)) | Standard HNSW, proven optimal |
| Entry point | Single global entry node per index | Simplest correct approach |
| Thread safety | RWLock on graph + lock-free search | Reads don't block each other |

#### Implementation Checklist

- [ ] **Node structure** — ID, level, neighbor lists (fixed `[M]` arrays per level)
- [ ] **Graph construction** — Greedy insertion with heuristic neighbor selection
- [ ] **Multi-layer search** — Top-down traversal from entry point
- [ ] **ef_search parameter** — Controls search beam width (recall vs. speed)
- [ ] **Deletion support** — Lazy tombstones (mark deleted, skip during search, compact later)
- [ ] **Thread-safe reads** — Multiple search threads, single writer thread
- [ ] **Serialization** — Save/load graph to snapshot format for persistence across restarts
- [ ] **Integration with `vinsert`** — Auto-add to HNSW index on vector insertion
- [ ] **Integration with `vsearch`** — Use HNSW when index exists, fallback to brute-force

#### Performance Targets

| Metric | Target | Baseline (Phase 1) |
|--------|--------|---------------------|
| Search latency (1M vectors, top-10) | < 1ms | ~50ms |
| Recall@10 (ef=64) | > 0.95 | 1.0 (exact) |
| Insert throughput | > 5K vec/sec | unlimited (no index) |
| Memory per vector (1536-dim) | ~8KB (vec + graph) | ~6KB (vec only) |

### 2.2 RaBitQ Quantization

RaBitQ (SIGMOD 2024/2025) is the breakthrough that makes this practical at scale.
It replaces Product Quantization entirely — better accuracy, no codebook training,
and distance computation via bitwise operations.

#### Architecture

```
src/vector/
├── rabitq.zig           # RaBitQ encoding/decoding
├── rabitq_index.zig     # Quantized index for fast pre-filtering
└── distance.zig         # (existing) + RaBitQ distance estimator
```

#### How RaBitQ Works

```
┌────────────────────────────────────────────────────────┐
│  1. Compute dataset centroid (mean of all vectors)      │
│  2. Normalize: v' = (v - centroid) / ‖v - centroid‖    │
│  3. Apply random orthogonal rotation: v'' = R × v'     │
│  4. Quantize: q[i] = sign(v''[i])  →  1 bit/dimension  │
│  5. Store: correction factors for distance estimation   │
└────────────────────────────────────────────────────────┘

Compression: float32 (32 bits/dim) → 1 bit/dim = 32× reduction
1536-dim vector: 6,144 bytes → 192 bytes
10M vectors: 57 GB → 1.8 GB
```

#### Implementation Checklist

- [ ] **Centroid computation** — Running mean, updated incrementally on inserts
- [ ] **Random orthogonal matrix** — Generate once per index, persist in snapshot
- [ ] **1-bit quantization** — Sign pattern extraction after rotation
- [ ] **Distance estimator** — Asymmetric: query in float, database in bits
- [ ] **Correction factors** — Per-vector norm and bias terms for accuracy
- [ ] **SIMD Hamming for quantized search** — `POPCNT(XOR)` path (already have `hamming()`)
- [ ] **Two-pass search** — BQ pre-filter → re-rank with full vectors top candidates
- [ ] **Extended RaBitQ (2-4 bit)** — Higher accuracy option for smaller datasets

#### Memory Impact

| Dataset | Full f32 | RaBitQ 1-bit | RaBitQ 4-bit |
|---------|----------|-------------|-------------|
| 100K × 1536 | 576 MB | 18 MB | 72 MB |
| 1M × 1536 | 5.7 GB | 180 MB | 720 MB |
| 10M × 1536 | 57 GB | 1.8 GB | 7.2 GB |

### 2.3 Filtered Search

Combine metadata predicates with vector similarity. Three strategies, selected automatically
based on filter selectivity:

```
Query: "Find memories similar to X, from last 7 days, tagged 'work'"

                  ┌─ Low selectivity ─→  Post-filter (ANN → filter results)
Filter analysis ──┤
                  ├─ Medium           ─→  Hybrid (pre-filter namespace → ANN subset)
                  │
                  └─ High selectivity ─→  Pre-filter (metadata scan → brute-force subset)
```

#### Implementation Checklist

- [ ] **Filter expression parser** — Simple DSL: `ts>1709000000 AND tag=work`
- [ ] **Metadata co-storage** — Store metadata at `meta:vec:<ns>:<id>` alongside vector
- [ ] **Pre-filter path** — Prefix scan + metadata check → brute-force on subset
- [ ] **Post-filter path** — HNSW search → filter results, oversample K
- [ ] **Auto-selection** — Estimate selectivity, pick cheapest strategy
- [ ] **`vsearch` integration** — Add optional `filter` argument

### 2.4 Native Wire Command

Move vector search from EXEC overhead to a dedicated WormWire command for hot-path optimization.

#### Protocol Extension

```
Command ID:  0x0D  VSEARCH
Payload:     [4B query_vec_len] [query_vec_bytes]
             [1B metric]       (0=cosine, 1=dot, 2=l2)
             [4B top_k]
             [4B namespace_len] [namespace]
             [4B filter_len]   [filter_expr]    (0 = no filter)
             [1B flags]        (bit 0: temporal_decay)

Response:    VALUE — binary packed results
             [4B result_count]
             For each result:
               [4B key_len] [key]
               [4B score (f32 IEEE 754)]
               [8B timestamp (u64 BE)]
```

#### Implementation Checklist

- [ ] **New `CommandId.vsearch = 0x0D`** in `types.zig`
- [ ] **Wire parser** in `wire.zig` — read/write VSEARCH frames
- [ ] **Executor integration** — Direct dispatch in `server/executor.zig`
- [ ] **Bun client support** — `client.ts` VSEARCH command
- [ ] **Binary response format** — Avoid JSON serialization overhead

---

## Phase 3 — Distributed Vector Search

**Goal**: Scatter-gather ANN across a WormDB cluster.

**Estimated effort**: 3-4 weeks

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Distributed VSEARCH                        │
│                                                              │
│  Client ──→ Any Node (coordinator)                           │
│                 │                                            │
│                 ├──→ Local HNSW search (top-K₁)              │
│                 ├──→ Peer A via meshguard (top-K₂)           │
│                 ├──→ Peer B via meshguard (top-K₃)           │
│                 └──→ Peer C via meshguard (top-K₄)           │
│                 │                                            │
│                 ▼                                            │
│              Merge K₁∪K₂∪K₃∪K₄, re-rank, return top-K       │
└──────────────────────────────────────────────────────────────┘
```

### Vector Placement Strategy

```
Option A: Hash-based partitioning (deterministic)
  shard = fnv1a(vector_key) % node_count
  → Even distribution, but rebalancing on node add/remove

Option B: Write-local (simplest — recommended first)
  Each node indexes only vectors it received directly.
  All nodes searched on every query. Good up to ~10 nodes.
  → No rebalancing ever. WORM data never moves.

Option C: Consistent hashing with virtual nodes (production)
  → Smooth rebalancing, but adds complexity
```

### WORM Advantage for Distributed Consistency

Mutable vector databases need complex conflict resolution for distributed updates.
WormDB's WORM vectors are a **G-Set CRDT** (grow-only set) — they're only ever added, never
modified or deleted. This means:

- **No vector clocks needed** — no concurrent writes to the same vector
- **No CAS conflicts** — append-only, deterministic
- **Replication is trivial** — just replicate inserts via meshguard
- **Index merge is trivial** — union of insert logs = correct global index
- **Anti-entropy is simple** — Merkle tree of vector key hashes

### Implementation Checklist

- [ ] **Cluster-aware `vsearch`** — Detect cluster mode, scatter to peers
- [ ] **Inter-node search RPC** — Lightweight binary message via meshguard
- [ ] **Result merging** — Merge top-K from all nodes, re-rank
- [ ] **Parallel scatter** — Fan-out to all peers simultaneously
- [ ] **Timeout handling** — Return partial results if a node is slow
- [ ] **Vector replication** — Replicate `vinsert` events to peers
- [ ] **Cluster-aware `vstats`** — Aggregate stats across all nodes
- [ ] **Benchmark: latency vs. node count** — Quantify scatter-gather overhead

---

## Phase 4 — Advanced Features

**Goal**: Feature parity with purpose-built vector databases.

**Estimated effort**: 4-6 weeks

### 4.1 Hybrid Dense + Sparse Search

Combine semantic vector search with keyword matching in a single query.
This is the 2025-2026 consensus for production RAG systems.

```
EXEC hsearch <query_vec_key> <query_text> <top_k> [namespace]

Result = RRF(
  dense_results  = vsearch(query_vec, top_k * 3),
  sparse_results = keyword_scan(query_text, top_k * 3)
)
```

- [ ] **BM25-style scoring** — TF-IDF over stored text metadata
- [ ] **Reciprocal Rank Fusion (RRF)** — Merge dense + sparse results
- [ ] **`hsearch` procedure** — Single entry point for hybrid queries
- [ ] **Inverted index** — Token → vector key mapping for keyword search
- [ ] **Benchmark vs. pure vector** — Measure recall improvement

### 4.2 Matryoshka Two-Stage Search

Leverage Matryoshka embedding models (OpenAI `text-embedding-3-*`) for
coarse-then-fine search without any index changes.

```
Stage 1: Search using first 128 dims (fast, lower fidelity)
         → Retrieve 10× candidates

Stage 2: Re-rank candidates using full 1536 dims (accurate)
         → Return final top-K
```

- [ ] **Truncated distance** — `cosine(a[0..128], b[0..128])`
- [ ] **Two-stage procedure** — `EXEC msearch <query> <top_k> <coarse_dims>`
- [ ] **Configurable coarse dimensions** — 64, 128, 256, 384
- [ ] **Benchmark: speedup vs. recall loss** — Find sweet spot

### 4.3 Multi-Vector Storage

Support multiple embeddings per document (e.g., one per sentence or paragraph).
Essential for ColBERT-style late interaction retrieval.

```
Key layout:
  vec:doc:123:0  → embedding for chunk 0
  vec:doc:123:1  → embedding for chunk 1
  vec:doc:123:2  → embedding for chunk 2

Aggregation: MaxSim — max similarity across all chunks
```

- [ ] **MaxSim aggregation** — Per-document score = max over chunk similarities
- [ ] **`vminsert` procedure** — Insert multi-vector document atomically
- [ ] **`vmsearch` procedure** — Search with MaxSim aggregation
- [ ] **Chunk-level results** — Return which chunk matched best

### 4.4 Time-Windowed Search

First-class temporal search APIs, beyond the basic decay scoring in Phase 1.

```
EXEC vwindow <query_vec> <top_k> <from_ts> <to_ts> [namespace]
```

- [ ] **Time-range filter** — Restrict search to `[from_ts, to_ts]`
- [ ] **Sliding window** — "Last 24 hours", "Last 7 days"
- [ ] **Temporal buckets** — Index vectors by time period for faster windowed search
- [ ] **Score fusion** — `w₁ × similarity + w₂ × freshness + w₃ × importance`

### 4.5 Index Persistence

Save and restore HNSW indexes across server restarts.

```
Snapshot format extension (WDBSNAP2):

┌──────────────────────────────────────────────────────┐
│  Existing WDBSNAP1 data (key-value entries)           │
├──────────────────────────────────────────────────────┤
│  Vector Index Section                                 │
│  ┌─ Magic: "WDBVIDX1"                               │
│  ├─ Index count (u32)                                │
│  ├─ For each index:                                  │
│  │   ├─ Namespace length + namespace                 │
│  │   ├─ Params (M, ef_construction, dim)             │
│  │   ├─ Node count (u64)                             │
│  │   ├─ Entry point ID (u64)                         │
│  │   ├─ RaBitQ rotation matrix (dim × dim × f32)     │
│  │   ├─ RaBitQ centroid (dim × f32)                  │
│  │   └─ For each node:                               │
│  │       ├─ ID, level, key_hash                      │
│  │       └─ Neighbor lists per level                 │
│  └─ CRC32 of index section                           │
└──────────────────────────────────────────────────────┘
```

- [ ] **Index serializer** — Write HNSW graph to binary format
- [ ] **Index deserializer** — Rebuild graph from binary on startup
- [ ] **Snapshot version bump** — `WDBSNAP1` → `WDBSNAP2` with backward compat
- [ ] **Incremental index WAL** — Log index mutations for crash recovery
- [ ] **Lazy rebuild fallback** — If index is corrupt, rebuild from stored vectors

---

## Phase 5 — Performance & Scale

**Goal**: Benchmark-competitive performance, billion-scale readiness.

**Estimated effort**: 3-4 weeks

### 5.1 SIMD Specialization

```zig
// Runtime CPU detection for optimal SIMD path
const cpu = @import("builtin").cpu;
const has_avx512 = cpu.features.isEnabled(.avx512f);
const has_avx2 = cpu.features.isEnabled(.avx2);

pub fn cosine(a: []const f32, b: []const f32) f32 {
    if (has_avx512) return cosine_avx512(a, b);     // 16-wide
    if (has_avx2) return cosine_avx2(a, b);          // 8-wide (current)
    return cosine_scalar(a, b);                      // fallback
}
```

- [ ] **AVX-512 fast path** — 16-wide f32 for 2× throughput on supported hardware
- [ ] **ARM NEON path** — For Graviton / Apple Silicon deployment
- [ ] **fp16 distance** — Half-precision for 2× throughput where acceptable
- [ ] **Prefetching** — `@prefetch` neighbor vectors during HNSW traversal
- [ ] **Memory alignment** — 64-byte aligned vector storage for AVX-512

### 5.2 Benchmarking Suite

```bash
# New benchmark targets
zig build bench-vector -- --dataset sift-1m --metric cosine
zig build bench-vector -- --dataset glove-100 --metric l2
zig build bench-vector -- --dataset deep-1b --metric dot --quantize rabitq
```

- [ ] **Standard benchmark datasets** — SIFT-1M, GloVe-100, Deep-1B
- [ ] **Recall@K measurement** — Compare against ground truth
- [ ] **QPS measurement** — Queries per second at target recall
- [ ] **Build time** — Index construction speed
- [ ] **Memory profiling** — Track per-component memory usage
- [ ] **Comparison baselines** — Faiss, Qdrant, Milvus numbers

### 5.3 Adaptive Graph Navigation (GATE)

Based on KDD 2025 research — query-aware graph traversal that adapts to actual query patterns.

- [ ] **Query distribution tracker** — Sample incoming queries, build distribution model
- [ ] **Hub identification** — Find high-connectivity nodes in the graph
- [ ] **Contrastive shortcuts** — Add edges that reduce hops for common query patterns
- [ ] **A/B test framework** — Compare static vs. adaptive HNSW on real workloads

### 5.4 DiskANN Overflow

For datasets that exceed available RAM, spill to SSD while keeping hot vectors in memory.

```
┌──────────────────────────────────────┐
│         Memory (hot tier)             │
│  HNSW graph + RaBitQ compressed vecs  │
├──────────────────────────────────────┤
│           SSD (warm tier)             │
│  Full-precision vectors for re-rank   │
│  Accessed only for final top-K        │
└──────────────────────────────────────┘
```

- [ ] **Tiered storage** — Graph + quantized in RAM, full vectors on disk
- [ ] **Async I/O for re-ranking** — io_uring for non-blocking disk reads
- [ ] **LRU cache** — Keep frequently accessed full vectors in memory
- [ ] **Memory budget config** — `--vector-memory-limit 8GB`

---

## EntryFlags Evolution

The current `EntryFlags` has 6 spare bits. Here's the planned allocation:

```zig
pub const EntryFlags = packed struct(u8) {
    is_worm: bool,       // bit 0 — existing
    is_deleted: bool,    // bit 1 — existing
    is_vector: bool,     // bit 2 — Phase 2: marks entry as vector data
    is_bq_hash: bool,    // bit 3 — Phase 2: marks entry as BQ hash
    is_indexed: bool,    // bit 4 — Phase 2: vector has been added to HNSW index
    _: u3 = 0,           // bits 5-7 — reserved
};
```

This enables the store to distinguish vector entries at the storage layer without
parsing key prefixes, which is critical for snapshot serialization and cluster replication.

---

## Wire Protocol Evolution

### New Command IDs (Phase 2+)

| ID | Command | Phase | Purpose |
|----|---------|-------|---------|
| `0x0D` | VSEARCH | 2 | Native vector similarity search |
| `0x0E` | VINSERT | 2 | Native vector insert |
| `0x0F` | VSTATS | 2 | Vector index statistics |
| `0x10` | VCONFIG | 3 | Configure vector index params |

### Backward Compatibility

- Phase 1 procedures (`EXEC vsearch`, etc.) remain forever — no breaking change
- Native commands are optional hot-path optimizations
- Clients can detect support via STATUS response flags
- Old clients continue using EXEC; new clients use native commands

---

## Key Conventions

### Key Layout

```
vec:<namespace>:<id>              →  raw f32 bytes (the embedding)
bq:<namespace>:<id>               →  binary-quantized hash (1 bit/dim)
meta:vec:<namespace>:<id>         →  metadata (tags, source, text snippet)
vec:<namespace>:stats:count       →  total vectors inserted
vec:<namespace>:index:params      →  HNSW parameters (M, ef, dims)
vec:<namespace>:index:centroid    →  RaBitQ centroid vector
```

### Default Namespace

When no namespace is specified, procedures use `vec:` as the default prefix.
This keeps all vectors in a single namespace for simple use cases while supporting
multi-tenant isolation via explicit namespaces.

### Vector Format

Vectors are stored as **raw little-endian f32 byte arrays**. A 1536-dimensional
embedding is exactly 6,144 bytes. No header, no metadata, no framing — just the
float values packed contiguously. This is the same format used by every major
embedding API (OpenAI, Cohere, Voyage, etc.) when exporting raw bytes.

---

## Research Papers Referenced

| Paper | Conference | Relevance |
|-------|-----------|-----------|
| HNSW (Malkov & Yashunin) | IEEE TPAMI 2018 | Foundation index algorithm |
| RaBitQ | SIGMOD 2024 | Core quantization strategy |
| Extended RaBitQ | SIGMOD 2025 | Multi-bit quantization |
| GATE | KDD 2025 | Adaptive graph navigation |
| d-HNSW | 2025 | Disaggregated memory HNSW |
| FANNS Benchmark | 2025 | Filtered vector search taxonomy |
| SMEC | EMNLP 2025 | Matryoshka embedding compression |
| MUVERA | Google 2025 | Multi-vector → single-vector reduction |
| SPLADE | 2021+ | Learned sparse retrieval |
| DiskANN / FreshDiskANN | NeurIPS 2019 / 2025 | SSD-backed vector search |
| ColBERT-Att | 2026 | Attention-enhanced late interaction |

---

## Competitive Positioning

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   "Distributed KV + Vector + Pub/Sub                         │
│    in a single 45KB static binary"                           │
│                                                              │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────┐  │
│   │   KV     │  │  Vector  │  │  Pub/Sub │  │ Procedures │  │
│   │  Store   │  │  Search  │  │  Events  │  │  (Zig FFI) │  │
│   └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬─────┘  │
│        └──────────────┴─────────────┴───────────────┘        │
│                         │                                    │
│              ┌──────────┴──────────┐                         │
│              │  WormWire Protocol  │                         │
│              │  WORM Immutability  │                         │
│              │  meshguard Cluster  │                         │
│              │  Ed25519 Auth       │                         │
│              └─────────────────────┘                         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### What Makes This Unique

| Capability | WormDB | Redis+VSS | Qdrant | Milvus | Pinecone |
|-----------|--------|-----------|--------|--------|----------|
| Single binary | ✅ 45KB | ❌ modules | ❌ | ❌ | ❌ SaaS |
| KV + Vector unified | ✅ | ✅ | ❌ | ❌ | ❌ |
| Pub/Sub built-in | ✅ | ✅ | ❌ | ❌ | ❌ |
| WORM immutability | ✅ | ❌ | ❌ | ❌ | ❌ |
| Temporal scoring | ✅ native | ❌ | ❌ | ❌ | ❌ |
| Encrypted clustering | ✅ | ❌ | ❌ | ❌ | ✅ SaaS |
| Stored procedures | ✅ Zig | ✅ Lua | ❌ | ❌ | ❌ |
| Org trust / certs | ✅ | ❌ | ❌ | ❌ | ❌ |
| Zero dependencies | ✅ | ❌ | ❌ | ❌ | ❌ |
| Self-hosted | ✅ | ✅ | ✅ | ✅ | ❌ |

### Target Use Cases

1. **AI Agent Memory** — Verbatim recall with temporal context and WORM provenance
2. **Edge RAG** — Run a complete RAG stack on a single node (no cloud dependency)
3. **Audit-Trail Retrieval** — Immutable embeddings with cryptographic provenance chain
4. **IoT Semantic Search** — Tiny binary, encrypted mesh, works on ARM
5. **Multi-Tenant SaaS** — Namespace isolation + org trust + encrypted replication

---

## Summary Timeline

```
Phase 1  ████████████████████ DONE — brute-force + SIMD + temporal
Phase 2  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ HNSW + RaBitQ + filters (4-6 wk)
Phase 3  ░░░░░░░░░░░░░░░░░░░░ distributed scatter-gather (3-4 wk)
Phase 4  ░░░░░░░░░░░░░░░░░░░░░░░░ hybrid/multi-vec/persistence (4-6 wk)
Phase 5  ░░░░░░░░░░░░░░░░░░░░ SIMD specialization + benchmarks (3-4 wk)
         ─────────────────────────────────────────────────────────────→
         now                                              ~4 months
```

The immediate next step is **Phase 2.1: HNSW graph index** — the single highest-impact
piece that takes WormDB vector search from "demo" to "production-grade."
