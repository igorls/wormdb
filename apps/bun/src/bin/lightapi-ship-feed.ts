#!/usr/bin/env bun
// lightapi-ship-feed.ts — keep WormDB's segment-backed Light API fresh straight from a nodeos SHiP
// websocket. NO MongoDB, NO Hyperion: the node is the only dependency.
//
// SHiP streams which rows changed each block (table_delta: contract_row / permission /
// permission_link / resource_usage). We decode just enough of each delta to learn the affected
// ACCOUNT, then render that account's current Light-API state from the node's chain API
// (get_table_rows / get_account) — the same shapes light-api produces — and write the WormDB overlay
// (bal:/acci:<chain>:<acct>). SHiP is the change-notifier; the chain API is the renderer.
//
// Fork-safety: we follow the irreversible stream (fetch_block=false until LIB), so applied state never
// needs rollback. synctime is stamped from each block's timestamp for request-time /sync.
//
//   bun lightapi-ship-feed.ts            ENV: SHIP CHAIN_API CHAIN PORT START SYSTOKEN SYSCONTRACT
import { ABI, Serializer } from "@wharfkit/antelope";
import { WormClient } from "../lib/client";

// Decode a SHiP type and flatten wharfkit's wrapped numerics (UInt32/Name/...) to plain JS values.
function decode(abi: ABI, type: string, data: Uint8Array): any {
  return Serializer.objectify(Serializer.decode({ abi, type, data }));
}

const SHIP = Bun.env.SHIP ?? "ws://127.0.0.1:18080/";
const CHAIN_API = Bun.env.CHAIN_API ?? "http://127.0.0.1:18888"; // nodeos http
const CHAIN = Bun.env.CHAIN ?? "libre";
// PORT is the WormWire port the OVERLAY is written to. When running this feed inside Docker against a
// host-published WormDB, use the *published host port* (e.g. 16589), NOT the container-internal 6389 —
// host.docker.internal:6389 would hit the host's 6389, not the 16589->6389 mapping.
const PORT = Number(Bun.env.PORT ?? 16589);
const SYSTOKEN = Bun.env.SYSTOKEN ?? "LIBRE";
const SYSCONTRACT = Bun.env.SYSCONTRACT ?? "eosio.token";
const START = Number(Bun.env.START ?? 0); // 0 => start at LIB head

const WORMHOST = Bun.env.WORMHOST ?? "127.0.0.1";
const worm = new WormClient({ host: WORMHOST, port: PORT, keepAlive: true, timeoutMs: 60_000 });
const set = (k: string, v: string) => worm.sendCommand({ kind: "SET", key: k, value: v, worm: false });

let infoCache: { at: number; info: any } | null = null;
async function chainInfo(): Promise<any> {
  const now = Date.now();
  if (infoCache && now - infoCache.at < 1000) return infoCache.info;
  const r = await fetch(`${CHAIN_API}/v1/chain/get_info`, { method: "POST" });
  const info = await r.json();
  infoCache = { at: now, info };
  return info;
}

