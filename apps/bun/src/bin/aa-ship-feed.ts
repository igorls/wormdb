#!/usr/bin/env bun
// aa-ship-feed.ts — keep WormDB's AtomicAssets overlay fresh straight from a nodeos SHiP websocket.
// NO MongoDB, NO Hyperion: the node is the only dependency. Mirrors lightapi-ship-feed.ts.
//
// SHiP streams which contract_rows changed each irreversible block. We look at the `atomicassets`
// `assets` table deltas: a present=true row (mint / transfer-in / setdata) and a present=false row
// (transfer-out / burn). For each touched asset we re-render its CURRENT state from the chain API
// (get_table_rows) and apply it to the overlay by EXEC-ing the AA apply procedures over WormWire
// (aa_mint / aa_burn) — those maintain the forward override + owner/collection/schema/template/global
// add-sets. SHiP is the change-notifier; the chain API is the renderer; the procs are the writers.
//
// Fork-safety: irreversible_only stream → applied state never needs rollback. A per-block checkpoint
// (aa:meta:block:<chain>) lets a restart resume past the snapshot block without re-applying from genesis.
//
//   bun aa-ship-feed.ts   ENV: SHIP CHAIN_API CHAIN PORT WORMHOST START AA_CONTRACT
import { ABI, Serializer } from "@wharfkit/antelope";
import { WormClient } from "../lib/client";

function decode(abi: ABI, type: string, data: Uint8Array): any {
  return Serializer.objectify(Serializer.decode({ abi, type, data }));
}

const SHIP = Bun.env.SHIP ?? "ws://127.0.0.1:28080/";
const CHAIN_API = Bun.env.CHAIN_API ?? "http://127.0.0.1:28888"; // nodeos http
const CHAIN = Bun.env.CHAIN ?? "jungle4";
// PORT is the WormWire port the OVERLAY is written to (the published host port when dockerized).
const PORT = Number(Bun.env.PORT ?? 6389);
const WORMHOST = Bun.env.WORMHOST ?? "127.0.0.1";
const AA_CONTRACT = Bun.env.AA_CONTRACT ?? "atomicassets";
const START = Number(Bun.env.START ?? 0); // checkpoint wins; else this; else LIB head

const worm = new WormClient({ host: WORMHOST, port: PORT, keepAlive: true, timeoutMs: 60_000 });
const set = (k: string, v: string) => worm.sendCommand({ kind: "SET", key: k, value: v, worm: false });
const execProc = async (procedure: string, args: string[]) => {
  // WormClient resolves an ERR response to {type:"error"} rather than throwing — surface it so a failed
  // aa_mint/aa_burn isn't silently treated as applied (which would advance the checkpoint + ACK past it).
  const r: any = await worm.sendCommand({ kind: "EXEC", procedure, args });
  if (r?.type === "error") throw new Error(`EXEC ${procedure} -> ${r.value ?? r.message ?? r.error ?? "ERR"}`);
  return r;
};
async function getKey(k: string): Promise<string | null> {
  const r = await worm.sendCommand({ kind: "GET", key: k });
  const v = (r as any)?.value ?? (r as any)?.data ?? null;
  return v == null || v === "" ? null : String(v);
}

