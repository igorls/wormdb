#!/usr/bin/env bun
// Vector benchmark runner.
//
// Usage:
//   bun run src/run.ts --adapter <wormdb|qdrant> --dataset <name> --mode <exact|quantized>
//                      [--efs 16,32,64,128,256] [--concurrency 8] [--N <limit>]
//
// Writes one JSON file per (adapter, mode) to ./results/<dataset>/.

import type { Adapter, AdapterConfig, AdapterMode } from "./adapters/base";
import { WormdbAdapter } from "./adapters/wormdb";
import { QdrantAdapter } from "./adapters/qdrant";
import { loadDataset, rowView, type Dataset } from "./datasets";
import { recallAtK, summarizeLatencies, type LatencySummary } from "./metrics";

type Args = {
  adapter: "wormdb" | "qdrant";
  dataset: string;
  mode: AdapterMode;
  efs: number[];
  concurrency: number;
  N: number;       // 0 = use full train set
  Q: number;       // 0 = use full test set
  topK: number;
  dataDir: string;
  resultsDir: string;
  asyncInsert: boolean;
};

function parseArgs(argv: string[]): Args {
  const a: Args = {
    adapter: "wormdb",
    dataset: "sift-128-euclidean",
    mode: "exact",
    efs: [16, 32, 64, 128, 256],
    concurrency: 8,
    N: 0,
    Q: 0,
    topK: 10,
    dataDir: "./data",
    resultsDir: "./results",
    asyncInsert: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i];
    const n = (): string => argv[++i] ?? "";
    switch (t) {
      case "--adapter": a.adapter = n() as Args["adapter"]; break;
      case "--dataset": a.dataset = n(); break;
      case "--mode": a.mode = n() as AdapterMode; break;
      case "--efs": a.efs = n().split(",").map(Number); break;
      case "--concurrency": a.concurrency = Number(n()); break;
      case "--N": a.N = Number(n()); break;
      case "--Q": a.Q = Number(n()); break;
      case "--topK": a.topK = Number(n()); break;
      case "--data-dir": a.dataDir = n(); break;
      case "--results-dir": a.resultsDir = n(); break;
      case "--async": a.asyncInsert = true; break;
    }
  }
  return a;
}

function buildAdapter(kind: Args["adapter"]): Adapter {
  if (kind === "wormdb") {
    return new WormdbAdapter(
      process.env.WORMDB_HOST ?? "127.0.0.1",
      Number(process.env.WORMDB_PORT ?? 6389),
    );
  }
  return new QdrantAdapter(process.env.QDRANT_URL ?? "http://127.0.0.1:6333");
}

type EfResult = {
  ef: number;
  recall: number;
  singleLatency: LatencySummary;
  singleQps: number;
  concurrentQps: number;
  concurrentLatency: LatencySummary;
};

type RunResult = {
  adapter: string;
  mode: AdapterMode;
  dataset: string;
  N: number;
  Q: number;
  dim: number;
  topK: number;
  metric: string;
  buildInsertMs: number;
  insertQps: number;
  waitUntilQueryableMs: number;
  perEf: EfResult[];
  notes: string[];
  startedAt: string;
  finishedAt: string;
};

