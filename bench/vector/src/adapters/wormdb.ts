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

function modeArg(mode: AdapterMode): "exact" | "auto" {
  return mode === "exact" ? "exact" : "auto";
}

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
    const start = Bun.nanoseconds();
    const metric = metricStr(this.cfg.metric);

    for (let i = 0; i < N; i += 1) {
      const key = `${NAMESPACE}${i}`;
      const vec = vectors.subarray(i * dim, (i + 1) * dim);
      const resp = await this.client.vinsertNative(key, floatsToBytes(vec), {
        worm: false,
        namespace: NAMESPACE,
        metric,
      });
      if (resp.type !== "ok") {
        throw new Error(`vinsert failed at i=${i}: ${JSON.stringify(resp)}`);
      }
      if (onProgress && (i + 1) % 10_000 === 0) {
        onProgress({
          inserted: i + 1,
          total: N,
          elapsedMs: (Bun.nanoseconds() - start) / 1e6,
        });
      }
    }
    return { insertMs: (Bun.nanoseconds() - start) / 1e6 };
  }

  /**
   * WormDB's applyVinsert builds the HNSW graph inline, so vectors are
   * queryable as soon as VINSERT returns OK. Nothing to wait on; report 0ms.
   */
  async waitUntilQueryable(
    _probeIds: Int32Array,
    _probeVectors: Float32Array,
    _dim: number,
    _timeoutMs: number,
  ): Promise<{ waitMs: number }> {
    return { waitMs: 0 };
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
