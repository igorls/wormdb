#!/usr/bin/env bun
/**
 * Financial Benchmark: WormDB Procedures vs Redis
 *
 * Real-world comparison of server-side compute (WormDB EXEC transfer)
 * vs client-side compute (Redis GET→check→SET).
 *
 * Both run through Bun — WormDB via WormClient, Redis via native RedisClient.
 *
 * Workload: account transfers between random accounts
 * - Seed N accounts with initial balance
 * - Run concurrent transfers: debit from, credit to, with balance check
 * - Measure latency and throughput
 * - Verify total balance is conserved (correctness check)
 */
import { RedisClient } from "bun";
import { WormClient } from "../lib/client";
import { parseArgs, type ParseArgsConfig } from "util";

// ── CLI ──

const cliSpec: ParseArgsConfig = {
    args: process.argv.slice(2),
    options: {
        "wormdb-port": { type: "string", default: "16389" },
        "redis-port": { type: "string", default: "16399" },
        host: { type: "string", default: "127.0.0.1" },
        accounts: { type: "string", default: "100" },
        "initial-balance": { type: "string", default: "100000" },
        "transfer-amount": { type: "string", default: "100" },
        ops: { type: "string", default: "10000" },
        concurrency: { type: "string", default: "8" },
        warmup: { type: "string", default: "500" },
    },
    strict: true,
};

const { values: opts } = parseArgs(cliSpec);

const HOST = opts.host as string;
const WORMDB_PORT = parseInt(opts["wormdb-port"] as string, 10);
const REDIS_PORT = parseInt(opts["redis-port"] as string, 10);
const NUM_ACCOUNTS = parseInt(opts.accounts as string, 10);
const INITIAL_BALANCE = parseInt(opts["initial-balance"] as string, 10);
const TRANSFER_AMOUNT = parseInt(opts["transfer-amount"] as string, 10);
const TOTAL_OPS = parseInt(opts.ops as string, 10);
const CONCURRENCY = parseInt(opts.concurrency as string, 10);
const WARMUP_OPS = parseInt(opts.warmup as string, 10);

// ── Helpers ──

function randomAccount(): number {
    return Math.floor(Math.random() * NUM_ACCOUNTS);
}

function randomPair(): [string, string] {
    let from = randomAccount();
    let to = randomAccount();
    while (to === from) to = randomAccount();
    return [`acct:${from}`, `acct:${to}`];
}

type BenchResult = {
    name: string;
    succeeded: number;
    failed: number;
    insufficientFunds: number;
    elapsedMs: number;
    opsPerSec: number;
    latencies: number[];
};

function printResult(r: BenchResult) {
    const sorted = [...r.latencies].sort((a, b) => a - b);
    const p50 = sorted[Math.floor(sorted.length * 0.5)] ?? 0;
    const p95 = sorted[Math.floor(sorted.length * 0.95)] ?? 0;
    const p99 = sorted[Math.floor(sorted.length * 0.99)] ?? 0;
    const avg = sorted.reduce((s, v) => s + v, 0) / sorted.length;

    console.log(`\n── ${r.name} ──`);
    console.log(`  attempted      : ${r.succeeded + r.failed + r.insufficientFunds}`);
    console.log(`  succeeded      : ${r.succeeded}`);
    console.log(`  insufficient   : ${r.insufficientFunds}`);
    console.log(`  errors         : ${r.failed}`);
    console.log(`  elapsed_ms     : ${r.elapsedMs.toFixed(2)}`);
    console.log(`  ops/sec        : ${r.opsPerSec.toFixed(0)}`);
    console.log(`  lat_avg_ms     : ${avg.toFixed(3)}`);
    console.log(`  lat_p50_ms     : ${p50.toFixed(3)}`);
    console.log(`  lat_p95_ms     : ${p95.toFixed(3)}`);
    console.log(`  lat_p99_ms     : ${p99.toFixed(3)}`);
}

// ── Parallel seeding for WormDB (avoids keepAlive queue saturation) ──