let infoCache: { at: number; info: any } | null = null;
async function chainInfo(): Promise<any> {
  const now = Date.now();
  if (infoCache && now - infoCache.at < 1000) return infoCache.info;
  const r = await fetch(`${CHAIN_API}/v1/chain/get_info`, { method: "POST", headers: { Host: "127.0.0.1" } });
  const info = await r.json();
  infoCache = { at: now, info };
  return info;
}
async function chain(path: string, body: unknown): Promise<any> {
  // nodeos http-validate-host rejects an unknown Host; force 127.0.0.1 regardless of the dialed host.
  const r = await fetch(`${CHAIN_API}/v1/chain/${path}`, {
    method: "POST",
    headers: { Host: "127.0.0.1", "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return r.json();
}

// Fetch one atomicassets `assets` row (current state) by owner-scope + asset_id.
async function assetRow(owner: string, assetId: string): Promise<any | null> {
  const res = await chain("get_table_rows", {
    code: AA_CONTRACT,
    scope: owner,
    table: "assets",
    lower_bound: assetId,
    upper_bound: assetId,
    key_type: "i64",
    index_position: "primary",
    limit: 1,
    json: true,
  });
  const rows = res?.rows ?? [];
  return rows.length ? rows[0] : null;
}

// ── SHiP client ──
let abi: ABI;
function send(ws: WebSocket, requestType: string, data: any) {
  const bytes = Serializer.encode({ abi, type: "request", object: [requestType, data] });
  ws.send(bytes.array);
}
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
let firstSync = true;
let applyTail: Promise<void> = Promise.resolve(); // serialize block application over the one WormWire socket

async function applyBlock(blk: any, ws: WebSocket) {
  const bnum = Number(blk.this_block?.block_num ?? 0);
  // Per block: present=true assets (mint / transfer-in / setdata) keyed by asset_id -> current owner
  // (scope); present=false asset_ids (transfer-out / burn). An id with a present=true is a move/update
  // (handled by re-emitting aa_mint with current state); a present=false-only id is a burn.
  const present = new Map<string, string>(); // asset_id -> owner (last writer wins within the block)
  const removed = new Set<string>();
  const deltas: any[] = blk.deltas ? decode(abi, "table_delta[]", hexOrBytes(blk.deltas)) : [];
  for (const elem of deltas) {
    const d = Array.isArray(elem) ? elem[1] : elem;
    if (d?.name !== "contract_row") continue;
    for (const row of d.rows ?? []) {
      const cr0 = decode(abi, "contract_row", hexOrBytes(row.data));
      const v = Array.isArray(cr0) ? cr0[1] : cr0;
      if (String(v.code) !== AA_CONTRACT || String(v.table) !== "assets") continue;
      const assetId = String(v.primary_key);
      if (row.present) present.set(assetId, String(v.scope));
      else removed.add(assetId);
    }
  }
  let mints = 0;
  let transfers = 0;
  let burns = 0;
  for (const [assetId, owner] of present) {
    if (removed.has(assetId)) {
      // TRANSFER: old-owner present=false + new-owner present=true. aa_transfer PRESERVES the existing
      // forward record (block_num, template_mint, immutable/mutable data) and only moves the owner +
      // owner add-sets — unlike aa_mint, which would reset those to the transfer block / 0.
      try { await execProc("aa_transfer", [assetId, owner]); transfers++; continue; } catch (e) {
        // ONLY a verified "asset not known yet" (a mint+transfer in the SAME block) falls back to minting.
        // Any other failure (transient WormWire timeout, proc/config error, internal EXEC error) must
        // propagate so the block retries — falling through to aa_mint otherwise would reintroduce the very
        // metadata reset aa_transfer exists to avoid, for a real transfer of an existing asset.
        if (!/unknown or burned/i.test((e as Error).message)) throw e;
      }
    }
    const r = await assetRow(owner, assetId);
    if (!r) continue; // raced (already moved/burned) — a later block's delta will correct it
    await execProc("aa_mint", [
      assetId,
      owner,
      String(r.collection_name ?? ""),
      String(r.schema_name ?? ""),
      String(r.template_id ?? -1),
      String(bnum),
      "0", // template_mint: derived from mint order (action traces) — left 0 in the structural feed
    ]);
    mints++;
  }
  for (const assetId of removed) {
    if (present.has(assetId)) continue; // present elsewhere this block => move, not a burn
    await execProc("aa_burn", [assetId]);
    burns++;
  }

  if (bnum > head) head = bnum;
  // freshness stamps (request-time /sync), anchored to the node head like the lightapi feed
  const headInfo = await chainInfo();
  if (headInfo?.head_block_time) {
    const headMs = Date.parse(headInfo.head_block_time + "Z");
    const ms = headMs - (Number(headInfo.head_block_num) - bnum) * 500;
    await set(`synctime:${CHAIN}`, String(ms));
    await set(`syncblock:${CHAIN}`, String(bnum));
    await set("syncchains", CHAIN);
    if (firstSync) { await set(`syncthr:${CHAIN}`, "240"); firstSync = false; }
  }
  await set(`aa:meta:block:${CHAIN}`, String(bnum)); // resume checkpoint (only reached if all EXECs applied)
  if (mints || transfers || burns) console.log(`[aa-ship] block ${bnum} mint=${mints} xfer=${transfers} burn=${burns}`);
  send(ws, "get_blocks_ack_request_v0", { num_messages: 1 });
}

const ws = new WebSocket(SHIP);
ws.binaryType = "arraybuffer";
ws.onmessage = async (ev) => {
  if (typeof ev.data === "string") {
    abi = ABI.from(JSON.parse(ev.data));
    console.log(`[aa-ship] ABI received; requesting status`);
    send(ws, "get_status_request_v0", {});
    return;
  }
  const raw = new Uint8Array(ev.data as ArrayBuffer);
  const [variant, val] = decodeResult(raw);
  if (variant === "get_status_result_v0") {
    const lib = Number(val.last_irreversible.block_num);
    const checkpoint = await getKey(`aa:meta:block:${CHAIN}`);
    const start = checkpoint ? Number(checkpoint) + 1 : START > 0 ? START : lib;
    console.log(`[aa-ship] status: LIB=${lib}; resume from ${start}${checkpoint ? ` (checkpoint ${checkpoint})` : ""}`);
    send(ws, "get_blocks_request_v0", {
      start_block_num: start,
      end_block_num: 0xffffffff,
      max_messages_in_flight: 1,
      have_positions: [],
      irreversible_only: true,
      fetch_block: false,
      fetch_traces: false,
      fetch_deltas: true,
    });
  } else if (variant === "get_blocks_result_v0") {
    if (!val.this_block) { send(ws, "get_blocks_ack_request_v0", { num_messages: 1 }); return; }
    // applyBlock is idempotent (re-decode + re-EXEC; aa_mint/transfer/burn overwrite/dedupe; the
    // checkpoint + ACK are its LAST step, only reached on full success). On error, retry the same block
    // a few times, then HALT (no ACK, no checkpoint advance) rather than silently skipping it — a skipped
    // mint/burn would be lost until a segment rebuild. The operator fixes the cause and restarts (resumes
    // from the checkpoint).
    const bn = Number(val.this_block?.block_num ?? 0);
    applyTail = applyTail.then(async () => {
      for (let attempt = 1; attempt <= 5; attempt++) {
        try { await applyBlock(val, ws); return; } catch (e) {
          console.log(`[aa-ship] block ${bn} apply failed (attempt ${attempt}/5): ${(e as Error).message}`);
          if (attempt < 5) await new Promise((r) => setTimeout(r, 500 * attempt));
        }
      }
      console.log(`[aa-ship] HALTED at block ${bn} — not ACKing/checkpointing (avoids silent loss); fix + restart.`);
    });
  }
};
ws.onerror = (e: any) => console.log("[aa-ship] WS error:", e?.message ?? e);
ws.onclose = () => { console.log("[aa-ship] closed"); process.exit(0); };
console.log(`[aa-ship] connecting ${SHIP} (chain=${CHAIN}, contract=${AA_CONTRACT}, overlay->${WORMHOST}:${PORT})`);
