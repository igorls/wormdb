/**
 * WormDB — library-grade WormWire client for embedding (e.g. BentoKit).
 *
 * Adds what the low-level `WormClient` lacks: a managed persistent connection
 * with reconnect + exponential backoff, pub/sub push routing ("pulse-drive"),
 * AUTH with automatic re-AUTH on reconnect, and typed wrappers for the
 * append-log EXEC procedure family and vector search.
 *
 * Correlation model: WormWire has no request ids. Responses are FIFO per
 * connection; EVENT frames (code 0x04) are out-of-band and are routed to
 * subscription handlers, never to the pending-response queue.
 */

import {
  WIRE_MAGIC,
  concatBytes,
  decodeResponse,
  encodeAuth,
  encodeCommandFrame,
  encodeSave,
  encodeVdelete,
  isEventCode,
  toBytes,
  tryConsumeFrame,
  type Bytes,
} from "./wire";
import type { WormResponse } from "./protocol";
import { parseCommand, type ParsedCommand } from "./command";
import { ClientConnectionClosedError, ClientTimeoutError } from "./client";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export type WormDBState = "idle" | "connecting" | "ready" | "reconnecting" | "closed";

export type ReconnectOptions = {
  enabled?: boolean;
  minDelayMs?: number;
  maxDelayMs?: number;
  maxAttempts?: number;
};

export type WormDBOptions = {
  host: string;
  port: number;
  /** Per-request timeout. A timeout tears the connection down (FIFO order is
   * unrecoverable once a response goes missing) and reconnect takes over. */
  timeoutMs?: number;
  reconnect?: ReconnectOptions;
  /** When > 0, send a STATUS ping after this many ms of idle time to detect
   * dead connections. Default off. */
  pingIntervalMs?: number;
};

export type WormEvent = { channel: string; message: string };
export type EventHandler = (evt: WormEvent) => void;

export type Subscription = {
  channel: string;
  unsubscribe(): Promise<void>;
};

export type WormEventIterator = AsyncIterableIterator<WormEvent> & {
  /** Number of events dropped (oldest-first) because the internal queue overflowed. */
  readonly dropped: number;
};

export type VsearchHit = { k: string; s: number; ts: number };

export type VsearchOptions = {
  namespace?: string;
  metric?: "cosine" | "dot" | "l2";
  decay?: number;
  mode?: string;
  decayTauHours?: number;
};

export interface AppendLogReceipt {
  seq: number;
  ingest_time_ms: number;
  key_hex: string;
  prev_event_hash: string;
  payload_hash: string;
  event_hash: string;
  accumulator_kind: string;
  accumulator_root: string;
  accumulator_leaf_count: number;
}

export interface AppendLogVerifyResult {
  count: number;
  last_seq: number;
  head_hash: string;
}

export interface AppendLogMmrProof {
  seq: number;
  leaf_index: number;
  leaf_count: number;
  root: string;
  record_hash: string;
  proof_hex: string;
}

/** Checkpoint / witness / bundle documents are proof-spine JSON; the schema is
 * owned by the server procedures, so the client passes them through as-is. */
export type AppendLogCheckpoint = Record<string, unknown>;
export type AppendLogWitness = Record<string, unknown>;
export type AppendLogProofBundle = Record<string, unknown>;

export type AppendLogCheckpointOptions = {
  fromSeq: number;
  toSeq: number;
  creatorPubkeyHex: string;
  skHex?: string;
  sigHex?: string;
  createdAtMs?: number;
  ingestedAtMs?: number;
  prevHex?: string;
  extHex?: string;
};

export type AppendLogWitnessOptions = {
  witnessPubkeyHex?: string;
  skHex?: string;
  sigHex?: string;
  observedAtMs?: number;
  extHex?: string;
};

/** The server answered with an ERR frame. */
export class WormServerError extends Error {
  code = "ESERVER" as const;

  constructor(message: string) {
    super(message);
    this.name = "WormServerError";
  }
}

// ---------------------------------------------------------------------------
// Bun socket typing (mirrors client.ts — kept local so the two files stay
// independently importable)
// ---------------------------------------------------------------------------

type SocketData = string | ArrayBuffer | SharedArrayBuffer | ArrayBufferView;

type BunSocket = {
  write(data: SocketData): number;
  end(): void;
};

