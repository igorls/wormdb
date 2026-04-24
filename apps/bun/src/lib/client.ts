import { parseCommand, type ParsedCommand } from "./command";
import {
  WIRE_MAGIC,
  concatBytes,
  decodeResponse,
  encodeCommandFrame,
  isEventCode,
  toBytes,
  tryConsumeFrame,
  type Bytes,
} from "./wire";
import type { WormResponse } from "./protocol";

export type WormClientOptions = {
  host: string;
  port: number;
  timeoutMs?: number;
  keepAlive?: boolean;
};

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
};

type BunGlobal = {
  connect(options: { hostname: string; port: number; socket: BunSocketHandlers }): Promise<BunSocket>;
};

declare const Bun: BunGlobal;

class ClientTimeoutError extends Error {
  code = "ETIMEDOUT" as const;

  constructor(timeoutMs: number) {
    super(`Timed out after ${timeoutMs}ms`);
    this.name = "ClientTimeoutError";
  }
}

class ClientConnectionClosedError extends Error {
  code = "ECONNCLOSED" as const;

  constructor() {
    super("Connection closed before receiving a response");
    this.name = "ClientConnectionClosedError";
  }
}

export class WormClient {
  private readonly host: string;
  private readonly port: number;
  private readonly timeoutMs: number;
  private readonly keepAlive: boolean;

  private socket: BunSocket | null = null;
  private connectPromise: Promise<BunSocket> | null = null;
  private inbound: Bytes = new Uint8Array(0);
  private pendingQueue: Array<{
    resolve: (value: WormResponse) => void;
    reject: (reason?: unknown) => void;
    timeout: ReturnType<typeof setTimeout>;
  }> = [];

  constructor(options: WormClientOptions) {
    this.host = options.host;
    this.port = options.port;
    this.timeoutMs = options.timeoutMs ?? 3000;
    this.keepAlive = options.keepAlive ?? false;
  }

  async send(command: string): Promise<WormResponse> {
    if (this.keepAlive) {
      return this.sendPersistent(parseCommand(command));
    }

    return this.sendOneShotParsed(parseCommand(command));
  }

  async sendCommand(parsed: ParsedCommand): Promise<WormResponse> {
    if (this.keepAlive) {
      return this.sendPersistent(parsed);
    }
    return this.sendOneShotParsed(parsed);
  }

  async vinsertNative(
    key: string,
    vector: Uint8Array,
    options: {
      worm?: boolean;
      namespace?: string;
      metric?: "cosine" | "dot" | "l2";
      timestamp?: bigint;
      async?: boolean;
    } = {},
  ): Promise<WormResponse> {
    return this.sendCommand({
      kind: "VINSERT",
      key,
      vector,
      worm: options.worm ?? true,
      namespace: options.namespace ?? "vec:",
      metric: options.metric ?? "cosine",
      timestamp: options.timestamp ?? BigInt(Date.now()),
      async: options.async ?? false,
    });
  }

  async close(): Promise<void> {
    this.rejectAllPending(new ClientConnectionClosedError());

    if (this.socket != null) {
      try {
        this.socket.end();
      } catch {
        // Best effort close.
      }
      this.socket = null;
    }

    this.connectPromise = null;
    this.inbound = new Uint8Array(0);
  }

  private async sendOneShotParsed(parsed: ParsedCommand): Promise<WormResponse> {
    const outboundFrame = concatBytes([WIRE_MAGIC, encodeCommandFrame(parsed)]);

    return await new Promise<WormResponse>(async (resolve, reject) => {
      let settled = false;
      let inbound: Bytes = new Uint8Array(0);
      let socketRef: BunSocket | null = null;

      const finalize = (fn: () => void): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        try {
          socketRef?.end();
        } catch {
          // Best effort close.
        }
        fn();
      };

      const fail = (err: unknown): void => {
        finalize(() => {
          reject(toError(err));
        });
      };

      const timeout = setTimeout(() => {
        fail(new ClientTimeoutError(this.timeoutMs));
      }, this.timeoutMs);

      const finish = (value: WormResponse) => {
        finalize(() => {
          resolve(value);
        });
      };

      try {
        socketRef = await Bun.connect({
          hostname: this.host,
          port: this.port,
          socket: {
            open(socket) {
              socket.write(outboundFrame);
            },
            data(_socket, chunk) {
              inbound = concatBytes([inbound, toBytes(chunk)]);

              while (!settled) {
                const frame = tryConsumeFrame(inbound);
                if (frame == null) {
                  return;
                }

                inbound = frame.remaining;

                if (isEventCode(frame.code)) {
                  // Event frames can interleave responses; ignore in one-shot request/response flow.
                  continue;
                }

                finish(decodeResponse(frame.code, frame.payload));
                return;
              }
            },
            close() {
              if (!settled) {
                fail(new ClientConnectionClosedError());
              }
            },
            error(_socket, err) {
              fail(err);
            },
          }
        });
      } catch (err) {
        fail(err);
      }
    });
  }

  private async sendPersistent(parsed: ParsedCommand): Promise<WormResponse> {
    const outboundFrame = encodeCommandFrame(parsed);
    const socket = await this.getOrCreateSocket();

    return await new Promise<WormResponse>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.rejectAllPending(new ClientTimeoutError(this.timeoutMs));
      }, this.timeoutMs);

      this.pendingQueue.push({ resolve, reject, timeout });

      // Write synchronously — TCP guarantees ordered delivery.
      // No need for a promise chain that adds microtask overhead per op.
      try {
        socket.write(outboundFrame);
      } catch (err) {
        const pending = this.pendingQueue.pop();
        if (pending) {
          clearTimeout(pending.timeout);
          pending.reject(toError(err));
        }
      }
    });
  }

  private async getOrCreateSocket(): Promise<BunSocket> {
    if (this.socket != null) {
      return this.socket;
    }

    if (this.connectPromise != null) {
      return await this.connectPromise;
    }

    this.connectPromise = Bun.connect({
      hostname: this.host,
      port: this.port,
      socket: {
        open: (socket) => {
          this.socket = socket;
          this.inbound = new Uint8Array(0);
          socket.write(WIRE_MAGIC);
        },
        data: (_socket, chunk) => {
          this.inbound = concatBytes([this.inbound, toBytes(chunk)]);

          while (true) {
            const frame = tryConsumeFrame(this.inbound);
            if (frame == null) {
              return;
            }

            this.inbound = frame.remaining;

            if (isEventCode(frame.code)) {
              continue;
            }

            const pending = this.pendingQueue.shift();
            if (pending == null) {
              continue;
            }

            clearTimeout(pending.timeout);
            pending.resolve(decodeResponse(frame.code, frame.payload));
          }
        },
        close: () => {
          this.socket = null;
          this.connectPromise = null;
          this.rejectAllPending(new ClientConnectionClosedError());
        },
        error: (_socket, err) => {
          this.socket = null;
          this.connectPromise = null;
          this.rejectAllPending(err);
        },
      },
    }).then(
      (socket) => {
        this.connectPromise = null;
        return socket;
      },
      (err) => {
        this.connectPromise = null;
        throw err;
      },
    );

    return await this.connectPromise;
  }

  private rejectAllPending(err: unknown): void {
    if (this.pendingQueue.length === 0) {
      return;
    }

    const out = this.pendingQueue;
    this.pendingQueue = [];
    const normalized = toError(err);

    for (const pending of out) {
      clearTimeout(pending.timeout);
      pending.reject(normalized);
    }
  }
}

function toError(err: unknown): Error {
  if (err instanceof Error) {
    return err;
  }
  return new Error(String(err));
}
