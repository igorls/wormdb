import { describe, expect, test } from "bun:test";
import type { ParsedCommand } from "./command";
import {
  WIRE_MAGIC,
  concatBytes,
  decodeResponse,
  encodeCommandFrame,
  isEventCode,
  toBytes,
  tryConsumeFrame,
} from "./wire";

function asHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function u32be(n: number): Uint8Array {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, n, false);
  return out;
}

describe("wire helpers", () => {
  test("exposes magic", () => {
    expect(asHex(WIRE_MAGIC)).toBe("5757");
  });

  test("concatBytes joins chunks", () => {
    const out = concatBytes([Uint8Array.of(1, 2), Uint8Array.of(3), Uint8Array.of(4, 5)]);
    expect(Array.from(out)).toEqual([1, 2, 3, 4, 5]);
  });

  test("toBytes handles string, arraybuffer, and typed arrays", () => {
    expect(asHex(toBytes("ok"))).toBe("6f6b");

    const ab = new Uint8Array([9, 8, 7]).buffer;
    expect(Array.from(toBytes(ab))).toEqual([9, 8, 7]);

    const src = new Uint8Array([0, 1, 2, 3]);
    const view = src.subarray(1, 3);
    expect(Array.from(toBytes(view))).toEqual([1, 2]);
  });
});

describe("encodeCommandFrame", () => {
  test("encodes GET", () => {
    const frame = encodeCommandFrame({ kind: "GET", key: "abc" });
    expect(frame[0]).toBe(0x01);
    expect(asHex(frame.subarray(1, 5))).toBe("00000007");
    expect(asHex(frame.subarray(5, 9))).toBe("00000003");
    expect(new TextDecoder().decode(frame.subarray(9))).toBe("abc");
  });

  test("encodes STATUS and CLUSTER STATUS with empty payload", () => {
    const status = encodeCommandFrame({ kind: "STATUS" });
    const cluster = encodeCommandFrame({ kind: "CLUSTER_STATUS" });
    expect(asHex(status)).toBe("0400000000");
    expect(asHex(cluster)).toBe("0500000000");
  });

  test("encodes SET with worm flag", () => {
    const frame = encodeCommandFrame({ kind: "SET", key: "k", value: "value", worm: true });
    expect(frame[0]).toBe(0x02);
    expect(frame[5]).toBe(0x01);
  });

  test("encodes PUB", () => {
    const frame = encodeCommandFrame({ kind: "PUB", channel: "c", message: "hello" });
    expect(frame[0]).toBe(0x08);
    expect(new TextDecoder().decode(frame.subarray(frame.length - 5))).toBe("hello");
  });

  test("covers all parsed command variants", () => {
    const cmds: ParsedCommand[] = [
      { kind: "GET", key: "a" },
      { kind: "DEL", key: "a" },
      { kind: "SUB", channel: "c" },
      { kind: "UNSUB", channel: "c" },
      { kind: "STATUS" },
      { kind: "CLUSTER_STATUS" },
      { kind: "SET", key: "k", value: "v", worm: false },
      { kind: "PUB", channel: "c", message: "m" },
    ];

    for (const cmd of cmds) {
      const encoded = encodeCommandFrame(cmd);
      expect(encoded.length).toBeGreaterThanOrEqual(5);
    }
  });

  test("encodes VINSERT with expected layout", () => {
    const key = "vec:articles:doc-1";
    const vector = new Uint8Array([0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0x40]); // 1.0, 2.0
    const namespace = "vec:articles:";
    const metric = "cosine" as const;
    const timestamp = 0x0123456789abcdefn;

    const frame = encodeCommandFrame({
      kind: "VINSERT",
      key,
      vector,
      worm: true,
      namespace,
      metric,
      timestamp,
    });

    expect(frame[0]).toBe(0x0d);

    const payloadLen = new DataView(frame.buffer, frame.byteOffset + 1, 4).getUint32(0, false);
    expect(payloadLen).toBe(frame.length - 5);

    let off = 5;
    const keyLen = new DataView(frame.buffer, frame.byteOffset + off, 4).getUint32(0, false);
    expect(keyLen).toBe(key.length);
    off += 4;
    expect(new TextDecoder().decode(frame.subarray(off, off + keyLen))).toBe(key);
    off += keyLen;

    const vecLen = new DataView(frame.buffer, frame.byteOffset + off, 4).getUint32(0, false);
    expect(vecLen).toBe(vector.length);
    off += 4;
    expect(Array.from(frame.subarray(off, off + vecLen))).toEqual(Array.from(vector));
    off += vecLen;

    expect(frame[off]).toBe(0x01); // worm
    off += 1;

    const nsLen = new DataView(frame.buffer, frame.byteOffset + off, 4).getUint32(0, false);
    expect(nsLen).toBe(namespace.length);
    off += 4;
    expect(new TextDecoder().decode(frame.subarray(off, off + nsLen))).toBe(namespace);
    off += nsLen;

    const metricLen = new DataView(frame.buffer, frame.byteOffset + off, 4).getUint32(0, false);
    expect(metricLen).toBe(metric.length);
    off += 4;
    expect(new TextDecoder().decode(frame.subarray(off, off + metricLen))).toBe(metric);
    off += metricLen;

    const ts = new DataView(frame.buffer, frame.byteOffset + off, 8).getBigUint64(0, false);
    expect(ts).toBe(timestamp);
  });

  test("throws for unsupported command variant at runtime", () => {
    expect(() => encodeCommandFrame({ kind: "INVALID" } as unknown as ParsedCommand)).toThrow(
      "Unhandled variant",
    );
  });
});