async function seedWormDB(label: string) {
    const SEED_CONNS = 8;
    const clients: WormClient[] = [];
    for (let i = 0; i < SEED_CONNS; i++) {
        clients.push(new WormClient({ host: HOST, port: WORMDB_PORT, keepAlive: true, timeoutMs: 30000 }));
    }
    // Warm connections
    for (const c of clients) await c.send("STATUS");

    // Distribute accounts across seed connections
    await Promise.all(
        clients.map(async (client, ci) => {
            for (let i = ci; i < NUM_ACCOUNTS; i += SEED_CONNS) {
                await client.send(`SET acct:${i} ${INITIAL_BALANCE}`);
            }
        }),
    );

    for (const c of clients) await c.close();
    console.log(`[${label}] Seeded ${NUM_ACCOUNTS} accounts ✓`);
}

// ── WormDB Benchmark: Server-Side EXEC transfer ──

async function benchWormDB(): Promise<BenchResult> {
    await seedWormDB("WormDB");

    // Create pool
    const pool: WormClient[] = [];
    for (let i = 0; i < CONCURRENCY; i++) {
        pool.push(
            new WormClient({ host: HOST, port: WORMDB_PORT, keepAlive: true, timeoutMs: 30000 }),
        );
    }
    // Warmup each connection
    for (const c of pool) {
        await c.send("STATUS");
    }

    // Warmup
    console.log(`[WormDB] Warmup (${WARMUP_OPS} ops)...`);
    const warmupPerWorker = Math.ceil(WARMUP_OPS / CONCURRENCY);
    await Promise.all(
        pool.map(async (client) => {
            for (let i = 0; i < warmupPerWorker; i++) {
                const [from, to] = randomPair();
                await client.send(`EXEC transfer ${from} ${to} ${TRANSFER_AMOUNT}`);
            }
        }),
    );

    // Re-seed after warmup (balances may have changed)
    await seedWormDB("WormDB reseed");

    // Measured run
    console.log(`[WormDB] Running ${TOTAL_OPS} transfers...`);
    const latencies: number[] = [];
    let succeeded = 0;
    let failed = 0;
    let insufficientFunds = 0;
    const opsPerWorker = Math.ceil(TOTAL_OPS / CONCURRENCY);

    const startMs = performance.now();

    await Promise.all(
        pool.map(async (client) => {
            for (let i = 0; i < opsPerWorker; i++) {
                const [from, to] = randomPair();
                const opStart = performance.now();
                try {
                    const resp = await client.send(
                        `EXEC transfer ${from} ${to} ${TRANSFER_AMOUNT}`,
                    );
                    latencies.push(performance.now() - opStart);
                    if (resp.type === "ok") {
                        succeeded++;
                    } else if (
                        resp.type === "error" &&
                        resp.message === "insufficient_funds"
                    ) {
                        insufficientFunds++;
                    } else {
                        failed++;
                    }
                } catch {
                    latencies.push(performance.now() - opStart);
                    failed++;
                }
            }
        }),
    );

    const elapsedMs = performance.now() - startMs;

    // Verify total balance conservation
    const verifyClient = new WormClient({
        host: HOST,
        port: WORMDB_PORT,
        keepAlive: true,
        timeoutMs: 30000,
    });
    let totalBalance = 0;
    for (let i = 0; i < NUM_ACCOUNTS; i++) {
        const r = await verifyClient.send(`GET acct:${i}`);
        if (r.type === "bulk") totalBalance += parseInt(r.value, 10);
    }
    await verifyClient.close();

    const expectedTotal = NUM_ACCOUNTS * INITIAL_BALANCE;
    console.log(
        `[WormDB] Balance check: total=${totalBalance} expected=${expectedTotal} ${totalBalance === expectedTotal ? "✅ PASS" : "❌ FAIL"}`,
    );

    // Cleanup
    for (const c of pool) await c.close();

    return {
        name: "WormDB (EXEC transfer — server-side procedure)",
        succeeded,
        failed,
        insufficientFunds,
        elapsedMs,
        opsPerSec: ((succeeded + insufficientFunds) / elapsedMs) * 1000,
        latencies,
    };
}

// ── Redis Benchmark: Client-Side GET→Check→SET ──

