import { BENCH_DEFAULTS, type BenchKind, type BenchOptions } from "./types";
import { availableBenchKinds } from "./scenarios";

function parseIntArg(flag: string, value: string | undefined, min: number, max?: number): number {
  if (!value) throw new Error(`${flag} requires a value`);
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || (max !== undefined && n > max)) {
    const range = max === undefined ? `>= ${min}` : `between ${min} and ${max}`;
    throw new Error(`${flag} must be an integer ${range}`);
  }
  return n;
}

function parseFloatArg(flag: string, value: string | undefined, min: number, max: number): number {
  if (!value) throw new Error(`${flag} requires a value`);
  const n = Number(value);
  if (!Number.isFinite(n) || n < min || n > max) {
    throw new Error(`${flag} must be a number between ${min} and ${max}`);
  }
  return n;
}

function parseKinds(raw: string): BenchKind[] {
  const values = raw
    .split(",")
    .map((v) => v.trim())
    .filter((v) => v.length > 0);

  if (values.length === 0) {
    throw new Error("--tests requires at least one test name");
  }

  const valid = new Set(availableBenchKinds());
  const out: BenchKind[] = [];

  for (const value of values) {
    if (!valid.has(value as BenchKind)) {
      throw new Error(`Unknown test kind: ${value}`);
    }
    out.push(value as BenchKind);
  }

  return Array.from(new Set(out));
}

export function parseBenchArgs(argv: string[]): BenchOptions {
  const options: BenchOptions = { ...BENCH_DEFAULTS };
  const explicitTests: BenchKind[] = [];

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];

    switch (arg) {
      case "--host":
        if (!next) throw new Error("--host requires a value");
        options.host = next;
        i += 1;
        break;
      case "--port":
        options.port = parseIntArg("--port", next, 1, 65535);
        i += 1;
        break;
      case "--ops":
        options.totalOps = parseIntArg("--ops", next, 1);
        i += 1;
        break;
      case "--concurrency":
        options.concurrency = parseIntArg("--concurrency", next, 1);
        i += 1;
        break;
      case "--pool-size":
        options.poolSize = parseIntArg("--pool-size", next, 1);
        i += 1;
        break;
      case "--inflight":
        options.inflight = parseIntArg("--inflight", next, 1);
        i += 1;
        break;
      case "--keyspace":
        options.keyspace = parseIntArg("--keyspace", next, 1);
        i += 1;
        break;
      case "--read-ratio":
        options.readRatio = parseFloatArg("--read-ratio", next, 0, 1);
        i += 1;
        break;
      case "--warmup-ops":
        options.warmupOps = parseIntArg("--warmup-ops", next, 0);
        i += 1;
        break;
      case "--timeout-ms":
        options.timeoutMs = parseIntArg("--timeout-ms", next, 1);
        i += 1;
        break;
      case "--value-size":
        options.valueSize = parseIntArg("--value-size", next, 1);
        i += 1;
        break;
      case "--key-prefix":
        if (!next) throw new Error("--key-prefix requires a value");
        options.keyPrefix = next;
        i += 1;
        break;
      case "--bank-read-ratio":
        options.bankReadRatio = parseFloatArg("--bank-read-ratio", next, 0, 1);
        i += 1;
        break;
      case "--bank-transfer-ratio":
        options.bankTransferRatio = parseFloatArg("--bank-transfer-ratio", next, 0, 1);
        i += 1;
        break;
      case "--bank-initial-balance":
        options.bankInitialBalance = parseIntArg("--bank-initial-balance", next, 0);
        i += 1;
        break;
      case "--bank-min-amount":
        options.bankMinAmount = parseIntArg("--bank-min-amount", next, 1);
        i += 1;
        break;
      case "--bank-max-amount":
        options.bankMaxAmount = parseIntArg("--bank-max-amount", next, 1);
        i += 1;
        break;
      case "--test":
        if (!next) throw new Error("--test requires a value");
        explicitTests.push(...parseKinds(next));
        i += 1;
        break;
      case "--tests":
        if (!next) throw new Error("--tests requires a value");
        explicitTests.push(...parseKinds(next));
        i += 1;
        break;
      case "--help":
      case "-h":
        printBenchHelp();
        process.exit(0);
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (explicitTests.length > 0) {
    options.tests = Array.from(new Set(explicitTests));
  }

  if (options.bankReadRatio + options.bankTransferRatio > 1) {
    throw new Error("--bank-read-ratio + --bank-transfer-ratio must be <= 1");
  }

  if (options.bankMaxAmount < options.bankMinAmount) {
    throw new Error("--bank-max-amount must be >= --bank-min-amount");
  }

  if (options.poolSize > options.concurrency) {
    throw new Error("--pool-size must be <= --concurrency");
  }

  if (options.inflight < 1) {
    throw new Error("--inflight must be >= 1");
  }

  return options;
}

