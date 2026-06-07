// atomicdata.ts — decode AtomicAssets `serialized_data` (the on-chain `eosio::atomicdata` format) into
// named attributes, driven by a schema `format`. A TypeScript port of the canonical Rust decoder
// (hyperion-tools `crates/atomicdata`), itself from `pinknetworkx/atomicassets-contract` and cross-checked
// against `atomicassets-js`. Kept byte-for-byte parity with that crate's golden vector (see the tests).
//
// Wire format: a flat sequence of `[varuint identifier][value]` pairs read until the slice is exhausted
// (no terminator). `identifier = format_index + RESERVED(4)`. Only present attributes are written (sparse).
//
// API parity: `uint64`/`int64`/`fixed64` decode to decimal STRINGS (dodging JS number precision); all
// narrower ints + `bool` to numbers; `float`/`double` to numbers; `string`/`image`/`ipfs` to strings;
// arrays to arrays. `canonVal` then renders each to the flat string the WormDB overlay stores (matching the
// Rust builder's `bson_canon`), so feed-applied attrs are byte-identical to segment-built ones.

const RESERVED = 4;

export type Field = { name: string; type: string };

/** Parse a schema `format` (a JSON array of `{name, type}`) into the ordered field list the decoder needs. */
export function parseFormat(fmt: unknown): Field[] {
  if (!Array.isArray(fmt)) throw new Error("atomicdata: schema format is not an array");
  return fmt.map((e: any) => {
    if (typeof e?.name !== "string" || typeof e?.type !== "string") throw new Error("atomicdata: format entry missing string name/type");
    return { name: e.name, type: e.type };
  });
}

class Cursor {
  pos = 0;
  constructor(public data: Uint8Array) {}
  remaining() { return this.data.length - this.pos; }
  u8(): number {
    if (this.pos >= this.data.length) throw new Error("atomicdata: unexpected end of data");
    return this.data[this.pos++];
  }
  take(n: number): Uint8Array {
    const end = this.pos + n;
    if (end > this.data.length) throw new Error(`atomicdata: unexpected end of data (need ${n} bytes)`);
    const s = this.data.subarray(this.pos, end);
    this.pos = end;
    return s;
  }
  // Unsigned LEB128 (low group first, 0x80 = continuation), matching the contract's varuint. Up to 64 bits.
  varuint(): bigint {
    let value = 0n, shift = 0n;
    for (;;) {
      if (shift >= 64n) throw new Error("atomicdata: varuint exceeds 64 bits");
      const b = this.u8();
      value |= BigInt(b & 0x7f) << shift;
      if ((b & 0x80) === 0) break;
      shift += 7n;
    }
    return value;
  }
}

// ZigZag decode (signed intN): even -> n/2, odd -> -(n/2)-1. Identical to the contract.
function zigzag(u: bigint): bigint { return (u >> 1n) ^ -(u & 1n); }

// A varuint used as a length / identifier / count -> a JS number, guarded so a malformed oversized
// varuint can't lose precision (and thus mis-route an identifier or request a giant allocation).
const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);
function toLen(v: bigint): number {
  if (v > MAX_SAFE) throw new Error("atomicdata: length/identifier exceeds MAX_SAFE_INTEGER");
  return Number(v);
}

function leF32(b: Uint8Array): number { return new DataView(b.buffer, b.byteOffset, 4).getFloat32(0, true); }
function leF64(b: Uint8Array): number { return new DataView(b.buffer, b.byteOffset, 8).getFloat64(0, true); }
function leU(b: Uint8Array): bigint { let v = 0n; for (let i = b.length - 1; i >= 0; i--) v = (v << 8n) | BigInt(b[i]); return v; }

const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function base58(bytes: Uint8Array): string {
  if (bytes.length === 0) return "";
  let zeros = 0;
  while (zeros < bytes.length && bytes[zeros] === 0) zeros++;
  const digits: number[] = [0];
  for (let i = zeros; i < bytes.length; i++) {
    let carry = bytes[i];
    for (let j = 0; j < digits.length; j++) {
      carry += digits[j] << 8;
      digits[j] = carry % 58;
      carry = (carry / 58) | 0;
    }
    while (carry > 0) { digits.push(carry % 58); carry = (carry / 58) | 0; }
  }
  let out = "1".repeat(zeros);
  for (let i = digits.length - 1; i >= 0; i--) out += B58[digits[i]];
  return out;
}

