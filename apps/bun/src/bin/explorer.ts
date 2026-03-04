#!/usr/bin/env bun
/**
 * WormDB KV Explorer — Server
 *
 * HTTP + WebSocket server that routes all data mutations through
 * custom EXEC procedures (kv_put, kv_get, kv_stats).
 */
import { WormClient } from "../lib/client";
import {
    WIRE_MAGIC,
    concatBytes,
    decodeResponse,
    encodeCommandFrame,
    isEventCode,
    toBytes,
    tryConsumeFrame,
    type Bytes,
} from "../lib/wire";
import path from "node:path";
import type { ServerWebSocket } from "bun";

const HOST = process.env.WORMDB_HOST ?? "127.0.0.1";
const PORT = Number(process.env.WORMDB_PORT ?? "6389");
const UI_PORT = Number(process.env.EXPLORER_PORT ?? "8082");
const UI_DIR = path.resolve(import.meta.dir, "../explorer");

function getClient() {
    return new WormClient({ host: HOST, port: PORT, timeoutMs: 3000 });
}

// ── Build Frontend ──────────────────────────────────────────

const htmlText = await Bun.file(path.join(UI_DIR, "index.html")).text();
const cssText = await Bun.file(path.join(UI_DIR, "styles.css")).text();
const buildResult = await Bun.build({
    entrypoints: [path.join(UI_DIR, "app.ts")],
    target: "browser",
    minify: false,
});
const appJsText = buildResult.success
    ? await buildResult.outputs[0].text()
    : "console.error('Build failed');";

// ── WebSocket Broadcasting ──────────────────────────────────

type WsData = { id: number };
const wsClients = new Set<ServerWebSocket<WsData>>();
let wsIdCounter = 0;

function broadcast(msg: object) {
    const payload = JSON.stringify(msg);
    for (const ws of wsClients) {
        try {
            ws.send(payload);
        } catch {
            wsClients.delete(ws);
        }
    }
}

// ── PUB/SUB Event Subscription ──────────────────────────────

type SocketData = string | ArrayBuffer | SharedArrayBuffer | ArrayBufferView;
let eventSocket: { write(data: SocketData): number; end(): void } | null = null;
let eventConnecting = false;
let eventInbound: Bytes = new Uint8Array(0);

function setupEventSubscription() {
    if (eventSocket || eventConnecting) return;
    eventConnecting = true;

    Bun.connect({
        hostname: HOST,
        port: PORT,
        socket: {
            open(socket) {
                eventConnecting = false;
                eventSocket = socket;
                eventInbound = new Uint8Array(0);
                socket.write(WIRE_MAGIC);
                socket.write(encodeCommandFrame({ kind: "SUB", channel: "kv_events" }));
                console.log("WS: subscribed to kv_events channel");
            },
            data(socket, chunk) {
                if (eventSocket !== socket) return;
                eventInbound = concatBytes([eventInbound, toBytes(chunk)]);

                while (true) {
                    const frame = tryConsumeFrame(eventInbound);
                    if (frame == null) return;
                    eventInbound = frame.remaining;
                    if (!isEventCode(frame.code)) continue;

                    const decoded = decodeResponse(frame.code, frame.payload);
                    if (decoded.type === "event" && decoded.channel === "kv_events") {
                        try {
                            const msg = JSON.parse(decoded.message);
                            broadcast(msg);
                        } catch {
                            /* ignore */
                        }
                    }
                }
            },
            close(socket) {
                if (eventSocket === socket) {
                    eventSocket = null;
                    setTimeout(setupEventSubscription, 3000);
                }
            },
            error(socket) {
                if (eventSocket && eventSocket === socket) {
                    eventSocket = null;
                    eventConnecting = false;
                    setTimeout(setupEventSubscription, 3000);
                }
            },
        },
    }).catch(() => {
        eventConnecting = false;
        eventSocket = null;
        setTimeout(setupEventSubscription, 3000);
    });
}

// ── Periodic Status + Stats Push ────────────────────────────

async function pushStatus() {
    try {
        const client = getClient();
        const response = await client.send("STATUS");
        if (response.type === "bulk" && response.value) {
            broadcast({ type: "status", response: { value: response.value } });
        }
    } catch {
        /* ignore */
    }
}

async function pushStats() {
    try {
        const client = getClient();
        const response = await client.send("EXEC kv_stats");
        if (response.type === "bulk" && response.value) {
            const kv = parseKV(response.value);
            broadcast({
                type: "stats",
                reads: parseInt(kv.reads || "0"),
                writes: parseInt(kv.writes || "0"),
            });
        }
    } catch {
        /* ignore */
    }
}

