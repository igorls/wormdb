#!/usr/bin/env bun
/**
 * REST API Backend for WormDB Browser Benchmark — "Classic" lane.
 *
 * Proxies key-value operations through an HTTP API, simulating the traditional
 * Client → REST API → Database → REST API → Client roundtrip.
 *
 * Endpoints:
 *   GET    /api/kv/:key          → WormDB GET
 *   POST   /api/kv/:key  {value} → WormDB SET
 *   DELETE /api/kv/:key          → WormDB DEL
 *   GET    /api/status           → WormDB STATUS
 */

import { WormClient } from "../../bun/src/lib/client";

const WORMDB_HOST = process.env.WORMDB_HOST || "127.0.0.1";
const WORMDB_PORT = parseInt(process.env.WORMDB_PORT || "6389");
const PORT = parseInt(process.env.API_PORT || "8082");

const cors = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
};

const client = new WormClient({
    host: WORMDB_HOST,
    port: WORMDB_PORT,
    timeoutMs: 5000,
    keepAlive: true,
});

Bun.serve({
    port: PORT,
    async fetch(req) {
        const url = new URL(req.url);

        if (req.method === "OPTIONS") {
            return new Response(null, { status: 204, headers: cors });
        }

        // GET /api/status
        if (url.pathname === "/api/status" && req.method === "GET") {
            try {
                const resp = await client.send("STATUS");
                return Response.json({ ok: true, data: resp }, { headers: cors });
            } catch (err: any) {
                return Response.json(
                    { ok: false, error: err.message },
                    { status: 502, headers: cors },
                );
            }
        }

        // Match /api/kv/:key
        const kvMatch = url.pathname.match(/^\/api\/kv\/(.+)$/);
        if (!kvMatch) {
            return Response.json({ error: "not found" }, { status: 404, headers: cors });
        }

        const key = decodeURIComponent(kvMatch[1]);

        try {
            if (req.method === "GET") {
                const resp = await client.send(`GET ${key}`);
                return Response.json({ ok: true, data: resp }, { headers: cors });
            }

            if (req.method === "POST") {
                const body = await req.json();
                const value = body.value ?? "";
                const resp = await client.send(`SET ${key} ${value}`);
                return Response.json({ ok: true, data: resp }, { headers: cors });
            }

            if (req.method === "DELETE") {
                const resp = await client.send(`DEL ${key}`);
                return Response.json({ ok: true, data: resp }, { headers: cors });
            }

            return Response.json({ error: "method not allowed" }, { status: 405, headers: cors });
        } catch (err: any) {
            return Response.json(
                { ok: false, error: err.message },
                { status: 502, headers: cors },
            );
        }
    },
});

console.log(`\n  📡 API Backend: http://localhost:${PORT}`);
console.log(`     WormDB upstream: ${WORMDB_HOST}:${WORMDB_PORT}`);
console.log(`     GET    /api/kv/:key`);
console.log(`     POST   /api/kv/:key  { value }`);
console.log(`     DELETE /api/kv/:key`);
console.log(`     GET    /api/status\n`);
