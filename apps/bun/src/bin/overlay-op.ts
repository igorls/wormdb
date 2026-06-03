#!/usr/bin/env bun
// Tiny overlay mutator — simulates a live feed by writing/removing WormDB KV overlay entries.
//   bun overlay-op.ts set <key> <value>
//   bun overlay-op.ts del <key>
// An overlay key (bal:<chain>:<acct>, acci:<chain>:<acct>, sync:<chain>, …) shadows the frozen
// segment baseline; removing it reverts to the segment.
import { WormClient } from "../lib/client";

const PORT = Number(Bun.env.PORT ?? 16489);
const HOST = Bun.env.HOST ?? "127.0.0.1";
const [op, key, value] = Bun.argv.slice(2);

const c = new WormClient({ host: HOST, port: PORT, keepAlive: false, timeoutMs: 30_000 });
if (op === "set") {
  await c.sendCommand({ kind: "SET", key, value: value ?? "", worm: false });
  console.log(`set ${key} = ${JSON.stringify(value ?? "")}`);
} else if (op === "del") {
  await c.sendCommand({ kind: "DEL", key });
  console.log(`del ${key}`);
} else {
  console.error("usage: set <key> <value> | del <key>");
  process.exit(1);
}
await c.close();
