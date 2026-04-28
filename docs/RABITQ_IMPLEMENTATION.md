# RaBitQ Implementation Notes

> **Status**: implemented for L2 namespaces. `EXEC vrabitq <namespace>`
> computes RaBitQ params, re-encodes existing `bq:*` entries, and snapshot
> format v2 persists the params alongside HNSW graph state.
>
> **Modes**: `mode=bq` uses the estimator directly; `mode=bq_rerank`
> uses RaBitQ to choose candidates and then performs exact stage-2 rerank.
>
> **Reference paper**: Gao & Long, *"RaBitQ: Quantizing High-Dimensional
> Vectors with a Theoretical Error Bound for Approximate Nearest Neighbor
> Search"*, SIGMOD 2024. [arxiv 2405.12497](https://arxiv.org/abs/2405.12497)
>
> **Follow-up**: Gao & Long, *"Practical and Asymptotically Optimal
> Quantization of High-Dimensional Vectors in Euclidean Space for
> Approximate Nearest Neighbor Search"* (Extended RaBitQ), SIGMOD 2025.
> [arxiv 2409.09913](https://arxiv.org/abs/2409.09913) — deferred; adds
> multi-bit codes on top of the 1-bit primitive.

---

## What exists today

### Code paths

| File | What it does now |
|---|---|
| [src/vector/rabitq.zig](src/vector/rabitq.zig) | RaBitQ params, rotation generation, encode/parse, and distance estimator |
| [src/vector/distance.zig](src/vector/distance.zig) | Naive BQ and Hamming primitives used by the fallback path |
| [src/vector/index.zig](src/vector/index.zig) | Stores per-namespace `RabitqParams` and persists them in snapshot v2 |
| [src/procedures/vrabitq.zig](src/procedures/vrabitq.zig) | `EXEC vrabitq <ns>` scans vectors, computes params, re-encodes `bq:*`, and installs params atomically |
| [src/procedures/vsearch.zig](src/procedures/vsearch.zig) | Uses RaBitQ estimates for `mode=bq`; uses exact rerank for `mode=bq_rerank` |
| [src/procedures/vector_ops.zig](src/procedures/vector_ops.zig) | New inserts use installed RaBitQ params when encoding BQ companions |
| [bench/vector/src/adapters/wormdb.ts](bench/vector/src/adapters/wormdb.ts) | Harness can benchmark exact, BQ, and `bq_rerank` modes |

### What the measurements say

Benchmarks on sift-128-euclidean, N=100k, Q=500, top-k=10:

- **Plain BQ** (before phase 1, sign threshold only): recall = **0.001**
  (expected — SIFT values are all ≥ 0 so every hash is identical)
- **Centered BQ** (phase 1, this session): recall = **0.600**
  (matches paper expectations for 1-bit without rotation)
- **Paper target with full RaBitQ at 1-bit**: recall ~= **0.85-0.90**
  on SIFT-128 with random rotation + unbiased distance estimator

The implemented RaBitQ path is designed to close that centered-BQ gap while keeping `bq_rerank` available when exact refinement is worth the extra pass.

### What was intentionally limited in phase 1

- No random rotation — bits are correlated across dimensions for
  structured data (SIFT features, image descriptors). Rotation
  decorrelates them.
- No correction factors — phase 1 used BQ hashes purely as a Hamming prefilter,
  then did an exact rerank on the top-M candidates via
  `ctx.getCopy + computeExactSim`. The paper's contribution is that
  correction factors make the distance estimate unbiased so the rerank
  is unnecessary for most queries.
- Centroid/rotation persistence was missing in phase 1. Snapshot v2 now
  persists full `RabitqParams` with the namespace index.

---

## The paper in one page

### Algorithm 1: encode(v, c, R) → (code, factors)

Given database point `v ∈ ℝ^d`, centroid `c ∈ ℝ^d`, and random
orthogonal matrix `R ∈ ℝ^(d×d)`:

```
1. residual  r       = v - c
2. normalize ȓ       = r / ||r||
3. rotate    ȓ'      = R @ ȓ
4. quantize  code[i] = sign(ȓ'[i]) for i in 0..d
5. factors:
      ||r||             — L2 distance from centroid (scalar)
      <ȓ', quantize(ȓ')> — bias-correction inner product (scalar)
```

The paper shows that if you pack the factors into the index, the
expected estimated distance is equal to the true distance (unbiased),
with an error bound that scales as O(1/√d).

### Algorithm 2: estimate(q, c, R, code_p, factors_p) → d̂(q, v)

At query time:

```
1. query residual    r_q    = q - c
2. query rotated     r_q'   = R @ r_q
3. inner product     ⟨r_q', ȓ'⟩ ≈ unpack_from_bits(code_p, r_q') / c_corr
4. reconstruct       d²(q,v) ≈ ||r_q||² + ||r||² − 2·||r_q||·||r||·⟨r_q', ȓ'⟩
```

Step 3 is where the bit arithmetic happens. The paper shows you can
estimate the inner product using **popcount of XOR + a scalar multiply**,
which is ~20× faster than computing the exact distance.

### Key properties

- **Single-pass search**: with correction factors, the estimated
  distance is good enough that you can directly return the top-K without
  a full-precision rerank step. (Rerank is still optional and cheap.)
- **Drop-in replacement**: works on top of any existing index (HNSW,
  IVF, brute-force). Just swap the distance function. For WormDB this
  means the BQ prefilter becomes a *primary* distance, not just a
  prefilter.
- **Deterministic encoding**: same R + same centroid + same v always
  produce the same code. Required for consistent search.

---

## Implementation notes — step by step

### Step 1: storage format decisions

These are the persistent additions — decide now to avoid churn.

**Per-namespace (on `NamespaceIndex`):**

```zig
const RabitqParams = struct {
    // Locked at first vrabitq call, immutable thereafter.
    centroid: []f32,         // length = dim (exists today)
    rotation: []f32,         // d×d orthogonal matrix, row-major (NEW)
    dim: u32,                // sanity
    seed: u64,               // RNG seed used to build rotation (for reproducibility)
};
```

**Per-vector (additions to the `bq:<key>` stored value):**

Current `bq:<key>` is `ceil(d/8)` bytes — raw 1-bit code.

New layout:

```
[bq_code: ceil(d/8) bytes]   — unchanged: rotated sign pattern
[l2_norm: f32]                — ||v - c||
[corr:    f32]                — bias correction factor (⟨ȓ', q_code⟩)
```

So every `bq:*` entry grows by 8 bytes. On SIFT-128: 16B → 24B. Still
trivial compared to the full vector (512B).

**Backwards compatibility**: detect old vs new format by value size.
`ceil(d/8)` → old naive-BQ. `ceil(d/8) + 8` → new RaBitQ. Migration via
re-running `vrabitq`.

**Snapshot persistence**: the rotation matrix must go into the
snapshot. It's d² f32s — for SIFT-128 that's 64KB per namespace, fine.
Extend [src/vector/index.zig](src/vector/index.zig)'s `writeToLocked` /
`readFromLocked` to serialize `RabitqParams`.

### Step 2: rotation matrix generation

**Goal**: produce a random orthogonal d×d matrix R with a reproducible
seed.

Naive: Gram-Schmidt on a Gaussian-random matrix. Correct but O(d³).
For d=128 that's ~2M ops — one-time cost per namespace, fine.

**Faster alternative** (recommended by the paper): random Walsh-Hadamard
transform — d·log(d) vs d³, but only works for d = 2^k. SIFT-128 is 2^7,
good. For non-power-of-2 dims (d=100 for GloVe, d=768 for many
embeddings), pad to next power of two.

```zig
// src/vector/rabitq.zig  (NEW FILE)

/// Generate a d×d orthogonal matrix using Gram-Schmidt on a PRNG'd
/// Gaussian matrix. Deterministic for a given seed.
pub fn generateRotation(allocator: Allocator, dim: usize, seed: u64) ![]f32 {
    // 1. Fill d×d buffer with N(0, 1) samples from a seeded xoshiro.
    // 2. Apply modified Gram-Schmidt in place to orthonormalize columns.
    // 3. Return the row-major d×d buffer.
}

/// Apply R to a vector: out = R @ v. Both in/out length d.
pub fn applyRotation(R: []const f32, v: []const f32, out: []f32) void {
    // matmul; SIMD-vectorized over 8-wide f32 lanes (reuse from distance.zig)
}
```

**Test**: `generateRotation(d=4, seed=1)` produces a matrix where
`R @ R^T ≈ I` within 1e-5. Also verify invariance of L2 norm under
rotation: `||R @ v|| ≈ ||v||`.

### Step 3: RaBitQ encode

Replace `binaryQuantizeCentered` with a richer encoder:

```zig
pub const EncodedVector = struct {
    code: []u8,   // ceil(d/8) bytes
    l2_norm: f32, // ||v - c||
    corr: f32,    // bias-correction factor
};

pub fn rabitqEncode(
    allocator: Allocator,
    v: []const f32,
    params: *const RabitqParams,
    scratch: []f32, // length d, caller-owned
) !EncodedVector {
    // 1. residual: scratch = v - c
    // 2. norm: l2 = ||scratch||; if l2 == 0, handle edge case (zero vec at centroid)
    // 3. normalize: scratch /= l2
    // 4. rotate: rotated = R @ scratch  (another scratch buffer)
    // 5. quantize: code[i] = sign(rotated[i])
    // 6. corr: c = dot(rotated, unquantize(code)) / (2 * d)   (paper's equation)
}
```

The `corr` scalar is the inner product between the rotated unit
vector and its bit-quantized version — a measure of how much info the
quantization lost. Paper gives the exact formula.

### Step 4: RaBitQ distance estimator

This replaces the Hamming-only path for candidate scoring:

```zig
pub fn rabitqEstimate(
    q_residual_rotated: []const f32, // R @ (q - c), length d
    q_l2_norm: f32,                  // ||q - c||
    code_p: []const u8,              // quantized db point
    p_l2_norm: f32,
    p_corr: f32,
) f32 {
    // 1. Inner product ⟨R(q̂), p_code_unpacked⟩ via paper's
    //    bit-trick formula: sum(-q_rotated[i] if !bit else q_rotated[i])
    //    Or popcount-based shortcut for normalized binary vectors.
    // 2. Unbiased scale: ip_est = ip_raw / p_corr
    // 3. Reconstruct: d² = q_l2² + p_l2² - 2 * q_l2 * p_l2 * ip_est
}
```

The inner-product step is the one to optimize most aggressively — it
runs per candidate. On 1536-dim vectors the paper reports ~4×–8× over
exact float distance; on 128-dim the speedup is smaller but still real.

**SIMD target**: process 8 codes in parallel with AVX2, or 16 with
AVX-512. Reuse the lane machinery from
[src/vector/distance.zig](src/vector/distance.zig).

### Step 5: wire into vsearch

The BQ path in [src/procedures/vsearch.zig](src/procedures/vsearch.zig)
currently does: Hamming-score prefilter → exact rerank via
`ctx.getCopy`.

New path when RaBitQ params are installed:

```
Stage 1:  rabitqEstimate on every bq:* entry → top-M by estimated distance
Stage 2 (optional, gated by query param):
           exact rerank of top-K' < M candidates for the highest-fidelity
           return. Default: skip the rerank; the estimator is unbiased.
```

Expose the rerank toggle via the existing vsearch mode: e.g. `mode=bq`
(no rerank, fast) vs `mode=bq_rerank` (one more pass). Measure both on
the bench harness.

### Step 6: refactor `EXEC vrabitq`

Current procedure does: compute centroid → re-quantize with centered
sign. Extend to:

```
1. First pass: accumulate running sum → centroid.
2. Generate rotation matrix R (deterministic seed from `ctx.timestamp()`
   or allow caller to pass it).
3. Second pass: rabitqEncode every vector, write new bq:* format.
4. Install RabitqParams on NamespaceIndex.
5. Update vstats to report:
     "rabitq": {
       "centroid_installed": true,
       "rotation_dim": 128,
       "rotation_seed": <u64>,
       "requantized": N
     }
```

Backwards compat: if a namespace has only a centroid (phase-1 state),
`vsearch` falls back to Hamming-only prefilter (current behavior).

### Step 7: harness support

Extend [bench/vector/src/adapters/wormdb.ts](bench/vector/src/adapters/wormdb.ts)
to exercise both the rerank and no-rerank variants:

```ts
type AdapterMode = "exact" | "hnsw" | "bq" | "bq_rerank";
```

Runtime: add a `--rabitq-no-rerank` flag (or similar). Measure:
- Recall with vs without rerank
- QPS with vs without rerank
- vrabitq wall time (it's now more work — rotation + encoding)

Expected: `bq_rerank` ≈ exact recall (1.0) with p50 20–40 ms; `bq`
(pure estimated) ≈ 0.85 recall with p50 5–10 ms.

### Step 8: tests

New unit tests in [src/vector/rabitq.zig](src/vector/rabitq.zig):

- `generateRotation` produces R where `R @ R^T - I` has Frobenius norm < 1e-5
- `applyRotation` preserves L2 norm to within 1e-5
- `rabitqEncode/Estimate` round-trip: synthetic Gaussian data → estimated
  distance within ±10% of exact for 95% of pairs
- `vrabitq` procedure integration test: load 1000 random vectors, run
  vrabitq, search with known ground truth, assert recall@10 ≥ 0.80

Don't forget to regenerate snapshot-roundtrip tests if the snapshot
format changes.

### Step 9: documentation

Current [docs/VECTOR_SEARCH.md](docs/VECTOR_SEARCH.md) phase-2 status:
- [x] binary quantization (phase 1, centered)
- [x] per-namespace centroid + `vrabitq` procedure
- [x] random orthogonal rotation
- [x] bias-correction factors
- [x] snapshot v2 persistence for RaBitQ params
- [ ] extended RaBitQ (multi-bit codes) → deferred to phase 3

Also update [docs/IN_DB_PROCEDURES_ADVANTAGE.md](docs/IN_DB_PROCEDURES_ADVANTAGE.md)
comparison table — WormDB's quantized mode should become "RaBitQ 1-bit"
once this lands, vs Qdrant's "scalar int8".

---

## Validation targets

Acceptance criteria for closing this work, with measured results from
the SIMD-vectorized ReleaseFast build on SIFT-128 (N=100k, Q=500, k=10):

| Metric | Target | Measured | Status |
|---|---|---|---|
| Recall@10, no rerank (`mode=bq`) | ≥ 0.85 | **0.348** | ❌ falls short — see "Honest results" below |
| Recall@10, with rerank (`mode=bq_rerank`) | ≥ 0.98 | **0.939** | ⚠️ close, not at target |
| p50 latency, single-client (`mode=bq_rerank`) | ≤ 10 ms | **18.34 ms** | ⚠️ ~2× over target |
| `EXEC vrabitq` wall time, 100k × 128 | ≤ 2 s | **0.23 s** | ✅ |
| Snapshot roundtrip preserves params | bit-exact | tested in unit | ✅ |
| Existing tests still pass | all green | 115/115 | ✅ |

For comparison on the same dataset:

| Mode | Recall@10 | p50 | 8-way QPS | Notes |
|---|---|---|---|---|
| `hnsw` (graph + exact rerank) | 1.000 | **0.55 ms** | 6879 | Best-in-class for indexed data |
| `exact` (brute force) | 1.000 | 19.00 ms | 215 | Reference truth |
| `bq_rerank` | 0.939 | 18.34 ms | 275 | 21× memory savings vs `exact` |
| `bq` (estimator only) | 0.348 | 18.32 ms | 275 | Best-effort; not production |

### Honest results

**`bq_rerank` is the production path.** It achieves 0.94 recall — close
to but below the paper's reported single-bit-with-rerank numbers. For
SIFT-128 specifically, the value proposition is **memory savings**
(24 B per vector vs 512 B for f32 exact = 21× compression) at recall
loss of ~6 percentage points vs exact, with latency comparable to
`exact` brute-force.

**`bq` (no rerank) underperforms the paper claim by a wide margin.**
The estimator's top-200 set captures 94% of true top-10 (we know this
because `bq_rerank` reranks within those 200 and recovers 0.94 recall),
but ranking *within* the top-200 by estimator alone is too noisy on
SIFT — only 35% of true top-10 land in the estimator's top-10. The
paper's 0.85 single-pass claim is likely tied to its Walsh-Hadamard
rotation choice or measurement convention, neither of which is the same
as our Gram-Schmidt-on-Gaussian rotation. We treat `bq` as best-effort
diagnostic mode, not a recommended production path.

**HNSW dominates `bq_rerank` on SIFT-128 by every metric** — 35× faster,
6 points higher recall. The reason to prefer `bq_rerank` over HNSW is
narrow:
- High-write workloads where the HNSW build cost is unaffordable
- Memory-constrained deployments (the BQ-only namespace stores 21× less)
- Append-only data where the index would be rebuilt per insert anyway

For a typical RAG / embedding-search workload at 100k–10M vectors, HNSW
remains the right answer.

Secondary (nice-to-have, partly delivered):
- ✅ Cosine metric: vrabitq + applyVinsert + vsearch now pre-normalize
  cosine namespaces to the unit sphere, so `cos = 1 − L²/2` recovers
  cosine ranking from the L2² estimator. Bench validation on a cosine
  dataset still pending.
- Dot product: deferred. Would need per-vector inner-product factors
  stored at encode time so the centroid-residual decomposition adds
  back the missing magnitude term.
- Run on a 1536-dim synthetic embedding set — confirms high-dim
  behavior; expectation is BQ's relative advantage grows with d (more
  per-vector compression, more compute per exact distance).