async function benchRedis(): Promise<BenchResult> {
    console.log(`\n[Redis] Seeding ${NUM_ACCOUNTS} accounts with balance ${INITIAL_BALANCE}...`);

    const seedClient = new RedisClient(`redis://${HOST}:${REDIS_PORT}`);
    for (let i = 0; i < NUM_ACCOUNTS; i++) {
        await seedClient.set(`acct:${i}`, String(INITIAL_BALANCE));
    }
    seedClient.close();

    // Create pool
    const pool: RedisClient[] = [];
    for (let i = 0; i < CONCURRENCY; i++) {
        const c = new RedisClient(`redis://${HOST}:${REDIS_PORT}`);
        await c.set("__ping__", "1"); // verify connection
        pool.push(c);
    }

    // Warmup
    console.log(`[Redis] Warmup (${WARMUP_OPS} ops)...`);
    const warmupPerWorker = Math.ceil(WARMUP_OPS / CONCURRENCY);
    await Promise.all(
        pool.map(async (client) => {
            for (let i = 0; i < warmupPerWorker; i++) {
                const [from, to] = randomPair();
                // Same logic as measured run
                const fromBal = parseInt((await client.get(from)) ?? "0", 10);
                if (fromBal >= TRANSFER_AMOUNT) {
                    const toBal = parseInt((await client.get(to)) ?? "0", 10);
                    await client.set(from, String(fromBal - TRANSFER_AMOUNT));
                    await client.set(to, String(toBal + TRANSFER_AMOUNT));
                }
            }
        }),
    );

    // Re-seed after warmup
    const reseedClient = new RedisClient(`redis://${HOST}:${REDIS_PORT}`);
    for (let i = 0; i < NUM_ACCOUNTS; i++) {
        await reseedClient.set(`acct:${i}`, String(INITIAL_BALANCE));
    }
    reseedClient.close();

    // Measured run
    console.log(`[Redis] Running ${TOTAL_OPS} transfers (client-side logic)...`);
    const latencies: number[] = [];
    let succeeded = 0;
    let failed = 0;
    let insufficientFunds = 0;
    const opsPerWorker = Math.ceil(TOTAL_OPS / CONCURRENCY);

    const startMs = performance.now();

    await Promise.all(
        pool.map(async (client) => {
            for (let i = 0; i < opsPerWorker; i++) {
                const [from, to] = randomPair();
                const opStart = performance.now();
                try {
                    // Real-world Redis pattern: GET → check → SET (3-4 round trips)
                    const fromBal = parseInt((await client.get(from)) ?? "0", 10);
                    if (fromBal < TRANSFER_AMOUNT) {
                        latencies.push(performance.now() - opStart);
                        insufficientFunds++;
                        continue;
                    }
                    const toBal = parseInt((await client.get(to)) ?? "0", 10);
                    await client.set(from, String(fromBal - TRANSFER_AMOUNT));
                    await client.set(to, String(toBal + TRANSFER_AMOUNT));
                    latencies.push(performance.now() - opStart);
                    succeeded++;
                } catch {
                    latencies.push(performance.now() - opStart);
                    failed++;
                }
            }
        }),
    );

    const elapsedMs = performance.now() - startMs;

    // Verify total balance
    const verifyClient = new RedisClient(`redis://${HOST}:${REDIS_PORT}`);
    let totalBalance = 0;
    for (let i = 0; i < NUM_ACCOUNTS; i++) {
        const val = await verifyClient.get(`acct:${i}`);
        totalBalance += parseInt(val ?? "0", 10);
    }
    verifyClient.close();

    const expectedTotal = NUM_ACCOUNTS * INITIAL_BALANCE;
    // Note: Redis client-side transfers are NOT atomic — race conditions
    // can cause balance drift under concurrency. This is the fundamental
    // problem that WormDB's server-side procedures solve.
    const status = totalBalance === expectedTotal ? "✅ PASS" : "⚠️  DRIFT (race condition)";
    console.log(
        `[Redis] Balance check: total=${totalBalance} expected=${expectedTotal} ${status}`,
    );

    // Cleanup
    for (const c of pool) c.close();

    return {
        name: "Redis (client-side GET→check→SET — 4 round trips)",
        succeeded,
        failed,
        insufficientFunds,
        elapsedMs,
        opsPerSec: ((succeeded + insufficientFunds) / elapsedMs) * 1000,
        latencies,
    };
}

