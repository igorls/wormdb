/**
 * WormDB browser client — direct WebSocket access to the database.
 *
 * Usage:
 *   const db = new WormDB("ws://localhost:6390");
 *   await db.connect();
 *   await db.set("user:1", "alice");
 *   const val = await db.get("user:1"); // "alice"
 *   await db.subscribe("events", (channel, message) => { ... });
 *   await db.close();
 *
 * Features:
 *   - Promise-based request/response over binary WebSocket
 *   - Auto-reconnect with exponential backoff
 *   - PubSub event delivery via callbacks
 *   - Optional SCT auth with token refresh
 *   - Multi-node latency probing (connect to fastest)
 *
 * @module
 */

import {
    type WormResponse,
    encodeGet,
    encodeSet,
    encodeDel,
    encodeStatus,
    encodeSub,
    encodeUnsub,
    encodePub,
    encodeExec,
    encodeAuth,
    decodeResponse,
} from "./wire.js";

// ── Types ──────────────────────────────────────────────────────────────

export type WormDBOptions = {
    /** WebSocket URL(s) — single node or multiple for latency probing.
     *  e.g. "ws://localhost:6390" or ["wss://us.db.co", "wss://eu.db.co"] */
    url: string | string[];
    /** Request timeout in ms (default: 5000) */
    timeoutMs?: number;
    /** Enable auto-reconnect on disconnect (default: true) */
    autoReconnect?: boolean;
    /** Max reconnect delay in ms (default: 30000) */
    maxReconnectDelayMs?: number;
    /** Callback to provide/refresh an SCT token (binary). Called on connect if set. */
    tokenProvider?: () => Promise<Uint8Array> | Uint8Array;
};

export type EventHandler = (channel: string, message: string) => void;

type PendingRequest = {
    resolve: (resp: WormResponse) => void;
    reject: (err: Error) => void;
    timer: ReturnType<typeof setTimeout>;
};

// ── Client ─────────────────────────────────────────────────────────────

export class WormDB {
    private readonly urls: string[];
    private readonly timeoutMs: number;
    private readonly autoReconnect: boolean;
    private readonly maxReconnectDelayMs: number;
    private readonly tokenProvider?: () => Promise<Uint8Array> | Uint8Array;

    private ws: WebSocket | null = null;
    private activeUrl = "";
    private pendingQueue: PendingRequest[] = [];
    private eventHandlers = new Map<string, Set<EventHandler>>();
    private globalEventHandler: EventHandler | null = null;
    private reconnectAttempt = 0;
    private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    private closed = false;

    /** State: "disconnected" | "connecting" | "connected" */
    private _state: "disconnected" | "connecting" | "connected" = "disconnected";

    /** Resolvers for connect() callers waiting for the connection to establish */
    private connectResolvers: Array<{
        resolve: () => void;
        reject: (err: Error) => void;
    }> = [];

    constructor(options: WormDBOptions | string) {
        if (typeof options === "string") {
            options = { url: options };
        }
        this.urls = Array.isArray(options.url) ? options.url : [options.url];
        this.timeoutMs = options.timeoutMs ?? 5000;
        this.autoReconnect = options.autoReconnect ?? true;
        this.maxReconnectDelayMs = options.maxReconnectDelayMs ?? 30_000;
        this.tokenProvider = options.tokenProvider;
    }

    // ── Connection ─────────────────────────────────────────────────────

    /** Connect to the fastest available node. Resolves when WebSocket is open. */
    async connect(): Promise<void> {
        if (this._state === "connected") return;
        this.closed = false;

        if (this._state === "connecting") {
            // Wait for the in-flight connection attempt
            return new Promise<void>((resolve, reject) => {
                this.connectResolvers.push({ resolve, reject });
            });
        }

        this._state = "connecting";

        // Multi-node: probe all URLs and connect to the fastest
        const url = this.urls.length === 1
            ? this.urls[0]
            : await this.probeFastest();

        return this.connectToUrl(url);
    }

    /** Current connection state */
    get state(): "disconnected" | "connecting" | "connected" {
        return this._state;
    }

    /** Currently connected URL */
    get connectedUrl(): string {
        return this.activeUrl;
    }

    /** Close the connection. No auto-reconnect after explicit close. */
    async close(): Promise<void> {
        this.closed = true;
        this.cancelReconnect();
        this.rejectAll(new Error("client closed"));

        if (this.ws) {
            this.ws.onclose = null; // Prevent reconnect
            this.ws.close(1000);
            this.ws = null;
        }
        this._state = "disconnected";
        this.activeUrl = "";
    }