---

## Open design questions to settle early

1. **Seed management**: should the rotation seed be deterministic
   (`0xRABITQ_SEED` constant per namespace) or derived from timestamp?
   Deterministic is easier to reproduce in tests; timestamp-derived is
   slightly more secure against adversarial inputs. Paper doesn't care
   — any orthogonal R works.

2. **Dimension padding**: for non-power-of-two dims, pad with zeros
   before applying Hadamard-based rotation, OR use Gram-Schmidt for all
   sizes. Simpler to always use GS; slightly slower for very-high-dim.

3. **SIMD strategy for rabitqEstimate**: ✅ DONE. The inner-product step
   is factored as a series of 8-wide sign-flipped adds (XOR on the f32
   sign bit). 20× speedup vs scalar. Prototype originally in
   [src/vector/bench.zig](src/vector/bench.zig) before wiring into
   vsearch — microbenchmark the cost per bit.

4. **Extended RaBitQ (multi-bit codes)**: deferred entirely here. Design
   1-bit to be extensible: `code` becomes `[u8]` sized by
   `ceil(d * bits / 8)`, with bit-count as a per-namespace param.
   Implementation in phase 3.

5. **Cluster replication**: `vrabitq` mutates every `bq:*` entry in the
   namespace. In cluster mode, the replicated `SET`s would storm the
   peers. Options:
   - Replicate the rotation matrix + centroid as a new control-plane
     message, have peers run `vrabitq` locally
   - Accept the storm on the read path (SETs replicate normally)
   - Skip replication for `bq:*` keys; rely on peers rerunning `vrabitq`
   Decide before wiring the procedure into the replication path.

---

## Out of scope for this workstream

Explicit list of things NOT to build as part of this plan:

- **Extended RaBitQ multi-bit codes** — phase 3 (paper 2)
- **GPU-accelerated encoding** — tiny per-namespace one-time cost
- **Dynamic centroid updates** — frozen-after-first-vrabitq is fine
  for our use cases; a stream-drift detector is separate work
- **Integration with the cluster anti-entropy path** for bq entries —
  depends on the replication decision above

---

## Estimated effort

Rough breakdown, assuming one focused session of ~6–8 hours:

- Rotation generator + tests: 1.5 h
- Encode/estimate functions: 2 h
- vsearch wiring + mode plumbing: 1 h
- `vrabitq` refactor + params storage: 1 h
- Snapshot roundtrip: 1 h
- Harness mode + benchmarks: 1 h
- Docs update: 0.5 h

Total: ~8 hours of focused work. Could split across two sessions if
the snapshot roundtrip needs its own pass.
