#!/usr/bin/env bun
// Host-local HTTP throughput for the shim: C concurrent workers issue sequential GETs.
const N = Number(Bun.env.N ?? 20_000);
const C = Number(Bun.env.C ?? 50);
const URL = Bun.argv[2] ?? "http://127.0.0.1:7100/api/balances/libre/eosio.token";

const per = Math.ceil(N / C);
const lat: number[] = [];
const t0 = Bun.nanoseconds();
await Promise.all(
  Array.from({ length: C }, async () => {
    for (let i = 0; i < per; i++) {
      const s = Bun.nanoseconds();
      const r = await fetch(URL);
      await r.text();
      lat.push((Bun.nanoseconds() - s) / 1e6);
    }
  }),
);
const wall = (Bun.nanoseconds() - t0) / 1e6;
lat.sort((a, b) => a - b);
const pct = (p: number) => lat[Math.floor((lat.length - 1) * p)].toFixed(2);
console.log(`${per * C} HTTP reqs in ${wall.toFixed(0)}ms -> ${((per * C) / wall * 1000).toFixed(0)} req/s (c=${C})`);
console.log(`latency ms: p50=${pct(0.5)} p95=${pct(0.95)} p99=${pct(0.99)}`);