    // ── Commands ───────────────────────────────────────────────────────

    async get(key: string): Promise<string | null> {
        const resp = await this.request(encodeGet(key));
        if (resp.type === "value") return resp.data;
        if (resp.type === "null") return null;
        if (resp.type === "error") throw new WormDBError(resp.message);
        throw new WormDBError(`unexpected response: ${resp.type}`);
    }

    async set(key: string, value: string, worm = false): Promise<void> {
        const resp = await this.request(encodeSet(key, value, worm));
        if (resp.type === "ok") return;
        if (resp.type === "error") throw new WormDBError(resp.message);
        throw new WormDBError(`unexpected response: ${resp.type}`);
    }

    async del(key: string): Promise<void> {
        const resp = await this.request(encodeDel(key));
        if (resp.type === "ok") return;
        if (resp.type === "error") throw new WormDBError(resp.message);
        throw new WormDBError(`unexpected response: ${resp.type}`);
    }

    async exec(procedure: string, ...args: string[]): Promise<WormResponse> {
        return this.request(encodeExec(procedure, args));
    }

    async status(): Promise<string> {
        const resp = await this.request(encodeStatus());
        if (resp.type === "value") return resp.data;
        if (resp.type === "error") throw new WormDBError(resp.message);
        throw new WormDBError(`unexpected response: ${resp.type}`);
    }

    async publish(channel: string, message: string): Promise<void> {
        const resp = await this.request(encodePub(channel, message));
        if (resp.type === "ok") return;
        if (resp.type === "error") throw new WormDBError(resp.message);
    }

    // ── PubSub ─────────────────────────────────────────────────────────

    /** Subscribe to a channel. The handler receives events for that channel. */
    async subscribe(channel: string, handler: EventHandler): Promise<void> {
        let handlers = this.eventHandlers.get(channel);
        if (!handlers) {
            handlers = new Set();
            this.eventHandlers.set(channel, handlers);
        }
        handlers.add(handler);

        // Send SUB command to server (idempotent on server side)
        const resp = await this.request(encodeSub(channel));
        if (resp.type === "error") throw new WormDBError(resp.message);
    }

    /** Unsubscribe a handler from a channel. If last handler, sends UNSUB to server. */
    async unsubscribe(channel: string, handler: EventHandler): Promise<void> {
        const handlers = this.eventHandlers.get(channel);
        if (!handlers) return;

        handlers.delete(handler);
        if (handlers.size === 0) {
            this.eventHandlers.delete(channel);
            const resp = await this.request(encodeUnsub(channel));
            if (resp.type === "error") throw new WormDBError(resp.message);
        }
    }

    /** Listen to ALL events across all channels. */
    onEvent(handler: EventHandler): void {
        this.globalEventHandler = handler;
    }

    // ── Auth ───────────────────────────────────────────────────────────

    /** Authenticate with a binary SCT token. */
    async auth(token: Uint8Array): Promise<void> {
        const resp = await this.request(encodeAuth(token));
        if (resp.type === "ok") return;
        if (resp.type === "error") throw new WormDBError(`auth failed: ${resp.message}`);
        throw new WormDBError(`unexpected auth response: ${resp.type}`);
    }

    // ── Internal: WebSocket management ─────────────────────────────────

    private connectToUrl(url: string): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            this.activeUrl = url;
            const ws = new WebSocket(url);
            ws.binaryType = "arraybuffer";

            ws.onopen = async () => {
                this._state = "connected";
                this.reconnectAttempt = 0;
                this.ws = ws;

                // Auto-auth if token provider is set
                if (this.tokenProvider) {
                    try {
                        const token = await this.tokenProvider();
                        await this.auth(token);
                    } catch (err) {
                        ws.close(4001); // 4001 = auth failed (browser only allows 1000 or 3000-4999)
                        const error = err instanceof Error ? err : new Error(String(err));
                        reject(error);
                        for (const r of this.connectResolvers) r.reject(error);
                        this.connectResolvers = [];
                        return;
                    }
                }

                // Re-subscribe to any channels after reconnect
                for (const channel of this.eventHandlers.keys()) {
                    this.request(encodeSub(channel)).catch(() => { });
                }

                resolve();
                for (const r of this.connectResolvers) r.resolve();
                this.connectResolvers = [];
            };

