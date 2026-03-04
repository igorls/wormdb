#!/usr/bin/env bun
/**
 * Bun-native Redis benchmark — uses Bun's built-in RedisClient
 * for a fair apples-to-apples comparison with the WormDB Bun client benchmark.
 *
 * Same benchmark methodology: sequential ops per connection, latency histograms,
 * warmup, percentiles. Matches bench.ts parameters.
 */
import { RedisClient } from "bun";
import { parseArgs, type ParseArgsConfig } from "util";

// ── CLI Parsing ──

const cliSpec: ParseArgsConfig = {
    args: process.argv.slice(2),
    options: {
        host: { type: "string", default: "127.0.0.1" },
        port: { type: "string", default: "6379" },
        tests: { type: "string", default: "read,write,mixed" },
        ops: { type: "string", default: "20000" },
        concurrency: { type: "string", default: "8" },
        inflight: { type: "string", default: "1" },
        keyspace: { type: "string", default: "1000" },
        "value-size": { type: "string", default: "128" },
        "read-ratio": { type: "string", default: "0.8" },
    },
    strict: true,
};

const { values: opts } = parseArgs(cliSpec);

const HOST = opts.host as string;
const PORT = parseInt(opts.port as string, 10);
const TESTS = (opts.tests as string).split(",");
const TOTAL_OPS = parseInt(opts.ops as string, 10);
const CONCURRENCY = parseInt(opts.concurrency as string, 10);
const INFLIGHT = parseInt(opts.inflight as string, 10);
const KEYSPACE = parseInt(opts.keyspace as string, 10);
const VALUE_SIZE = parseInt(opts["value-size"] as string, 10);
const READ_RATIO = parseFloat(opts["read-ratio"] as string);
const WARMUP_OPS = 1000;

const VALUE = "x".repeat(VALUE_SIZE);

// ── Connection Pool ──

async function createPool(size: number): Promise<RedisClient[]> {
    const pool: RedisClient[] = [];
    for (let i = 0; i < size; i++) {
        const client = new RedisClient(`redis://${HOST}:${PORT}`);
        // Verify connectivity
        await client.set("__ping__", "1");
        pool.push(client);
    }
    return pool;
}

// ── Benchmark Runner ──

type OpFn = (client: RedisClient) => Promise<void>;

async function runBenchmark(
    name: string,
    pool: RedisClient[],
    opFn: OpFn,
): Promise<void> {
    const opsPerWorker = Math.ceil(TOTAL_OPS / pool.length);
    const latencies: number[] = [];
    let succeeded = 0;
    let failed = 0;

    // Warmup
    const warmupPerWorker = Math.ceil(WARMUP_OPS / pool.length);
    await Promise.all(
        pool.map(async (client) => {
            for (let i = 0; i < warmupPerWorker; i++) {
                try {
                    await opFn(client);
                } catch { }
            }
        }),
    );

    // Measured run
    const startMs = performance.now();

    if (INFLIGHT <= 1) {
        // Serial: one op at a time per connection
        await Promise.all(
            pool.map(async (client) => {
                for (let i = 0; i < opsPerWorker; i++) {
                    const opStart = performance.now();
                    try {
                        await opFn(client);
                        latencies.push(performance.now() - opStart);
                        succeeded++;
                    } catch {
                        failed++;
                    }
                }
            }),
        );
    } else {
        // Pipelined: N ops in-flight per connection
        await Promise.all(
            pool.map(async (client) => {
                for (let batch = 0; batch < opsPerWorker; batch += INFLIGHT) {
                    const batchSize = Math.min(INFLIGHT, opsPerWorker - batch);
                    const promises = Array.from({ length: batchSize }, async () => {
                        const opStart = performance.now();
                        try {
                            await opFn(client);
                            latencies.push(performance.now() - opStart);
                            succeeded++;
                        } catch {
                            failed++;
                        }
                    });
                    await Promise.all(promises);
                }
            }),
        );
    }

    const elapsedMs = performance.now() - startMs;
    const opsPerSec = (succeeded / elapsedMs) * 1000;

    // Latency percentiles
    latencies.sort((a, b) => a - b);
    const p50 = latencies[Math.floor(latencies.length * 0.5)] ?? 0;
    const p95 = latencies[Math.floor(latencies.length * 0.95)] ?? 0;
    const p99 = latencies[Math.floor(latencies.length * 0.99)] ?? 0;
    const avg = latencies.reduce((s, v) => s + v, 0) / latencies.length;

    console.log(`\nResults`);
    console.log(`test          : ${name}`);
    console.log(`attempted     : ${succeeded + failed}`);
    console.log(`succeeded     : ${succeeded}`);
    console.log(`failed        : ${failed}`);
    console.log(`elapsed_ms    : ${elapsedMs.toFixed(2)}`);
    console.log(`ops/sec       : ${opsPerSec.toFixed(2)}`);
    console.log(`lat_avg_ms    : ${avg.toFixed(3)}`);
    console.log(`lat_p50_ms    : ${p50.toFixed(3)}`);
    console.log(`lat_p95_ms    : ${p95.toFixed(3)}`);
    console.log(`lat_p99_ms    : ${p99.toFixed(3)}`);
}

// ── Main ──

async function main() {
    console.log(`Bun-native Redis benchmark\n`);
    console.log(`target        : ${HOST}:${PORT}`);
    console.log(`tests         : ${TESTS.join(",")}`);
    console.log(`ops/test      : ${TOTAL_OPS}`);
    console.log(`concurrency   : ${CONCURRENCY}`);
    console.log(`inflight      : ${INFLIGHT}`);
    console.log(`keyspace      : ${KEYSPACE}`);
    console.log(`read_ratio    : ${READ_RATIO}`);
    console.log(`value_size    : ${VALUE_SIZE}`);

    const pool = await createPool(CONCURRENCY);

    // Seed keyspace
    const seedClient = pool[0];
    for (let i = 0; i < KEYSPACE; i++) {
        await seedClient.set(`bench:${i}`, VALUE);
    }

    function randomKey(): string {
        return `bench:${Math.floor(Math.random() * KEYSPACE)}`;
    }

    for (const test of TESTS) {
        switch (test) {
            case "read":
                console.log(`\nTest: read (read-only GET workload)`);
                await runBenchmark("read", pool, async (c) => {
                    await c.get(randomKey());
                });
                break;

            case "write":
                console.log(`\nTest: write (write-only SET workload)`);
                await runBenchmark("write", pool, async (c) => {
                    await c.set(randomKey(), VALUE);
                });
                break;

            case "mixed":
                console.log(`\nTest: mixed (mixed GET/SET load using --read-ratio)`);
                await runBenchmark("mixed", pool, async (c) => {
                    if (Math.random() < READ_RATIO) {
                        await c.get(randomKey());
                    } else {
                        await c.set(randomKey(), VALUE);
                    }
                });
                break;
        }
    }

    // Cleanup
    for (const c of pool) {
        c.close();
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
