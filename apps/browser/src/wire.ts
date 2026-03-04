/**
 * WormWire binary protocol encoder/decoder for browser WebSocket.
 *
 * Each binary WebSocket message = one WormWire frame:
 *   [1B cmd/resp code][4B payload length (big-endian)][payload...]
 *
 * No WIRE_MAGIC handshake needed — WebSocket handles connection framing.
 * @module
 */

// ── Command codes ──────────────────────────────────────────────────────

export const CMD = {
    GET: 0x01,
    SET: 0x02,
    DEL: 0x03,
    STATUS: 0x04,
    CLUSTER_STATUS: 0x05,
    SUB: 0x06,
    UNSUB: 0x07,
    PUB: 0x08,
    EXEC: 0x09,
    CLUSTER_PEERS: 0x0A,
    SAVE: 0x0B,
    AUTH: 0x0C,
} as const;

// ── Response codes ─────────────────────────────────────────────────────

export const RESP = {
    OK: 0x00,
    VALUE: 0x01,
    NULL: 0x02,
    ERR: 0x03,
    EVENT: 0x04,
} as const;

// ── Types ──────────────────────────────────────────────────────────────

export type WormResponse =
    | { type: "ok" }
    | { type: "error"; message: string }
    | { type: "null" }
    | { type: "value"; data: string }
    | { type: "event"; channel: string; message: string };

// ── Encoding ───────────────────────────────────────────────────────────

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function u8(s: string): Uint8Array { return encoder.encode(s); }
function str(b: Uint8Array): string { return decoder.decode(b); }

function writeU32BE(target: Uint8Array, offset: number, value: number): void {
    const view = new DataView(target.buffer, target.byteOffset, target.byteLength);
    view.setUint32(offset, value, false);
}

function readU32BE(source: Uint8Array, offset: number): number {
    const view = new DataView(source.buffer, source.byteOffset, source.byteLength);
    return view.getUint32(offset, false);
}

/** Encode a WormWire frame: [1B code][4B len][payload] */
function frame(code: number, payload: Uint8Array): Uint8Array {
    const out = new Uint8Array(5 + payload.length);
    out[0] = code;
    writeU32BE(out, 1, payload.length);
    out.set(payload, 5);
    return out;
}

/** Encode a length-prefixed UTF-8 string field: [4B len][bytes] */
function lenPrefixed(s: string): Uint8Array {
    const data = u8(s);
    const out = new Uint8Array(4 + data.length);
    writeU32BE(out, 0, data.length);
    out.set(data, 4);
    return out;
}

/** Encode a length-prefixed binary field: [4B len][bytes] */
function lenPrefixedBytes(data: Uint8Array): Uint8Array {
    const out = new Uint8Array(4 + data.length);
    writeU32BE(out, 0, data.length);
    out.set(data, 4);
    return out;
}

// ── Command Encoders ───────────────────────────────────────────────────

export function encodeGet(key: string): Uint8Array {
    return frame(CMD.GET, lenPrefixed(key));
}

export function encodeSet(key: string, value: string, worm = false): Uint8Array {
    const keyBuf = u8(key);
    const valBuf = u8(value);
    const payload = new Uint8Array(1 + 4 + keyBuf.length + 4 + valBuf.length);
    payload[0] = worm ? 0x01 : 0x00;
    let off = 1;
    writeU32BE(payload, off, keyBuf.length); off += 4;
    payload.set(keyBuf, off); off += keyBuf.length;
    writeU32BE(payload, off, valBuf.length); off += 4;
    payload.set(valBuf, off);
    return frame(CMD.SET, payload);
}

export function encodeDel(key: string): Uint8Array {
    return frame(CMD.DEL, lenPrefixed(key));
}

export function encodeStatus(): Uint8Array {
    return frame(CMD.STATUS, new Uint8Array(0));
}

export function encodeSub(channel: string): Uint8Array {
    return frame(CMD.SUB, lenPrefixed(channel));
}

export function encodeUnsub(channel: string): Uint8Array {
    return frame(CMD.UNSUB, lenPrefixed(channel));
}

export function encodePub(channel: string, message: string): Uint8Array {
    const chBuf = u8(channel);
    const msgBuf = u8(message);
    const payload = new Uint8Array(4 + chBuf.length + 4 + msgBuf.length);
    let off = 0;
    writeU32BE(payload, off, chBuf.length); off += 4;
    payload.set(chBuf, off); off += chBuf.length;
    writeU32BE(payload, off, msgBuf.length); off += 4;
    payload.set(msgBuf, off);
    return frame(CMD.PUB, payload);
}

export function encodeExec(procedure: string, args: string[]): Uint8Array {
    const procBuf = u8(procedure);
    const argBufs = args.map(u8);
    let size = 4 + procBuf.length + 4;
    for (const a of argBufs) size += 4 + a.length;
    const payload = new Uint8Array(size);
    let off = 0;
    writeU32BE(payload, off, procBuf.length); off += 4;
    payload.set(procBuf, off); off += procBuf.length;
    writeU32BE(payload, off, argBufs.length); off += 4;
    for (const a of argBufs) {
        writeU32BE(payload, off, a.length); off += 4;
        payload.set(a, off); off += a.length;
    }
    return frame(CMD.EXEC, payload);
}

export function encodeAuth(token: Uint8Array): Uint8Array {
    return frame(CMD.AUTH, lenPrefixedBytes(token));
}

// ── Response Decoder ───────────────────────────────────────────────────

export function decodeResponse(data: Uint8Array): WormResponse {
    if (data.length < 5) return { type: "error", message: "frame too short" };

    const code = data[0];
    const payloadLen = readU32BE(data, 1);
    const payload = data.subarray(5, 5 + payloadLen);

    switch (code) {
        case RESP.OK:
            return { type: "ok" };

        case RESP.VALUE:
            return { type: "value", data: str(payload) };

        case RESP.NULL:
            return { type: "null" };

        case RESP.ERR:
            return { type: "error", message: str(payload) };

        case RESP.EVENT: {
            if (payload.length < 8) return { type: "error", message: "malformed event" };
            const chLen = readU32BE(payload, 0);
            const chStart = 4;
            const chEnd = chStart + chLen;
            if (chEnd + 4 > payload.length) return { type: "error", message: "malformed event" };
            const msgLen = readU32BE(payload, chEnd);
            const msgStart = chEnd + 4;
            const msgEnd = msgStart + msgLen;
            if (msgEnd > payload.length) return { type: "error", message: "malformed event" };
            return {
                type: "event",
                channel: str(payload.subarray(chStart, chEnd)),
                message: str(payload.subarray(msgStart, msgEnd)),
            };
        }

        default:
            return { type: "error", message: `unknown response code: 0x${code.toString(16)}` };
    }
}
