// Probe the FFI semantics via node:wasi before building the browser page.
// NOTE: a wasm call can grow memory, which detaches every existing view. Always re-read
// memory.buffer after a call that can allocate — the browser page must do the same.
import { readFileSync } from "node:fs";
import { createWasi } from "../examples/browser-wormdb/wasi-shim.mjs";

const m = await WebAssembly.compile(readFileSync("zig-out/bin/wormdb_ffi.wasm"));
let log = "";
// The shim needs the instance's memory, which only exists after instantiation, so it reads
// through a late-bound handle. The browser page does the same.
const memRef = { };
const shim = createWasi(memRef, { onStdout: (t) => (log += t) });
const inst = await WebAssembly.instantiate(m, { wasi_snapshot_preview1: shim });
const ex = inst.exports;
memRef.buffer = ex.memory;
const enc = new TextEncoder();
const dec = new TextDecoder();

const mem = () => new Uint8Array(ex.memory.buffer);
const dv = () => new DataView(ex.memory.buffer);

const scratch = (() => { let p = 8 << 20; return () => (p += 4096); })();
function writeStr(s) {
  const at = scratch();
  const b = enc.encode(s);
  mem().set(b, at);
  mem()[at + b.length] = 0;
  return { ptr: at, len: b.length };
}

const v = ex.wormdb_version();
const start = v;
let end = v; while (mem()[end] !== 0) end++;
console.log("wormdb_version:", dec.decode(mem().subarray(start, end)));

const dir = writeStr("mem");            // unused when persistence=none
const db = ex.wormdb_open(dir.ptr, 2);  // 2 = PERSIST_NONE
console.log("wormdb_open(persistence=none) ->", db);

const k = writeStr("greeting");
const val = writeStr("hello from wasm");
console.log("wormdb_set ->", ex.wormdb_set(db, k.ptr, k.len, val.ptr, val.len));

const outPtr = scratch();
const outLen = scratch();
console.log("wormdb_get ->", ex.wormdb_get(db, k.ptr, k.len, outPtr, outLen));
const vp = dv().getUint32(outPtr, true);
const vl = dv().getUint32(outLen, true);
console.log("  out ptr/len:", vp, vl);
console.log("  value:", dec.decode(mem().subarray(vp, vp + vl)));
ex.wormdb_free(vp, vl);

// A second key, then read both back — proves it is a store, not a scratch buffer.
const k2 = writeStr("second");
const v2 = writeStr("another value");
ex.wormdb_set(db, k2.ptr, k2.len, v2.ptr, v2.len);
const p2 = scratch(), l2 = scratch();
ex.wormdb_get(db, k2.ptr, k2.len, p2, l2);
console.log("  second:", dec.decode(mem().subarray(dv().getUint32(p2, true), dv().getUint32(p2, true) + dv().getUint32(l2, true))));

// Overwrite then delete, to show the store is live.
ex.wormdb_set(db, k.ptr, k.len, writeStr("updated!").ptr, 8);
const p3 = scratch(), l3 = scratch();
ex.wormdb_get(db, k.ptr, k.len, p3, l3);
console.log("  after overwrite:", dec.decode(mem().subarray(dv().getUint32(p3, true), dv().getUint32(p3, true) + dv().getUint32(l3, true))));
console.log("wormdb_delete ->", ex.wormdb_delete(db, k.ptr, k.len));
const p4 = scratch(), l4 = scratch();
console.log("  get after delete ->", ex.wormdb_get(db, k.ptr, k.len, p4, l4));
ex.wormdb_close(db);
console.log("wormdb_close -> ok");