function hex(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += x.toString(16).padStart(2, "0");
  return s;
}

const utf8 = new TextDecoder();

type Value = number | string | boolean | null | Value[];

function decodeAttribute(ty: string, c: Cursor): Value {
  if (ty.endsWith("[]")) {
    const base = ty.slice(0, -2);
    const n = toLen(c.varuint());
    if (n > c.remaining()) throw new Error("atomicdata: array count exceeds remaining bytes"); // each elem ≥1 byte
    const arr: Value[] = [];
    for (let i = 0; i < n; i++) arr.push(decodeAttribute(base, c));
    return arr;
  }
  switch (ty) {
    // signed: zigzag then LEB128; widths truncate like Rust `as iN`. 64-bit -> string.
    case "int8": return Number(BigInt.asIntN(8, zigzag(c.varuint())));
    case "int16": return Number(BigInt.asIntN(16, zigzag(c.varuint())));
    case "int32": return Number(BigInt.asIntN(32, zigzag(c.varuint())));
    case "int64": return BigInt.asIntN(64, zigzag(c.varuint())).toString();
    // unsigned: LEB128; widths truncate like Rust `as uN`. 64-bit -> string.
    case "uint8": return Number(BigInt.asUintN(8, c.varuint()));
    case "uint16": return Number(BigInt.asUintN(16, c.varuint()));
    case "uint32": return Number(BigInt.asUintN(32, c.varuint()));
    case "uint64": return BigInt.asUintN(64, c.varuint()).toString();
    // fixed-width little-endian, unsigned. 64-bit -> string.
    case "fixed8": return c.take(1)[0];
    case "fixed16": return Number(leU(c.take(2)));
    case "fixed32": return Number(leU(c.take(4)));
    case "fixed64": return leU(c.take(8)).toString();
    case "byte": return c.u8();
    case "bool": return c.u8() === 1 ? 1 : 0; // 0/1 number, atomicassets-js parity
    case "float": { const f = leF32(c.take(4)); return Number.isFinite(f) ? f : null; }
    case "double": { const f = leF64(c.take(8)); return Number.isFinite(f) ? f : null; }
    case "string": case "image": { const n = toLen(c.varuint()); return utf8.decode(c.take(n)); }
    case "ipfs": { const n = toLen(c.varuint()); return base58(c.take(n)); }
    case "bytes": { const n = toLen(c.varuint()); return hex(c.take(n)); }
    default: throw new Error(`atomicdata: unsupported attribute type '${ty}'`);
  }
}

/** Decode a `serialized_data` blob into its present attributes (schema index + name + API-parity value),
 *  in blob order. `format` must be the schema's field list in original on-chain order. */
export function deserialize(data: Uint8Array | number[], format: Field[]): { idx: number; name: string; value: Value }[] {
  const c = new Cursor(data instanceof Uint8Array ? data : Uint8Array.from(data));
  const out: { idx: number; name: string; value: Value }[] = [];
  while (c.remaining() > 0) {
    const id = toLen(c.varuint());
    const idx = id - RESERVED;
    if (idx < 0) throw new Error(`atomicdata: identifier ${id} < RESERVED(${RESERVED})`);
    const field = format[idx];
    if (!field) throw new Error(`atomicdata: identifier ${id} -> format index ${idx} out of range (${format.length} fields)`);
    out.push({ idx, name: field.name, value: decodeAttribute(field.type, c) });
  }
  return out;
}

/** Render one decoded value to the flat string the overlay stores — matching the Rust builder's
 *  `bson_canon`: strings verbatim, numbers/bools as their decimal/0-1 text, arrays as `[a,b,c]`, and a
 *  null (a non-finite float/double, which the decoder defensively maps to null) as `""` (Bson::Null parity). */
export function canonVal(value: Value): string {
  if (value === null || value === undefined) return ""; // non-finite float/double -> Null -> "" (bson_canon)
  if (Array.isArray(value)) return "[" + value.map(canonVal).join(",") + "]";
  if (typeof value === "string") return value;
  if (typeof value === "boolean") return value ? "1" : "0";
  return String(value);
}

/** Decode + canonicalize into `[schemaIndex, valueString]` pairs ready for the aa_mint attr JSON arg. */
export function toAttrPairs(data: Uint8Array | number[], format: Field[]): [number, string][] {
  return deserialize(data, format).map((a) => [a.idx, canonVal(a.value)]);
}
