// WormDB adapter — drives the bun client directly.
//
// Modes:
//   exact       — EXEC vsearch ... mode=exact (full brute-force scan)
//   quantized   — EXEC vsearch ... mode=auto  (BQ 1-bit prefilter → exact rerank)
//
// HNSW is always on under the hood (index is built by applyVinsert). `ef`
// is a per-namespace runtime parameter; we set it via EXEC vreindex if the
// procedure is available, otherwise it's a no-op (HNSW default kicks in).

import { WormClient } from "../../../../apps/bun/src/lib/client";
import type {
  Adapter,
  AdapterConfig,
  AdapterMode,
  BuildProgress,
  DistanceMetric,
  QueryResult,
} from "./base";

const NAMESPACE = "vec:bench:";
const QUERY_NAMESPACE = "vec:benchq:";

function floatsToBytes(f: Float32Array): Uint8Array {
  return new Uint8Array(f.buffer, f.byteOffset, f.byteLength);
}

function metricStr(m: DistanceMetric): "l2" | "cosine" | "dot" {
  if (m === "l2") return "l2";
  if (m === "cosine") return "cosine";
  return "dot";
}

/**
 * Translate a harness AdapterMode into the `mode=` argument passed to
 * WormDB's `EXEC vsearch`. Each branch is named after what the server
 * actually does, not any marketing label.
 *
 *   exact      → brute-force full-precision scan (server mode=exact)
 *   hnsw       → HNSW graph + full-precision rerank (server mode=auto)
 *   bq         → quantized prefilter, NO rerank (server mode=bq)
 *   bq_rerank  → quantized prefilter + full-precision rerank (server mode=bq_rerank)
 *   quantized  → reject; Qdrant-only label
 */
function modeArg(mode: AdapterMode): "exact" | "auto" | "bq" | "bq_rerank" {
  switch (mode) {
    case "exact": return "exact";
    case "hnsw": return "auto";
    case "bq": return "bq";
    case "bq_rerank": return "bq_rerank";
    case "quantized":
      throw new Error("wormdb adapter: 'quantized' is a Qdrant-only label; use 'hnsw', 'bq', or 'bq_rerank'");
  }
}

const DEFAULT_BUILD_PARALLELISM = 8;
// Bulk-insert batch size. The client now handles partial socket writes
// (drain-driven flush), so this can be larger. 256 items × ~540B = ~138KB.
const BULK_BATCH_SIZE = 256;

export class WormdbAdapter implements Adapter {
  readonly name = "wormdb";
  private client!: WormClient;
  private cfg!: AdapterConfig;

  constructor(private readonly host: string, private readonly port: number) {}

  async setup(config: AdapterConfig): Promise<void> {
    this.cfg = config;
    this.client = new WormClient({
      host: this.host,
      port: this.port,
      keepAlive: true,
      timeoutMs: 120_000,
    });
    // Drop any leftover namespaces from a prior run — purge=1 deletes data too.
    await this.client.send(`EXEC vnsdrop ${NAMESPACE} 1`);
    await this.client.send(`EXEC vnsdrop ${QUERY_NAMESPACE} 1`);
  }

  async connect(config: AdapterConfig): Promise<void> {
    this.cfg = config;
    this.client = new WormClient({
      host: this.host,
      port: this.port,
      keepAlive: true,
      timeoutMs: 120_000,
    });
  }

  async build(
    vectors: Float32Array,
    dim: number,
    onProgress?: (p: BuildProgress) => void,
  ): Promise<{ insertMs: number }> {
    const N = vectors.length / dim;
    const metric = metricStr(this.cfg.metric);
    const asyncInsert = this.cfg.asyncInsert ?? false;
    const start = Bun.nanoseconds();
    if (N === 0) return { insertMs: 0 };

    const tsNow = BigInt(Date.now());

    // Send one batch at a time. Each VBULKINSERT amortizes per-frame wire
    // cost across BULK_BATCH_SIZE items, which is the main lever vs
    // single-VINSERT; it also performs ONE namespace-lock acquisition per
    // batch (sync mode) or ONE queue-lock acquisition (async mode).
    let cursor = 0;
    let lastProgress = 0;
    while (cursor < N) {
      const end = Math.min(N, cursor + BULK_BATCH_SIZE);
      const items: { key: string; vector: Uint8Array; timestamp: bigint }[] = [];
      for (let i = cursor; i < end; i += 1) {
        items.push({
          key: `${NAMESPACE}${i}`,
          vector: floatsToBytes(vectors.subarray(i * dim, (i + 1) * dim)),
          timestamp: tsNow,
        });
      }
      const resp = await this.client.vbulkinsertNative(items, {
        worm: false,
        namespace: NAMESPACE,
        metric,
        async: asyncInsert,
      });
      if (resp.type !== "ok") throw new Error(`vbulkinsert failed at cursor=${cursor}: ${JSON.stringify(resp)}`);
      cursor = end;
      if (onProgress && cursor - lastProgress >= 10_000) {
        lastProgress = cursor;
        onProgress({ inserted: cursor, total: N, elapsedMs: (Bun.nanoseconds() - start) / 1e6 });
      }
    }

    // For bq / bq_rerank modes, install RaBitQ params (centroid +
    // rotation) and re-encode all BQ hashes so the prefilter is
    // actually useful. Without this, SIFT-like unsigned data collapses
    // every hash to the same value → recall ≈ 0.
    if (this.cfg.mode === "bq" || this.cfg.mode === "bq_rerank") {
      const rabitqStart = Bun.nanoseconds();
      const resp = await this.client.send(`EXEC vrabitq ${NAMESPACE}`);
      if (resp.type !== "bulk") {
        throw new Error(`vrabitq failed: ${JSON.stringify(resp)}`);
      }
      const rabitqMs = (Bun.nanoseconds() - rabitqStart) / 1e6;
      console.log(`  vrabitq (centroid + rotation + re-encode): ${rabitqMs.toFixed(0)}ms  ${resp.value}`);
    }

    return { insertMs: (Bun.nanoseconds() - start) / 1e6 };
  }

