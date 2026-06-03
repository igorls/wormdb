#!/usr/bin/env bun
// Full Light-API load into WormDB: balances (packed) + accinfo bodies + meta, sourced from a running
// light-api (which emits byte-correct cc32d9 JSON) so parity is guaranteed.
//   bal:libre:<acct>   (from TSV, packed)         acci:libre:<acct>  (accinfo body)
//   lacfg:libre  lanet  uc:libre  hc:libre:<c>:<s>
import { WormClient } from "../lib/client";

const PORT = Number(Bun.env.PORT ?? 6389);
const LAPI = Bun.env.LAPI ?? "http://127.0.0.1:7001";
const FILE = Bun.argv[2] ?? "protodata/balances.tsv";

const text = await Bun.file(FILE).text();
const byAcct = new Map<string, string[]>();
for (const line of text.split("\n")) {
  const t = line.indexOf("\t");
  if (t < 0) continue;
  const arr = byAcct.get(line.slice(0, t)) ?? [];
  arr.push(line.slice(t + 1));
  byAcct.set(line.slice(0, t), arr);
}
const accts = [...byAcct.keys()];
console.log(`accounts: ${accts.length}`);

const chainJson =
  '{"network":"libre","sync":0,"decimals":4,"systoken":"LIBRE",' +
  '"chainid":"38b1d7815474d0c60683ecbea321d723e83f5da6ae5f1c1f9fecc69d9ba96465",' +
  '"production":1,"block_num":245975500,"block_time":"","description":"Libre","rex_enabled":0}';

const c = new WormClient({ host: "127.0.0.1", port: PORT, keepAlive: true, timeoutMs: 60_000 });
const set = (k: string, v: string) => c.sendCommand({ kind: "SET", key: k, value: v, worm: false });

// meta + balances
await set("lacfg:libre", chainJson);
await set("lanet", (await (await fetch(`${LAPI}/api/networks`)).text()).trim());
await set("uc:libre", (await (await fetch(`${LAPI}/api/usercount/libre`)).text()).trim());
await set("hc:libre:eosio.token:LIBRE", (await (await fetch(`${LAPI}/api/holdercount/libre/eosio.token/LIBRE`)).text()).trim());

let t0 = Bun.nanoseconds();
for (let i = 0; i < accts.length; i += 256) {
  await Promise.all(accts.slice(i, i + 256).map((acc) => set(`bal:libre:${acc}`, byAcct.get(acc)!.join("\n"))));
}
console.log(`balances: ${accts.length} in ${((Bun.nanoseconds() - t0) / 1e6).toFixed(0)}ms`);

// accinfo bodies — fetch from light-api (exact parity) + store, with concurrency
const CC = 64;
let done = 0;
t0 = Bun.nanoseconds();
const chunks: string[][] = Array.from({ length: CC }, () => []);
accts.forEach((a, i) => chunks[i % CC]!.push(a));
await Promise.all(
  chunks.map(async (slice) => {
    for (const acc of slice) {
      const body = await (await fetch(`${LAPI}/api/accinfo/libre/${acc}`)).text();
      await set(`acci:libre:${acc}`, body);
      done++;
    }
  }),
);
console.log(`accinfo: ${done} in ${((Bun.nanoseconds() - t0) / 1e6).toFixed(0)}ms (${((done / (Bun.nanoseconds() - t0)) * 1e9).toFixed(0)}/s)`);
await c.close();
