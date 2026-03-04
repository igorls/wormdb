import type { BenchKind, BenchScenario, WorkContext } from "./types";
import type { WormResponse } from "../protocol";

function randomInt(maxExclusive: number): number {
  return Math.floor(Math.random() * maxExclusive);
}

function nextKey(ctx: WorkContext): string {
  const keyId = randomInt(ctx.options.keyspace);
  return `${ctx.options.keyPrefix}:${keyId}`;
}

function parseBalance(response: WormResponse): number | null {
  if (response.type !== "bulk") return null;
  const value = Number(response.value);
  if (!Number.isFinite(value) || value < 0) return null;
  return Math.floor(value);
}

function randomAmount(ctx: WorkContext): number {
  const min = ctx.options.bankMinAmount;
  const max = ctx.options.bankMaxAmount;
  if (max <= min) return min;
  return min + randomInt(max - min + 1);
}

const SCENARIOS: Record<BenchKind, BenchScenario> = {
  mixed: {
    kind: "mixed",
    description: "mixed GET/SET load using --read-ratio",
    needsSeed: true,
    makeCommand(ctx) {
      const key = nextKey(ctx);
      const opIsRead = Math.random() < ctx.options.readRatio;
      return opIsRead ? `GET ${key}` : `SET ${key} ${ctx.valuePayload}`;
    },
  },
  read: {
    kind: "read",
    description: "read-only GET workload",
    needsSeed: true,
    makeCommand(ctx) {
      return `GET ${nextKey(ctx)}`;
    },
  },
  write: {
    kind: "write",
    description: "write-only SET workload",
    needsSeed: false,
    makeCommand(ctx) {
      return `SET ${nextKey(ctx)} ${ctx.valuePayload}`;
    },
  },
  status: {
    kind: "status",
    description: "STATUS command throughput/latency",
    needsSeed: false,
    makeCommand() {
      return "STATUS";
    },
  },
  "cluster-status": {
    kind: "cluster-status",
    description: "CLUSTER STATUS command throughput/latency",
    needsSeed: false,
    makeCommand() {
      return "CLUSTER STATUS";
    },
  },
  banking: {
    kind: "banking",
    description: "banking simulation: balance checks, deposits, and transfers",
    needsSeed: true,
    seedValueForKey(ctx) {
      return String(ctx.options.bankInitialBalance);
    },
    async runOperation(client, ctx) {
      const r = Math.random();
      const source = nextKey(ctx);

      // Balance inquiry
      if (r < ctx.options.bankReadRatio) {
        const read = await client.send(`GET ${source}`);
        return parseBalance(read) === null ? "failure" : "success";
      }

      const transferThreshold = ctx.options.bankReadRatio + ctx.options.bankTransferRatio;

      // Transfer between two accounts (non-atomic simulation)
      if (r < transferThreshold) {
        let target = nextKey(ctx);
        if (target === source) {
          target = `${ctx.options.keyPrefix}:${(randomInt(ctx.options.keyspace - 1) + 1) % ctx.options.keyspace}`;
        }

        const fromRes = await client.send(`GET ${source}`);
        const toRes = await client.send(`GET ${target}`);
        const fromBal = parseBalance(fromRes);
        const toBal = parseBalance(toRes);
        if (fromBal === null || toBal === null) return "failure";

        const amount = randomAmount(ctx);
        if (fromBal < amount) {
          return "success";
        }

        const debit = await client.send(`SET ${source} ${fromBal - amount}`);
        if (debit.type === "error") return "failure";

        const credit = await client.send(`SET ${target} ${toBal + amount}`);
        return credit.type === "error" ? "failure" : "success";
      }

      // Deposit on one account
      const read = await client.send(`GET ${source}`);
      const balance = parseBalance(read);
      if (balance === null) return "failure";

      const amount = randomAmount(ctx);
      const write = await client.send(`SET ${source} ${balance + amount}`);
      return write.type === "error" ? "failure" : "success";
    },
  },
  "spacetime-transfer": {
    kind: "spacetime-transfer",
    description: "SpacetimeDB-style transfer workload: seed fixed balances, then transfer(from,to,amount)",
    needsSeed: true,
    seedValueForKey(ctx) {
      // Mirrors SpacetimeDB template seed(n, balance).
      return String(ctx.options.bankInitialBalance);
    },
    async runOperation(client, ctx) {
      const from = nextKey(ctx);
      let to = nextKey(ctx);
      if (to === from) {
        const nextId = (randomInt(ctx.options.keyspace - 1) + 1) % ctx.options.keyspace;
        to = `${ctx.options.keyPrefix}:${nextId}`;
      }

      // SpacetimeDB reducer uses u32 amount and rejects with insufficient_funds.
      const amount = randomAmount(ctx);

      const fromRes = await client.send(`GET ${from}`);
      const toRes = await client.send(`GET ${to}`);
      const fromBal = parseBalance(fromRes);
      const toBal = parseBalance(toRes);
      if (fromBal === null || toBal === null) return "failure";

      // Treat insufficient funds as a valid business outcome (not infra failure),
      // matching reducer semantics that reject the transaction.
      if (fromBal < amount) {
        return "success";
      }

      const debit = await client.send(`SET ${from} ${fromBal - amount}`);
      if (debit.type === "error") return "failure";

      const credit = await client.send(`SET ${to} ${toBal + amount}`);
      return credit.type === "error" ? "failure" : "success";
    },
  },
  "exec-transfer": {
    kind: "exec-transfer",
    description: "server-side atomic EXEC transfer — single round-trip, one lock, apples-to-apples with SpacetimeDB",
    needsSeed: true,
    seedValueForKey(ctx) {
      return String(ctx.options.bankInitialBalance);
    },
    async runOperation(client, ctx) {
      const from = nextKey(ctx);
      let to = nextKey(ctx);
      if (to === from) {
        const nextId = (randomInt(ctx.options.keyspace - 1) + 1) % ctx.options.keyspace;
        to = `${ctx.options.keyPrefix}:${nextId}`;
      }
      const amount = randomAmount(ctx);

      // Single command → server executes atomically under one lock
      const res = await client.send(`EXEC transfer ${from} ${to} ${amount}`);

      // "insufficient_funds" is a valid business outcome, not infra failure
      if (res.type === "error" && res.message === "insufficient_funds") {
        return "success";
      }
      return res.type === "error" ? "failure" : "success";
    },
  },
};

export function availableBenchKinds(): BenchKind[] {
  return Object.keys(SCENARIOS) as BenchKind[];
}

export function getScenario(kind: BenchKind): BenchScenario {
  return SCENARIOS[kind];
}
