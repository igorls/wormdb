import { afterEach, describe, expect, test } from "bun:test";
import { WormDB, WormServerError, type WormEvent } from "./wormdb";
import { WIRE_MAGIC, concatBytes } from "./wire";

type SocketData = string | ArrayBuffer | SharedArrayBuffer | ArrayBufferView;
type TestSocket = {
  writes: Uint8Array[];
  ended: boolean;
  write(data: SocketData): number;
  end(): void;
};

type SocketHandlers = {
  open?(socket: TestSocket): void;
  data?(socket: TestSocket, data: SocketData): void;
  close?(socket: TestSocket): void;
  error?(socket: TestSocket, error: Error): void;
  drain?(socket: TestSocket): void;
};

type ConnectOpts = {
  hostname: string;
  port: number;
  socket: SocketHandlers;
};

const bunGlobal = Bun as unknown as {
  connect: (options: ConnectOpts) => Promise<TestSocket>;
};

const originalConnect = bunGlobal.connect;

afterEach(() => {
  bunGlobal.connect = originalConnect;
});

function utf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

function responseFrame(code: number, payload: Uint8Array = new Uint8Array(0)): Uint8Array {
  const hdr = new Uint8Array(5);
  hdr[0] = code;
  new DataView(hdr.buffer).setUint32(1, payload.length, false);
  return concatBytes([hdr, payload]);
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

type Conn = {
  socket: TestSocket;
  handlers: SocketHandlers;
  writes: Uint8Array[];
};

/** Multi-connection mock: every Bun.connect call records a fresh connection so
 * reconnect tests can inspect each socket's handlers and writes separately. */
function installConnectMock(): { conns: Conn[] } {
  const conns: Conn[] = [];

  bunGlobal.connect = async (opts: ConnectOpts) => {
    const writes: Uint8Array[] = [];
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

    conns.push({ socket, handlers: opts.socket, writes });
    opts.socket.open?.(socket);
    return socket;
  };

  return { conns };
}

function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

async function waitFor(cond: () => boolean, timeoutMs = 1000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error("waitFor timed out");
    await tick();
  }
}

function feed(conn: Conn, bytes: Uint8Array): void {
  conn.handlers.data?.(conn.socket, bytes);
}

/** Decode an EXEC frame into { procedure, args } (args as UTF-8 strings). */
function decodeExecFrame(frame: Uint8Array): { procedure: string; args: string[] } {
  expect(frame[0]).toBe(0x09);
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  const payloadLen = view.getUint32(1, false);
  expect(payloadLen).toBe(frame.length - 5);
  let off = 5;
  const procLen = view.getUint32(off, false);
  off += 4;
  const procedure = new TextDecoder().decode(frame.subarray(off, off + procLen));
  off += procLen;
  const argc = view.getUint32(off, false);
  off += 4;
  const args: string[] = [];
  for (let i = 0; i < argc; i += 1) {
    const argLen = view.getUint32(off, false);
    off += 4;
    args.push(new TextDecoder().decode(frame.subarray(off, off + argLen)));
    off += argLen;
  }
  expect(off).toBe(frame.length);
  return { procedure, args };
}

function newDb(overrides: Partial<ConstructorParameters<typeof WormDB>[0]> = {}): WormDB {
  return new WormDB({
    host: "127.0.0.1",
    port: 6389,
    timeoutMs: 500,
    reconnect: { enabled: false },
    ...overrides,
  });
}

/** Connect + drive one subscribe to completion, returning the sub promise. */
async function subscribeOk(
  db: WormDB,
  conns: Conn[],
  channel: string,
  handler: (evt: WormEvent) => void,
): ReturnType<WormDB["subscribe"]> {
  const p = db.subscribe(channel, handler);
  await tick();
  feed(conns[conns.length - 1], responseFrame(0x00));
  return await p;
}

