#!/usr/bin/env bun
// Docker multi-node vsearch scatter-gather smoke (wormdb#67, epic #68).
//
// Topology: the repo's 6-node compose cluster (embedded meshguard, SWIM
// discovery chain, --cluster-open), host ports 26389..26394 -> 6389.
//
// Bring-up (repo root; the Dockerfile copies a Linux binary from zig-out):
//   zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast -Dcrypto-backend=std
//   docker build -t wormdb:latest . && docker compose up -d
//   bun run apps/bun/src/bin/scatter-smoke.ts
//
// Re-runnable against a warm cluster (WORM re-inserts tolerated).
//
// Proof structure:
//   1. SWIM convergence — coordinator (node4) sees 5 peers.
//   2. Corpus written on node1 (vec:smoke:0..5 + query key vec:smoke:q,
//      all INSIDE the namespace), replication carries it cluster-wide.
//   3. Scatter proof — vsearch_cluster from node4 with include_self=0:
//      every returned item must carry src:"peer", i.e. it traveled
//      node4 -> peer (vsearch_local_raw over the replication channel) -> back.
//   4. Merged-path proof — default include_self from node1: local+peer
//      dedup, correct nearest neighbor at rank 1.
//   5. Self-exclusion live (the c170cfc HNSW fix) — the query key never
//      appears, cluster path or plain vsearch, though it is stored and
//      indexed in the searched namespace on every node.
import { WormDB } from "../lib/wormdb";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const f32 = (v: number[]) => new Uint8Array(new Float32Array(v).buffer);

let failures = 0;
function check(label: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"}: ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures++;
}

const writer = new WormDB({ host: "127.0.0.1", port: 26389, timeoutMs: 15000 }); // node1
const coord = new WormDB({ host: "127.0.0.1", port: 26392, timeoutMs: 15000 }); // node4
await writer.connect();
await coord.connect();

// ── 1. SWIM convergence on the coordinator ──────────────────────────
// (wormwire= in CLUSTER_PEERS is NOT a scatter-readiness signal — peer
// connections establish on demand, so a node that never originated a
// write shows disconnected even while its scatter serves 5/5. Readiness
// for scatter is handled below by retrying while partial=true.)
let alive = 0;
let peersRaw = "";
for (let i = 0; i < 90; i++) {
  peersRaw = await coord.clusterPeers();
  alive = peersRaw.split("---").slice(1).filter((b) => b.includes("state=alive")).length;
  if (alive >= 5) break;
  await sleep(1000);
}
console.log(`CLUSTER_PEERS on node4 after convergence wait:\n${peersRaw.trim()}\n`);
check("SWIM convergence: node4 sees 5 alive peers", alive >= 5, `alive ${alive}`);

// ── 2. Corpus on node1: 6 near-orthogonal vectors + in-namespace query ──
// e3 is the planted nearest neighbor of the query.
const dim = 8;
const corpus: number[][] = [];
for (let i = 0; i < 6; i++) {
  const v = new Array(dim).fill(0.01);
  v[i] = 1.0;
  corpus.push(v);
}
const query = new Array(dim).fill(0.02);
query[3] = 0.95; // closest to corpus[3] under cosine

// Native VINSERT takes the FULL key (must carry the namespace prefix —
// keyBelongsToNamespace), unlike EXEC vinsert which builds it from an id.
// Vectors are WORM; tolerate already-exists so the smoke is re-runnable
// against a warm cluster.
async function vinsertIdempotent(key: string, bytes: Uint8Array) {
  try {
    await writer.vinsert(key, bytes, { namespace: "vec:smoke:", metric: "cosine" });
  } catch (e) {
    // EXEC path says "already exists"; native VINSERT says "WORM violation".
    if (!(e instanceof Error && (e.message.includes("already exists") || e.message.includes("WORM violation")))) throw e;
  }
}
for (let i = 0; i < 6; i++) await vinsertIdempotent(`vec:smoke:smoke-${i}`, f32(corpus[i]));
await vinsertIdempotent("vec:smoke:smoke-q", f32(query));