// ── Redis Benchmark: Lua EVAL Atomic Transfer (1 round trip) ──

const TRANSFER_LUA = `
local from_key = KEYS[1]
local to_key = KEYS[2]
local amount = tonumber(ARGV[1])

local from_bal = tonumber(redis.call('GET', from_key))
if from_bal == nil then return redis.error_reply('from account not found') end

local to_bal = tonumber(redis.call('GET', to_key))
if to_bal == nil then return redis.error_reply('to account not found') end

if from_bal < amount then return redis.error_reply('insufficient_funds') end

redis.call('SET', from_key, tostring(from_bal - amount))
redis.call('SET', to_key, tostring(to_bal + amount))
return 'OK'
`;

async function benchRedisLua(): Promise<BenchResult> {
    console.log(`\n[Redis Lua] Seeding ${NUM_ACCOUNTS} accounts with balance ${INITIAL_BALANCE}...`);

    const seedClient = new RedisClient(`redis://${HOST}:${REDIS_PORT}`);
    for (let i = 0; i < NUM_ACCOUNTS; i++) {
        await seedClient.set(`acct:${i}`, String(INITIAL_BALANCE));
    }

    // Pre-load the script and get its SHA1 hash — this is how production Redis works.
    // EVALSHA sends only the 40-char hash instead of the full script text per call,
    // matching WormDB's approach of sending just the procedure name.
    const sha = await seedClient.send("SCRIPT", ["LOAD", TRANSFER_LUA]) as string;
    console.log(`[Redis Lua] Script loaded, SHA1: ${sha}`);
    seedClient.close();

    // Create pool
    const pool: RedisClient[] = [];
    for (let i = 0; i < CONCURRENCY; i++) {
        const c = new RedisClient(`redis://${HOST}:${REDIS_PORT}`);
        await c.set("__ping__", "1");
        pool.push(c);
    }

    // Warmup
    console.log(`[Redis Lua] Warmup (${WARMUP_OPS} ops)...`);
    const warmupPerWorker = Math.ceil(WARMUP_OPS / CONCURRENCY);
    await Promise.all(
        pool.map(async (client) => {
            for (let i = 0; i < warmupPerWorker; i++) {
                const [from, to] = randomPair();
                try {
                    await client.send("EVALSHA", [
                        sha, "2", from, to, String(TRANSFER_AMOUNT),
                    ]);
                } catch { }
            }
        }),
    );

    // Re-seed after warmup
    const reseedClient = new RedisClient(`redis://${HOST}:${REDIS_PORT}`);
    for (let i = 0; i < NUM_ACCOUNTS; i++) {
        await reseedClient.set(`acct:${i}`, String(INITIAL_BALANCE));
    }
    reseedClient.close();

    // Measured run
    console.log(`[Redis Lua] Running ${TOTAL_OPS} transfers (EVALSHA cached script)...`);
    const latencies: number[] = [];
    let succeeded = 0;
    let failed = 0;
    let insufficientFunds = 0;
    const opsPerWorker = Math.ceil(TOTAL_OPS / CONCURRENCY);

    const startMs = performance.now();

    await Promise.all(
        pool.map(async (client) => {
            for (let i = 0; i < opsPerWorker; i++) {
                const [from, to] = randomPair();
                const opStart = performance.now();
                try {
                    await client.send("EVALSHA", [
                        sha, "2", from, to, String(TRANSFER_AMOUNT),
                    ]);
                    latencies.push(performance.now() - opStart);
                    succeeded++;
                } catch (err: any) {
                    latencies.push(performance.now() - opStart);
                    const msg = String(err?.message ?? err);
                    if (msg.includes("insufficient_funds")) {
                        insufficientFunds++;
                    } else {
                        failed++;
                    }
                }
            }
        }),
    );

    const elapsedMs = performance.now() - startMs;

    // Verify total balance
    const verifyClient = new RedisClient(`redis://${HOST}:${REDIS_PORT}`);
    let totalBalance = 0;
    for (let i = 0; i < NUM_ACCOUNTS; i++) {
        const val = await verifyClient.get(`acct:${i}`);
        totalBalance += parseInt(val ?? "0", 10);
    }
    verifyClient.close();

    const expectedTotal = NUM_ACCOUNTS * INITIAL_BALANCE;
    console.log(
        `[Redis Lua] Balance check: total=${totalBalance} expected=${expectedTotal} ${totalBalance === expectedTotal ? "✅ PASS" : "❌ FAIL"}`,
    );

    for (const c of pool) c.close();

    return {
        name: "Redis EVALSHA (cached Lua script — 1 round trip)",
        succeeded,
        failed,
        insufficientFunds,
        elapsedMs,
        opsPerSec: ((succeeded + insufficientFunds) / elapsedMs) * 1000,
        latencies,
    };
}

