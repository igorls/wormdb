#!/usr/bin/env bun
// Light-API comparison matrix: each endpoint × each containerized stack, benched identically (c=50).
const C = 50;
const stacks = [
  { name: "WormDB", base: "http://127.0.0.1:16390", n: 15000 },
  { name: "Rust+Mongo", base: "http://127.0.0.1:7000", n: 15000 },
  { name: "cc32d9", base: "http://127.0.0.1:5001", n: 2500 },
];
const endpoints = [
  { ep: "balances", path: "/api/balances/libre/eosio.token" },
  { ep: "account", path: "/api/account/libre/eosio.token" },
  { ep: "accinfo", path: "/api/accinfo/libre/eosio.token" },
  { ep: "tokenbalance", path: "/api/tokenbalance/libre/eosio.token/eosio.token/LIBRE" },
  { ep: "usercount", path: "/api/usercount/libre" },
  { ep: "holdercount", path: "/api/holdercount/libre/eosio.token/LIBRE" },
  { ep: "networks", path: "/api/networks" },
];

async function bench(url: string, n: number): Promise<number> {
  const per = Math.ceil(n / C);
  const t0 = Bun.nanoseconds();
  await Promise.all(
    Array.from({ length: C }, async () => {
      for (let i = 0; i < per; i++) await (await fetch(url)).text();
    }),
  );
  return (per * C) / ((Bun.nanoseconds() - t0) / 1e6) * 1000;
}

console.log(`endpoint`.padEnd(14) + stacks.map((s) => s.name.padStart(12)).join("") + "    (req/s, c=50)");
console.log("-".repeat(14 + 12 * stacks.length));
for (const e of endpoints) {
  const cells: string[] = [];
  for (const s of stacks) {
    try {
      await (await fetch(s.base + e.path)).text(); // warm
      const qps = await bench(s.base + e.path, s.n);
      cells.push(qps.toFixed(0).padStart(12));
    } catch {
      cells.push("ERR".padStart(12));
    }
  }
  console.log(e.ep.padEnd(14) + cells.join(""));
}
