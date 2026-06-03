#!/usr/bin/env bun
// Raw WormWire throughput for EXEC lightapi_balances (pure procedure, no HTTP).
// C concurrent keepAlive clients each issue sequential EXECs → C in-flight (matches ApacheBench -c).
import { WormClient } from "../lib/client";

const N = Number(Bun.env.N ?? 50_000);
const C = Number(Bun.env.C ?? 50);
const ACCT = Bun.argv[2] ?? "eosio.token";

const clients = Array.from({ length: C }, () =>
  new WormClient({ host: "127.0.0.1", port: 6389, keepAlive: true, timeoutMs: 30_000 }),
);
const per = Math.ceil(N / C);
const lat: number[] = [];

const t0 = Bun.nanoseconds();
await Promise.all(
  clients.map(async (c) => {
    for (let i = 0; i < per; i++) {
      const s = Bun.nanoseconds();
      const r = await c.sendCommand({ kind: "EXEC", procedure: "lightapi_balances", args: ["libre", ACCT] });
      if (r.type === "error") throw new Error(r.message);
      lat.push((Bun.nanoseconds() - s) / 1e6);
    }
  }),
);
const wall = (Bun.nanoseconds() - t0) / 1e6;
lat.sort((a, b) => a - b);
const pct = (p: number) => lat[Math.floor((lat.length - 1) * p)].toFixed(2);
console.log(`EXEC lightapi_balances libre ${ACCT}`);
console.log(`${per * C} reqs in ${wall.toFixed(0)}ms -> ${((per * C) / wall * 1000).toFixed(0)} req/s  (c=${C})`);
console.log(`latency ms: p50=${pct(0.5)} p95=${pct(0.95)} p99=${pct(0.99)}`);
for (const c of clients) await c.close();