type BunSocketHandlers = {
  open?(socket: BunSocket): void;
  data?(socket: BunSocket, data: SocketData): void;
  close?(socket: BunSocket): void;
  error?(socket: BunSocket, error: Error): void;
  drain?(socket: BunSocket): void;
};

type BunGlobal = {
  connect(options: { hostname: string; port: number; socket: BunSocketHandlers }): Promise<BunSocket>;
};

declare const Bun: BunGlobal;

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

type RawFrame = { code: number; payload: Bytes };

type Pending = {
  resolve: (frame: RawFrame) => void;
  reject: (reason?: unknown) => void;
  timeout: ReturnType<typeof setTimeout>;
};

type SubEntry = {
  filter?: string;
  handlers: Set<EventHandler>;
  /** True once a SUB frame for this channel has been acknowledged. Only these
   * entries are re-subscribed by onOpen — a fresh subscribe() in flight sends
   * its own SUB, so re-sending here would double-enqueue a response. */
  wireSubscribed: boolean;
};

type ReadyWaiter = {
  resolve: () => void;
  reject: (reason?: unknown) => void;
};

const DEFAULT_RECONNECT: Required<ReconnectOptions> = {
  enabled: true,
  minDelayMs: 100,
  maxDelayMs: 10_000,
  maxAttempts: Infinity,
};

function toError(err: unknown): Error {
  return err instanceof Error ? err : new Error(String(err));
}

function decodeBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) out[i] = bin.charCodeAt(i);
  return out;
}

// ---------------------------------------------------------------------------
// WormDB client
// ---------------------------------------------------------------------------

export class WormDB {
  private readonly host: string;
  private readonly port: number;
  private readonly timeoutMs: number;
  private readonly reconnectCfg: Required<ReconnectOptions>;
  private readonly pingIntervalMs: number;

  private stateValue: WormDBState = "idle";
  private socket: BunSocket | null = null;
  private inbound: Bytes = new Uint8Array(0);
  private pendingQueue: Pending[] = [];
  private writeBacklog: Bytes[] = [];
  private readyWaiters: ReadyWaiter[] = [];
  private subs = new Map<string, SubEntry>();
  private authToken: Uint8Array | null = null;
  private reconnectAttempts = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private pingTimer: ReturnType<typeof setInterval> | null = null;
  private lastActivityMs = 0;
  private connecting = false;
  private generation = 0;

  constructor(options: WormDBOptions) {
    this.host = options.host;
    this.port = options.port;
    this.timeoutMs = options.timeoutMs ?? 3000;
    this.reconnectCfg = { ...DEFAULT_RECONNECT, ...(options.reconnect ?? {}) };
    this.pingIntervalMs = options.pingIntervalMs ?? 0;
  }

  get state(): WormDBState {
    return this.stateValue;
  }

  /** Establish the connection eagerly (all commands also connect lazily). */
  async connect(): Promise<void> {
    await this.ensureReady();
  }