            ws.onmessage = (event: MessageEvent) => {
                const data = new Uint8Array(event.data as ArrayBuffer);
                const resp = decodeResponse(data);

                // Route events to handlers
                if (resp.type === "event") {
                    const handlers = this.eventHandlers.get(resp.channel);
                    if (handlers) {
                        for (const h of handlers) {
                            try { h(resp.channel, resp.message); } catch { /* swallow handler errors */ }
                        }
                    }
                    if (this.globalEventHandler) {
                        try { this.globalEventHandler(resp.channel, resp.message); } catch { /* swallow */ }
                    }
                    return;
                }

                // Route request/response
                const pending = this.pendingQueue.shift();
                if (pending) {
                    clearTimeout(pending.timer);
                    pending.resolve(resp);
                }
            };

            ws.onclose = () => {
                const wasConnecting = this._state === "connecting";
                this.ws = null;
                this._state = "disconnected";
                this.rejectAll(new Error("connection closed"));

                if (wasConnecting) {
                    const err = new Error(`failed to connect to ${url}`);
                    reject(err);
                    for (const r of this.connectResolvers) r.reject(err);
                    this.connectResolvers = [];
                }

                if (!this.closed && this.autoReconnect) {
                    this.scheduleReconnect();
                }
            };

            ws.onerror = () => {
                // onclose will fire after onerror
            };
        });
    }

    private request(frame: Uint8Array): Promise<WormResponse> {
        return new Promise<WormResponse>((resolve, reject) => {
            if (!this.ws || this._state !== "connected") {
                reject(new WormDBError("not connected"));
                return;
            }

            const timer = setTimeout(() => {
                const idx = this.pendingQueue.findIndex(p => p.timer === timer);
                if (idx !== -1) this.pendingQueue.splice(idx, 1);
                reject(new WormDBError(`request timed out after ${this.timeoutMs}ms`));
            }, this.timeoutMs);

            this.pendingQueue.push({ resolve, reject, timer });
            this.ws.send(frame);
        });
    }

    // ── Reconnect ──────────────────────────────────────────────────────

    private scheduleReconnect(): void {
        if (this.closed) return;

        const delay = Math.min(
            1000 * Math.pow(2, this.reconnectAttempt),
            this.maxReconnectDelayMs,
        );
        this.reconnectAttempt++;

        this.reconnectTimer = setTimeout(() => {
            this.reconnectTimer = null;
            this._state = "connecting";

            // Try a different node on reconnect (round-robin)
            const idx = this.reconnectAttempt % this.urls.length;
            this.connectToUrl(this.urls[idx]).catch(() => {
                // Will retry via onclose → scheduleReconnect
            });
        }, delay);
    }

    private cancelReconnect(): void {
        if (this.reconnectTimer) {
            clearTimeout(this.reconnectTimer);
            this.reconnectTimer = null;
        }
    }

    // ── Multi-node latency probing ─────────────────────────────────────

    private async probeFastest(): Promise<string> {
        const results = await Promise.allSettled(
            this.urls.map(url => this.probeLatency(url)),
        );

        let bestUrl = this.urls[0];
        let bestLatency = Infinity;

        for (let i = 0; i < results.length; i++) {
            const result = results[i];
            if (result.status === "fulfilled" && result.value < bestLatency) {
                bestLatency = result.value;
                bestUrl = this.urls[i];
            }
        }

        return bestUrl;
    }

    private probeLatency(url: string): Promise<number> {
        return new Promise<number>((resolve, reject) => {
            const start = performance.now();
            const ws = new WebSocket(url);
            ws.binaryType = "arraybuffer";

            const timer = setTimeout(() => {
                ws.close();
                reject(new Error("probe timeout"));
            }, 3000);

            ws.onopen = () => {
                const latency = performance.now() - start;
                clearTimeout(timer);
                ws.close(1000);
                resolve(latency);
            };

            ws.onerror = () => {
                clearTimeout(timer);
                reject(new Error(`probe failed: ${url}`));
            };
        });
    }

    // ── Helpers ────────────────────────────────────────────────────────

    private rejectAll(err: Error): void {
        const queue = this.pendingQueue;
        this.pendingQueue = [];
        for (const p of queue) {
            clearTimeout(p.timer);
            p.reject(err);
        }
    }
}

// ── Error type ─────────────────────────────────────────────────────────

export class WormDBError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "WormDBError";
    }
}

// Re-export for convenience
export type { WormResponse };
