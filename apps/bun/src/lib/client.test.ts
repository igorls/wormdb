import { afterEach, describe, expect, test } from "bun:test";
import { parseCommand } from "./command";
import { WormClient } from "./client";
import { WIRE_MAGIC, concatBytes, encodeCommandFrame } from "./wire";

type SocketData = string | ArrayBuffer | SharedArrayBuffer | ArrayBufferView;
type TestSocket = {
  writes: Uint8Array[];
  ended: boolean;
  write(data: SocketData): number;
  end(): void;
};

type ConnectOpts = {
  hostname: string;
  port: number;
  socket: {
    open?(socket: TestSocket): void;
    data?(socket: TestSocket, data: SocketData): void;
    close?(socket: TestSocket): void;
    error?(socket: TestSocket, error: Error): void;
  };
};

const bunGlobal = Bun as unknown as {
  connect: (options: ConnectOpts) => Promise<TestSocket>;
};

const originalConnect = bunGlobal.connect;

afterEach(() => {
  bunGlobal.connect = originalConnect;
});

function responseFrame(code: number, payload: Uint8Array = new Uint8Array(0)): Uint8Array {
  const hdr = new Uint8Array(5);
  hdr[0] = code;
  new DataView(hdr.buffer).setUint32(1, payload.length, false);
  return concatBytes([hdr, payload]);
}

function utf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

function eventPayload(channel: string, message: string): Uint8Array {
  const c = utf8(channel);
  const m = utf8(message);
  const cl = new Uint8Array(4);
  const ml = new Uint8Array(4);
  new DataView(cl.buffer).setUint32(0, c.length, false);
  new DataView(ml.buffer).setUint32(0, m.length, false);
  return concatBytes([cl, c, ml, m]);
}

function installConnectMock(
  setup: (opts: ConnectOpts, socket: TestSocket) => void,
): { lastWrite: () => Uint8Array | undefined } {
  const writes: Uint8Array[] = [];

  bunGlobal.connect = async (opts: ConnectOpts) => {
    const socket: TestSocket = {
      writes,
      ended: false,
      write(data: SocketData): number {
        const asBytes =
          typeof data === "string"
            ? utf8(data)
            : data instanceof ArrayBuffer || data instanceof SharedArrayBuffer
              ? new Uint8Array(data)
              : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
        writes.push(asBytes);
        return asBytes.length;
      },
      end(): void {
        socket.ended = true;
      },
    };

    setup(opts, socket);
    opts.socket.open?.(socket);
    return socket;
  };

  return {
    lastWrite: () => writes[writes.length - 1],
  };
}

type SocketHandlers = ConnectOpts["socket"];

function captureHandlers(setup: (opts: ConnectOpts, socket: TestSocket) => void) {
  const box: { h: SocketHandlers | null } = { h: null };
  const monitor = installConnectMock((opts, socket) => {
    setup(opts, socket);
    box.h = opts.socket;
  });
  return { handlers: () => box.h!, monitor };
}

describe("WormClient", () => {
  test("writes magic + encoded command and resolves OK", async () => {
    const { handlers, monitor } = captureHandlers(() => { });

    const client = new WormClient({ host: "127.0.0.1", port: 6389, timeoutMs: 500 });
    const req = client.send("STATUS");

    handlers().data?.({} as TestSocket, responseFrame(0x00));
    await expect(req).resolves.toEqual({ type: "ok" });

    const sent = monitor.lastWrite();
    expect(sent).toBeDefined();

    const expected = concatBytes([WIRE_MAGIC, encodeCommandFrame(parseCommand("STATUS"))]);
    expect(Array.from(sent ?? [])).toEqual(Array.from(expected));
  });

  test("handles event interleaving before value response", async () => {
    const { handlers } = captureHandlers(() => { });

    const client = new WormClient({ host: "127.0.0.1", port: 6389, timeoutMs: 500 });
    const req = client.send("GET alpha");

    const event = responseFrame(0x04, eventPayload("updates", "hello"));
    const value = responseFrame(0x01, utf8("world"));
    handlers().data?.({} as TestSocket, concatBytes([event, value]));

    await expect(req).resolves.toEqual({ type: "bulk", value: "world" });
  });

  test("handles chunked frame delivery", async () => {
    const { handlers } = captureHandlers(() => { });

    const client = new WormClient({ host: "127.0.0.1", port: 6389, timeoutMs: 500 });
    const req = client.send("GET alpha");

    const frame = responseFrame(0x01, utf8("chunked"));
    handlers().data?.({} as TestSocket, frame.subarray(0, 3));
    handlers().data?.({} as TestSocket, frame.subarray(3, 6));
    handlers().data?.({} as TestSocket, frame.subarray(6));

    await expect(req).resolves.toEqual({ type: "bulk", value: "chunked" });
  });

  test("rejects when server closes before response", async () => {
    const { handlers } = captureHandlers(() => { });

    const client = new WormClient({ host: "127.0.0.1", port: 6389, timeoutMs: 500 });
    const req = client.send("STATUS");

    handlers().close?.({} as TestSocket);
    await expect(req).rejects.toThrow("Connection closed before receiving a response");
  });

  test("rejects on socket error callback", async () => {
    const { handlers } = captureHandlers(() => { });

    const client = new WormClient({ host: "127.0.0.1", port: 6389, timeoutMs: 500 });
    const req = client.send("STATUS");

    handlers().error?.({} as TestSocket, new Error("boom"));
    await expect(req).rejects.toThrow("boom");
  });

  test("rejects if Bun.connect throws", async () => {
    bunGlobal.connect = async () => {
      throw new Error("connect failed");
    };

    const client = new WormClient({ host: "127.0.0.1", port: 6389, timeoutMs: 500 });
    await expect(client.send("STATUS")).rejects.toThrow("connect failed");
  });

  test("rejects with timeout when no response arrives", async () => {
    installConnectMock(() => {
      // Intentionally do nothing.
    });

    const client = new WormClient({ host: "127.0.0.1", port: 6389, timeoutMs: 20 });
    await expect(client.send("STATUS")).rejects.toThrow("Timed out after 20ms");
  });

  test("normalizes non-Error thrown values", async () => {
    bunGlobal.connect = async () => {
      throw "failed as string";
    };

    const client = new WormClient({ host: "127.0.0.1", port: 6389, timeoutMs: 500 });
    await expect(client.send("STATUS")).rejects.toThrow("failed as string");
  });
});