describe("WormDB pub/sub push", () => {
  test("routes EVENT frames to handlers without confusing pending responses", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const seen: WormEvent[] = [];
    await subscribeOk(db, conns, "alpha", (evt) => seen.push(evt));

    // Interleave: EVENT arrives before the GET's Value response.
    const getP = db.get("k");
    await tick();
    feed(conns[0], concatBytes([
      responseFrame(0x04, eventPayload("alpha", "m1")),
      responseFrame(0x01, utf8("world")),
    ]));

    await expect(getP).resolves.toBe("world");
    expect(seen).toEqual([{ channel: "alpha", message: "m1" }]);

    await db.close();
  });

  test("routes by channel across multiple subscriptions, including prefix matches", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const alpha: WormEvent[] = [];
    const beta: WormEvent[] = [];
    const vecPrefix: WormEvent[] = [];
    await subscribeOk(db, conns, "alpha", (evt) => alpha.push(evt));
    await subscribeOk(db, conns, "beta", (evt) => beta.push(evt));
    await subscribeOk(db, conns, "vec:", (evt) => vecPrefix.push(evt));

    feed(conns[0], responseFrame(0x04, eventPayload("beta", "for-beta")));
    feed(conns[0], responseFrame(0x04, eventPayload("vec:ns:doc-1", "for-vec")));

    expect(alpha).toEqual([]);
    expect(beta).toEqual([{ channel: "beta", message: "for-beta" }]);
    // Server prefix-matching mirrored client-side: "vec:" catches "vec:ns:doc-1".
    expect(vecPrefix).toEqual([{ channel: "vec:ns:doc-1", message: "for-vec" }]);

    await db.close();
  });

  test("supports multiple handlers per channel and removal via unsubscribe", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const first: WormEvent[] = [];
    const second: WormEvent[] = [];
    const sub1 = await subscribeOk(db, conns, "alpha", (evt) => first.push(evt));
    // Second handler on the same channel — no second SUB frame goes out.
    const subFramesBefore = conns[0].writes.filter((w) => w[0] === 0x06).length;
    const sub2 = await db.subscribe("alpha", (evt) => second.push(evt));
    const subFramesAfter = conns[0].writes.filter((w) => w[0] === 0x06).length;
    expect(subFramesAfter).toBe(subFramesBefore);

    feed(conns[0], responseFrame(0x04, eventPayload("alpha", "both")));
    expect(first).toEqual([{ channel: "alpha", message: "both" }]);
    expect(second).toEqual([{ channel: "alpha", message: "both" }]);

    // Removing one handler keeps the channel live (no UNSUB frame).
    await sub1.unsubscribe();
    expect(conns[0].writes.filter((w) => w[0] === 0x07).length).toBe(0);

    feed(conns[0], responseFrame(0x04, eventPayload("alpha", "second-only")));
    expect(first.length).toBe(1);
    expect(second.length).toBe(2);

    // Removing the last handler sends UNSUB and stops routing.
    const unsubP = sub2.unsubscribe();
    await tick();
    expect(conns[0].writes.filter((w) => w[0] === 0x07).length).toBe(1);
    feed(conns[0], responseFrame(0x00));
    await unsubP;

    feed(conns[0], responseFrame(0x04, eventPayload("alpha", "nobody")));
    expect(second.length).toBe(2);

    await db.close();
  });
});

describe("WormDB events() async iterator", () => {
  test("delivers events in order", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const it = db.events("chan");
    await tick();
    feed(conns[0], responseFrame(0x00)); // SUB ok
    await tick();

    feed(conns[0], responseFrame(0x04, eventPayload("chan", "e1")));
    feed(conns[0], responseFrame(0x04, eventPayload("chan", "e2")));

    await expect(it.next()).resolves.toEqual({ done: false, value: { channel: "chan", message: "e1" } });
    await expect(it.next()).resolves.toEqual({ done: false, value: { channel: "chan", message: "e2" } });

    // Waiting next() wakes when a later event arrives.
    const pendingNext = it.next();
    feed(conns[0], responseFrame(0x04, eventPayload("chan", "e3")));
    await expect(pendingNext).resolves.toEqual({ done: false, value: { channel: "chan", message: "e3" } });

    const retP = it.return!();
    await tick();
    feed(conns[0], responseFrame(0x00)); // UNSUB ok
    await expect(retP).resolves.toEqual({ done: true, value: undefined });

    await db.close();
  });

  test("bounded queue drops oldest on overflow and counts drops", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const it = db.events("chan", { queueLimit: 2 });
    await tick();
    feed(conns[0], responseFrame(0x00));
    await tick();

    feed(conns[0], responseFrame(0x04, eventPayload("chan", "e1")));
    feed(conns[0], responseFrame(0x04, eventPayload("chan", "e2")));
    feed(conns[0], responseFrame(0x04, eventPayload("chan", "e3"))); // e1 dropped

    expect(it.dropped).toBe(1);
    await expect(it.next()).resolves.toEqual({ done: false, value: { channel: "chan", message: "e2" } });
    await expect(it.next()).resolves.toEqual({ done: false, value: { channel: "chan", message: "e3" } });

    await db.close();
  });
});

