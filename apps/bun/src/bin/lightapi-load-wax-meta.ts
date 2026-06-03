#!/usr/bin/env bun
// Load the small/aggregate Light-API values for WAX into WormDB's KV store.
// The big per-account tables (balances, accinfo) come from the frozen .wseg segment; only these
// cheap/precomputed values live in KV:
//   lacfg:wax (chain block)   uc:wax (usercount)   hc:wax:<c>:<s> (holdercount)   lanet (networks)
//   th:wax:<c>:<s> (top holders)   topram:wax   topstake:wax   (top-1000 packed "acct\tval\n")
// Aggregates are sourced from a running light-api (byte-correct cc32d9 JSON / live indexed sorts).
import { WormClient } from "../lib/client";

const PORT = Number(Bun.env.PORT ?? 16489);
const HOST = Bun.env.HOST ?? "127.0.0.1";
const LAPI = Bun.env.LAPI ?? "http://127.0.0.1:7001";

// The WAX chain{} block (matches light-api's /api/.../chain for wax).
const chainJson =
  '{"network":"wax","sync":0,"decimals":8,"systoken":"WAX",' +
  '"chainid":"1064487b3cd1a897ce03ae5b6a865651747e2e152090f99c1d19d44e01aea5a4",' +
  '"production":1,"block_num":437909753,"block_time":"","description":"WAX Mainnet","rex_enabled":0}';

const c = new WormClient({ host: HOST, port: PORT, keepAlive: true, timeoutMs: 60_000 });
const set = (k: string, v: string) => c.sendCommand({ kind: "SET", key: k, value: v, worm: false });
const get = async (p: string) => (await (await fetch(`${LAPI}${p}`)).text()).trim();
// cc32d9 top-N is [["acct",v1[,v2]],…]; WormDB's lightapi_topn reads packed "acct\tv1[\tv2]\n…".
// Parse TEXTUALLY (no JSON.parse): topstake's cpu/net weights exceed 2^53, so JS Number coercion
// would corrupt them. Values here are scalars (no nested commas) — split on "],[" then ",".
const packTop = (j: string) => {
  const s = j.trim();
  if (s.length < 4) return ""; // "[]" or empty
  const inner = s.slice(1, -1).trim(); // drop outer [ ]
  if (!inner) return "";
  return inner
    .split("],[")
    .map((r, i, arr) => {
      let x = r;
      if (i === 0) x = x.replace(/^\[/, "");
      if (i === arr.length - 1) x = x.replace(/\]$/, "");
      return x
        .split(",")
        .map((f) => {
          f = f.trim();
          return f.startsWith('"') && f.endsWith('"') ? f.slice(1, -1) : f; // unquote, keep digits exact
        })
        .join("\t");
    })
    .join("\n");
};

await set("lacfg:wax", chainJson);
await set("uc:wax", await get("/api/usercount/wax"));
await set("hc:wax:eosio.token:WAX", await get("/api/holdercount/wax/eosio.token/WAX"));
await set("lanet", await get("/api/networks"));
await set("th:wax:eosio.token:WAX", packTop(await get("/api/topholders/wax/eosio.token/WAX/1000")));
await set("topram:wax", packTop(await get("/api/topram/wax/1000")));
await set("topstake:wax", packTop(await get("/api/topstake/wax/1000")));
console.log("wax meta loaded (lacfg, uc, hc, lanet, topholders, topram, topstake)");
await c.close();