  /**
   * Sync mode: HNSW is built inline during VINSERT → vectors are queryable
   * as soon as VINSERT returns; report 0 ms.
   *
   * Async mode: probe the namespace until `vstats` reports pending=0 OR a
   * sample probe returns the expected top-1 for its own near-copy.
   */
  async waitUntilQueryable(
    probeIds: Int32Array,
    probeVectors: Float32Array,
    dim: number,
    timeoutMs: number,
  ): Promise<{ waitMs: number }> {
    if (!(this.cfg.asyncInsert ?? false)) return { waitMs: 0 };

    const start = Bun.nanoseconds();
    const deadline = start + timeoutMs * 1e6;
    const metric = metricStr(this.cfg.metric);

    // Insert each probe's vector under a scratch key *sync* (not in async
    // namespace) so querying it always finds the base. Actually simpler:
    // poll vstats for pending==0 — that's a direct signal the worker drained.
    while (Bun.nanoseconds() < deadline) {
      const resp = await this.client.send(`EXEC vstats ${NAMESPACE}`);
      if (resp.type === "bulk") {
        // Conservative parse: look for "pending":0 (or absence of pending)
        const match = /"pending"\s*:\s*(\d+)/.exec(resp.value);
        const pending = match ? Number(match[1]) : 0;
        if (pending === 0) {
          // Belt-and-suspenders: verify one probe actually returns its base.
          if (probeIds.length > 0) {
            const pidx = 0;
            const pvec = probeVectors.subarray(pidx * dim, (pidx + 1) * dim);
            // Insert probe under the query namespace and search.
            const qkey = `vec:benchq:probe:${pidx}`;
            await this.client.vinsertNative(qkey, floatsToBytes(pvec), {
              worm: false,
              namespace: "vec:benchq:",
              metric,
            });
            const sresp = await this.client.send(
              `EXEC vsearch ${qkey} 1 ${NAMESPACE} ${metric} 0 auto`,
            );
            if (sresp.type === "bulk") {
              const parsed = JSON.parse(sresp.value) as Array<{ k: string }>;
              const expectedKey = `${NAMESPACE}${probeIds[pidx]}`;
              if (parsed.length > 0 && parsed[0].k === expectedKey) {
                return { waitMs: (Bun.nanoseconds() - start) / 1e6 };
              }
            }
          } else {
            return { waitMs: (Bun.nanoseconds() - start) / 1e6 };
          }
        }
      }
      await Bun.sleep(50);
    }
    throw new Error(`wormdb waitUntilQueryable: timeout after ${timeoutMs}ms`);
  }

  async prepareQueries(queries: Float32Array, dim: number): Promise<void> {
    // Pre-insert each test-set query vector under a stable key so the
    // measured query path is a single EXEC vsearch round-trip.
    const Q = queries.length / dim;
    const metric = metricStr(this.cfg.metric);
    for (let q = 0; q < Q; q += 1) {
      const vec = queries.subarray(q * dim, (q + 1) * dim);
      const resp = await this.client.vinsertNative(`${QUERY_NAMESPACE}${q}`, floatsToBytes(vec), {
        worm: false,
        namespace: QUERY_NAMESPACE,
        metric,
      });
      if (resp.type !== "ok") throw new Error(`query insert failed at q=${q}: ${JSON.stringify(resp)}`);
    }
  }

  async setEf(_ef: number): Promise<void> {
    // HNSW ef_search is currently a build constant (see vsearch.zig); no
    // runtime knob exists. This is a known gap to surface in the report.
    // No-op for now so the benchmark still runs at the HNSW default.
  }

  async query(qIdx: number, _queryVec: Float32Array, k: number): Promise<QueryResult> {
    const metric = metricStr(this.cfg.metric);
    const mode = modeArg(this.cfg.mode);
    const qkey = `${QUERY_NAMESPACE}${qIdx}`;
    const resp = await this.client.send(`EXEC vsearch ${qkey} ${k} ${NAMESPACE} ${metric} 0 ${mode}`);
    if (resp.type !== "bulk") throw new Error(`vsearch failed: ${JSON.stringify(resp)}`);

    const parsed = JSON.parse(resp.value) as Array<{ k: string; s: number; ts: number }>;
    const ids = new Int32Array(parsed.length);
    const scores = new Float32Array(parsed.length);
    for (let i = 0; i < parsed.length; i += 1) {
      const m = /^vec:bench:(\d+)$/.exec(parsed[i].k);
      ids[i] = m ? Number(m[1]) : -1;
      scores[i] = parsed[i].s;
    }
    return { ids, scores };
  }

  async teardown(): Promise<void> {
    await this.client.close();
  }
}
