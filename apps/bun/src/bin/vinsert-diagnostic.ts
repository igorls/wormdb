#!/usr/bin/env bun
// Insert-throughput diagnostic: run N vector inserts under different client
// strategies and measure vec/s. Each strategy uses an isolated namespace so
// HNSW index cost is comparable across trials.
//
// Usage: bun run src/bin/vinsert-diagnostic.ts [--host H] [--port P] [--N 20000] [--dim 128]

import { WormClient } from "../lib/client";
import type { ParsedCommand } from "../lib/command";

type Args = { host: string; port: number; N: number; dim: number; metric: "l2" | "cosine" };

function parseArgs(argv: string[]): Args {
  const a: Args = { host: "127.0.0.1", port: 6389, N: 20_000, dim: 128, metric: "l2" };
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i];
    const n = (): string => argv[++i] ?? "";
    if (t === "--host") a.host = n();
    else if (t === "--port") a.port = Number(n());
    else if (t === "--N") a.N = Number(n());
    else if (t === "--dim") a.dim = Number(n());
  }
  return a;
}

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

function generateData(N: number, dim: number): Float32Array {
  const rng = mulberry32(0xbeef);
  const data = new Float32Array(N * dim);
  for (let i = 0; i < N * dim; i += 2) {
    const u1 = Math.max(rng(), 1e-12);
    const u2 = rng();
    const mag = Math.sqrt(-2.0 * Math.log(u1));
    data[i] = mag * Math.cos(2 * Math.PI * u2);
    if (i + 1 < N * dim) data[i + 1] = mag * Math.sin(2 * Math.PI * u2);
  }
  return data;
}

function floatsToBytes(f: Float32Array): Uint8Array {
  return new Uint8Array(f.buffer, f.byteOffset, f.byteLength);
}

function vinsertCmd(key: string, vec: Uint8Array, namespace: string, metric: Args["metric"]): ParsedCommand {
  return {
    kind: "VINSERT",
    key,
    vector: vec,
    worm: false,
    namespace,
    metric,
    timestamp: BigInt(Date.now()),
  };
}

type Result = { name: string; wallMs: number; vps: number; p50Ms: number; p99Ms: number };

async function runStrategy(
  name: string,
  host: string,
  port: number,
  N: number,
  dim: number,
  metric: Args["metric"],
  data: Float32Array,
  fn: (clients: WormClient[], ns: string) => Promise<{ perItemMs: number[] }>,
  clientCount: number,
): Promise<Result> {
  const ns = `vec:diag:${name.replace(/[^a-z0-9]/gi, "")}:`;
  const clients: WormClient[] = [];
  for (let i = 0; i < clientCount; i += 1) {
    clients.push(new WormClient({ host, port, keepAlive: true, timeoutMs: 60_000 }));
  }
  const t0 = Bun.nanoseconds();
  const { perItemMs } = await fn(clients, ns);
  const wallMs = (Bun.nanoseconds() - t0) / 1e6;
  for (const c of clients) await c.close();
  perItemMs.sort((a, b) => a - b);
  return {
    name,
    wallMs,
    vps: (N / wallMs) * 1000,
    p50Ms: perItemMs[Math.floor(perItemMs.length * 0.5)],
    p99Ms: perItemMs[Math.floor(perItemMs.length * 0.99)],
  };
}