async function chain(path: string, body: unknown): Promise<any> {
  // nodeos http-validate-host rejects a Host it doesn't recognize (only localhost/127.0.0.1 by
  // default), so force it regardless of the hostname we dialed.
  const r = await fetch(`${CHAIN_API}/v1/chain/${path}`, {
    method: "POST",
    headers: { Host: "127.0.0.1", "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return r.json();
}

// ── Light-API renderers (read decoded state from the node, emit the WormDB overlay shapes) ──

// Token-contract scan is unbounded in general; for the feed we refresh the system token plus any
// contract that emitted a row for this account (tracked per block). Balances overlay = packed lines.
async function renderBalances(acct: string, contracts: Set<string>) {
  const lines: string[] = [];
  for (const code of contracts) {
    const res = await chain("get_currency_balance", { code, account: acct });
    for (const bal of res ?? []) {
      // "2318562158.1658 LIBRE" -> contract \t symbol \t decimals \t amount
      const [amt, sym] = String(bal).split(" ");
      const decimals = amt.includes(".") ? amt.split(".")[1].length : 0;
      lines.push(`${code}\t${sym}\t${decimals}\t${amt}`);
    }
  }
  await set(`bal:${CHAIN}:${acct}`, lines.join("\n"));
}

// accinfo fragment from get_account (resources, permissions, delegations) — the cc32d9 shape minus
// the {account_name,chain} prefix, matching the segment fragment WormDB's procedures wrap.
function asset(s: string): number {
  const n = String(s ?? "0").split(" ")[0];
  return Number(n.replace(".", "")) || 0;
}
async function renderAccinfo(acct: string) {
  const a = await chain("get_account", { account_name: acct });
  if (!a || a.error || !a.account_name) return;
  let out = "";
  const net = asset(a.total_resources?.net_weight ?? "0");
  const cpu = asset(a.total_resources?.cpu_weight ?? "0");
  const ram = a.total_resources?.ram_bytes ?? 0;
  out += `"resources":{"net_weight":${net},"cpu_weight":${cpu},"ram_bytes":${ram}}`;
  // permissions (sorted by name, like light-api)
  const perms = (a.permissions ?? []).slice().sort((x: any, y: any) => x.perm_name.localeCompare(y.perm_name));
  out += `,"permissions":[` + perms.map((p: any) => {
    const ra = p.required_auth ?? {};
    const keys = (ra.keys ?? []).map((k: any) =>
      `{"pubkey":"${k.key}","public_key":"${k.key}","weight":${k.weight}}`).join(",");
    const accs = (ra.accounts ?? []).map((ac: any) =>
      `{"actor":"${ac.permission?.actor}","permission":"${ac.permission?.permission}","weight":${ac.weight}}`).join(",");
    return `{"perm":"${p.perm_name}","threshold":${ra.threshold ?? 1},"auth":{"keys":[${keys}],"accounts":[${accs}]}}`;
  }).join(",") + `]`;
  // delegations
  const dt = (a.self_delegated_bandwidth ? [a.self_delegated_bandwidth] : []);
  out += `,"delegated_to":[` + dt.map((d: any) =>
    `{"del_to":"${d.to}","cpu_weight":${asset(d.cpu_weight)},"net_weight":${asset(d.net_weight)}}`).join(",") + `]`;
  out += `,"delegated_from":[]`;
  out += `,"linkauth":[]`;
  out += `}`;
  await set(`acci:${CHAIN}:${acct}`, out);
}

// ── SHiP client ──

let abi: ABI;
function send(ws: WebSocket, requestType: string, data: any) {
  // request is the ABI's top variant: [requestType, data]
  const bytes = Serializer.encode({ abi, type: "request", object: [requestType, data] });
  ws.send(bytes.array);
}

// SHiP nests bytes either as a hex string or a byte array depending on objectify; normalize.
function hexOrBytes(x: any): Uint8Array {
  if (x instanceof Uint8Array) return x;
  if (typeof x === "string") {
    const a = new Uint8Array(x.length / 2);
    for (let i = 0; i < a.length; i++) a[i] = parseInt(x.substr(i * 2, 2), 16);
    return a;
  }
  if (Array.isArray(x)) return new Uint8Array(x);
  return new Uint8Array(0);
}

const decodeResult = (raw: Uint8Array) => Serializer.objectify(Serializer.decode({ abi, type: "result", data: raw })) as any;

let head = 0;
let firstSync = true; // set the sync threshold (LIB-lag-tolerant) once
let applyTail: Promise<void> = Promise.resolve(); // serializes block application (one WormWire socket)
async function applyBlock(blk: any, ws: WebSocket) {
  const bnum = Number(blk.this_block?.block_num ?? 0);
  // deltas is an optional array of [type, bytes]; only present when fetch_deltas was set.
  const changed = new Map<string, Set<string>>(); // account -> contracts that touched it
  const acciAccts = new Set<string>();
  // deltas: table_delta[] where each element is the variant [="table_delta_v0", {name, rows:[{present,data}]}].
  const deltas: any[] = blk.deltas ? decode(abi, "table_delta[]", hexOrBytes(blk.deltas)) : [];
  for (const elem of deltas) {
    const d = Array.isArray(elem) ? elem[1] : elem; // unwrap the [typename, value] variant
    const name = d?.name;
    if (name === "contract_row") {
      for (const row of d.rows ?? []) {
        const cr = decode(abi, "contract_row", hexOrBytes(row.data));
        const v = Array.isArray(cr) ? cr[1] : cr; // contract_row is also a variant
        if (v.table === "accounts") {
          const acct = String(v.scope);
          if (!changed.has(acct)) changed.set(acct, new Set());
          changed.get(acct)!.add(String(v.code));
        }
      }
    } else if (name === "permission" || name === "resource_usage" || name === "resource_limits") {
      for (const row of d.rows ?? []) {
        const pr0 = decode(abi, name, hexOrBytes(row.data));
        const pr = Array.isArray(pr0) ? pr0[1] : pr0;
        const acct = String(pr.owner ?? pr.name ?? "");
        if (acct) acciAccts.add(acct);
      }
    }
  }
  for (const [acct, contracts] of changed) { await renderBalances(acct, contracts); acciAccts.add(acct); }
  for (const acct of acciAccts) await renderAccinfo(acct);
  if (bnum > head) head = bnum;
  // Freshness: stamp the wall time of the block we just applied. With fetch_block=false there's no
  // header, so anchor to the node's head (block_num -> ms via the 0.5s Antelope interval). When the
  // feed is caught up, bnum ≈ LIB and this ≈ now - LIB_lag (~180s on Libre — irreversibility is
  // inherently a few minutes behind head). /sync grows further if the feed stalls.
  const headInfo = await chainInfo();
  if (headInfo) {
    const headMs = Date.parse(headInfo.head_block_time + "Z");
    const ms = headMs - (Number(headInfo.head_block_num) - bnum) * 500;
    await set(`synctime:${CHAIN}`, String(ms));
    await set(`syncblock:${CHAIN}`, String(bnum));
    await set("syncchains", CHAIN);
    // Tolerate the LIB lag: in-sync if within (lag + 30s). cc32d9/light-api use a similar threshold.
    if (firstSync) { await set(`syncthr:${CHAIN}`, "240"); firstSync = false; }
  }
  if (changed.size || acciAccts.size) {
    console.log(`[ship] block ${bnum} bal=${changed.size} acci=${acciAccts.size}`);
  }
  // ack one block so SHiP sends the next
  send(ws, "get_blocks_ack_request_v0", { num_messages: 1 });
}

const ws = new WebSocket(SHIP);
ws.binaryType = "arraybuffer";
ws.onmessage = async (ev) => {
  if (typeof ev.data === "string") {
    abi = ABI.from(JSON.parse(ev.data)); // handshake ABI
    console.log(`[ship] ABI received; requesting status`);
    send(ws, "get_status_request_v0", {});
    return;
  }
  const raw = new Uint8Array(ev.data as ArrayBuffer);
  const [variant, val] = decodeResult(raw);
  if (variant === "get_status_result_v0") {
    const lib = Number(val.last_irreversible.block_num);
    const start = START > 0 ? START : lib;
    console.log(`[ship] status: LIB=${lib}, streaming irreversible from ${start}`);
    send(ws, "get_blocks_request_v0", {
      start_block_num: start,
      end_block_num: 0xffffffff,
      max_messages_in_flight: 1,
      have_positions: [],
      irreversible_only: true, // fork-safe: only finalized blocks
      fetch_block: false,
      fetch_traces: false,
      fetch_deltas: true,
    });
  } else if (variant === "get_blocks_result_v0") {
    if (!val.this_block) { send(ws, "get_blocks_ack_request_v0", { num_messages: 1 }); return; }
    // Serialize block application: onmessage is sync-fired, but applyBlock awaits chain-API + overlay
    // writes over a single keepAlive WormWire socket. Running them concurrently would interleave
    // frames on that socket. Chain through a promise tail so blocks apply strictly in order.
    applyTail = applyTail
      .then(() => applyBlock(val, ws))
      .catch((e) => { console.log(`[ship] applyBlock error:`, (e as Error).message); send(ws, "get_blocks_ack_request_v0", { num_messages: 1 }); });
  }
};
ws.onerror = (e: any) => console.log("[ship] WS error:", e?.message ?? e);
ws.onclose = () => { console.log("[ship] closed"); process.exit(0); };
console.log(`[ship] connecting ${SHIP} (chain=${CHAIN}, overlay->:${PORT})`);