// ── KV Index Management ─────────────────────────────────────

async function getIndex(): Promise<{ key: string; locked: boolean }[]> {
    const client = getClient();
    const res = await client.send("GET kv:index");
    if (res.type === "bulk" && res.value) {
        try {
            const json = Buffer.from(res.value, "base64").toString("utf-8");
            return JSON.parse(json);
        } catch {
            return [];
        }
    }
    return [];
}

async function saveIndex(index: { key: string; locked: boolean }[]) {
    const client = getClient();
    const valueB64 = Buffer.from(JSON.stringify(index)).toString("base64");
    await client.send(`SET kv:index ${valueB64}`);
}

// ── Metadata Parser ─────────────────────────────────────────

function parseMeta(raw: string) {
    const kv = parseKV(raw);
    return {
        created: kv.created || "0",
        updated: kv.updated || "0",
        writes: parseInt(kv.writes || "0"),
        reads: parseInt(kv.reads || "0"),
    };
}

function parseKV(text: string): Record<string, string> {
    const kv: Record<string, string> = {};
    text.split("\n").forEach((line) => {
        const [key, ...rest] = line.split("=");
        if (key && rest.length > 0) kv[key.trim()] = rest.join("=").trim();
    });
    return kv;
}

// ── HTTP Server ─────────────────────────────────────────────