async function main(): Promise<void> {
  const args = parseArgs(Bun.argv.slice(2));
  console.log(`Config: ${JSON.stringify(args)}\n`);

  console.log(`Generating ${args.N} × ${args.dim}-dim vectors ...`);
  const data = generateData(args.N, args.dim);
  const { host, port, N, dim, metric } = args;

  const ipM = (): number[] => [];

  // Helper — insert with a given pipeline depth on one client.
  const runPipelined = async (client: WormClient, ns: string, depth: number, indices: number[]): Promise<number[]> => {
    const latencies: number[] = [];
    let i = 0;
    while (i < indices.length) {
      const batch = indices.slice(i, i + depth);
      const starts = batch.map(() => Bun.nanoseconds());
      const ps = batch.map((idx) => {
        const vec = data.subarray(idx * dim, (idx + 1) * dim);
        return client.sendCommand(vinsertCmd(`${ns}${idx}`, floatsToBytes(vec), ns, metric));
      });
      const results = await Promise.all(ps);
      for (let k = 0; k < results.length; k += 1) {
        const r = results[k];
        if (r.type !== "ok") throw new Error(`insert fail at ${indices[i + k]}: ${JSON.stringify(r)}`);
        latencies.push((Bun.nanoseconds() - starts[k]) / 1e6);
      }
      i += depth;
    }
    return latencies;
  };

  const strategies: Array<{ name: string; clients: number; run: (clients: WormClient[], ns: string) => Promise<{ perItemMs: number[] }> }> = [
    {
      name: "seq",
      clients: 1,
      run: async (clients, ns) => {
        const all = Array.from({ length: N }, (_, i) => i);
        const perItemMs = await runPipelined(clients[0], ns, 1, all);
        return { perItemMs };
      },
    },
    {
      name: "pipe8",
      clients: 1,
      run: async (clients, ns) => {
        const all = Array.from({ length: N }, (_, i) => i);
        const perItemMs = await runPipelined(clients[0], ns, 8, all);
        return { perItemMs };
      },
    },
    {
      name: "pipe64",
      clients: 1,
      run: async (clients, ns) => {
        const all = Array.from({ length: N }, (_, i) => i);
        const perItemMs = await runPipelined(clients[0], ns, 64, all);
        return { perItemMs };
      },
    },
    {
      name: "pipe256",
      clients: 1,
      run: async (clients, ns) => {
        const all = Array.from({ length: N }, (_, i) => i);
        const perItemMs = await runPipelined(clients[0], ns, 256, all);
        return { perItemMs };
      },
    },
    {
      name: "par4-seq",
      clients: 4,
      run: async (clients, ns) => {
        const per: number[][] = await Promise.all(
          clients.map(async (client, w) => {
            const idxs = Array.from({ length: N }, (_, i) => i).filter((i) => i % 4 === w);
            return runPipelined(client, ns, 1, idxs);
          }),
        );
        return { perItemMs: per.flat() };
      },
    },
    {
      name: "par8-seq",
      clients: 8,
      run: async (clients, ns) => {
        const per: number[][] = await Promise.all(
          clients.map(async (client, w) => {
            const idxs = Array.from({ length: N }, (_, i) => i).filter((i) => i % 8 === w);
            return runPipelined(client, ns, 1, idxs);
          }),
        );
        return { perItemMs: per.flat() };
      },
    },
    {
      name: "par8-pipe8",
      clients: 8,
      run: async (clients, ns) => {
        const per: number[][] = await Promise.all(
          clients.map(async (client, w) => {
            const idxs = Array.from({ length: N }, (_, i) => i).filter((i) => i % 8 === w);
            return runPipelined(client, ns, 8, idxs);
          }),
        );
        return { perItemMs: per.flat() };
      },
    },
    {
      name: "par16-seq",
      clients: 16,
      run: async (clients, ns) => {
        const per: number[][] = await Promise.all(
          clients.map(async (client, w) => {
            const idxs = Array.from({ length: N }, (_, i) => i).filter((i) => i % 16 === w);
            return runPipelined(client, ns, 1, idxs);
          }),
        );
        return { perItemMs: per.flat() };
      },
    },
  ];

  const results: Result[] = [];
  for (const s of strategies) {
    console.log(`Running ${s.name} (clients=${s.clients})...`);
    try {
      const r = await runStrategy(s.name, host, port, N, dim, metric, data, s.run, s.clients);
      console.log(`  ${r.name.padEnd(14)}  ${r.wallMs.toFixed(0).padStart(7)}ms   ${r.vps.toFixed(0).padStart(6)} vec/s   p50=${r.p50Ms.toFixed(2)}ms  p99=${r.p99Ms.toFixed(2)}ms`);
      results.push(r);
    } catch (e) {
      console.error(`  ${s.name} FAILED: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  console.log("\n=== Summary ===");
  console.log("strategy          wall(ms)    vec/s     p50(ms)   p99(ms)");
  for (const r of results) {
    console.log(`${r.name.padEnd(16)}  ${r.wallMs.toFixed(0).padStart(7)}   ${r.vps.toFixed(0).padStart(6)}     ${r.p50Ms.toFixed(2).padStart(6)}    ${r.p99Ms.toFixed(2).padStart(6)}`);
  }
  void ipM;
}

main().catch((err) => {
  console.error(err instanceof Error ? err.stack : String(err));
  process.exit(1);
});
