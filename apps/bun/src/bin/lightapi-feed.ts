#!/usr/bin/env bun
// lightapi-feed.ts — keep WormDB's segment-backed Light API fresh from a running chain.
//
// Polls Hyperion's per-chain MongoDB for state docs with block_num > watermark, re-renders the
// changed accounts via light-api (byte-correct), and writes them to WormDB's KV overlay (which
// shadows the frozen segment). This is the "alongside Hyperion" feed: Hyperion keeps Mongo live
// from SHiP; the feed mirrors only what changed into WormDB, so the 99.9% unchanged accounts stay
// in the fast mmap segment. A periodic segment rebase (not here) drops the overlay and re-warms.
//
//   bun lightapi-feed.ts [sinceBlock]      ENV: MONGO DB CHAIN LAPI PORT INTERVAL ONCE
import { MongoClient } from "mongodb";
import { WormClient } from "../lib/client";

const MONGO = Bun.env.MONGO ?? "mongodb://127.0.0.1:27017";
const DB = Bun.env.DB ?? "hyperion_wax";
const CHAIN = Bun.env.CHAIN ?? "wax";
const LAPI = Bun.env.LAPI ?? "http://127.0.0.1:7001";
const PORT = Number(Bun.env.PORT ?? 16489);
const INTERVAL = Number(Bun.env.INTERVAL ?? 2000);
const ONCE = Bun.env.ONCE === "1";
let since = Number(Bun.argv[2] ?? 0);

const mongo = new MongoClient(MONGO);
await mongo.connect();
const db = mongo.db(DB);
const worm = new WormClient({ host: "127.0.0.1", port: PORT, keepAlive: true, timeoutMs: 60_000 });
const set = (k: string, v: string) => worm.sendCommand({ kind: "SET", key: k, value: v, worm: false });
const txt = async (p: string) => await (await fetch(`${LAPI}${p}`)).text();

// Which account a changed doc belongs to, and whether it affects balances or accinfo.
const SOURCES: [string, string[], "bal" | "acci"][] = [
  ["accounts", ["scope"], "bal"], // a transfer changes both ends' balance rows
  ["permissions", ["account"], "acci"], // updateauth / linkauth / newaccount
  ["eosio-userres", ["@scope"], "acci"], // (un)stake, powerup
  ["eosio-delband", ["from", "to"], "acci"], // (un)delegatebw affects both ends' accinfo
];

function packBalances(j: string): string {
  try {
    const o = JSON.parse(j);
    return (o.balances ?? []).map((b: any) => `${b.contract}\t${b.currency}\t${b.decimals}\t${b.amount}`).join("\n");
  } catch {
    return "";
  }
}
function fragment(j: string): string {
  // strip the {"account_name":…,"chain":{…}, prefix -> "resources":…} (the segment fragment shape)
  const i = j.indexOf('"resources":');
  return i < 0 ? "" : j.slice(i);
}

async function poll() {
  const bal = new Set<string>(), acci = new Set<string>();
  let head = since;
  for (const [coll, fields, kind] of SOURCES) {
    const proj: Record<string, 1> = { block_num: 1 };
    for (const f of fields) proj[f] = 1;
    const cur = db.collection(coll).find({ block_num: { $gt: since } }).project(proj);
    for await (const d of cur) {
      const bn = Number(d.block_num);
      if (bn > head) head = bn;
      for (const f of fields) if (d[f]) (kind === "bal" ? bal : acci).add(d[f] as string);
    }
  }
  // Re-render only the changed accounts (light-api reads the live Mongo) into the overlay.
  for (const a of bal) await set(`bal:${CHAIN}:${a}`, packBalances(await txt(`/api/balances/${CHAIN}/${a}`)));
  for (const a of acci) await set(`acci:${CHAIN}:${a}`, fragment(await txt(`/api/accinfo/${CHAIN}/${a}`)));
  if (head > since) since = head;
  // Freshness: a live chain supplies real block_time; the static snapshot has none, so report "0 OK".
  await set(`sync:${CHAIN}`, "0 OK");
  console.log(`[feed] head=${since} refreshed bal=${bal.size} acci=${acci.size}`);
}

console.log(`[feed] ${DB} chain=${CHAIN} since=${since} interval=${INTERVAL}ms once=${ONCE}`);
await poll();
if (ONCE) {
  await worm.close();
  await mongo.close();
} else {
  setInterval(poll, INTERVAL);
}