// ── Wait for replication to reach the coordinator ───────────────────
let replicated = false;
for (let i = 0; i < 60; i++) {
  if ((await coord.get("vec:smoke:smoke-q")) !== null) {
    replicated = true;
    break;
  }
  await sleep(500);
}
check("replication: query key reached node4", replicated);

// ── 3. Scatter proof: include_self=0 from node4 ─────────────────────
// <query_key> <top_k> [ns] [metric] [decay] [mode] [tau] [max_peers] [include_self]
// partial=true is the server's honest cold-connection signal (peer conns
// establish on demand) — the consumer contract is retry-on-partial.
type ClusterResult = {
  items: { k: string; s: number; ts: number; src: "local" | "peer" }[];
  peers_queried: number;
  peers_failed: number;
  partial: boolean;
};
let scatterRaw = "";
let scatter!: ClusterResult;
for (let attempt = 1; attempt <= 10; attempt++) {
  scatterRaw = await coord.exec(
    "vsearch_cluster",
    "vec:smoke:smoke-q", "5", "vec:smoke:", "cosine", "0", "auto", "168", "5", "0",
  );
  scatter = JSON.parse(scatterRaw) as ClusterResult;
  if (!scatter.partial) {
    if (attempt > 1) console.log(`(scatter clean on attempt ${attempt})`);
    break;
  }
  await sleep(1000);
}
console.log(`\nvsearch_cluster include_self=0 from node4:\n${scatterRaw}\n`);
check("scatter: peers queried", scatter.peers_queried >= 1, `peers_queried=${scatter.peers_queried}`);
check("scatter: no peer failures / not partial", scatter.peers_failed === 0 && !scatter.partial);
check("scatter: results returned", scatter.items.length > 0, `${scatter.items.length} items`);
check("scatter: every hit served by a PEER (src=peer)", scatter.items.every((it) => it.src === "peer"));
check("scatter: planted neighbor at rank 1", scatter.items[0]?.k === "vec:smoke:smoke-3", `got ${scatter.items[0]?.k}`);
check("scatter: self-hit excluded (c170cfc live)", !scatter.items.some((it) => it.k === "vec:smoke:smoke-q"));

// ── 4. Merged path: default include_self from node1 ─────────────────
const mergedRaw = await writer.exec("vsearch_cluster", "vec:smoke:smoke-q", "5", "vec:smoke:");
const merged = JSON.parse(mergedRaw) as typeof scatter;
console.log(`\nvsearch_cluster defaults from node1:\n${mergedRaw}\n`);
check("merged: peers queried", merged.peers_queried >= 1, `peers_queried=${merged.peers_queried}`);
check("merged: planted neighbor at rank 1", merged.items[0]?.k === "vec:smoke:smoke-3", `got ${merged.items[0]?.k}`);
check("merged: dedup holds (no duplicate keys)", new Set(merged.items.map((i) => i.k)).size === merged.items.length);
check("merged: self-hit excluded", !merged.items.some((it) => it.k === "vec:smoke:smoke-q"));

// ── 5. Plain vsearch through the fixed a095d8b wrapper on node4 ─────
const local = await coord.vsearch("vec:smoke:smoke-q", 5, { namespace: "vec:smoke:", metric: "cosine" });
console.log(`plain vsearch (fixed wrapper) on node4: ${JSON.stringify(local)}\n`);
check("wrapper: opts search returns hits (a095d8b live)", local.length > 0);
check("wrapper: planted neighbor at rank 1", local[0]?.k === "vec:smoke:smoke-3", `got ${local[0]?.k}`);
check("wrapper: self-hit excluded", !local.some((h) => h.k === "vec:smoke:smoke-q"));

await writer.close();
await coord.close();

console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
