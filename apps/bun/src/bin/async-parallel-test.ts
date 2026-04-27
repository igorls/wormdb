#!/usr/bin/env bun
// Does async-mode VINSERT scale with parallel producer clients?
// Run multiple clients each feeding the same namespace in async mode.
// If throughput scales linearly-ish with client count, bulk VINSERT is
// less urgent. If it stays flat at ~5000 vec/s, we need server-side batching.

import { WormClient } from "../lib/client";

function parseArgs(argv: string[]): { host: string; port: number; N: number; dim: number; clients: number[] } {
  const a = { host: "127.0.0.1", port: 6389, N: 20_000, dim: 128, clients: [1, 2, 4, 8, 16] };
  for (let i = 0; i < argv.length; i += 1) {
    const t = argv[i];
    const n = (): string => argv[++i] ?? "";
    if (t === "--host") a.host = n();
    else if (t === "--port") a.port = Number(n());
    else if (t === "--N") a.N = Number(n());
    else if (t === "--dim") a.dim = Number(n());
    else if (t === "--clients") a.clients = n().split(",").map(Number);
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

async function runWithClients(
  host: string,
  port: number,
  N: number,
  dim: number,
  clientCount: number,
  data: Float32Array,
  trial: number,
): Promise<{ wall: number; vps: number }> {
  const ns = `vec:par:${clientCount}c${trial}:`;
  const clients: WormClient[] = [];
  for (let i = 0; i < clientCount; i += 1) {
    clients.push(new WormClient({ host, port, keepAlive: true, timeoutMs: 60_000 }));
  }

  const t0 = Bun.nanoseconds();

  // First insert on each ns sets async mode. Do one sync-looking call with async=true
  // from client 0 to establish the mode before fanning out.
  const establishKey = `${ns}establish`;
  const establishVec = new Uint8Array(dim * 4);
  await clients[0].vinsertNative(establishKey, establishVec, {
    worm: false,
    namespace: ns,
    metric: "l2",
    async: true,
  });

  // Fan out inserts across clients. Each client does N/clientCount inserts.
  await Promise.all(
    clients.map(async (client, w) => {
      for (let i = 0; i < N; i += 1) {
        if (i % clientCount !== w) continue;
        const key = `${ns}${i}`;
        const vec = data.subarray(i * dim, (i + 1) * dim);
        const resp = await client.vinsertNative(key, floatsToBytes(vec), {
          worm: false,
          namespace: ns,
          metric: "l2",
          async: true,
        });
        if (resp.type !== "ok") throw new Error(`insert failed c=${w} i=${i}: ${JSON.stringify(resp)}`);
      }
    }),
  );

  const wall = (Bun.nanoseconds() - t0) / 1e6;
  for (const c of clients) await c.close();
  return { wall, vps: (N / wall) * 1000 };
}

async function main(): Promise<void> {
  const args = parseArgs(Bun.argv.slice(2));
  console.log(`Config: ${JSON.stringify(args)}\n`);

  console.log(`Generating ${args.N} × ${args.dim}-dim vectors ...`);
  const data = generateData(args.N, args.dim);
  console.log("Client ack throughput under async-mode VINSERT:\n");
  console.log("clients   wall(ms)    vec/s       per-client");
  console.log("-------   --------    ------      ----------");

  for (const cc of args.clients) {
    const r = await runWithClients(args.host, args.port, args.N, args.dim, cc, data, Date.now() & 0xffff);
    const perClient = r.vps / cc;
    console.log(`${String(cc).padEnd(7)}   ${r.wall.toFixed(0).padStart(7)}    ${r.vps.toFixed(0).padStart(6)}      ${perClient.toFixed(0).padStart(6)}`);
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.stack : String(err));
  process.exit(1);
});
