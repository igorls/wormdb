#!/usr/bin/env bun
// Minimal diagnostic: run one VBULKINSERT against the docker wormdb to
// narrow down where the harness hangs.

import { WormClient } from "../../../apps/bun/src/lib/client";

const host = process.env.WORMDB_HOST ?? "wormdb";
const port = Number(process.env.WORMDB_PORT ?? 6389);

console.log(`Connecting to ${host}:${port}`);
const c = new WormClient({ host, port, keepAlive: true, timeoutMs: 10000 });

try {
  console.log("1. single vinsert (sanity)");
  const v = new Uint8Array(512);
  const r1 = await c.vinsertNative("vec:probe:0", v, { namespace: "vec:probe:", metric: "l2", worm: false });
  console.log("   resp:", JSON.stringify(r1));

  console.log("2. small vbulkinsert (4 items)");
  const items4 = Array.from({ length: 4 }, (_, i) => ({ key: `vec:probe4:${i}`, vector: new Uint8Array(512) }));
  const r2 = await c.vbulkinsertNative(items4, { namespace: "vec:probe4:", metric: "l2", worm: false, async: false });
  console.log("   resp:", JSON.stringify(r2));

  console.log("3. medium vbulkinsert (64 items)");
  const items64 = Array.from({ length: 64 }, (_, i) => ({ key: `vec:probe64:${i}`, vector: new Uint8Array(512) }));
  const r3 = await c.vbulkinsertNative(items64, { namespace: "vec:probe64:", metric: "l2", worm: false, async: false });
  console.log("   resp:", JSON.stringify(r3));

  // Simulate the harness's actual load: ~400 bulk calls of 256 items each
  // in the same namespace (= 100k total) to see when it breaks.
  console.log("4. sustained vbulkinsert (400 × 256 items = 100k)");
  const NS = "vec:sustained:";
  for (let batch = 0; batch < 400; batch += 1) {
    const items = Array.from({ length: 256 }, (_, i) => ({
      key: `${NS}${batch * 256 + i}`,
      vector: new Uint8Array(512),
    }));
    const t0 = performance.now();
    try {
      const r = await c.vbulkinsertNative(items, { namespace: NS, metric: "l2", worm: false, async: false });
      if (r.type !== "ok") {
        console.error(`   batch ${batch}: ${r.type}`);
        break;
      }
      const dt = performance.now() - t0;
      if (batch % 20 === 0 || dt > 200) {
        console.log(`   batch ${batch}: ok in ${dt.toFixed(0)}ms`);
      }
    } catch (e) {
      console.error(`   batch ${batch} FAILED: ${e instanceof Error ? e.message : String(e)}`);
      break;
    }
  }

  console.log("DONE");
} catch (e) {
  console.error("FAILED:", e instanceof Error ? e.message : String(e));
  process.exit(1);
}

await c.close();
