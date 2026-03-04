import { WormClient } from "../client";
import { getScenario } from "./scenarios";
import type { BenchKind, BenchOptions, BenchResult, WorkContext } from "./types";

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx];
}

function summarize(test: BenchKind, opCount: number, elapsedMs: number, succeeded: number, failed: number, latencies: number[]): BenchResult {
  const sorted = [...latencies].sort((a, b) => a - b);
  const sum = latencies.reduce((acc, ms) => acc + ms, 0);

  return {
    test,
    attempted: opCount,
    succeeded,
    failed,
    elapsedMs,
    opsPerSec: elapsedMs > 0 ? (succeeded / elapsedMs) * 1000 : 0,
    latMsAvg: latencies.length > 0 ? sum / latencies.length : 0,
    latMsP50: percentile(sorted, 50),
    latMsP95: percentile(sorted, 95),
    latMsP99: percentile(sorted, 99),
  };
}

async function seedKeyspace(client: WormClient, options: BenchOptions, valueForKey: (key: string) => string): Promise<void> {
  for (let i = 0; i < options.keyspace; i += 1) {
    const key = `${options.keyPrefix}:${i}`;
    const response = await client.send(`SET ${key} ${valueForKey(key)}`);
    if (response.type === "error") {
      throw new Error(`Seed failed on key '${key}': ${response.message}`);
    }
  }
}

async function runWorkload(
  clients: WormClient[],
  options: BenchOptions,
  test: BenchKind,
  opCount: number,
  measureLatency: boolean,
): Promise<{ succeeded: number; failed: number; latencies: number[] }> {
  const scenario = getScenario(test);
  const ctx: WorkContext = {
    options,
    valuePayload: "v".repeat(options.valueSize),
  };

  let cursor = 0;
  let succeeded = 0;
  let failed = 0;
  const latencies: number[] = [];

  const worker = async (workerId: number) => {
    const client = clients[workerId % clients.length];
    const maxInFlight = Math.max(1, options.inflight);

    const active = new Set<Promise<void>>();

    const launchOne = (): boolean => {
      const index = cursor;
      cursor += 1;
      if (index >= opCount) return false;

      const op = (async () => {
        const start = measureLatency ? performance.now() : 0;

        try {
          let classified: "success" | "failure";
          if (scenario.runOperation) {
            classified = await scenario.runOperation(client, ctx);
          } else if (scenario.makeCommand) {
            const command = scenario.makeCommand(ctx);
            const result = await client.send(command);
            classified = scenario.classifyResult ? scenario.classifyResult(result) : result.type === "error" ? "failure" : "success";
          } else {
            throw new Error(`Scenario '${test}' is not executable`);
          }

          if (classified === "failure") {
            failed += 1;
          } else {
            succeeded += 1;
          }
        } catch {
          failed += 1;
        } finally {
          if (measureLatency) {
            latencies.push(performance.now() - start);
          }
        }
      })();

      active.add(op);
      op.finally(() => {
        active.delete(op);
      }).catch(() => {
        // Already recorded as failure in the operation body.
      });
      return true;
    };

    while (active.size < maxInFlight && launchOne()) {
      // Fill initial pipeline.
    }

    while (active.size > 0) {
      await Promise.race(active);
      while (active.size < maxInFlight && launchOne()) {
        // Refill pipeline as operations complete.
      }
    }
  };

  await Promise.all(Array.from({ length: options.concurrency }, (_, workerId) => worker(workerId)));
  return { succeeded, failed, latencies };
}

export async function runBenchmarks(options: BenchOptions): Promise<BenchResult[]> {
  const clients = Array.from({ length: options.poolSize }, () =>
    new WormClient({
      host: options.host,
      port: options.port,
      timeoutMs: options.timeoutMs,
      keepAlive: true,
    }),
  );
  const seedClient = clients[0];
  const defaultSeedPayload = "v".repeat(options.valueSize);

  const results: BenchResult[] = [];

  try {
    for (const test of options.tests) {
      const scenario = getScenario(test);
      console.log(`\nTest: ${test} (${scenario.description})`);

      if (scenario.needsSeed) {
        console.log("Seeding keyspace...");
        const seedCtx: WorkContext = { options, valuePayload: defaultSeedPayload };
        const seedValueForKey = scenario.seedValueForKey;
        const seedFn = seedValueForKey
          ? (key: string) => seedValueForKey(seedCtx, key)
          : () => defaultSeedPayload;
        await seedKeyspace(seedClient, options, seedFn);
      }

      if (options.warmupOps > 0) {
        console.log("Running warmup...");
        await runWorkload(clients, options, test, options.warmupOps, false);
      }

      console.log("Running measured workload...");
      const start = performance.now();
      const run = await runWorkload(clients, options, test, options.totalOps, true);
      const elapsed = performance.now() - start;

      const result = summarize(test, options.totalOps, elapsed, run.succeeded, run.failed, run.latencies);
      results.push(result);
    }
  } finally {
    await Promise.all(clients.map(async (client) => client.close()));
  }

  return results;
}

export function printConfig(options: BenchOptions): void {
  console.log("WormDB single-node benchmark\n");
  console.log(`target        : ${options.host}:${options.port}`);
  console.log(`tests         : ${options.tests.join(",")}`);
  console.log(`ops/test      : ${options.totalOps}`);
  console.log(`concurrency   : ${options.concurrency}`);
  console.log(`pool_size     : ${options.poolSize}`);
  console.log(`inflight      : ${options.inflight}`);
  console.log(`keyspace      : ${options.keyspace}`);
  console.log(`read_ratio    : ${options.readRatio}`);
  console.log(`warmup_ops    : ${options.warmupOps}`);
  console.log(`value_size    : ${options.valueSize}`);
  console.log(`bank_read     : ${options.bankReadRatio}`);
  console.log(`bank_transfer : ${options.bankTransferRatio}`);
  console.log(`bank_initial  : ${options.bankInitialBalance}`);
  console.log(`bank_amount   : ${options.bankMinAmount}-${options.bankMaxAmount}`);
  console.log(`timeout_ms    : ${options.timeoutMs}`);
}

export function printResults(results: BenchResult[]): void {
  for (const result of results) {
    console.log("\nResults");
    console.log(`test          : ${result.test}`);
    console.log(`attempted     : ${result.attempted}`);
    console.log(`succeeded     : ${result.succeeded}`);
    console.log(`failed        : ${result.failed}`);
    console.log(`elapsed_ms    : ${result.elapsedMs.toFixed(2)}`);
    console.log(`ops/sec       : ${result.opsPerSec.toFixed(2)}`);
    console.log(`lat_avg_ms    : ${result.latMsAvg.toFixed(3)}`);
    console.log(`lat_p50_ms    : ${result.latMsP50.toFixed(3)}`);
    console.log(`lat_p95_ms    : ${result.latMsP95.toFixed(3)}`);
    console.log(`lat_p99_ms    : ${result.latMsP99.toFixed(3)}`);
  }
}