async function main(): Promise<void> {
  const args = parseArgs(Bun.argv.slice(2));
  console.log(`Args: ${JSON.stringify(args)}`);

  let ds = await loadDataset(args.dataset, args.dataDir);
  const N = args.N > 0 ? Math.min(args.N, ds.N) : ds.N;
  const Q = args.Q > 0 ? Math.min(args.Q, ds.Q) : ds.Q;
  const dim = ds.dim;

  const trainSlice = ds.train.subarray(0, N * dim);
  const testSlice = ds.test.subarray(0, Q * dim);

  // If we truncated the train set, the dataset's ground-truth neighbors point
  // to indices outside our subset. Recompute brute-force for this (N, Q) pair.
  let gtNeighbors = ds.neighbors;
  let gtK = ds.gtK;
  if (N < ds.N || Q < ds.Q) {
    console.log(`Recomputing ground truth for truncated subset (N=${N}, Q=${Q})...`);
    gtK = Math.min(100, N);
    gtNeighbors = recomputeGroundTruth(trainSlice, testSlice, dim, N, Q, gtK, ds.metric);
    ds = { ...ds, neighbors: gtNeighbors, gtK, N, Q };
  }

  console.log(`Dataset ${ds.name}: N=${N}, Q=${Q}, dim=${dim}, metric=${ds.metric}, gtK=${gtK}`);

  const cfg: AdapterConfig = {
    mode: args.mode,
    metric: ds.metric,
    dim,
    asyncInsert: args.asyncInsert,
  };

  const adapter = buildAdapter(args.adapter);
  console.log(`\n--- ${adapter.name} / ${args.mode} ---`);

  const startedAt = new Date().toISOString();
  await adapter.setup(cfg);

  // Build
  console.log(`Building index (${N} vectors)...`);
  const { insertMs } = await adapter.build(trainSlice, dim, (p) => {
    const rate = (p.inserted / p.elapsedMs) * 1000;
    console.log(`  progress: ${p.inserted}/${p.total} (${rate.toFixed(0)} vec/s)`);
  });
  const insertQps = (N / insertMs) * 1000;
  console.log(`  insert: ${insertMs.toFixed(0)}ms wall, ${insertQps.toFixed(0)} vec/s`);

  // Time-until-queryable: probe 16 known IDs until they come back as top-1
  const probeCount = Math.min(16, N);
  const probeIds = new Int32Array(probeCount);
  for (let i = 0; i < probeCount; i += 1) probeIds[i] = Math.floor((i * N) / probeCount);
  const probeVecs = new Float32Array(probeCount * dim);
  for (let i = 0; i < probeCount; i += 1) {
    probeVecs.set(rowView(trainSlice, probeIds[i], dim), i * dim);
  }
  const { waitMs } = await adapter.waitUntilQueryable(probeIds, probeVecs, dim, 300_000);
  console.log(`  time-until-queryable: ${waitMs.toFixed(0)}ms`);

  // Prepare queries (WormDB pre-inserts test set; Qdrant no-ops)
  await adapter.prepareQueries(testSlice, dim);

  const perEf: EfResult[] = [];
  for (const ef of args.efs) {
    await adapter.setEf(ef);
    console.log(`\n  ef=${ef}`);

    // Single-client pass: latency + QPS + recall
    const predicted: Int32Array[] = [];
    const latencies: number[] = [];
    const singleStart = Bun.nanoseconds();
    for (let q = 0; q < Q; q += 1) {
      const vec = rowView(testSlice, q, dim);
      const tStart = Bun.nanoseconds();
      const r = await adapter.query(q, vec, args.topK);
      latencies.push((Bun.nanoseconds() - tStart) / 1e6);
      predicted.push(r.ids);
    }
    const singleWallMs = (Bun.nanoseconds() - singleStart) / 1e6;
    const singleQps = (Q / singleWallMs) * 1000;
    const singleLatency = summarizeLatencies(latencies);
    const recall = recallAtK(predicted, ds.neighbors, ds.gtK, args.topK);
    console.log(
      `    single: recall@${args.topK}=${recall.toFixed(3)}  qps=${singleQps.toFixed(0)}  p50=${singleLatency.p50Ms.toFixed(2)}ms p95=${singleLatency.p95Ms.toFixed(2)}ms p99=${singleLatency.p99Ms.toFixed(2)}ms`,
    );

    // Concurrent pass — C independent adapters, each running Q/C queries
    const C = args.concurrency;
    const workers: Promise<number[]>[] = [];
    const concurrentAdapters: Adapter[] = [];
    for (let w = 0; w < C; w += 1) {
      const a = buildAdapter(args.adapter);
      await a.connect(cfg);
      await a.setEf(ef);
      concurrentAdapters.push(a);
    }
    const concurrentStart = Bun.nanoseconds();
    for (let w = 0; w < C; w += 1) {
      const aw = concurrentAdapters[w];
      const slice = Array.from({ length: Math.ceil(Q / C) }, (_, i) => w + i * C).filter((q) => q < Q);
      workers.push((async () => {
        const ls: number[] = [];
        for (const q of slice) {
          const vec = rowView(testSlice, q, dim);
          const tStart = Bun.nanoseconds();
          await aw.query(q, vec, args.topK);
          ls.push((Bun.nanoseconds() - tStart) / 1e6);
        }
        return ls;
      })());
    }
    const concurrentLats = (await Promise.all(workers)).flat();
    const concurrentWallMs = (Bun.nanoseconds() - concurrentStart) / 1e6;
    const concurrentQps = (Q / concurrentWallMs) * 1000;
    const concurrentLatency = summarizeLatencies(concurrentLats);
    console.log(
      `    ${C}-way: qps=${concurrentQps.toFixed(0)}  p50=${concurrentLatency.p50Ms.toFixed(2)}ms p95=${concurrentLatency.p95Ms.toFixed(2)}ms p99=${concurrentLatency.p99Ms.toFixed(2)}ms`,
    );
    for (const a of concurrentAdapters) await a.teardown();

    perEf.push({ ef, recall, singleLatency, singleQps, concurrentQps, concurrentLatency });
  }

  const finishedAt = new Date().toISOString();
  await adapter.teardown();

  const result: RunResult = {
    adapter: adapter.name,
    mode: args.mode,
    dataset: args.dataset,
    N, Q, dim,
    topK: args.topK,
    metric: ds.metric,
    buildInsertMs: insertMs,
    insertQps,
    waitUntilQueryableMs: waitMs,
    perEf,
    notes: noteFor(args.adapter, args.mode, args.asyncInsert),
    startedAt,
    finishedAt,
  };

  const suffix = args.asyncInsert ? "-async" : "";
  const outPath = `${args.resultsDir}/${args.dataset}/${args.adapter}-${args.mode}${suffix}.json`;
  await Bun.write(outPath, JSON.stringify(result, null, 2));
  console.log(`\nWrote ${outPath}`);
}

