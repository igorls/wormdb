export type DistanceMetric = "l2" | "cosine" | "dot";

export type BuildProgress = {
  inserted: number;
  total: number;
  elapsedMs: number;
};

/**
 * Bench modes — named to reflect what each adapter ACTUALLY does, not
 * what the vendor's marketing label claims.
 *
 * WormDB:
 *   exact      — EXEC vsearch mode=exact; brute-force full-precision scan.
 *   hnsw       — EXEC vsearch mode=auto; HNSW graph + full-precision rerank.
 *                NO quantization in this path.
 *   bq         — EXEC vsearch mode=bq. With RaBitQ params installed, scores
 *                via the unbiased estimator and returns top-K directly (NO
 *                rerank). Without params, falls back to Hamming prefilter +
 *                full-precision rerank.
 *   bq_rerank  — EXEC vsearch mode=bq_rerank; quantized prefilter (RaBitQ
 *                or Hamming) + full-precision rerank on candidates. Higher
 *                recall than bq, more work per query.
 *
 * Qdrant:
 *   exact     — collection without quantization config; full-precision HNSW.
 *   hnsw      — same as exact for Qdrant (alias for clarity).
 *   quantized — collection with scalar(int8) quantization enabled.
 *                Genuine quantization (4× compression).
 */
export type AdapterMode = "exact" | "hnsw" | "bq" | "bq_rerank" | "quantized";

export type AdapterConfig = {
  mode: AdapterMode;
  metric: DistanceMetric;
  dim: number;
  m?: number;
  efConstruction?: number;
  /**
   * If true, VINSERT requests set the async flag — server queues the HNSW
   * build to a background worker and acks after store+BQ. Adapter is
   * responsible for waitUntilQueryable() honestly reporting the lag.
   * Qdrant is always async by default; this flag is only honored by the
   * WormDB adapter.
   */
  asyncInsert?: boolean;
};

export type QueryResult = {
  ids: Int32Array;    // indices into the train set
  scores: Float32Array;
};

/**
 * Contract: every adapter gets a fresh collection/namespace per run.
 * `setup()` initializes the collection with the given config.
 * `build()` inserts all train vectors. Return wall time in ms.
 * `waitUntilQueryable(sampleIds, ...)` polls until a sample query returns
 *   the expected top-1 — honest "time-until-queryable" metric that
 *   accounts for async index builds (Qdrant) or inline builds (WormDB).
 * `prepareQueries()` pre-stages the test-set queries. WormDB pre-inserts
 *   them so `query()` is a single round-trip; Qdrant no-ops.
 * `setEf(ef)` tunes the search-time recall/QPS knob (no-op if N/A).
 * `query(qIdx, vec, k)` runs a single top-K search. `qIdx` is an index
 *   into the prepared query set; adapters that need it use qIdx, others
 *   ignore it and use `vec` directly.
 * `teardown()` closes connections. Docker compose deletes the container.
 *
 * All query adapters must spawn independent connections if constructed
 * multiple times — the harness creates 8 parallel adapters for the
 * concurrent QPS pass.
 */
export interface Adapter {
  name: string;
  /** Fresh collection: drop anything existing and create per config. */
  setup(config: AdapterConfig): Promise<void>;
  /** Attach to an already-built collection (for concurrent query clients). */
  connect(config: AdapterConfig): Promise<void>;
  build(
    vectors: Float32Array,
    dim: number,
    onProgress?: (p: BuildProgress) => void,
  ): Promise<{ insertMs: number }>;
  waitUntilQueryable(
    probeIds: Int32Array,
    probeVectors: Float32Array,
    dim: number,
    timeoutMs: number,
  ): Promise<{ waitMs: number }>;
  prepareQueries(queries: Float32Array, dim: number): Promise<void>;
  setEf(ef: number): Promise<void>;
  query(qIdx: number, queryVec: Float32Array, k: number): Promise<QueryResult>;
  teardown(): Promise<void>;
}