// ── Main ──

async function main() {
    console.log("╔══════════════════════════════════════════════════════════════╗");
    console.log("║  Financial Benchmark: Server-Side vs Client-Side Logic      ║");
    console.log("╚══════════════════════════════════════════════════════════════╝");
    console.log(`\n  accounts       : ${NUM_ACCOUNTS}`);
    console.log(`  initial_balance: ${INITIAL_BALANCE}`);
    console.log(`  transfer_amount: ${TRANSFER_AMOUNT}`);
    console.log(`  operations     : ${TOTAL_OPS}`);
    console.log(`  concurrency    : ${CONCURRENCY}`);
    console.log(`  wormdb         : ${HOST}:${WORMDB_PORT}`);
    console.log(`  redis          : ${HOST}:${REDIS_PORT}`);

    const wormdbResult = await benchWormDB();
    const redisClientResult = await benchRedis();
    const redisLuaResult = await benchRedisLua();

    // ── Side-by-side comparison ──
    console.log("\n╔══════════════════════════════════════════════════════════════╗");
    console.log("║                      RESULTS COMPARISON                     ║");
    console.log("╚══════════════════════════════════════════════════════════════╝");

    printResult(wormdbResult);
    printResult(redisLuaResult);
    printResult(redisClientResult);

    // Percentile helper
    const getP50 = (r: BenchResult) =>
        [...r.latencies].sort((a, b) => a - b)[Math.floor(r.latencies.length * 0.5)] ?? 0;

    const wP50 = getP50(wormdbResult);
    const luaP50 = getP50(redisLuaResult);
    const clientP50 = getP50(redisClientResult);

    console.log(`\n  ──────────────────────────────────────────`);
    console.log(`  📊 Latency Comparison (p50)`);
    console.log(`  ──────────────────────────────────────────`);
    console.log(`  WormDB EXEC    : ${wP50.toFixed(3)}ms  (1 round trip, native Zig)`);
    console.log(`  Redis EVAL Lua : ${luaP50.toFixed(3)}ms  (1 round trip, Lua VM)`);
    console.log(`  Redis client   : ${clientP50.toFixed(3)}ms  (4 round trips, JS logic)`);

    if (wP50 && luaP50) {
        const ratio = luaP50 / wP50;
        console.log(`\n  ⚡ WormDB is ${ratio.toFixed(1)}x ${ratio > 1 ? "faster" : "slower"} than Redis Lua (atomic vs atomic)`);
    }
    if (wP50 && clientP50) {
        const ratio = clientP50 / wP50;
        console.log(`  ⚡ WormDB is ${ratio.toFixed(1)}x ${ratio > 1 ? "faster" : "slower"} than Redis client-side`);
    }

    console.log(`\n  ──────────────────────────────────────────`);
    console.log(`  🔒 Correctness`);
    console.log(`  ──────────────────────────────────────────`);
    console.log(`  WormDB EXEC    : Atomic (shard locks) ✅`);
    console.log(`  Redis EVAL Lua : Atomic (single-threaded) ✅`);
    console.log(`  Redis client   : NOT atomic (race conditions) ⚠️\n`);
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});

