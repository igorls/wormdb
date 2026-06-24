import type { ParsedCommand } from "./command";
import type { WormResponse } from "./protocol";

export type Bytes = Uint8Array<ArrayBufferLike>;

export const WIRE_MAGIC: Bytes = Uint8Array.of(0x57, 0x57);

const enum CommandCode {
  Get = 0x01,
  Set = 0x02,
  Del = 0x03,
  Status = 0x04,
  ClusterStatus = 0x05,
  Sub = 0x06,
  Unsub = 0x07,
  Pub = 0x08,
  Exec = 0x09,
  ClusterPeers = 0x0A,
  Vinsert = 0x0D,
  Vbulkinsert = 0x0F,
}

const enum ResponseCode {
  Ok = 0x00,
  Value = 0x01,
  Null = 0x02,
  Err = 0x03,
  Event = 0x04,
}

type ParsedFrame = {
  code: number;
  payload: Bytes;
  remaining: Bytes;
};

export function encodeCommandFrame(command: ParsedCommand): Bytes {
  switch (command.kind) {
    case "GET": {
      const payload = encodeLenPrefixedUtf8(command.key);
      return writeFrame(CommandCode.Get, payload);
    }
    case "DEL": {
      const payload = encodeLenPrefixedUtf8(command.key);
      return writeFrame(CommandCode.Del, payload);
    }
    case "SUB": {
      const channel = encodeUtf8(command.channel);
      const filter = command.filter ? encodeUtf8(command.filter) : undefined;
      const payload = new Uint8Array(4 + channel.length + (filter ? 4 + filter.length : 0));
      writeUint32BE(payload, 0, channel.length);
      payload.set(channel, 4);
      if (filter) {
        const filterLenPos = 4 + channel.length;
        writeUint32BE(payload, filterLenPos, filter.length);
        payload.set(filter, filterLenPos + 4);
      }
      return writeFrame(CommandCode.Sub, payload);
    }
    case "UNSUB": {
      const payload = encodeLenPrefixedUtf8(command.channel);
      return writeFrame(CommandCode.Unsub, payload);
    }
    case "STATUS":
      return writeFrame(CommandCode.Status, new Uint8Array(0));
    case "CLUSTER_STATUS":
      return writeFrame(CommandCode.ClusterStatus, new Uint8Array(0));
    case "CLUSTER_PEERS":
      return writeFrame(CommandCode.ClusterPeers, new Uint8Array(0));
    case "SET": {
      const key = encodeUtf8(command.key);
      const value = encodeUtf8(command.value);
      const payload = new Uint8Array(1 + 4 + key.length + 4 + value.length);
      payload[0] = command.worm ? 0x01 : 0x00;
      writeUint32BE(payload, 1, key.length);
      payload.set(key, 5);
      const valueLenPos = 5 + key.length;
      writeUint32BE(payload, valueLenPos, value.length);
      payload.set(value, valueLenPos + 4);
      return writeFrame(CommandCode.Set, payload);
    }
    case "PUB": {
      const channel = encodeUtf8(command.channel);
      const message = encodeUtf8(command.message);
      const payload = new Uint8Array(4 + channel.length + 4 + message.length);
      writeUint32BE(payload, 0, channel.length);
      payload.set(channel, 4);
      const msgLenPos = 4 + channel.length;
      writeUint32BE(payload, msgLenPos, message.length);
      payload.set(message, msgLenPos + 4);
      return writeFrame(CommandCode.Pub, payload);
    }
    case "EXEC": {
      const proc = encodeUtf8(command.procedure);
      // Args may be strings or raw Uint8Array (for binary payloads like
      // vector embeddings). The wire format carries raw bytes regardless.
      const encodedArgs: Uint8Array[] = command.args.map((a) =>
        typeof a === "string" ? encodeUtf8(a) : a,
      );
      let size = 4 + proc.length + 4;
      for (const a of encodedArgs) size += 4 + a.length;
      const payload = new Uint8Array(size);
      let off = 0;
      writeUint32BE(payload, off, proc.length); off += 4;
      payload.set(proc, off); off += proc.length;
      writeUint32BE(payload, off, encodedArgs.length); off += 4;
      for (const a of encodedArgs) {
        writeUint32BE(payload, off, a.length); off += 4;
        payload.set(a, off); off += a.length;
      }
      return writeFrame(CommandCode.Exec, payload);
    }
    case "VINSERT": {
      const key = encodeUtf8(command.key);
      const vec = command.vector;
      const ns = encodeUtf8(command.namespace);
      const metric = encodeUtf8(command.metric);
      const size = 4 + key.length + 4 + vec.length + 1 + 4 + ns.length + 4 + metric.length + 8;
      const payload = new Uint8Array(size);
      let off = 0;
      writeUint32BE(payload, off, key.length); off += 4;
      payload.set(key, off); off += key.length;
      writeUint32BE(payload, off, vec.length); off += 4;
      payload.set(vec, off); off += vec.length;
      let flags = 0;
      if (command.worm) flags |= 0x01;
      if (command.async) flags |= 0x02;
      payload[off] = flags; off += 1;
      writeUint32BE(payload, off, ns.length); off += 4;
      payload.set(ns, off); off += ns.length;
      writeUint32BE(payload, off, metric.length); off += 4;
      payload.set(metric, off); off += metric.length;
      writeUint64BE(payload, off, command.timestamp); off += 8;
      return writeFrame(CommandCode.Vinsert, payload);
    }
    case "VBULKINSERT": {
      const ns = encodeUtf8(command.namespace);
      const metric = encodeUtf8(command.metric);
      let size = 4 + ns.length + 4 + metric.length + 1 + 4;
      const encodedKeys: Bytes[] = [];
      for (const it of command.items) {
        const k = encodeUtf8(it.key);
        encodedKeys.push(k);
        size += 4 + k.length + 4 + it.vector.length + 8;
      }
      const payload = new Uint8Array(size);
      let off = 0;
      writeUint32BE(payload, off, ns.length); off += 4;
      payload.set(ns, off); off += ns.length;
      writeUint32BE(payload, off, metric.length); off += 4;
      payload.set(metric, off); off += metric.length;
      let flags = 0;
      if (command.worm) flags |= 0x01;
      if (command.async) flags |= 0x02;
      payload[off] = flags; off += 1;
      writeUint32BE(payload, off, command.items.length); off += 4;
      for (let i = 0; i < command.items.length; i += 1) {
        const key = encodedKeys[i];
        const it = command.items[i];
        writeUint32BE(payload, off, key.length); off += 4;
        payload.set(key, off); off += key.length;
        writeUint32BE(payload, off, it.vector.length); off += 4;
        payload.set(it.vector, off); off += it.vector.length;
        writeUint64BE(payload, off, it.timestamp); off += 8;
      }
      return writeFrame(CommandCode.Vbulkinsert, payload);
    }
    default:
      return assertNever(command);
  }
}

