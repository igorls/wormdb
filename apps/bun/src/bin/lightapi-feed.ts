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

// [collection, block_num field, block_time field|null, account field(s), kind]. NOTE the field split:
// accounts/permissions carry plain `block_num`; the eosio @-tables carry `@block_num`/`@block_time`.
const SOURCES: [string, string, string | null, string[], "bal" | "acci"][] = [
  ["accounts", "block_num", null, ["scope"], "bal"], // a transfer changes both ends' balance rows
  ["permissions", "block_num", "last_updated", ["account"], "acci"], // updateauth / linkauth / newaccount
  ["eosio-userres", "@block_num", "@block_time", ["@scope"], "acci"], // (un)stake, powerup
  ["eosio-delband", "@block_num", "@block_time", ["from", "to"], "acci"], // (un)delegatebw — both ends
];

// Parse a Hyperion time string as UTC epoch-ms (the docs omit the zone designator).
function tparse(s: string): number {
  if (!s) return 0;
  const z = /[zZ]|[+-]\d\d:?\d\d$/.test(s) ? s : s + "Z";
  const ms = Date.parse(z);
  return isNaN(ms) ? 0 : ms;
}

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
  let head = since, headTimeMs = 0;
  for (const [coll, bf, tf, fields, kind] of SOURCES) {
    const proj: Record<string, 1> = { [bf]: 1 };
    for (const f of fields) proj[f] = 1;
    if (tf) proj[tf] = 1;
    const cur = db.collection(coll).find({ [bf]: { $gt: since } }).project(proj);
    for await (const d of cur) {
      const bn = Number(d[bf]);
      if (bn > head) head = bn;
      if (tf) { const ms = tparse(d[tf] as string); if (ms > headTimeMs) headTimeMs = ms; }
      for (const f of fields) if (d[f]) (kind === "bal" ? bal : acci).add(d[f] as string);
    }
  }
  // Re-render only the changed accounts (light-api reads the live Mongo) into the overlay.
  for (const a of bal) await set(`bal:${CHAIN}:${a}`, packBalances(await txt(`/api/balances/${CHAIN}/${a}`)));
  for (const a of acci) await set(`acci:${CHAIN}:${a}`, fragment(await txt(`/api/accinfo/${CHAIN}/${a}`)));
  if (head > since) since = head;
  // Freshness: head block time if any timed change this poll, else now (caught up => current).
  // /sync + /status compute `now - synctime` at request time, so the delay grows if the feed stalls.
  const syncMs = headTimeMs > 0 ? headTimeMs : Date.now();
  await set(`synctime:${CHAIN}`, String(syncMs));
  await set("syncchains", CHAIN);
  console.log(`[feed] head=${since} bal=${bal.size} acci=${acci.size} delay=${Math.max(0, (Date.now() - syncMs) / 1000) | 0}s`);
}

console.log(`[feed] ${DB} chain=${CHAIN} since=${since} interval=${INTERVAL}ms once=${ONCE}`);
await poll();
if (ONCE) {
  await worm.close();
  await mongo.close();
} else {
  setInterval(poll, INTERVAL);
}