describe("WormDB auth", () => {
  test("auth() sends 0x0C frame with length-prefixed token", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const token = Uint8Array.of(0xde, 0xad, 0xbe, 0xef);
    const authP = db.auth(token);
    await tick();

    const frame = conns[0].writes[conns[0].writes.length - 1];
    // [0x0C][u32 payloadLen=8][u32 tokenLen=4][token]
    expect(Array.from(frame)).toEqual([0x0c, 0, 0, 0, 8, 0, 0, 0, 4, 0xde, 0xad, 0xbe, 0xef]);

    feed(conns[0], responseFrame(0x00));
    await expect(authP).resolves.toBeUndefined();

    await db.close();
  });

  test("auth() accepts base64 string tokens", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const authP = db.auth(btoa(String.fromCharCode(1, 2, 3)));
    await tick();
    const frame = conns[0].writes[conns[0].writes.length - 1];
    expect(Array.from(frame)).toEqual([0x0c, 0, 0, 0, 7, 0, 0, 0, 3, 1, 2, 3]);

    feed(conns[0], responseFrame(0x00));
    await authP;
    await db.close();
  });

  test("auth() rejects with WormServerError on ERR response", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const authP = db.auth(Uint8Array.of(1));
    await tick();
    feed(conns[0], responseFrame(0x03, utf8("invalid signature")));

    await expect(authP).rejects.toBeInstanceOf(WormServerError);
    await expect(db.auth(Uint8Array.of(1)).catch((e) => e.message)).resolves.toBeDefined();
    await db.close();
  });
});

describe("WormDB reconnect lifecycle", () => {
  test("close -> backoff -> reconnect re-sends magic, AUTH, then SUB frames in order", async () => {
    const { conns } = installConnectMock();
    const db = newDb({ reconnect: { enabled: true, minDelayMs: 1, maxDelayMs: 2 } });

    // Authenticate and subscribe on the first connection.
    const token = Uint8Array.of(9, 9, 9);
    const authP = db.auth(token);
    await tick();
    feed(conns[0], responseFrame(0x00));
    await authP;

    const seen: WormEvent[] = [];
    await subscribeOk(db, conns, "alpha", (evt) => seen.push(evt));
    expect(db.state).toBe("ready");

    // In-flight request at disconnect rejects (no silent replay).
    const inflight = db.get("k");
    await tick();
    conns[0].handlers.close?.(conns[0].socket);
    await expect(inflight).rejects.toThrow("Connection closed before receiving a response");
    expect(db.state).toBe("reconnecting");

    // Backoff elapses -> a second connection is dialed.
    await waitFor(() => conns.length === 2);
    const w = conns[1].writes;

    // Byte order on the new socket: magic, AUTH frame, SUB frame.
    expect(Array.from(w[0])).toEqual(Array.from(WIRE_MAGIC));
    expect(w[1][0]).toBe(0x0c);
    expect(Array.from(w[1].subarray(9))).toEqual([9, 9, 9]);
    expect(w[2][0]).toBe(0x06);
    const chanLen = new DataView(w[2].buffer, w[2].byteOffset, w[2].byteLength).getUint32(5, false);
    expect(new TextDecoder().decode(w[2].subarray(9, 9 + chanLen))).toBe("alpha");

    expect(db.state).toBe("ready");

    // Settle the pipelined AUTH + SUB responses, then verify the connection works.
    feed(conns[1], responseFrame(0x00));
    feed(conns[1], responseFrame(0x00));

    const getP = db.get("k2");
    await tick();
    feed(conns[1], responseFrame(0x01, utf8("v2")));
    await expect(getP).resolves.toBe("v2");

    // Events flow again after resubscribe.
    feed(conns[1], responseFrame(0x04, eventPayload("alpha", "back")));
    expect(seen).toEqual([{ channel: "alpha", message: "back" }]);

    await db.close();
  });

  test("reconnect disabled: connection drop rejects in-flight and returns to idle", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const getP = db.get("k");
    await tick();
    conns[0].handlers.close?.(conns[0].socket);

    await expect(getP).rejects.toThrow("Connection closed before receiving a response");
    expect(db.state).toBe("idle");
    expect(conns.length).toBe(1);

    // Next call lazily dials a fresh connection.
    const getP2 = db.get("k");
    await tick();
    expect(conns.length).toBe(2);
    feed(conns[1], responseFrame(0x02));
    await expect(getP2).resolves.toBeNull();

    await db.close();
  });

  test("closed client refuses new requests", async () => {
    installConnectMock();
    const db = newDb();
    await db.close();
    expect(db.state).toBe("closed");
    await expect(db.get("k")).rejects.toThrow("Connection closed before receiving a response");
  });
});

