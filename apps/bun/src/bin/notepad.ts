#!/usr/bin/env bun
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
const UI_PORT = Number(process.env.NOTEPAD_PORT ?? "8081");
const UI_DIR = path.resolve(import.meta.dir, "../notepad");

type WormEndpoint = { host: string; port: number };
const activeEndpoint: WormEndpoint = { host: HOST, port: PORT };

function getClient() {
    return new WormClient({ host: activeEndpoint.host, port: activeEndpoint.port, timeoutMs: 10000 });
}

function generateULID() {
    const time = Date.now().toString(36).padStart(10, "0");
    const rand = crypto.randomUUID().replace(/-/g, "").substring(0, 16);
    return (time + rand).toUpperCase();
}

// Ensure valid port
if (!Number.isInteger(activeEndpoint.port) || activeEndpoint.port < 1 || activeEndpoint.port > 65535) {
    console.error(`Invalid WORMDB_PORT '${process.env.WORMDB_PORT ?? ""}'.`);
    process.exit(1);
}

// ── Build Frontend ──
const htmlText = await Bun.file(path.join(UI_DIR, "index.html")).text();
const cssText = await Bun.file(path.join(UI_DIR, "styles.css")).text();
const buildResult = await Bun.build({
    entrypoints: [path.join(UI_DIR, "app.ts")],
    target: "browser",
    minify: false,
});
const appJsText = buildResult.success ? await buildResult.outputs[0].text() : "console.error('Build failed');";

// ── WebSocket Real-Time Infrastructure ──
type WsData = { id: number };
const wsClients = new Set<ServerWebSocket<WsData>>();
let wsIdCounter = 0;

function broadcast(msg: object) {
    const payload = JSON.stringify(msg);
    for (const ws of wsClients) {
        try { ws.send(payload); } catch { wsClients.delete(ws); }
    }
}

// Shared WormDB Event Subscription
type SocketData = string | ArrayBuffer | SharedArrayBuffer | ArrayBufferView;
let eventSocket: { write(data: SocketData): number; end(): void } | null = null;
let eventConnecting = false;
let eventInbound: Bytes = new Uint8Array(0);

function setupEventSubscription() {
    if (eventSocket || eventConnecting) return;
    eventConnecting = true;

    Bun.connect({
        hostname: activeEndpoint.host,
        port: activeEndpoint.port,
        socket: {
            open(socket) {
                eventConnecting = false;
                eventSocket = socket;
                eventInbound = new Uint8Array(0);

                socket.write(WIRE_MAGIC);
                socket.write(encodeCommandFrame({ kind: "SUB", channel: "notes" }));
                console.log("WS: subscribed to notes channel");
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
                    if (decoded.type === "event" && decoded.channel === "notes") {
                        try {
                            const msg = JSON.parse(decoded.message);
                            broadcast(msg);
                        } catch { /* ignore invalid JSON */ }
                    }
                }
            },
            close(socket) {
                if (eventSocket === socket) { eventSocket = null; setTimeout(setupEventSubscription, 3000); }
            },
            error(socket) {
                if (eventSocket && eventSocket === socket) { eventSocket = null; eventConnecting = false; setTimeout(setupEventSubscription, 3000); }
            },
        }
    }).catch(() => {
        eventConnecting = false;
        eventSocket = null;
        setTimeout(setupEventSubscription, 3000);
    });
}

// Periodic Status Push
async function pushStatus() {
    try {
        const client = getClient();
        const response = await client.send("STATUS");
        if (response.type === "bulk" && response.value) {
            broadcast({ type: "status", response: { value: response.value } });
        }
    } catch { /* ignore */ }
}

// ── Helper ──
async function getIndex(): Promise<any[]> {
    const client = getClient();
    const res = await client.send("GET notes:index");
    if (res.type === "bulk" && res.value) {
        try {
            const json = Buffer.from(res.value, "base64").toString("utf-8");
            return JSON.parse(json);
        } catch { return []; }
    }
    return [];
}

async function saveIndex(index: any[]) {
    const client = getClient();
    const valueB64 = Buffer.from(JSON.stringify(index)).toString("base64");
    await client.send(`SET notes:index ${valueB64}`);
}