  /** Close permanently. In-flight requests reject; no reconnect is attempted. */
  async close(): Promise<void> {
    this.stateValue = "closed";
    if (this.reconnectTimer != null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.stopPing();
    this.rejectAllPending(new ClientConnectionClosedError());
    this.rejectReadyWaiters(new ClientConnectionClosedError());

    if (this.socket != null) {
      const socket = this.socket;
      this.socket = null;
      try {
        socket.end();
      } catch {
        // Best effort close.
      }
    }
    this.inbound = new Uint8Array(0);
    this.writeBacklog = [];
  }

  // -------------------------------------------------------------------------
  // Text-command compatibility (same surface as WormClient.send)
  // -------------------------------------------------------------------------

  /** Parse and send a text command ("GET k", "STATUS", ...) — WormClient parity. */
  async send(command: string): Promise<WormResponse> {
    return this.sendCommand(parseCommand(command));
  }

  async sendCommand(parsed: ParsedCommand): Promise<WormResponse> {
    return this.request(encodeCommandFrame(parsed));
  }

  // -------------------------------------------------------------------------
  // AUTH
  // -------------------------------------------------------------------------

  /**
   * Authenticate with a binary SCT token (raw bytes or base64 string). On
   * success the token is retained and automatically re-sent on every
   * reconnect, before resubscribes and queued sends.
   */
  async auth(token: Uint8Array | string): Promise<void> {
    const tokenBytes = typeof token === "string" ? decodeBase64(token) : token;
    const resp = await this.request(encodeAuth(tokenBytes));
    if (resp.type === "error") throw new WormServerError(resp.message);
    this.authToken = tokenBytes;
  }

  // -------------------------------------------------------------------------
  // Pub/sub push
  // -------------------------------------------------------------------------

  /**
   * Subscribe to a channel. The server prefix-matches: `SUB vec:` receives
   * every `vec:*` event, so incoming events are routed to each subscription
   * whose channel is a prefix of the event channel. Multiple handlers per
   * channel are allowed; the SUB frame is only sent for the first.
   */
  async subscribe(channel: string, handler: EventHandler, opts: { filter?: string } = {}): Promise<Subscription> {
    let entry = this.subs.get(channel);
    const isNew = entry == null;
    if (entry == null) {
      entry = {
        handlers: new Set(),
        wireSubscribed: false,
        ...(opts.filter != null ? { filter: opts.filter } : {}),
      };
      this.subs.set(channel, entry);
    }
    entry.handlers.add(handler);

    if (isNew) {
      try {
        const resp = await this.request(
          encodeCommandFrame({ kind: "SUB", channel, ...(opts.filter != null ? { filter: opts.filter } : {}) }),
        );
        if (resp.type === "error") throw new WormServerError(resp.message);
        entry.wireSubscribed = true;
      } catch (err) {
        entry.handlers.delete(handler);
        if (entry.handlers.size === 0) this.subs.delete(channel);
        throw err;
      }
    }

    let active = true;
    return {
      channel,
      unsubscribe: async () => {
        if (!active) return;
        active = false;
        await this.removeHandler(channel, handler);
      },
    };
  }

  /**
   * Async-iterator view over a channel, built on the same machinery as
   * `subscribe`. Events buffer in a bounded queue (default 1024); on overflow
   * the oldest event is dropped and `dropped` increments.
   */
  events(channel: string, opts: { filter?: string; queueLimit?: number } = {}): WormEventIterator {
    const limit = Math.max(1, opts.queueLimit ?? 1024);
    const queue: WormEvent[] = [];
    let droppedCount = 0;
    let wake: (() => void) | null = null;
    let finished = false;

    const handler: EventHandler = (evt) => {
      queue.push(evt);
      if (queue.length > limit) {
        queue.shift();
        droppedCount += 1;
      }
      wake?.();
    };

    const subPromise = this.subscribe(channel, handler, opts.filter != null ? { filter: opts.filter } : {});
    // Surface subscription failure through next(); avoid an unhandled rejection.
    subPromise.catch(() => {});

    const finish = async (): Promise<void> => {
      if (finished) return;
      finished = true;
      wake?.();
      try {
        const sub = await subPromise;
        await sub.unsubscribe();
      } catch {
        // Subscription never became active — nothing to remove.
      }
    };

    const iterator: WormEventIterator = {
      get dropped(): number {
        return droppedCount;
      },
      [Symbol.asyncIterator]() {
        return iterator;
      },
      next: async (): Promise<IteratorResult<WormEvent>> => {
        await subPromise; // throws if the subscribe failed
        while (true) {
          const evt = queue.shift();
          if (evt != null) return { done: false, value: evt };
          if (finished || this.stateValue === "closed") {
            return { done: true, value: undefined };
          }
          await new Promise<void>((resolve) => {
            wake = resolve;
          });
          wake = null;
        }
      },
      return: async (): Promise<IteratorResult<WormEvent>> => {
        await finish();
        return { done: true, value: undefined };
      },
      throw: async (err?: unknown): Promise<IteratorResult<WormEvent>> => {
        await finish();
        throw toError(err);
      },
    };
    return iterator;
  }

  async pub(channel: string, message: string): Promise<void> {
    this.expectOk(await this.request(encodeCommandFrame({ kind: "PUB", channel, message })));
  }

  // -------------------------------------------------------------------------
  // KV + admin wrappers
  // -------------------------------------------------------------------------

  async get(key: string): Promise<string | null> {
    const resp = await this.request(encodeCommandFrame({ kind: "GET", key }));
    if (resp.type === "error") throw new WormServerError(resp.message);
    if (resp.type === "null") return null;
    if (resp.type === "bulk") return resp.value;
    throw new WormServerError(`unexpected GET response: ${resp.type}`);
  }

  async getBytes(key: string): Promise<Uint8Array | null> {
    const frame = await this.requestRaw(encodeCommandFrame({ kind: "GET", key }));
    const resp = decodeResponse(frame.code, frame.payload);
    if (resp.type === "error") throw new WormServerError(resp.message);
    if (resp.type === "null") return null;
    if (resp.type === "bulk") return frame.payload.slice();
    throw new WormServerError(`unexpected GET response: ${resp.type}`);
  }

  async set(key: string, value: string, opts: { worm?: boolean } = {}): Promise<void> {
    this.expectOk(
      await this.request(encodeCommandFrame({ kind: "SET", key, value, worm: opts.worm ?? false })),
    );
  }

  async del(key: string): Promise<void> {
    this.expectOk(await this.request(encodeCommandFrame({ kind: "DEL", key })));
  }

  async status(): Promise<string> {
    return this.expectValue(await this.request(encodeCommandFrame({ kind: "STATUS" })));
  }

  async clusterStatus(): Promise<string> {
    return this.expectValue(await this.request(encodeCommandFrame({ kind: "CLUSTER_STATUS" })));
  }

  async clusterPeers(): Promise<string> {
    return this.expectValue(await this.request(encodeCommandFrame({ kind: "CLUSTER_PEERS" })));
  }

  async save(): Promise<void> {
    this.expectOk(await this.request(encodeSave()));
  }

  /** Run a compiled-in stored procedure. Returns the Value payload as a string
   * ("" for a bare OK). */
  async exec(procedure: string, ...args: (string | Uint8Array)[]): Promise<string> {
    const resp = await this.request(encodeCommandFrame({ kind: "EXEC", procedure, args }));
    if (resp.type === "error") throw new WormServerError(resp.message);
    if (resp.type === "bulk") return resp.value;
    if (resp.type === "ok") return "";
    throw new WormServerError(`unexpected EXEC response: ${resp.type}`);
  }

  // -------------------------------------------------------------------------
  // Vector wrappers
  // -------------------------------------------------------------------------

  async vinsert(
    key: string,
    vector: Uint8Array,
    options: {
      worm?: boolean;
      namespace?: string;
      metric?: "cosine" | "dot" | "l2";
      timestamp?: bigint;
      async?: boolean;
    } = {},
  ): Promise<void> {
    this.expectOk(
      await this.request(
        encodeCommandFrame({
          kind: "VINSERT",
          key,
          vector,
          worm: options.worm ?? true,
          namespace: options.namespace ?? "vec:",
          metric: options.metric ?? "cosine",
          timestamp: options.timestamp ?? BigInt(Date.now()),
          async: options.async ?? false,
        }),
      ),
    );
  }

  async vbulkinsert(
    items: { key: string; vector: Uint8Array; timestamp?: bigint }[],
    options: {
      worm?: boolean;
      namespace?: string;
      metric?: "cosine" | "dot" | "l2";
      async?: boolean;
    } = {},
  ): Promise<void> {
    const now = BigInt(Date.now());
    this.expectOk(
      await this.request(
        encodeCommandFrame({
          kind: "VBULKINSERT",
          namespace: options.namespace ?? "vec:",
          metric: options.metric ?? "cosine",
          worm: options.worm ?? false,
          async: options.async ?? false,
          items: items.map((it) => ({
            key: it.key,
            vector: it.vector,
            timestamp: it.timestamp ?? now,
          })),
        }),
      ),
    );
  }

  async vdelete(key: string, namespace: string): Promise<void> {
    this.expectOk(await this.request(encodeVdelete(key, namespace)));
  }

  async vsearch(queryKey: string, topK: number, opts: VsearchOptions = {}): Promise<VsearchHit[]> {
    const args: string[] = [queryKey, String(topK)];
    if (opts.namespace != null) args.push(`namespace=${opts.namespace}`);
    if (opts.metric != null) args.push(`metric=${opts.metric}`);
    if (opts.decay != null) args.push(`decay=${opts.decay}`);
    if (opts.mode != null) args.push(`mode=${opts.mode}`);
    if (opts.decayTauHours != null) args.push(`decay_tau_hours=${opts.decayTauHours}`);
    return this.execJson<VsearchHit[]>("vsearch", args);
  }

  // -------------------------------------------------------------------------
  // Auth minting
  // -------------------------------------------------------------------------

  /** Mint a namespace-scoped SCT via `EXEC auth_mint_scoped`. Returns the
   * base64 token string (feed it straight to `auth()`). */
  async authMintScoped(
    namespace: string,
    opts: { ttlS?: number; subject?: string; mode?: "read" | "write" | "readwrite" } = {},
  ): Promise<string> {
    // Args are positional: <ns> [ttl_s] [subject] [mode] — later args require
    // the earlier ones to be present on the wire.
    const args: string[] = [namespace];
    if (opts.ttlS != null) args.push(String(opts.ttlS));
    if (opts.subject != null) {
      if (opts.ttlS == null) throw new Error("authMintScoped: subject requires ttlS (positional args)");
      args.push(opts.subject);
    }
    if (opts.mode != null) {
      if (opts.subject == null) throw new Error("authMintScoped: mode requires subject (positional args)");
      args.push(opts.mode);
    }
    const minted = await this.execJson<{ token: string }>("auth_mint_scoped", args);
    return minted.token;
  }

  // -------------------------------------------------------------------------
  // Append-log (proof spine) API
  // -------------------------------------------------------------------------

  readonly appendLog = {
    append: async (
      logId: string,
      payload: string | Uint8Array,
      opts: { tsMs?: number; attachmentHashesHex?: string[] } = {},
    ): Promise<AppendLogReceipt> => {
      const args: (string | Uint8Array)[] = [logId, payload];
      if (opts.tsMs != null) args.push(`ts=${opts.tsMs}`);
      if (opts.attachmentHashesHex != null) args.push(...opts.attachmentHashesHex);
      return this.execJson<AppendLogReceipt>("append_log_append", args);
    },

    verify: async (logId: string): Promise<AppendLogVerifyResult> => {
      return this.execJson<AppendLogVerifyResult>("append_log_verify", [logId]);
    },

    mmrProof: async (logId: string, seq: number): Promise<AppendLogMmrProof> => {
      return this.execJson<AppendLogMmrProof>("append_log_mmr_proof", [logId, String(seq)]);
    },

    mmrVerify: async (recordHashHex: string, rootHex: string, proofHex: string): Promise<boolean> => {
      const out = await this.execJson<{ valid: boolean }>("append_log_mmr_verify", [
        recordHashHex,
        rootHex,
        proofHex,
      ]);
      return out.valid;
    },

    checkpoint: async (logId: string, opts: AppendLogCheckpointOptions): Promise<AppendLogCheckpoint> => {
      if (opts.skHex == null && opts.sigHex == null) {
        throw new Error("appendLog.checkpoint: one of skHex or sigHex is required");
      }
      const args: string[] = [logId, String(opts.fromSeq), String(opts.toSeq), opts.creatorPubkeyHex];
      if (opts.skHex != null) args.push(`sk=${opts.skHex}`);
      else args.push(`sig=${opts.sigHex}`);
      if (opts.createdAtMs != null) args.push(`created_at_ms=${opts.createdAtMs}`);
      if (opts.ingestedAtMs != null) args.push(`ingested_at_ms=${opts.ingestedAtMs}`);
      if (opts.prevHex != null) args.push(`prev=${opts.prevHex}`);
      if (opts.extHex != null) args.push(`ext=${opts.extHex}`);
      return this.execJson<AppendLogCheckpoint>("append_log_checkpoint", args);
    },

    proofBundle: async (
      logId: string,
      fromSeq: number,
      toSeq: number,
      checkpointHashHex: string,
    ): Promise<AppendLogProofBundle> => {
      return this.execJson<AppendLogProofBundle>("append_log_proof_bundle", [
        logId,
        String(fromSeq),
        String(toSeq),
        checkpointHashHex,
      ]);
    },

    proofVerify: async (
      logId: string,
      seq: number,
      recordHashHex: string,
      checkpointHashHex: string,
      proofHex: string,
    ): Promise<boolean> => {
      const out = await this.execJson<{ valid: boolean }>("append_log_proof_verify", [
        logId,
        String(seq),
        recordHashHex,
        checkpointHashHex,
        proofHex,
      ]);
      return out.valid;
    },

    witness: async (
      logId: string,
      checkpointHashHex: string,
      opts: AppendLogWitnessOptions = {},
    ): Promise<AppendLogWitness> => {
      const args: string[] = [logId, checkpointHashHex];
      if (opts.witnessPubkeyHex != null) args.push(opts.witnessPubkeyHex);
      if (opts.skHex != null) args.push(`sk=${opts.skHex}`);
      else if (opts.sigHex != null) args.push(`sig=${opts.sigHex}`);
      if (opts.observedAtMs != null) args.push(`observed_at_ms=${opts.observedAtMs}`);
      if (opts.extHex != null) args.push(`ext=${opts.extHex}`);
      return this.execJson<AppendLogWitness>("append_log_witness", args);
    },

    witnessRequest: async (logId: string, checkpointHashHex: string): Promise<number> => {
      const out = await this.execJson<{ requested: number }>("append_log_witness_request", [
        logId,
        checkpointHashHex,
      ]);
      return out.requested;
    },

    witnessImport: async (
      logId: string,
      checkpointHashHex: string,
      canonicalWitnessHex: string,
    ): Promise<AppendLogWitness> => {
      return this.execJson<AppendLogWitness>("append_log_witness_import", [
        logId,
        checkpointHashHex,
        canonicalWitnessHex,
      ]);
    },

    witnessVerify: async (
      logId: string,
      checkpointHashHex: string,
      witnessPubkeyHex: string,
    ): Promise<boolean> => {
      const out = await this.execJson<{ valid: boolean }>("append_log_witness_verify", [
        logId,
        checkpointHashHex,
        witnessPubkeyHex,
      ]);
      return out.valid;
    },
  };

  // -------------------------------------------------------------------------
  // Response helpers
  // -------------------------------------------------------------------------

  private expectOk(resp: WormResponse): void {
    if (resp.type === "error") throw new WormServerError(resp.message);
    if (resp.type !== "ok") throw new WormServerError(`unexpected response: ${resp.type}`);
  }

  private expectValue(resp: WormResponse): string {
    if (resp.type === "error") throw new WormServerError(resp.message);
    if (resp.type === "bulk") return resp.value;
    throw new WormServerError(`unexpected response: ${resp.type}`);
  }

  private async execJson<T>(procedure: string, args: (string | Uint8Array)[]): Promise<T> {
    const raw = await this.exec(procedure, ...args);
    try {
      return JSON.parse(raw) as T;
    } catch {
      throw new WormServerError(`${procedure}: expected JSON result, got: ${raw.slice(0, 128)}`);
    }
  }

  // -------------------------------------------------------------------------
  // Request/response engine
  // -------------------------------------------------------------------------

  private async request(frame: Bytes): Promise<WormResponse> {
    const raw = await this.requestRaw(frame);
    return decodeResponse(raw.code, raw.payload);
  }

  private async requestRaw(frame: Bytes): Promise<RawFrame> {
    const socket = await this.ensureReady();
    return await new Promise<RawFrame>((resolve, reject) => {
      this.enqueuePending(resolve, reject);
      try {
        this.writeOrQueue(socket, frame);
        this.lastActivityMs = Date.now();
      } catch (err) {
        const pending = this.pendingQueue.pop();
        if (pending != null) {
          clearTimeout(pending.timeout);
          pending.reject(toError(err));
        }
      }
    });
  }

  private enqueuePending(resolve: (frame: RawFrame) => void, reject: (reason?: unknown) => void): void {
    const generation = this.generation;
    const timeout = setTimeout(() => {
      // A missing response desynchronizes the FIFO queue — every later
      // response would resolve the wrong request. Tear the connection down;
      // reconnect (if enabled) re-establishes auth + subscriptions.
      if (this.generation === generation) {
        this.failConnection(new ClientTimeoutError(this.timeoutMs));
      }
    }, this.timeoutMs);
    this.pendingQueue.push({ resolve, reject, timeout });
  }

  /** Reject every in-flight request and drop the socket (close handler runs reconnect). */
  private failConnection(err: Error): void {
    this.rejectAllPending(err);
    if (this.socket != null) {
      const socket = this.socket;
      this.socket = null;
      try {
        socket.end();
      } catch {
        // Best effort close.
      }
      // Bun fires `close` after end(); handleDisconnect is idempotent, so run
      // it now to avoid dangling in "ready" until the callback lands.
      this.handleDisconnect();
    }
  }

  private async ensureReady(): Promise<BunSocket> {
    while (true) {
      if (this.stateValue === "closed") throw new ClientConnectionClosedError();
      if (this.socket != null && this.stateValue === "ready") return this.socket;

      if (!this.connecting && this.reconnectTimer == null) {
        if (this.stateValue === "idle") this.stateValue = "connecting";
        this.openSocket();
        // openSocket may complete synchronously (its `open` callback can fire
        // before Bun.connect resolves) — recheck before parking on a waiter.
        continue;
      }

      await new Promise<void>((resolve, reject) => {
        this.readyWaiters.push({ resolve, reject });
      });
    }
  }

  private openSocket(): void {
    if (this.connecting || this.stateValue === "closed") return;
    this.connecting = true;

    Bun.connect({
      hostname: this.host,
      port: this.port,
      socket: {
        open: (socket) => {
          this.connecting = false;
          this.onOpen(socket);
        },
        data: (_socket, chunk) => {
          this.onData(toBytes(chunk));
        },
        drain: (socket) => {
          this.flushBacklog(socket);
        },
        close: () => {
          this.handleDisconnect();
        },
        error: (_socket, err) => {
          this.handleDisconnect(toError(err));
        },
      },
    }).then(
      () => {
        this.connecting = false;
      },
      (err) => {
        // Keep the original connect error (e.g. ECONNREFUSED) so callers can
        // produce accurate diagnostics when reconnect is disabled.
        this.connecting = false;
        this.handleDisconnect(toError(err));
      },
    );
  }

  private onOpen(socket: BunSocket): void {
    this.generation += 1;
    this.socket = socket;
    this.inbound = new Uint8Array(0);
    this.writeBacklog = [];

    // Handshake magic, then re-AUTH, then resubscribe — pipelined in that
    // order. The server applies frames sequentially, so the token is active
    // before the SUB frames are evaluated, and both happen before any queued
    // user sends (which are only released when we flip to "ready" below).
    socket.write(WIRE_MAGIC);

    if (this.authToken != null) {
      const settle = new Promise<RawFrame>((resolve, reject) => {
        this.enqueuePending(resolve, reject);
      });
      settle.catch(() => {}); // best-effort: a failed re-AUTH surfaces on the next protected command
      this.writeOrQueue(socket, encodeAuth(this.authToken));
    }

    for (const [channel, entry] of this.subs) {
      // Only re-establish subs that were live on the previous connection; a
      // fresh subscribe() awaiting readiness sends its own SUB afterwards.
      if (!entry.wireSubscribed) continue;
      const settle = new Promise<RawFrame>((resolve, reject) => {
        this.enqueuePending(resolve, reject);
      });
      settle.catch(() => {});
      this.writeOrQueue(socket, encodeCommandFrame({ kind: "SUB", channel, ...(entry.filter != null ? { filter: entry.filter } : {}) }));
    }

    this.stateValue = "ready";
    this.reconnectAttempts = 0;
    this.lastActivityMs = Date.now();
    this.startPing();

    const waiters = this.readyWaiters;
    this.readyWaiters = [];
    for (const waiter of waiters) waiter.resolve();
  }

  private onData(chunk: Bytes): void {
    this.inbound = concatBytes([this.inbound, chunk]);
    this.lastActivityMs = Date.now();

    while (true) {
      const frame = tryConsumeFrame(this.inbound);
      if (frame == null) return;
      this.inbound = frame.remaining;

      if (isEventCode(frame.code)) {
        // Out-of-band push — route to subscribers, never to the pending queue.
        const decoded = decodeResponse(frame.code, frame.payload);
        if (decoded.type === "event") {
          this.dispatchEvent({ channel: decoded.channel, message: decoded.message });
        }
        continue;
      }

      const pending = this.pendingQueue.shift();
      if (pending == null) continue; // response with no requester (post-teardown stray)
      clearTimeout(pending.timeout);
      pending.resolve({ code: frame.code, payload: frame.payload });
    }
  }

  private dispatchEvent(evt: WormEvent): void {
    for (const [channel, entry] of this.subs) {
      // Server-side matching is prefix-based (SUB "vec:" sees "vec:ns:key"
      // events); mirror it when routing to local handlers.
      if (evt.channel === channel || evt.channel.startsWith(channel)) {
        for (const handler of entry.handlers) {
          try {
            handler(evt);
          } catch {
            // Handler exceptions must not break frame processing.
          }
        }
      }
    }
  }

  private handleDisconnect(cause?: Error): void {
    this.socket = null;
    this.inbound = new Uint8Array(0);
    this.writeBacklog = [];
    this.stopPing();

    // In-flight requests are rejected, never silently replayed: the write may
    // have reached the server, so a replay could double-apply.
    this.rejectAllPending(cause ?? new ClientConnectionClosedError());

    if (this.stateValue === "closed") return;

    if (!this.reconnectCfg.enabled) {
      // Lazy mode: next call dials a fresh connection (and re-runs auth+subs).
      this.stateValue = "idle";
      this.rejectReadyWaiters(cause ?? new ClientConnectionClosedError());
      return;
    }

    this.stateValue = "reconnecting";
    this.scheduleReconnect();
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer != null || this.connecting || this.stateValue === "closed") return;

    if (this.reconnectAttempts >= this.reconnectCfg.maxAttempts) {
      this.stateValue = "closed";
      this.rejectReadyWaiters(new ClientConnectionClosedError());
      return;
    }

    // Exponential backoff with jitter in [backoff/2, backoff].
    const backoff = Math.min(
      this.reconnectCfg.maxDelayMs,
      this.reconnectCfg.minDelayMs * 2 ** this.reconnectAttempts,
    );
    const delay = backoff / 2 + Math.random() * (backoff / 2);
    this.reconnectAttempts += 1;

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.openSocket();
    }, delay);
  }

  private rejectAllPending(err: unknown): void {
    if (this.pendingQueue.length === 0) return;
    const out = this.pendingQueue;
    this.pendingQueue = [];
    const normalized = toError(err);
    for (const pending of out) {
      clearTimeout(pending.timeout);
      pending.reject(normalized);
    }
  }

  private rejectReadyWaiters(err: unknown): void {
    if (this.readyWaiters.length === 0) return;
    const out = this.readyWaiters;
    this.readyWaiters = [];
    const normalized = toError(err);
    for (const waiter of out) waiter.reject(normalized);
  }

  private async removeHandler(channel: string, handler: EventHandler): Promise<void> {
    const entry = this.subs.get(channel);
    if (entry == null) return;
    entry.handlers.delete(handler);
    if (entry.handlers.size > 0) return;

    this.subs.delete(channel);
    // Only tell the server if we're connected; a dead/reconnecting link simply
    // won't resubscribe this channel.
    if (this.socket != null && this.stateValue === "ready") {
      try {
        await this.request(encodeCommandFrame({ kind: "UNSUB", channel }));
      } catch {
        // Connection died mid-unsub — the subscription is gone either way.
      }
    }
  }

  // -------------------------------------------------------------------------
  // Liveness ping
  // -------------------------------------------------------------------------

  private startPing(): void {
    if (this.pingIntervalMs <= 0 || this.pingTimer != null) return;
    this.pingTimer = setInterval(() => {
      if (this.stateValue !== "ready" || this.socket == null) return;
      if (Date.now() - this.lastActivityMs < this.pingIntervalMs) return;
      // STATUS doubles as the liveness probe; a timeout tears the connection
      // down and reconnect takes over.
      this.request(encodeCommandFrame({ kind: "STATUS" })).catch(() => {});
    }, this.pingIntervalMs);
  }

  private stopPing(): void {
    if (this.pingTimer != null) {
      clearInterval(this.pingTimer);
      this.pingTimer = null;
    }
  }

  // -------------------------------------------------------------------------
  // Backpressure-aware writes (same contract as client.ts)
  // -------------------------------------------------------------------------

  private writeOrQueue(socket: BunSocket, data: Bytes): void {
    if (this.writeBacklog.length > 0) {
      this.writeBacklog.push(data);
      return;
    }
    const written = socket.write(data);
    if (written < 0) throw new Error("socket.write failed");
    if (written < data.length) {
      this.writeBacklog.push(data.subarray(written));
    }
  }

  private flushBacklog(socket: BunSocket): void {
    while (this.writeBacklog.length > 0) {
      const chunk = this.writeBacklog[0];
      const written = socket.write(chunk);
      if (written < 0) {
        this.writeBacklog.shift();
        continue;
      }
      if (written < chunk.length) {
        this.writeBacklog[0] = chunk.subarray(written);
        return;
      }
      this.writeBacklog.shift();
    }
  }
}
