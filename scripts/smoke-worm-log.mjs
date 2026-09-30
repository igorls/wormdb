// Verify the WORM append-log + chain-verification API, then the exact logic goes in the page.
import { readFileSync } from "node:fs";
import { createWasi } from "./wasi-shim.mjs";

const m = await WebAssembly.compile(readFileSync("zig-out/bin/wormdb_ffi.wasm"));
const memRef = {};
const shim = createWasi(memRef, { onStdout: () => {} });
const inst = await WebAssembly.instantiate(m, { wasi_snapshot_preview1: shim });
const ex = inst.exports;
memRef.buffer = ex.memory;

const enc = new TextEncoder();
const dec = new TextDecoder();
const mem = () => new Uint8Array(ex.memory.buffer);
const dv = () => new DataView(ex.memory.buffer);
let sp = 16 << 20;
const scratch = (n = 4096) => { const p = sp; sp += n; return p; };
function writeStr(s) {
  const at = scratch(8192);
  const b = enc.encode(s);
  mem().set(b, at); mem()[at + b.length] = 0;
  return { ptr: at, len: b.length };
}
const hex = (ptr, len) => Array.from(mem().subarray(ptr, ptr + len)).map((x) => x.toString(16).padStart(2, "0")).join("");

const dir = writeStr("mem");
const db = ex.wormdb_open(dir.ptr, 2);
console.log("open ->", !!db);

// AppendReceipt: u64 seq@0, u64 ingest_time_ms@8, then four 32-byte hashes @16,48,80,112 (=144B)
// AppendLogReport: u32 count@0, pad, u64 last_seq@8, head_hash[32]@16 (=48B)
const RECEIPT = 144, REPORT = 48;

const logId = writeStr("audit-log");
const receipts = [];
for (const msg of ["patient record created", "lab result attached", "record signed"]) {
  const payload = writeStr(msg);
  const rp = scratch(RECEIPT);
  const rc = ex.wormdb_append_log(db, logId.ptr, logId.len, payload.ptr, payload.len, 0, 0, 0n, rp);
  if (rc !== 0) { console.log("append failed rc=", rc); break; }
  receipts.push({
    seq: dv().getBigUint64(rp + 0, true).toString(),
    time: dv().getBigUint64(rp + 8, true).toString(),
    prev: hex(rp + 16, 32),
    payload: hex(rp + 48, 32),
    event: hex(rp + 80, 32),
    record: hex(rp + 112, 32),
  });
}
for (const r of receipts) console.log(`seq=${r.seq} prev=${r.prev.slice(0, 12)} event=${r.event.slice(0, 12)} record=${r.record.slice(0, 12)}`);

// The chain claim: entry N's prev_event_hash should equal entry N-1's event hash.
let linked = true;
for (let i = 1; i < receipts.length; i++) if (receipts[i].prev !== receipts[i - 1].event) linked = false;
console.log("chain links (prev_event == prev event hash):", linked);

const rpt = scratch(REPORT);
const vrc = ex.wormdb_append_log_verify(db, logId.ptr, logId.len, rpt);
console.log("verify rc =", vrc);
console.log("  count =", dv().getUint32(rpt + 0, true));
console.log("  last_seq =", dv().getBigUint64(rpt + 8, true).toString());
const head = hex(rpt + 16, 32);
console.log("  head_hash =", head.slice(0, 16));
console.log("  head matches last event hash:", head === receipts.at(-1).event);
console.log("  head matches last record hash:", head === receipts.at(-1).record);
