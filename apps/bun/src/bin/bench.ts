#!/usr/bin/env bun
import { parseBenchArgs } from "../lib/bench/cli";
import { printConfig, printResults, runBenchmarks } from "../lib/bench/runner";

async function main(): Promise<void> {
  const options = parseBenchArgs(Bun.argv.slice(2));
  printConfig(options);
  const results = await runBenchmarks(options);
  printResults(results);

  if (results.some((r) => r.failed > 0)) {
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(`Benchmark failed: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
