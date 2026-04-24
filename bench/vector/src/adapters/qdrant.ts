// Qdrant adapter — drives the REST client.
//
// Modes:
//   exact       — no quantization configured; full-precision HNSW search.
//   quantized   — scalar (int8) quantization enabled. This is NOT equivalent
//                 to WormDB's 1-bit BQ — it's a much milder compression.
//                 Label as "scalar(int8)" in the report.

import { QdrantClient } from "@qdrant/js-client-rest";
import type {
  Adapter,
  AdapterConfig,
  AdapterMode,
  BuildProgress,
  DistanceMetric,
  QueryResult,
} from "./base";

const COLLECTION = "vbench";

function qdrantMetric(m: DistanceMetric): "Euclid" | "Cosine" | "Dot" {
  if (m === "l2") return "Euclid";
  if (m === "cosine") return "Cosine";
  return "Dot";
}

export class QdrantAdapter implements Adapter {
  readonly name = "qdrant";
  private client!: QdrantClient;
  private cfg!: AdapterConfig;
  private efSearch = 64;

  constructor(private readonly url: string) {}

  async connect(config: AdapterConfig): Promise<void> {
    this.cfg = config;
    this.client = new QdrantClient({ url: this.url });
  }

  async setup(config: AdapterConfig): Promise<void> {
    this.cfg = config;
    this.client = new QdrantClient({ url: this.url });

    try {
      await this.client.deleteCollection(COLLECTION);
    } catch {
      // first run — collection doesn't exist yet
    }

    const params: Record<string, unknown> = {
      vectors: {
        size: config.dim,
        distance: qdrantMetric(config.metric),
      },
      hnsw_config: {
        m: config.m ?? 16,
        ef_construct: config.efConstruction ?? 200,
      },
      on_disk_payload: false,
    };

    if (config.mode === "quantized") {
      params.quantization_config = {
        scalar: {
          type: "int8",
          always_ram: true,
        },
      };
    } else if (config.mode === "bq") {
      throw new Error("qdrant adapter: 'bq' is a WormDB-only label; use 'quantized' (scalar int8) or 'exact'/'hnsw'");
    }
    // "exact" and "hnsw" both map to Qdrant's default full-precision HNSW
    // (no quantization config). The distinction only matters for WormDB.

    await this.client.createCollection(COLLECTION, params as Parameters<QdrantClient["createCollection"]>[1]);
  }

  async build(
    vectors: Float32Array,
    dim: number,
    onProgress?: (p: BuildProgress) => void,
  ): Promise<{ insertMs: number }> {
    const N = vectors.length / dim;
    const BATCH = 512;
    const start = Bun.nanoseconds();

    for (let i = 0; i < N; i += BATCH) {
      const end = Math.min(N, i + BATCH);
      const points = [];
      for (let j = i; j < end; j += 1) {
        points.push({
          id: j,
          vector: Array.from(vectors.subarray(j * dim, (j + 1) * dim)),
        });
      }
      await this.client.upsert(COLLECTION, {
        wait: false,
        points,
      });
      if (onProgress && (end % 10_000 === 0 || end === N)) {
        onProgress({
          inserted: end,
          total: N,
          elapsedMs: (Bun.nanoseconds() - start) / 1e6,
        });
      }
    }
    return { insertMs: (Bun.nanoseconds() - start) / 1e6 };
  }

  async waitUntilQueryable(
    probeIds: Int32Array,
    probeVectors: Float32Array,
    dim: number,
    timeoutMs: number,
  ): Promise<{ waitMs: number }> {
    // Qdrant builds the HNSW index asynchronously after upsert. Poll the
    // collection status + a sample query until the probe IDs come back as
    // top-1 for their own vectors. This is the honest "time-until-queryable"
    // — matches what WormDB reports as 0 (inline build).
    const start = Bun.nanoseconds();
    const deadline = start + timeoutMs * 1e6;

    while (Bun.nanoseconds() < deadline) {
      let ok = 0;
      for (let p = 0; p < probeIds.length; p += 1) {
        const vec = Array.from(probeVectors.subarray(p * dim, (p + 1) * dim));
        const res = await this.client.search(COLLECTION, {
          vector: vec,
          limit: 1,
          with_payload: false,
          with_vector: false,
        });
        if (res.length > 0 && Number(res[0].id) === probeIds[p]) ok += 1;
      }
      if (ok === probeIds.length) {
        return { waitMs: (Bun.nanoseconds() - start) / 1e6 };
      }
      await Bun.sleep(200);
    }
    throw new Error(`Qdrant waitUntilQueryable: timeout after ${timeoutMs}ms`);
  }

  async prepareQueries(_queries: Float32Array, _dim: number): Promise<void> {
    // No-op: Qdrant accepts raw query vectors per call.
  }

  async setEf(ef: number): Promise<void> {
    this.efSearch = ef;
  }

  async query(_qIdx: number, queryVec: Float32Array, k: number): Promise<QueryResult> {
    const res = await this.client.search(COLLECTION, {
      vector: Array.from(queryVec),
      limit: k,
      params: { hnsw_ef: this.efSearch },
      with_payload: false,
      with_vector: false,
    });
    const ids = new Int32Array(res.length);
    const scores = new Float32Array(res.length);
    for (let i = 0; i < res.length; i += 1) {
      ids[i] = Number(res[i].id);
      scores[i] = res[i].score;
    }
    return { ids, scores };
  }

  async teardown(): Promise<void> {
    // REST client has no persistent socket to close.
  }
}
