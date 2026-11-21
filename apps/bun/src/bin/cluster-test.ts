#!/usr/bin/env bun
// WormDB 3-Node Cluster Test
//
// Validates replication, WORM enforcement, DEL propagation, and cluster
// status against a running 3-node WormDB cluster (docker-compose.cluster-test.yml).
//
// Topology: 3 nodes, host ports 26389 (node1), 26390 (node2), 26391 (node3).
// node1 is the seed; node2 and node3 both join via --seed node1:51821.
//
// Prerequisites:
//   docker compose -f docker-compose.cluster-test.yml up -d
//
// Usage:
//   bun run apps/bun/src/bin/cluster-test.ts
//
// Re-runnable against a warm cluster (uses unique keys per run via timestamp).

import { WormDB } from "../lib/wormdb";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const NODES = [
  { name: "node1", host: "127.0.0.1", port: 26389 },
  { name: "node2", host: "127.0.0.1", port: 26390 },
  { name: "node3", host: "127.0.0.1", port: 26391 },
] as const;

const TIMEOUT = 15000;
// Unique key prefix so re-runs against a warm cluster don't collide.
const RUN_ID = `${Date.now().toString(36)}`;

let failures = 0;
let checks = 0;
function check(label: string, ok: boolean, detail = ""): void {
  checks++;
  console.log(`  ${ok ? "PASS" : "FAIL"}: ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures++;
}

// ── Connect to all 3 nodes ──────────────────────────────────────────
console.log("\n=== WormDB 3-Node Cluster Test ===\n");

const clients = await Promise.all(
  NODES.map(async (n) => {
    const c = new WormDB({ host: n.host, port: n.port, timeoutMs: TIMEOUT });
    await c.connect();
    return { name: n.name, client: c };
  }),
);
console.log("Connected to all 3 nodes.");

// Helper: get a client by node name
function clientFor(name: string): WormDB {
  const entry = clients.find((c) => c.name === name);
  if (!entry) throw new Error(`unknown node: ${name}`);
  return entry.client;
}

// ── 1. SWIM convergence ─────────────────────────────────────────────
console.log("\n--- Phase 1: SWIM Convergence ---");

let converged = false;
let peersRaw = "";
for (let i = 0; i < 90; i++) {
  peersRaw = await clientFor("node1").clusterPeers();
  const alive = peersRaw.split("---").slice(1).filter((b) => b.includes("state=alive")).length;
  if (alive >= 2) {
    converged = true;
    console.log(`  Converged after ~${i}s — ${alive} alive peers on node1.`);
    break;
  }
  await sleep(1000);
}
console.log(`  CLUSTER_PEERS on node1:\n${peersRaw.trim().replace(/^/gm, "    ")}`);
check("SWIM convergence: node1 sees 2 alive peers", converged);

// CLUSTER STATUS on all nodes
for (const { name, client } of clients) {
  try {
    const status = await client.clusterStatus();
    check(`CLUSTER STATUS on ${name} responds`, status.length > 0, status.slice(0, 80));
  } catch (e) {
    check(`CLUSTER STATUS on ${name} responds`, false, String(e));
  }
}

// ── 2. SET replication ──────────────────────────────────────────────
console.log("\n--- Phase 2: SET Replication ---");

const setKey = `ctest:${RUN_ID}:set`;
const setVal = `replicated-value-${RUN_ID}`;
await clientFor("node1").set(setKey, setVal);
console.log(`  SET ${setKey} = "${setVal}" on node1`);

for (const { name, client } of clients) {
  let replicated = false;
  let lastVal: string | null = null;
  for (let i = 0; i < 60; i++) {
    lastVal = await client.get(setKey);
    if (lastVal === setVal) {
      replicated = true;
      break;
    }
    await sleep(500);
  }
  check(`SET replicated to ${name}`, replicated, `got "${lastVal}"`);
}

// ── 3. WORM mode enforcement ────────────────────────────────────────
console.log("\n--- Phase 3: WORM Mode ---");

const wormKey = `ctest:${RUN_ID}:worm`;
const wormVal = `immutable-${RUN_ID}`;
await clientFor("node2").set(wormKey, wormVal, { worm: true });
console.log(`  SET ${wormKey} = "${wormVal}" WORM on node2`);

// Wait for WORM key to replicate to node1
let wormReplicated = false;
for (let i = 0; i < 60; i++) {
  if ((await clientFor("node1").get(wormKey)) === wormVal) {
    wormReplicated = true;
    break;
  }
  await sleep(500);
}
check("WORM key replicated to node1", wormReplicated);

// Attempt overwrite on node1 — should fail
let wormViolation = false;
try {
  await clientFor("node1").set(wormKey, "overwritten");
} catch (e) {
  wormViolation = true;
}
check("WORM violation rejected on node1 (overwrite attempt)", wormViolation);

// Verify the original value is intact on all nodes
for (const { name, client } of clients) {
  let val: string | null = null;
  for (let i = 0; i < 30; i++) {
    val = await client.get(wormKey);
    if (val === wormVal) break;
    await sleep(500);
  }
  check(`WORM value intact on ${name}`, val === wormVal, `got "${val}"`);
}

// ── 4. DEL replication ──────────────────────────────────────────────
console.log("\n--- Phase 4: DEL Replication ---");

const delKey = `ctest:${RUN_ID}:del`;
const delVal = `deletable-${RUN_ID}`;
await clientFor("node3").set(delKey, delVal);
console.log(`  SET ${delKey} = "${delVal}" on node3`);

// Wait for it to replicate to node1
for (let i = 0; i < 60; i++) {
  if ((await clientFor("node1").get(delKey)) === delVal) break;
  await sleep(500);
}

await clientFor("node1").del(delKey);
console.log(`  DEL ${delKey} on node1`);

for (const { name, client } of clients) {
  let deleted = false;
  for (let i = 0; i < 60; i++) {
    const val = await client.get(delKey);
    if (val === null) {
      deleted = true;
      break;
    }
    await sleep(500);
  }
  check(`DEL replicated to ${name}`, deleted);
}

// ── 5. Write on each node, read from all ─────────────────────────────
console.log("\n--- Phase 5: Multi-Writer Replication ---");

for (let i = 0; i < 3; i++) {
  const writer = clients[i];
  const key = `ctest:${RUN_ID}:multi-${i}`;
  const val = `from-${writer.name}-${RUN_ID}`;
  await writer.client.set(key, val);
  console.log(`  SET ${key} = "${val}" on ${writer.name}`);

  for (const { name, client } of clients) {
    let replicated = false;
    for (let j = 0; j < 60; j++) {
      if ((await client.get(key)) === val) {
        replicated = true;
        break;
      }
      await sleep(500);
    }
    check(`${writer.name}→${name} replication`, replicated);
  }
}

// ── Cleanup ─────────────────────────────────────────────────────────
for (const { client } of clients) await client.close();

console.log(`\n${checks - failures}/${checks} checks passed.`);
if (failures > 0) {
  console.error(`\n${failures} CHECK(S) FAILED`);
  process.exit(1);
}
console.log("\nAll cluster replication checks passed.");
