#!/usr/bin/env bun
// Load Libre balances into WormDB for the Light-API prototype.
// Reads a TSV (scope\tcode\tsymbol\tdecimals\tamount), groups by account, and SETs
//   bal:libre:<account> -> "<contract>\t<symbol>\t<decimals>\t<amount>\n..."  (packed, O(1) per-account)
// plus lacfg:libre -> the chain{} block.
import { WormClient } from "../lib/client";

const PORT = Number(Bun.env.PORT ?? 6389);
const FILE = Bun.argv[2] ?? "protodata/balances.tsv";

const text = await Bun.file(FILE).text();
const byAcct = new Map<string, string[]>();
for (const line of text.split("\n")) {
  if (!line) continue;
  const tab = line.indexOf("\t");
  if (tab < 0) continue;
  const scope = line.slice(0, tab);
  const rest = line.slice(tab + 1); // "code\tsymbol\tdec\tamount"
  const arr = byAcct.get(scope) ?? [];
  arr.push(rest);
  byAcct.set(scope, arr);
}
console.log(`accounts: ${byAcct.size}`);

const chainJson =
  '{"network":"libre","sync":0,"decimals":4,"systoken":"LIBRE",' +
  '"chainid":"38b1d7815474d0c60683ecbea321d723e83f5da6ae5f1c1f9fecc69d9ba96465",' +
  '"production":1,"block_num":245975500,"block_time":"","description":"Libre","rex_enabled":0}';

const c = new WormClient({ host: "127.0.0.1", port: PORT, keepAlive: true, timeoutMs: 60_000 });
await c.sendCommand({ kind: "SET", key: "lacfg:libre", value: chainJson, worm: false });

const entries = [...byAcct.entries()];
const DEPTH = 256;
const t0 = Bun.nanoseconds();
let done = 0;
for (let i = 0; i < entries.length; i += DEPTH) {
  const batch = entries.slice(i, i + DEPTH);
  const rs = await Promise.all(
    batch.map(([acct, arr]) =>
      c.sendCommand({ kind: "SET", key: `bal:libre:${acct}`, value: arr.join("\n"), worm: false }),
    ),
  );
  for (const r of rs) if (r.type === "error") throw new Error(`SET failed: ${r.message}`);
  done += batch.length;
}
const wall = (Bun.nanoseconds() - t0) / 1e6;
console.log(`loaded ${done} accounts in ${wall.toFixed(0)}ms (${((done / wall) * 1000).toFixed(0)} sets/s)`);
await c.close();