function noteFor(adapter: Args["adapter"], mode: AdapterMode, asyncInsert: boolean): string[] {
  const notes: string[] = [];
  if (adapter === "wormdb") {
    if (asyncInsert) {
      notes.push("HNSW built asynchronously via background worker; insert acks after store+BQ only.");
      notes.push("time-until-queryable measured by polling `vstats.hnsw.pending == 0`.");
    } else {
      notes.push("HNSW built inline during VINSERT; time-until-queryable == 0.");
    }
    switch (mode) {
      case "exact":
        notes.push("exact mode: full-precision brute-force scan. No HNSW, no quantization.");
        break;
      case "hnsw":
        notes.push("hnsw mode: HNSW graph search + full-precision rerank on top-M candidates. NO quantization.");
        break;
      case "bq":
        notes.push("bq mode: RaBitQ unbiased estimator scores all bq:* entries; returns top-K directly (NO rerank). Falls back to Hamming prefilter + rerank when RaBitQ params aren't installed.");
        break;
      case "bq_rerank":
        notes.push("bq_rerank mode: quantized prefilter (RaBitQ estimator if params installed, else Hamming) + full-precision rerank on top-M. Higher recall than bq, more work per query.");
        break;
      case "quantized":
        notes.push("quantized mode is Qdrant-only; runtime will have rejected this.");
        break;
    }
  } else {
    notes.push("Qdrant HNSW built asynchronously; time-until-queryable measured via probe-poll.");
    switch (mode) {
      case "exact":
      case "hnsw":
        notes.push("Full-precision HNSW (no quantization_config on the collection).");
        break;
      case "quantized":
        notes.push("scalar(int8) quantization configured; Qdrant does two-pass search with internal rerank.");
        break;
      case "bq":
      case "bq_rerank":
        notes.push("bq / bq_rerank modes are WormDB-only; runtime will have rejected this.");
        break;
    }
  }
  return notes;
}

function recomputeGroundTruth(
  train: Float32Array,
  test: Float32Array,
  dim: number,
  N: number,
  Q: number,
  k: number,
  metric: "l2" | "cosine",
): Int32Array {
  const out = new Int32Array(Q * k);
  const distances = new Float32Array(N);
  const useL2 = metric === "l2";
  for (let q = 0; q < Q; q += 1) {
    const qOff = q * dim;
    for (let i = 0; i < N; i += 1) {
      const iOff = i * dim;
      if (useL2) {
        let d = 0;
        for (let j = 0; j < dim; j += 1) {
          const x = train[iOff + j] - test[qOff + j];
          d += x * x;
        }
        distances[i] = d;
      } else {
        let dot = 0, na = 0, nb = 0;
        for (let j = 0; j < dim; j += 1) {
          const a = train[iOff + j];
          const b = test[qOff + j];
          dot += a * b; na += a * a; nb += b * b;
        }
        distances[i] = 1 - dot / (Math.sqrt(na) * Math.sqrt(nb) + 1e-12);
      }
    }
    const idx = Array.from({ length: N }, (_, i) => i).sort((a, b) => distances[a] - distances[b]);
    for (let i = 0; i < k; i += 1) out[q * k + i] = idx[i];
    if ((q + 1) % 50 === 0) console.log(`  gt: ${q + 1}/${Q}`);
  }
  return out;
}

main().catch((err) => {
  console.error(err instanceof Error ? err.stack : String(err));
  process.exit(1);
});