export function printBenchHelp(): void {
  const kinds = availableBenchKinds().join(", ");

  console.log(`WormDB Bun Benchmark (single node)

Usage:
  bun run src/bin/bench.ts [options]

Options:
  --host <host>             WormDB host (default: ${BENCH_DEFAULTS.host})
  --port <port>             WormDB port (default: ${BENCH_DEFAULTS.port})
  --ops <n>                 Total measured operations per test (default: ${BENCH_DEFAULTS.totalOps})
  --concurrency <n>         Number of concurrent workers (default: ${BENCH_DEFAULTS.concurrency})
  --pool-size <n>           Number of persistent TCP connections (default: ${BENCH_DEFAULTS.poolSize})
  --inflight <n>            Max in-flight ops per worker/connection (default: ${BENCH_DEFAULTS.inflight})
  --keyspace <n>            Number of hot keys (default: ${BENCH_DEFAULTS.keyspace})
  --read-ratio <0..1>       Fraction of GET ops for mixed test (default: ${BENCH_DEFAULTS.readRatio})
  --warmup-ops <n>          Warmup operations per test (default: ${BENCH_DEFAULTS.warmupOps})
  --value-size <bytes>      Value payload size for SET (default: ${BENCH_DEFAULTS.valueSize})
  --timeout-ms <ms>         Client timeout per operation (default: ${BENCH_DEFAULTS.timeoutMs})
  --key-prefix <prefix>     Benchmark key prefix (default: ${BENCH_DEFAULTS.keyPrefix})
  --bank-read-ratio <0..1>  Banking scenario balance-check ratio (default: ${BENCH_DEFAULTS.bankReadRatio})
  --bank-transfer-ratio <0..1> Banking scenario transfer ratio (default: ${BENCH_DEFAULTS.bankTransferRatio})
  --bank-initial-balance <n> Banking scenario initial account balance (default: ${BENCH_DEFAULTS.bankInitialBalance})
  --bank-min-amount <n>     Banking scenario minimum transfer/deposit amount (default: ${BENCH_DEFAULTS.bankMinAmount})
  --bank-max-amount <n>     Banking scenario maximum transfer/deposit amount (default: ${BENCH_DEFAULTS.bankMaxAmount})
  --test <kind>             Benchmark kind (repeatable)
  --tests <a,b,c>           Comma-separated benchmark kinds
  --help, -h                Show this help

Available test kinds:
  ${kinds}

Examples:
  bun run src/bin/bench.ts --test mixed --ops 50000 --concurrency 128
  bun run src/bin/bench.ts --test mixed --ops 50000 --concurrency 128 --pool-size 128
  bun run src/bin/bench.ts --test exec-transfer --ops 200000 --concurrency 64 --pool-size 64 --inflight 64
  bun run src/bin/bench.ts --tests read,write,status --ops 20000 --warmup-ops 2000
  bun run src/bin/bench.ts --test spacetime-transfer --ops 50000 --keyspace 10000 --bank-initial-balance 100000
  bun run src/bin/bench.ts --test exec-transfer --ops 50000 --keyspace 10000 --concurrency 128
`);
}