describe("WormDB appendLog wrappers", () => {
  test("append encodes EXEC args and parses the receipt", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const p = db.appendLog.append("audit", "hello", { tsMs: 1234, attachmentHashesHex: ["aabb", "ccdd"] });
    await tick();

    const { procedure, args } = decodeExecFrame(conns[0].writes[conns[0].writes.length - 1]);
    expect(procedure).toBe("append_log_append");
    expect(args).toEqual(["audit", "hello", "ts=1234", "aabb", "ccdd"]);

    const receipt = {
      seq: 7,
      ingest_time_ms: 1234,
      key_hex: "6b",
      prev_event_hash: "00",
      payload_hash: "aa",
      event_hash: "bb",
      accumulator_kind: "mmr",
      accumulator_root: "cc",
      accumulator_leaf_count: 7,
    };
    feed(conns[0], responseFrame(0x01, utf8(JSON.stringify(receipt))));
    await expect(p).resolves.toEqual(receipt);

    await db.close();
  });

  test("verify encodes args and parses result; verifiers unwrap valid flag", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const verifyP = db.appendLog.verify("audit");
    await tick();
    expect(decodeExecFrame(conns[0].writes[conns[0].writes.length - 1])).toEqual({
      procedure: "append_log_verify",
      args: ["audit"],
    });
    feed(conns[0], responseFrame(0x01, utf8('{"count":3,"last_seq":3,"head_hash":"ff"}')));
    await expect(verifyP).resolves.toEqual({ count: 3, last_seq: 3, head_hash: "ff" });

    const mmrVerifyP = db.appendLog.mmrVerify("aa", "bb", "cc");
    await tick();
    expect(decodeExecFrame(conns[0].writes[conns[0].writes.length - 1])).toEqual({
      procedure: "append_log_mmr_verify",
      args: ["aa", "bb", "cc"],
    });
    feed(conns[0], responseFrame(0x01, utf8('{"valid":true}')));
    await expect(mmrVerifyP).resolves.toBe(true);

    await db.close();
  });

  test("checkpoint requires a signing input and encodes kv options", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    await expect(
      db.appendLog.checkpoint("audit", { fromSeq: 1, toSeq: 5, creatorPubkeyHex: "ab" }),
    ).rejects.toThrow("skHex or sigHex");

    const p = db.appendLog.checkpoint("audit", {
      fromSeq: 1,
      toSeq: 5,
      creatorPubkeyHex: "ab",
      skHex: "cd",
      prevHex: "ef",
    });
    await tick();
    expect(decodeExecFrame(conns[0].writes[conns[0].writes.length - 1])).toEqual({
      procedure: "append_log_checkpoint",
      args: ["audit", "1", "5", "ab", "sk=cd", "prev=ef"],
    });
    feed(conns[0], responseFrame(0x01, utf8('{"checkpoint_hash":"12"}')));
    await expect(p).resolves.toEqual({ checkpoint_hash: "12" });

    await db.close();
  });

  test("witnessRequest unwraps the requested count", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const p = db.appendLog.witnessRequest("audit", "beef");
    await tick();
    expect(decodeExecFrame(conns[0].writes[conns[0].writes.length - 1])).toEqual({
      procedure: "append_log_witness_request",
      args: ["audit", "beef"],
    });
    feed(conns[0], responseFrame(0x01, utf8('{"requested":2}')));
    await expect(p).resolves.toBe(2);

    await db.close();
  });
});

describe("WormDB vsearch wrapper", () => {
  test("encodes positional args (padding skipped slots) and parses hits", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const p = db.vsearch("vec:mem:q1", 5, { namespace: "vec:mem:", metric: "cosine", decayTauHours: 12 });
    await tick();
    expect(decodeExecFrame(conns[0].writes[conns[0].writes.length - 1])).toEqual({
      procedure: "vsearch",
      args: ["vec:mem:q1", "5", "vec:mem:", "cosine", "0", "auto", "12"],
    });

    feed(conns[0], responseFrame(0x01, utf8('[{"k":"vec:mem:a","s":0.91,"ts":1700000000000}]')));
    await expect(p).resolves.toEqual([{ k: "vec:mem:a", s: 0.91, ts: 1700000000000 }]);

    await db.close();
  });

  test("no opts sends only query_key + top_k; a lone later opt pads earlier defaults", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const bare = db.vsearch("vec:mem:q1", 3);
    await tick();
    expect(decodeExecFrame(conns[0].writes[conns[0].writes.length - 1])).toEqual({
      procedure: "vsearch",
      args: ["vec:mem:q1", "3"],
    });
    feed(conns[0], responseFrame(0x01, utf8("[]")));
    await expect(bare).resolves.toEqual([]);

    const sparse = db.vsearch("vec:mem:q1", 3, { mode: "exact" });
    await tick();
    expect(decodeExecFrame(conns[0].writes[conns[0].writes.length - 1])).toEqual({
      procedure: "vsearch",
      args: ["vec:mem:q1", "3", "vec:", "cosine", "0", "exact"],
    });
    feed(conns[0], responseFrame(0x01, utf8("[]")));
    await expect(sparse).resolves.toEqual([]);

    await db.close();
  });

  test("server ERR surfaces as WormServerError", async () => {
    const { conns } = installConnectMock();
    const db = newDb();

    const p = db.vsearch("missing", 3);
    await tick();
    feed(conns[0], responseFrame(0x03, utf8("vsearch: query key not found")));
    await expect(p).rejects.toBeInstanceOf(WormServerError);

    await db.close();
  });
});