// ── HTTP Server ──
const server = Bun.serve<WsData>({
    port: UI_PORT,
    async fetch(req, server) {
        const url = new URL(req.url);

        if (url.pathname === "/ws") {
            if (server.upgrade(req, { data: { id: ++wsIdCounter } })) return;
            return new Response("Upgrade failed", { status: 400 });
        }

        if (req.method === "GET") {
            if (url.pathname === "/") return new Response(htmlText, { headers: { "content-type": "text/html" } });
            if (url.pathname === "/styles.css") return new Response(cssText, { headers: { "content-type": "text/css" } });
            if (url.pathname === "/app.js") return new Response(appJsText, { headers: { "content-type": "application/javascript" } });
        }

        // ── API ──
        const client = getClient();

        if (url.pathname === "/api/notes" && req.method === "GET") {
            const index = await getIndex();
            return Response.json(index);
        }

        if (url.pathname === "/api/notes" && req.method === "POST") {
            const id = generateULID();
            const note = {
                title: "Untitled Note",
                body: "",
                author: "Guest",
                updatedAt: new Date().toISOString(),
                locked: false
            };

            const valueB64 = Buffer.from(JSON.stringify(note)).toString("base64");
            await client.send(`SET note:${id} ${valueB64}`);

            const index = await getIndex();
            index.unshift({ id, title: note.title, updatedAt: note.updatedAt, locked: note.locked });
            await saveIndex(index);


            return Response.json({ id, ...note }, { status: 201 });
        }

        const matchId = url.pathname.match(/^\/api\/notes\/([^/]+)$/);
        if (matchId) {
            const id = matchId[1];

            if (req.method === "GET") {
                const res = await client.send(`GET note:${id}`);
                if (res.type === "bulk" && res.value) {
                    try {
                        const json = Buffer.from(res.value, "base64").toString("utf-8");
                        const data = JSON.parse(json);
                        return Response.json({ id, ...data });
                    } catch { return new Response("Invalid note format", { status: 500 }); }
                }
                return new Response("Not found", { status: 404 });
            }

            if (req.method === "PUT") {
                try {
                    const body = await req.json();
                    const res = await client.send(`GET note:${id}`);
                    let note: any = {};
                    if (res.type === "bulk" && res.value) {
                        note = JSON.parse(Buffer.from(res.value, "base64").toString("utf-8"));
                    }
                    if (note.locked) return new Response("Note is locked", { status: 403 });

                    note.title = body.title ?? note.title;
                    note.body = body.body ?? note.body;
                    note.author = body.author ?? note.author;
                    note.updatedAt = new Date().toISOString();

                    const valueB64 = Buffer.from(JSON.stringify(note)).toString("base64");
                    await client.send(`SET note:${id} ${valueB64}`);

                    const index = await getIndex();
                    const item = index.find(i => i.id === id);
                    if (item) {
                        item.title = note.title;
                        item.updatedAt = note.updatedAt;
                        item.locked = !!note.locked;
                        await saveIndex(index);
                    }


                    return Response.json({ id, ...note });
                } catch (err: any) {
                    if (err.message?.includes("WORM")) {
                        // "Cannot overwrite WORM key"
                        return new Response("Note is WORM-locked", { status: 403 });
                    }
                    return new Response("Bad request", { status: 400 });
                }
            }

            if (req.method === "DELETE") {
                try {
                    await client.send(`DEL note:${id}`);
                    const index = await getIndex();
                    const newIndex = index.filter(i => i.id !== id);
                    await saveIndex(newIndex);

                    await client.send(`PUB notes ${JSON.stringify({ type: "note:deleted", id })}`);

                    return new Response(null, { status: 204 });
                } catch (err: any) {
                    if (err.message?.includes("WORM")) {
                        return new Response("Cannot delete WORM-locked note", { status: 403 });
                    }
                    return new Response(String(err), { status: 500 });
                }
            }
        }

        const matchLock = url.pathname.match(/^\/api\/notes\/([^/]+)\/lock$/);
        if (matchLock && req.method === "POST") {
            const id = matchLock[1];
            try {
                const res = await client.send(`GET note:${id}`);
                if (res.type !== "bulk" || !res.value) return new Response("Not found", { status: 404 });

                let note = JSON.parse(Buffer.from(res.value, "base64").toString("utf-8"));
                note.locked = true;
                note.updatedAt = new Date().toISOString();

                const valueB64 = Buffer.from(JSON.stringify(note)).toString("base64");
                await client.send(`SET note:${id} ${valueB64} WORM`);

                const index = await getIndex();
                const item = index.find(i => i.id === id);
                if (item) {
                    item.locked = true;
                    item.updatedAt = note.updatedAt;
                    await saveIndex(index);
                }

                await client.send(`PUB notes ${JSON.stringify({ type: "note:locked", id, author: note.author })}`);
                return Response.json({ id, ...note });
            } catch (err: any) {
                return new Response(String(err), { status: 500 });
            }
        }

        if (url.pathname === "/api/save" && req.method === "POST") {
            await client.send("SAVE");
            return Response.json({ ok: true });
        }

        return new Response("Not found", { status: 404 });
    },
    websocket: {
        open(ws) { wsClients.add(ws); pushStatus(); },
        close(ws) { wsClients.delete(ws); },
        message() { /* client doesn't send ws msgs */ }
    }
});

console.log(`Notepad server running on http://localhost:${server.port}`);

setupEventSubscription();
setInterval(pushStatus, 2000);
