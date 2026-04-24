#!/usr/bin/env bun
// End-to-end benchmark for the agent-memory showcase.
//
// Measures:
//   1. Ingest throughput (docs/sec)
//   2. Query latency p50/p95 (HNSW path when the index is populated)
//   3. Recall@10 against a brute-force ground truth on the same data
//
// The recall check is what makes this worth running — it validates the
// whole HNSW dispatch end-to-end over the wire, not a library-level
// synthetic test.
//
// Usage:
//   bun run examples/agent-memory/client/bench.ts [--ns bench] [--n 2000] [--queries 200] [--dim 128]

import { connect, type QueryHit } from "./mem";
import { embed, embedderId } from "../fixtures/embedder";

function parseArgs(argv: string[]): {
  ns: string;
  n: number;
  queries: number;
  dim: number;
  k: number;
  host: string;
  port: number;
} {
  let ns = "bench";
  let n = 2000;
  let queries = 200;
  let dim = 128;
  let k = 10;
  let host = "127.0.0.1";
  let port = 6389;
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i];
    const next = () => argv[++i] ?? "";
    if (t === "--ns") ns = next();
    else if (t === "--n") n = Number(next());
    else if (t === "--queries") queries = Number(next());
    else if (t === "--dim") dim = Number(next());
    else if (t === "-k") k = Number(next());
    else if (t === "--host") host = next();
    else if (t === "--port") port = Number(next());
  }
  return { ns, n, queries, dim, k, host, port };
}

/// Produce a deterministic synthetic corpus. Each doc is a handful of
/// random words drawn from a fixed vocabulary — pretty good at producing
/// distinguishable hash-embedder vectors.
function synthCorpus(n: number): { id: string; text: string }[] {
  const vocab = [
    "kyoto", "cherry", "ryokan", "kaiseki", "shojin", "arashiyama", "gion",
    "rust", "async", "tokio", "enum", "match", "cancel", "spawn",
    "piano", "prelude", "chopin", "rachmaninoff", "modal", "cadence", "voicing",
    "cortisol", "caffeine", "protein", "marathon", "tempo", "zone",
    "vector", "embedding", "cosine", "recall", "index", "hnsw",
    "atlantic", "pacific", "current", "gulf", "polar", "tropic",
    "novel", "prose", "verse", "sonnet", "metaphor", "allegory",
  ];
  const seed = 0x9e3779b9;
  let state = seed >>> 0;
  const lcg = () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state;
  };
  const docs: { id: string; text: string }[] = [];
  for (let i = 0; i < n; i += 1) {
    const len = 3 + (lcg() % 6);
    const words: string[] = [];
    for (let j = 0; j < len; j += 1) words.push(vocab[lcg() % vocab.length]);
    docs.push({ id: `d-${i.toString().padStart(6, "0")}`, text: words.join(" ") });
  }
  return docs;
}

/// Cosine similarity between two raw f32 byte arrays. Mirrors the Zig
/// server's cosine metric so brute-force ground truth lines up.
function cosine(a: Uint8Array, b: Uint8Array): number {
  const af = new Float32Array(a.buffer, a.byteOffset, a.byteLength / 4);
  const bf = new Float32Array(b.buffer, b.byteOffset, b.byteLength / 4);
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < af.length; i += 1) {
    dot += af[i] * bf[i];
    na += af[i] * af[i];
    nb += bf[i] * bf[i];
  }
  const d = Math.sqrt(na) * Math.sqrt(nb);
  return d === 0 ? 0 : dot / d;
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor(sorted.length * p));
  return sorted[idx];
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const { wire, mem } = connect({ host: args.host, port: args.port, timeoutMs: 60_000 });

  try {
    // Fresh namespace every run.
    console.error(`Dropping '${args.ns}' if present...`);
    await mem.drop(args.ns);
    const eid = embedderId({ dim: args.dim });
    await mem.init(args.ns, eid, "cosine");

    // ── Stage 1: ingest ──────────────────────────────────────────
    const corpus = synthCorpus(args.n);
    // Pre-embed everything on the client so ingest timing is dominated
    // by wire + server work, not embedding.
    const preEmbedded = corpus.map((d) => ({
      id: d.id,
      text: d.text,
      vec: embed(d.text, { dim: args.dim }),
    }));

    console.error(`Ingesting ${corpus.length} docs (dim=${args.dim})...`);
    const tIngest0 = performance.now();
    for (const d of preEmbedded) {
      await mem.add(args.ns, d.id, d.text, d.vec, { worm: true });
    }
    const tIngest = performance.now() - tIngest0;
    const ingestRate = corpus.length / (tIngest / 1000);
    console.error(`  done in ${tIngest.toFixed(0)}ms → ${ingestRate.toFixed(0)} docs/s`);

    // ── Stage 2: query latency ──────────────────────────────────
    // Pick a random subset of corpus items as queries — each query
    // vector should recover itself at rank 1 under brute-force.
    const rng = () => Math.floor(Math.random() * preEmbedded.length);
    const queryIdxs = Array.from({ length: args.queries }, rng);

    console.error(`Running ${args.queries} queries (k=${args.k})...`);
    const latencies: number[] = [];
    const serverResults: QueryHit[][] = [];
    for (const qi of queryIdxs) {
      const q = preEmbedded[qi];
      const t0 = performance.now();
      const hits = await mem.query(args.ns, q.vec, args.k, { snippetChars: -1 });
      latencies.push(performance.now() - t0);
      serverResults.push(hits);
    }
    latencies.sort((a, b) => a - b);
    const p50 = percentile(latencies, 0.5);
    const p95 = percentile(latencies, 0.95);
    const p99 = percentile(latencies, 0.99);
    console.error(
      `  p50=${p50.toFixed(2)}ms p95=${p95.toFixed(2)}ms p99=${p99.toFixed(2)}ms`,
    );

    // ── Stage 3: recall@k vs. brute-force ground truth ──────────
    console.error("Computing brute-force ground truth...");
    let totalIntersect = 0;
    let totalExpected = 0;
    for (let qi = 0; qi < queryIdxs.length; qi += 1) {
      const q = preEmbedded[queryIdxs[qi]];
      const scored = preEmbedded.map((d) => ({
        id: d.id,
        score: cosine(q.vec, d.vec),
      }));
      scored.sort((a, b) => b.score - a.score);
      const truth = new Set(scored.slice(0, args.k).map((s) => s.id));
      const got = new Set(serverResults[qi].map((h) => h.id));
      let intersect = 0;
      for (const id of got) if (truth.has(id)) intersect += 1;
      totalIntersect += intersect;
      totalExpected += args.k;
    }
    const recall = totalIntersect / totalExpected;
    console.error(`  recall@${args.k} = ${recall.toFixed(4)}`);

    // ── Summary (structured, friendly to grep) ──────────────────
    const stats = await mem.stats(args.ns);
    const summary = {
      namespace: args.ns,
      docs: corpus.length,
      dim: args.dim,
      ingest_ms: Math.round(tIngest),
      ingest_rate_per_s: Math.round(ingestRate),
      query_ms: {
        p50: Number(p50.toFixed(3)),
        p95: Number(p95.toFixed(3)),
        p99: Number(p99.toFixed(3)),
      },
      [`recall@${args.k}`]: Number(recall.toFixed(4)),
      index: stats.hnsw ?? null,
    };
    console.log(JSON.stringify(summary, null, 2));
  } finally {
    await wire.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
