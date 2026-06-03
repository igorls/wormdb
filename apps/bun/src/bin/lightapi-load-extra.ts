#!/usr/bin/env bun
// Load the remaining Light-API data into WormDB: codehash (chh:<hash>), top-holders (packed),
// a key sample (pk:<key>), and the rex/sync/status constants — all sourced from light-api.
import { WormClient } from "../lib/client";

const PORT = Number(Bun.env.PORT ?? 6389);
const LAPI = Bun.env.LAPI ?? "http://127.0.0.1:7001";
const c = new WormClient({ host: "127.0.0.1", port: PORT, keepAlive: true, timeoutMs: 60_000 });
const set = (k: string, v: string) => c.sendCommand({ kind: "SET", key: k, value: v, worm: false });

// constants (Libre: rex disabled, snapshot-only so out of sync)
await set("rexraw:libre", "REX is not enabled on libre");
await set("sync:libre", "0 OUT_OF_SYNC");
await set("lastatus", "OUT_OF_SYNC libre:0;");

// topholders top-1000 → packed "acct\tamount\n…"
const th = (await (await fetch(`${LAPI}/api/topholders/libre/eosio.token/LIBRE/1000`)).json()) as [string, string][];
await set("th:libre:eosio.token:LIBRE", th.map(([a, m]) => `${a}\t${m}`).join("\n"));
console.log(`topholders: ${th.length}`);

// codehash (full response per hash)
const hashes = (await Bun.file("../../protodata/hashes.txt").text()).split("\n").map((s) => s.trim()).filter(Boolean);
for (const h of hashes) await set(`chh:${h}`, await (await fetch(`${LAPI}/api/codehash/${h}`)).text());
console.log(`codehash: ${hashes.length}`);

// key sample (full response per key), concurrent
const keys = (await Bun.file("../../protodata/keys.txt").text()).split("\n").map((s) => s.trim()).filter(Boolean);
const CC = 32;
let kdone = 0;
const chunks: string[][] = Array.from({ length: CC }, () => []);
keys.forEach((k, i) => chunks[i % CC]!.push(k));
await Promise.all(
  chunks.map(async (slice) => {
    for (const k of slice) {
      await set(`pk:${k}`, await (await fetch(`${LAPI}/api/key/${k}`)).text());
      kdone++;
    }
  }),
);
console.log(`keys: ${kdone}`);
await c.close();