describe("frame consume/decode", () => {
  test("returns null for incomplete header or payload", () => {
    expect(tryConsumeFrame(Uint8Array.of(1, 2, 3, 4))).toBeNull();

    const frame = concatBytes([Uint8Array.of(0x01), u32be(10), Uint8Array.of(1, 2)]);
    expect(tryConsumeFrame(frame)).toBeNull();
  });

  test("consumes a frame and returns remaining bytes", () => {
    const frameA = concatBytes([Uint8Array.of(0x01), u32be(2), Uint8Array.of(0xaa, 0xbb)]);
    const frameB = concatBytes([Uint8Array.of(0x00), u32be(0)]);
    const all = concatBytes([frameA, frameB]);

    const first = tryConsumeFrame(all);
    expect(first).not.toBeNull();
    expect(first?.code).toBe(0x01);
    expect(Array.from(first?.payload ?? [])).toEqual([0xaa, 0xbb]);

    const second = tryConsumeFrame(first!.remaining);
    expect(second?.code).toBe(0x00);
    expect(second?.payload.length).toBe(0);
    expect(second?.remaining.length).toBe(0);
  });

  test("detects event code", () => {
    expect(isEventCode(0x04)).toBe(true);
    expect(isEventCode(0x03)).toBe(false);
  });

  test("decodes ok/value/null/error/unknown responses", () => {
    expect(decodeResponse(0x00, new Uint8Array())).toEqual({ type: "ok" });
    expect(decodeResponse(0x01, toBytes("value"))).toEqual({ type: "bulk", value: "value" });
    expect(decodeResponse(0x02, new Uint8Array())).toEqual({ type: "null" });
    expect(decodeResponse(0x03, toBytes("boom"))).toEqual({ type: "error", message: "boom" });
    expect(decodeResponse(0xff, new Uint8Array())).toEqual({ type: "error", message: "Unknown response code: 255" });
  });

  test("decodes event response", () => {
    const channel = toBytes("updates");
    const message = toBytes("hello");
    const payload = concatBytes([u32be(channel.length), channel, u32be(message.length), message]);

    expect(decodeResponse(0x04, payload)).toEqual({
      type: "event",
      channel: "updates",
      message: "hello",
    });
  });

  test("reports malformed event responses", () => {
    expect(decodeResponse(0x04, Uint8Array.of(1, 2, 3))).toEqual({
      type: "error",
      message: "Malformed event response",
    });

    const badLayout = concatBytes([u32be(10), Uint8Array.of(0, 0, 0, 0)]);
    expect(decodeResponse(0x04, badLayout)).toEqual({
      type: "error",
      message: "Malformed event response",
    });

    const channel = toBytes("c");
    const badMsg = concatBytes([u32be(channel.length), channel, u32be(10), toBytes("tiny")]);
    expect(decodeResponse(0x04, badMsg)).toEqual({
      type: "error",
      message: "Malformed event response",
    });
  });
});
