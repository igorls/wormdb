#!/usr/bin/env bun
// Thin HTTP front for the WormDB Light-API prototype: GET /api/balances/:chain/:acct -> EXEC.
// A pool of keepAlive WormWire clients is round-robined across requests.
import { WormClient } from "../lib/client";

const HTTP_PORT = Number(Bun.env.HTTP_PORT ?? 7100);
const WORM_PORT = Number(Bun.env.WORM_PORT ?? 6389);
const POOL = Number(Bun.env.POOL ?? 32);

const pool = Array.from({ length: POOL }, () =>
  new WormClient({ host: "127.0.0.1", port: WORM_PORT, keepAlive: true, timeoutMs: 30_000 }),
);
let rr = 0;

const re = /^\/api\/balances\/([^/]+)\/([^/]+)$/;

Bun.serve({
  port: HTTP_PORT,
  async fetch(req) {
    const m = new URL(req.url).pathname.match(re);
    if (!m) return new Response("not found", { status: 404 });
    const c = pool[(rr = (rr + 1) % POOL)];
    const r = await c.sendCommand({ kind: "EXEC", procedure: "lightapi_balances", args: [m[1]!, m[2]!] });
    if (r.type === "bulk") {
      return new Response(r.value, { headers: { "content-type": "application/json" } });
    }
    if (r.type === "error") return new Response(r.message, { status: 500 });
    return new Response("null", { status: 404 });
  },
});
console.log(`lightapi-http shim on :${HTTP_PORT} (pool=${POOL} -> wormdb :${WORM_PORT})`);
