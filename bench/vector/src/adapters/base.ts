export type DistanceMetric = "l2" | "cosine" | "dot";

export type BuildProgress = {
  inserted: number;
  total: number;
  elapsedMs: number;
};

export type AdapterMode = "exact" | "quantized";

export type AdapterConfig = {
  mode: AdapterMode;
  metric: DistanceMetric;
  dim: number;
  m?: number;
  efConstruction?: number;
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
