#!/usr/bin/env bun
// Merges all results/<dataset>/*.json into a markdown report.
//
// Usage: bun run src/report.ts --dataset sift-128-euclidean

import { readdir } from "node:fs/promises";

type EfResult = {
  ef: number;
  recall: number;
  singleLatency: { meanMs: number; p50Ms: number; p95Ms: number; p99Ms: number };
  singleQps: number;
  concurrentQps: number;
  concurrentLatency: { meanMs: number; p50Ms: number; p95Ms: number; p99Ms: number };
};

type RunResult = {
  adapter: string;
  mode: string;
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
  const argv = Bun.argv.slice(2);
  let dataset = "sift-128-euclidean";
  let resultsDir = "./results";
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--dataset") dataset = argv[++i];
    else if (argv[i] === "--results-dir") resultsDir = argv[++i];
  }

  const dir = `${resultsDir}/${dataset}`;
  const files = (await readdir(dir)).filter((f) => f.endsWith(".json")).sort();
  const runs: RunResult[] = [];
  for (const f of files) {
    runs.push(JSON.parse(await Bun.file(`${dir}/${f}`).text()));
  }
  if (runs.length === 0) {
    console.error(`No results in ${dir}`);
    process.exit(1);
  }

  const lines: string[] = [];
  const r0 = runs[0];
  lines.push(`# Vector Benchmark — ${dataset}`);
  lines.push("");
  lines.push(`**Dataset**: ${dataset} (N=${r0.N}, Q=${r0.Q}, dim=${r0.dim}, metric=${r0.metric})`);
  lines.push(`**Top-K**: ${r0.topK}`);
  lines.push(`**Run timestamp**: ${r0.startedAt}`);
  lines.push("");
  lines.push("## Build / Index");
  lines.push("");
  lines.push("| adapter / mode | insert wall (ms) | insert/s | time-until-queryable (ms) |");
  lines.push("| -------------- | ---------------: | -------: | ------------------------: |");
  for (const r of runs) {
    lines.push(`| ${r.adapter} / ${r.mode} | ${r.buildInsertMs.toFixed(0)} | ${r.insertQps.toFixed(0)} | ${r.waitUntilQueryableMs.toFixed(0)} |`);
  }
  lines.push("");
  lines.push("> **Note**: \"insert wall\" is time from first insert to last-insert-ack. \"time-until-queryable\" is the honest metric — first point at which a query returns the expected nearest neighbor for a 16-ID probe set. Qdrant builds HNSW asynchronously, so its time-until-queryable is typically much greater than insert wall. WormDB builds inline, so they coincide.");
  lines.push("");
  lines.push("## Query Performance");
  lines.push("");
  lines.push("| adapter / mode | ef | recall@K | p50 (ms) | p95 (ms) | p99 (ms) | qps (1c) | qps (Nc) |");
  lines.push("| -------------- | -: | -------: | -------: | -------: | -------: | -------: | -------: |");
  for (const r of runs) {
    for (const e of r.perEf) {
      lines.push(
        `| ${r.adapter} / ${r.mode} | ${e.ef} | ${e.recall.toFixed(3)} | ${e.singleLatency.p50Ms.toFixed(2)} | ${e.singleLatency.p95Ms.toFixed(2)} | ${e.singleLatency.p99Ms.toFixed(2)} | ${e.singleQps.toFixed(0)} | ${e.concurrentQps.toFixed(0)} |`,
      );
    }
  }
  lines.push("");
  lines.push("## Notes");
  lines.push("");
  for (const r of runs) {
    lines.push(`**${r.adapter} / ${r.mode}**:`);
    for (const n of r.notes) lines.push(`- ${n}`);
    lines.push("");
  }

  const outPath = `${dir}/report.md`;
  await Bun.write(outPath, lines.join("\n"));
  console.log(`Wrote ${outPath}`);
  console.log("");
  console.log(lines.join("\n"));
}

main().catch((err) => {
  console.error(err instanceof Error ? err.stack : String(err));
  process.exit(1);
});
