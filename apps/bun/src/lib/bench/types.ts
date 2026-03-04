import type { WormClient } from "../client";

export type BenchKind = "mixed" | "read" | "write" | "status" | "cluster-status" | "banking" | "spacetime-transfer" | "exec-transfer";

export type BenchOptions = {
  host: string;
  port: number;
  totalOps: number;
  concurrency: number;
  poolSize: number;
  inflight: number;
  keyspace: number;
  readRatio: number;
  warmupOps: number;
  timeoutMs: number;
  valueSize: number;
  keyPrefix: string;
  tests: BenchKind[];
  bankReadRatio: number;
  bankTransferRatio: number;
  bankInitialBalance: number;
  bankMinAmount: number;
  bankMaxAmount: number;
};

export type BenchResult = {
  test: BenchKind;
  attempted: number;
  succeeded: number;
  failed: number;
  elapsedMs: number;
  opsPerSec: number;
  latMsAvg: number;
  latMsP50: number;
  latMsP95: number;
  latMsP99: number;
};

export type WorkContext = {
  options: BenchOptions;
  valuePayload: string;
};

export type BenchScenario = {
  kind: BenchKind;
  description: string;
  needsSeed: boolean;
  makeCommand?: (ctx: WorkContext) => string;
  runOperation?: (client: WormClient, ctx: WorkContext) => Promise<"success" | "failure">;
  seedValueForKey?: (ctx: WorkContext, key: string) => string;
  classifyResult?: (result: Awaited<ReturnType<WormClient["send"]>>) => "success" | "failure";
};

export const BENCH_DEFAULTS: BenchOptions = {
  host: "127.0.0.1",
  port: 6389,
  totalOps: 10000,
  concurrency: 64,
  poolSize: 64,
  inflight: 1,
  keyspace: 1000,
  readRatio: 0.8,
  warmupOps: 1000,
  timeoutMs: 5000,
  valueSize: 128,
  keyPrefix: "bench",
  tests: ["mixed"],
  bankReadRatio: 0.6,
  bankTransferRatio: 0.25,
  bankInitialBalance: 100000,
  bankMinAmount: 1,
  bankMaxAmount: 1000,
};
