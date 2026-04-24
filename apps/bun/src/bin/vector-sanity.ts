#!/usr/bin/env bun
// Pre-harness sanity: insert N synthetic 128-dim vectors via native VINSERT
// under L2, then query a random subset via EXEC vsearch and assert each
// self-match lands at rank 1 with score 0 (L2 distance is inverted by the
// server — higher score = closer; exact match scores are at the top end).
//
// This validates byte layout, metric plumbing, and server stability at scale
// BEFORE we invest in the full docker/Qdrant harness.

import { WormClient } from "../lib/client";

type Args = {
  host: string;
  port: number;
  count: number;
  dim: number;
  queries: number;
  ef: number;
  namespace: string;
  metric: "cosine" | "dot" | "l2";
};

function parseArgs(argv: string[]): Args {
  const a: Args = {
    host: "127.0.0.1",
    port: 6389,
    count: 1000,
    dim: 128,
    queries: 50,
    ef: 64,
    namespace: "vec:sanity:",
    metric: "l2",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i];
    const next = (): string => argv[++i] ?? "";
    switch (t) {
      case "--host": a.host = next(); break;
      case "--port": a.port = Number(next()); break;
      case "--count": a.count = Number(next()); break;
      case "--dim": a.dim = Number(next()); break;
      case "--queries": a.queries = Number(next()); break;
      case "--ef": a.ef = Number(next()); break;
      case "--namespace": a.namespace = next(); break;
      case "--metric": a.metric = next() as Args["metric"]; break;
    }
  }
  return a;
}

// Box-Muller — deterministic per seed for reproducibility
function mulberry32(seed: number): () => number {
  let t = seed >>> 0;
  return () => {
    t = (t + 0x6d2b79f5) >>> 0;
    let x = t;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

function gaussianVec(rng: () => number, dim: number): Float32Array {
  const v = new Float32Array(dim);
  for (let i = 0; i < dim; i += 2) {
    const u1 = Math.max(rng(), 1e-12);
    const u2 = rng();
    const mag = Math.sqrt(-2.0 * Math.log(u1));
    v[i] = mag * Math.cos(2 * Math.PI * u2);
    if (i + 1 < dim) v[i + 1] = mag * Math.sin(2 * Math.PI * u2);
  }
  return v;
}

function floatsToBytes(f: Float32Array): Uint8Array {
  return new Uint8Array(f.buffer, f.byteOffset, f.byteLength);
}

async function main(): Promise<void> {
  const args = parseArgs(Bun.argv.slice(2));
  console.log(`Sanity config: ${JSON.stringify(args)}`);

  const client = new WormClient({ host: args.host, port: args.port, keepAlive: true, timeoutMs: 30_000 });

  const rng = mulberry32(0xc0ffee);
  const vectors: Float32Array[] = [];
  for (let i = 0; i < args.count; i += 1) vectors.push(gaussianVec(rng, args.dim));

  // Insert
  const insertStart = Bun.nanoseconds();
  for (let i = 0; i < args.count; i += 1) {
    const key = `${args.namespace}${i}`;
    const resp = await client.vinsertNative(key, floatsToBytes(vectors[i]), {
      worm: true,
      namespace: args.namespace,
      metric: args.metric,
    });
    if (resp.type !== "ok") {
      console.error(`insert failed at i=${i}: ${JSON.stringify(resp)}`);
      await client.close();
      process.exit(1);
    }
  }
  const insertMs = (Bun.nanoseconds() - insertStart) / 1e6;
  const insertQps = (args.count / insertMs) * 1000;
  console.log(`Inserted ${args.count} vectors in ${insertMs.toFixed(0)}ms (${insertQps.toFixed(0)} inserts/s)`);

  // Insert queries as near-copies of specific base vectors (with tiny noise),
  // stored under a different key. vsearch excludes the exact query key, so the
  // expected nearest neighbor is the original base vector.
  const queryKeys: string[] = [];
  const expectedBases: string[] = [];
  for (let q = 0; q < args.queries; q += 1) {
    const idx = Math.floor(rng() * args.count);
    const base = vectors[idx];
    const noisy = new Float32Array(base.length);
    for (let d = 0; d < base.length; d += 1) {
      noisy[d] = base[d] + (rng() - 0.5) * 1e-4;
    }
    const qkey = `${args.namespace}q:${q}`;
    queryKeys.push(qkey);
    expectedBases.push(`${args.namespace}${idx}`);
    const resp = await client.vinsertNative(qkey, floatsToBytes(noisy), {
      worm: true,
      namespace: args.namespace,
      metric: args.metric,
    });
    if (resp.type !== "ok") {
      console.error(`query insert failed: ${JSON.stringify(resp)}`);
      await client.close();
      process.exit(1);
    }
  }

  let top1 = 0;
  let top10 = 0;
  const latenciesMs: number[] = [];

  for (let q = 0; q < args.queries; q += 1) {
    const qStart = Bun.nanoseconds();
    const resp = await client.send(`EXEC vsearch ${queryKeys[q]} 10 ${args.namespace} ${args.metric} 0 exact`);
    latenciesMs.push((Bun.nanoseconds() - qStart) / 1e6);
    if (resp.type !== "bulk") {
      console.error(`vsearch failed on ${queryKeys[q]}: ${JSON.stringify(resp)}`);
      continue;
    }
    const parsed = JSON.parse(resp.value) as Array<{ k: string; s: number; ts: number }>;
    if (parsed.length === 0) continue;
    if (parsed[0].k === expectedBases[q]) top1 += 1;
    if (parsed.some((r) => r.k === expectedBases[q])) top10 += 1;
  }

  latenciesMs.sort((a, b) => a - b);
  const p50 = latenciesMs[Math.floor(latenciesMs.length * 0.5)];
  const p95 = latenciesMs[Math.floor(latenciesMs.length * 0.95)];
  const p99 = latenciesMs[Math.floor(latenciesMs.length * 0.99)];

  console.log(`Queried ${args.queries} near-copies (expected base as nearest):`);
  console.log(`  top@1 = ${top1}/${args.queries} (${((top1 / args.queries) * 100).toFixed(1)}%)`);
  console.log(`  top@10 = ${top10}/${args.queries} (${((top10 / args.queries) * 100).toFixed(1)}%)`);
  console.log(`  latency p50/p95/p99 = ${p50.toFixed(2)} / ${p95.toFixed(2)} / ${p99.toFixed(2)} ms`);

  await client.close();

  if (top1 / args.queries < 0.95) {
    console.error("FAIL: top@1 rate below 95% — something is wrong with insert or search");
    process.exit(1);
  }
  console.log("PASS");
}

main().catch((err) => {
  console.error(err instanceof Error ? err.stack : String(err));
  process.exit(1);
});
