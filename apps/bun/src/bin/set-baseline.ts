#!/usr/bin/env bun
// Raw SET throughput baseline — same payload size as 128-dim f32 vector (512B)
// but no HNSW work. Isolates HNSW cost from wire + store overhead.

import { WormClient } from "../lib/client";

const N = Number(Bun.argv[2] ?? 10_000);
const value = "x".repeat(512);

async function runStrategy(name: string, clientCount: number, pipelineDepth: number): Promise<void> {
  const clients: WormClient[] = [];
  for (let i = 0; i < clientCount; i += 1) {
    clients.push(new WormClient({ host: "127.0.0.1", port: 6389, keepAlive: true, timeoutMs: 60_000 }));
  }
  const t0 = Bun.nanoseconds();

  const runOne = async (client: WormClient, indices: number[]): Promise<void> => {
    let i = 0;
    while (i < indices.length) {
      const batch = indices.slice(i, i + pipelineDepth);
      const ps = batch.map((idx) => client.send(`SET ${name}:k${idx} ${value}`));
      const rs = await Promise.all(ps);
      for (const r of rs) if (r.type === "error") throw new Error(r.message);
      i += pipelineDepth;
    }
  };

  await Promise.all(
    clients.map((c, w) => {
      const idxs = Array.from({ length: N }, (_, i) => i).filter((i) => i % clientCount === w);
      return runOne(c, idxs);
    }),
  );

  const wall = (Bun.nanoseconds() - t0) / 1e6;
  const vps = (N / wall) * 1000;
  console.log(`${name.padEnd(18)} ${wall.toFixed(0).padStart(7)}ms   ${vps.toFixed(0).padStart(6)} ops/s`);
  for (const c of clients) await c.close();
}

console.log(`SET baseline @ N=${N}, value=512B\n`);
await runStrategy("seq-1c", 1, 1);
await runStrategy("pipe64-1c", 1, 64);
await runStrategy("par8-seq", 8, 1);
await runStrategy("par8-pipe8", 8, 8);
await runStrategy("par16-pipe8", 16, 8);
