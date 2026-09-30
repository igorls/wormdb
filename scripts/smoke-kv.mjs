// Smoke test: run the key/value FFI entry points in a real WASI host, and FAIL if any of it is
// wrong. Exit code is the verdict; the log is for a human reading a failure.
//
// Takes the module path as argv[2] (the build passes the just-built artifact, so this can never
// read a stale zig-out copy):
//   bun scripts/smoke-kv.mjs <module.wasm>
//
// NOTE: a wasm call can grow memory, which detaches every existing view. Always re-read
// memory.buffer after a call that can allocate.
import { readFileSync } from "node:fs";
import { createWasi } from "./wasi-shim.mjs";

const modulePath = process.argv[2];
if (!modulePath) { console.error("usage: bun scripts/smoke-kv.mjs <module.wasm>"); process.exit(2); }

/** Every failure is collected so one run reports all of them, then the process exits non-zero. */
const failures = [];
const check = (ok, what, detail = "") => {
  console.log(`${ok ? "ok  " : "FAIL"}  ${what}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures.push(what);
};
const finish = () => {
  if (failures.length) { console.error(`\nsmoke-kv: ${failures.length} check(s) failed:\n  ${failures.join("\n  ")}`); process.exit(1); }
  console.log("\nsmoke-kv: PASS");
};

let m, shim, inst, ex;
try {
  m = await WebAssembly.compile(readFileSync(modulePath));
  const memRef = {};
  shim = createWasi(memRef, { onStdout: () => {} });
  inst = await WebAssembly.instantiate(m, { wasi_snapshot_preview1: shim });
  ex = inst.exports;
  memRef.buffer = ex.memory;
} catch (err) {
  // An instantiation failure is itself the result: imports unresolved, bad memory type, a trap.
  console.error(`smoke-kv: module failed to instantiate: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
}
check(true, "module instantiates with every WASI import resolved");

const enc = new TextEncoder();
const dec = new TextDecoder();
const mem = () => new Uint8Array(ex.memory.buffer);
const dv = () => new DataView(ex.memory.buffer);

// The export surface the host depends on. A missing entry point is a hard failure, not a warning.
for (const name of ["wormdb_version", "wormdb_open", "wormdb_set", "wormdb_get", "wormdb_delete", "wormdb_alloc", "wormdb_free", "wormdb_close"]) {
  check(typeof ex[name] === "function", `exports ${name}`);
}

// Host buffers come from the module's own allocator. This used to hand out offsets from 8 MiB up,
// which the module had never allocated: those bytes were only "free" by accident of what the linker
// happened to reserve, and a memory.grow during any call can move or reclaim them. Asking for them
// means the allocator knows they are in use, and the offsets are real.
// Out-parameters: 8 bytes for a length/pointer the callee writes back.
const scratch = () => {
  const at = ex.wormdb_alloc(8);
  check(at !== 0, "wormdb_alloc(8) for an out-param");
  return at;
};
function writeStr(s) {
  const b = enc.encode(s);
  const at = ex.wormdb_alloc(b.length + 1);
  check(at !== 0, `wormdb_alloc(${b.length + 1}) for a host buffer`);
  mem().set(b, at);
  mem()[at + b.length] = 0;
  return { ptr: at, len: b.length };
}
/** Read a returned (ptr,len) pair: the callee owns it, so the caller frees it. */
function readOut(ptrSlot, lenSlot) {
  const p = dv().getUint32(ptrSlot, true), l = dv().getUint32(lenSlot, true);
  const text = dec.decode(mem().subarray(p, p + l));
  ex.wormdb_free(p, l);
  return text;
}

const vPtr = ex.wormdb_version();
let vEnd = vPtr; while (mem()[vEnd] !== 0) vEnd++;
const version = dec.decode(mem().subarray(vPtr, vEnd));
check(/^wormdb-ffi \d/.test(version), "wormdb_version returns a version string", version);

const dir = writeStr("mem");            // unused when persistence=none
const db = ex.wormdb_open(dir.ptr, 2);  // 2 = PERSIST_NONE
check(!!db, "wormdb_open(persistence=none) returns a handle");
if (!db) { finish(); }

const k = writeStr("greeting");
const val = writeStr("hello from wasm");
check(ex.wormdb_set(db, k.ptr, k.len, val.ptr, val.len) === 0, "wormdb_set returns 0");

const outPtr = scratch(), outLen = scratch();
check(ex.wormdb_get(db, k.ptr, k.len, outPtr, outLen) === 0, "wormdb_get returns 0");
check(readOut(outPtr, outLen) === "hello from wasm", "the value round-trips");

// A second key, read back while the first is still there: proves it is a store, not a scratch buffer.
const k2 = writeStr("second"), v2 = writeStr("another value");
check(ex.wormdb_set(db, k2.ptr, k2.len, v2.ptr, v2.len) === 0, "wormdb_set (second key) returns 0");
const p1 = scratch(), l1 = scratch();
check(ex.wormdb_get(db, k2.ptr, k2.len, p1, l1) === 0 && readOut(p1, l1) === "another value", "the second value round-trips");
const p1b = scratch(), l1b = scratch();
check(ex.wormdb_get(db, k.ptr, k.len, p1b, l1b) === 0 && readOut(p1b, l1b) === "hello from wasm", "the first key survives a second insert");

// Overwrite, then delete: the store must be live, not append-only.
const upd = writeStr("updated!");
check(ex.wormdb_set(db, k.ptr, k.len, upd.ptr, upd.len) === 0, "overwrite returns 0");
const p3 = scratch(), l3 = scratch();
check(ex.wormdb_get(db, k.ptr, k.len, p3, l3) === 0 && readOut(p3, l3) === "updated!", "the overwrite is visible");
check(ex.wormdb_delete(db, k.ptr, k.len) === 0, "wormdb_delete returns 0");
const p4 = scratch(), l4 = scratch();
check(ex.wormdb_get(db, k.ptr, k.len, p4, l4) !== 0, "a deleted key is not found");

check((ex.wormdb_close(db), true), "wormdb_close does not throw");
finish();