export function tryConsumeFrame(buffer: Bytes): ParsedFrame | null {
  if (buffer.length < 5) return null;

  const code = buffer[0];
  const payloadLen = readUint32BE(buffer, 1);
  const totalLen = 5 + payloadLen;
  if (buffer.length < totalLen) return null;

  return {
    code,
    payload: buffer.subarray(5, totalLen),
    remaining: buffer.subarray(totalLen),
  };
}

export function isEventCode(code: number): boolean {
  return code === ResponseCode.Event;
}

export function decodeResponse(code: number, payload: Bytes): WormResponse {
  switch (code as ResponseCode) {
    case ResponseCode.Ok:
      return { type: "ok" };
    case ResponseCode.Value:
      return { type: "bulk", value: decodeUtf8(payload) };
    case ResponseCode.Null:
      return { type: "null" };
    case ResponseCode.Err:
      return { type: "error", message: decodeUtf8(payload) };
    case ResponseCode.Event: {
      if (payload.length < 8) {
        return { type: "error", message: "Malformed event response" };
      }

      const channelLen = readUint32BE(payload, 0);
      if (payload.length < 4 + channelLen + 4) {
        return { type: "error", message: "Malformed event response" };
      }

      const channelStart = 4;
      const channelEnd = channelStart + channelLen;
      const msgLen = readUint32BE(payload, channelEnd);
      const msgStart = channelEnd + 4;
      const msgEnd = msgStart + msgLen;
      if (msgEnd > payload.length) {
        return { type: "error", message: "Malformed event response" };
      }

      return {
        type: "event",
        channel: decodeUtf8(payload.subarray(channelStart, channelEnd)),
        message: decodeUtf8(payload.subarray(msgStart, msgEnd)),
      };
    }
    default:
      return { type: "error", message: `Unknown response code: ${code}` };
  }
}

export function concatBytes(chunks: readonly Bytes[]): Bytes {
  let totalLen = 0;
  for (const chunk of chunks) {
    totalLen += chunk.length;
  }

  const out: Bytes = new Uint8Array(totalLen);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }

  return out;
}

export function toBytes(data: string | ArrayBuffer | SharedArrayBuffer | ArrayBufferView): Bytes {
  if (typeof data === "string") {
    return encodeUtf8(data);
  }

  if (data instanceof ArrayBuffer || data instanceof SharedArrayBuffer) {
    return new Uint8Array(data);
  }

  return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
}

function writeFrame(code: CommandCode, payload: Bytes): Bytes {
  const out: Bytes = new Uint8Array(5 + payload.length);
  out[0] = code;
  writeUint32BE(out, 1, payload.length);
  out.set(payload, 5);
  return out;
}

function encodeLenPrefixedUtf8(value: string): Bytes {
  const data = encodeUtf8(value);
  const out = new Uint8Array(4 + data.length);
  writeUint32BE(out, 0, data.length);
  out.set(data, 4);
  return out;
}

function writeUint32BE(target: Bytes, offset: number, value: number): void {
  new DataView(target.buffer, target.byteOffset, target.byteLength).setUint32(offset, value, false);
}

function writeUint64BE(target: Bytes, offset: number, value: bigint): void {
  new DataView(target.buffer, target.byteOffset, target.byteLength).setBigUint64(offset, value, false);
}

function readUint32BE(source: Bytes, offset: number): number {
  return new DataView(source.buffer, source.byteOffset, source.byteLength).getUint32(offset, false);
}

function encodeUtf8(value: string): Bytes {
  return new TextEncoder().encode(value);
}

function decodeUtf8(value: Bytes): string {
  return new TextDecoder().decode(value);
}

function assertNever(value: never): never {
  throw new Error(`Unhandled variant: ${String(value)}`);
}