const server = Bun.serve<WsData>({
    port: UI_PORT,
    async fetch(req, server) {
        const url = new URL(req.url);

        // WebSocket upgrade
        if (url.pathname === "/ws") {
            if (server.upgrade(req, { data: { id: ++wsIdCounter } })) return;
            return new Response("Upgrade failed", { status: 400 });
        }

        // Static files
        if (req.method === "GET") {
            if (url.pathname === "/")
                return new Response(htmlText, {
                    headers: { "content-type": "text/html" },
                });
            if (url.pathname === "/styles.css")
                return new Response(cssText, {
                    headers: { "content-type": "text/css" },
                });
            if (url.pathname === "/app.js")
                return new Response(appJsText, {
                    headers: { "content-type": "application/javascript" },
                });
        }

        const client = getClient();

        // ── GET /api/keys — list all keys ───────────────────────
        if (url.pathname === "/api/keys" && req.method === "GET") {
            const index = await getIndex();
            return Response.json(index);
        }

        // ── POST /api/keys — create key via EXEC kv_put ─────────
        if (url.pathname === "/api/keys" && req.method === "POST") {
            try {
                const body = await req.json();
                const key = body.key?.trim();
                const value = body.value ?? "";

                if (!key) return new Response("Missing key", { status: 400 });

                // Encode value as base64 for safe transport through EXEC args
                const valueB64 = Buffer.from(value).toString("base64");
                const res = await client.send(`EXEC kv_put ${key} ${valueB64}`);
                if (res.type === "error")
                    return new Response(res.message, { status: 400 });

                // Update index
                const index = await getIndex();
                if (!index.find((e) => e.key === key)) {
                    index.unshift({ key, locked: false });
                    await saveIndex(index);
                }

                // Broadcast via PUB/SUB
                await client.send(
                    `PUB kv_events ${JSON.stringify({ type: "kv:updated", key })}`
                );

                // Get metadata for the response
                const metaRes = await client.send(`GET meta:${key}`);
                const meta =
                    metaRes.type === "bulk" && metaRes.value
                        ? parseMeta(metaRes.value)
                        : null;

                return Response.json({ key, value, meta }, { status: 201 });
            } catch (err: any) {
                return new Response(err.message || "Bad request", { status: 400 });
            }
        }

        // ── Key-specific routes ─────────────────────────────────
        const keyMatch = url.pathname.match(/^\/api\/keys\/([^/]+)$/);
        if (keyMatch) {
            const key = decodeURIComponent(keyMatch[1]);

            // GET /api/keys/:key — read via EXEC kv_get
            if (req.method === "GET") {
                try {
                    const res = await client.send(`EXEC kv_get ${key}`);
                    if (res.type === "error")
                        return new Response(res.message, { status: 404 });

                    const rawValue = res.type === "bulk" ? res.value ?? "" : "";
                    // Value is stored as base64 by kv_put, decode for client
                    const value = rawValue ? Buffer.from(rawValue, "base64").toString("utf-8") : "";

                    // Check locked status
                    const index = await getIndex();
                    const entry = index.find((e) => e.key === key);

                    // Get metadata
                    const metaRes = await client.send(`GET meta:${key}`);
                    const meta =
                        metaRes.type === "bulk" && metaRes.value
                            ? parseMeta(metaRes.value)
                            : null;

                    return Response.json({
                        key,
                        value,
                        locked: entry?.locked ?? false,
                        meta,
                    });
                } catch (err: any) {
                    return new Response(err.message || "Error", { status: 500 });
                }
            }

            // PUT /api/keys/:key — update via EXEC kv_put
            if (req.method === "PUT") {
                try {
                    const body = await req.json();
                    const value = body.value ?? "";

                    // Check locked
                    const index = await getIndex();
                    const entry = index.find((e) => e.key === key);
                    if (entry?.locked)
                        return new Response("Key is WORM-locked", { status: 403 });

                    const valueB64 = Buffer.from(value).toString("base64");
                    const res = await client.send(`EXEC kv_put ${key} ${valueB64}`);
                    if (res.type === "error")
                        return new Response(res.message, { status: 400 });

                    // Broadcast
                    await client.send(
                        `PUB kv_events ${JSON.stringify({ type: "kv:updated", key })}`
                    );

                    // Get refreshed metadata
                    const metaRes = await client.send(`GET meta:${key}`);
                    const meta =
                        metaRes.type === "bulk" && metaRes.value
                            ? parseMeta(metaRes.value)
                            : null;

                    return Response.json({ key, value, meta });
                } catch (err: any) {
                    if (err.message?.includes("WORM"))
                        return new Response("WORM-locked", { status: 403 });
                    return new Response(err.message || "Error", { status: 400 });
                }
            }

            // DELETE /api/keys/:key
            if (req.method === "DELETE") {
                try {
                    const index = await getIndex();
                    const entry = index.find((e) => e.key === key);
                    if (entry?.locked)
                        return new Response("Cannot delete WORM-locked key", {
                            status: 403,
                        });

                    await client.send(`DEL ${key}`);
                    await client.send(`DEL meta:${key}`);

                    const newIndex = index.filter((e) => e.key !== key);
                    await saveIndex(newIndex);

                    await client.send(
                        `PUB kv_events ${JSON.stringify({ type: "kv:deleted", key })}`
                    );
                    return new Response(null, { status: 204 });
                } catch (err: any) {
                    if (err.message?.includes("WORM"))
                        return new Response("Cannot delete WORM-locked key", {
                            status: 403,
                        });
                    return new Response(err.message || "Error", { status: 500 });
                }
            }
        }

        // ── POST /api/keys/:key/lock — WORM lock ────────────────
        const lockMatch = url.pathname.match(/^\/api\/keys\/([^/]+)\/lock$/);
        if (lockMatch && req.method === "POST") {
            const key = decodeURIComponent(lockMatch[1]);
            try {
                // Re-read the current value and re-set with WORM flag
                const res = await client.send(`EXEC kv_get ${key}`);
                if (res.type === "error")
                    return new Response(res.message, { status: 404 });

                const rawValue = res.type === "bulk" ? res.value ?? "" : "";
                // Value is stored base64, pass it directly for WORM re-set
                await client.send(`SET ${key} ${rawValue} WORM`);

                // Update index
                const index = await getIndex();
                const entry = index.find((e) => e.key === key);
                if (entry) {
                    entry.locked = true;
                    await saveIndex(index);
                }

                await client.send(
                    `PUB kv_events ${JSON.stringify({ type: "kv:locked", key })}`
                );
                return Response.json({ key, locked: true });
            } catch (err: any) {
                return new Response(err.message || "Error", { status: 500 });
            }
        }

        // ── GET /api/stats — aggregate stats via EXEC kv_stats ──
        if (url.pathname === "/api/stats" && req.method === "GET") {
            try {
                const res = await client.send("EXEC kv_stats");
                if (res.type === "bulk" && res.value) {
                    const kv = parseKV(res.value);
                    return Response.json({
                        reads: parseInt(kv.reads || "0"),
                        writes: parseInt(kv.writes || "0"),
                    });
                }
                return Response.json({ reads: 0, writes: 0 });
            } catch {
                return Response.json({ reads: 0, writes: 0 });
            }
        }

        return new Response("Not found", { status: 404 });
    },

    websocket: {
        open(ws) {
            wsClients.add(ws);
            pushStatus();
            pushStats();
        },
        close(ws) {
            wsClients.delete(ws);
        },
        message() {
            /* client doesn't send ws msgs */
        },
    },
});

console.log(`KV Explorer running on http://localhost:${server.port}`);

setupEventSubscription();
setInterval(pushStatus, 3000);
setInterval(pushStats, 2000);
