// Smoke test: run the WORM append-log and its chain verification in a real WASI host, and FAIL if
// anything is wrong. Exit code is the verdict.
//
// Takes the module path as argv[2], which the build passes, so this can never read a stale zig-out
// copy. The previous version only printed its findings and `break`-ed out of the append loop on
// error, so a failure looked exactly like a pass.
import { readFileSync } from "node:fs";
import { createWasi } from "./wasi-shim.mjs";

const modulePath = process.argv[2];
if (!modulePath) { console.error("usage: bun scripts/smoke-worm-log.mjs <module.wasm>"); process.exit(2); }

const failures = [];
const check = (ok, what, detail = "") => {
  console.log(`${ok ? "ok  " : "FAIL"}  ${what}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures.push(what);
};
const finish = () => {
  if (failures.length) { console.error(`\nsmoke-worm-log: ${failures.length} check(s) failed:\n  ${failures.join("\n  ")}`); process.exit(1); }
  console.log("\nsmoke-worm-log: PASS");
};

let ex;
try {
  const m = await WebAssembly.compile(readFileSync(modulePath));
  const memRef = {};
  const shim = createWasi(memRef, { onStdout: () => {} });
  const inst = await WebAssembly.instantiate(m, { wasi_snapshot_preview1: shim });
  ex = inst.exports;
  memRef.buffer = ex.memory;
} catch (err) {
  console.error(`smoke-worm-log: module failed to instantiate: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
}

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

for (const name of ["wormdb_open", "wormdb_append_log", "wormdb_append_log_verify"]) {
  check(typeof ex[name] === "function", `exports ${name}`);
}

const dir = writeStr("mem");
const db = ex.wormdb_open(dir.ptr, 2);
check(!!db, "wormdb_open(persistence=none) returns a handle");
if (!db) { finish(); }

// AppendReceipt: u64 seq@0, u64 ingest_time_ms@8, then four 32-byte hashes @16,48,80,112 (=144B)
// AppendLogReport: u32 count@0, pad, u64 last_seq@8, head_hash[32]@16 (=48B)
const RECEIPT = 144, REPORT = 48;

const logId = writeStr("audit-log");
const receipts = [];
for (const msg of ["patient record created", "lab result attached", "record signed"]) {
  const payload = writeStr(msg);
  const rp = scratch(RECEIPT);
  const rc = ex.wormdb_append_log(db, logId.ptr, logId.len, payload.ptr, payload.len, 0, 0, 0n, rp);
  // An append that fails must FAIL the run. Breaking out quietly is what made this test vacuous.
  check(rc === 0, `append_log("${msg}") returns 0`, `rc=${rc}`);
  if (rc !== 0) { finish(); }
  receipts.push({
    seq: Number(dv().getBigUint64(rp + 0, true)),
    time: dv().getBigUint64(rp + 8, true).toString(),
    prev: hex(rp + 16, 32),
    payload: hex(rp + 48, 32),
    event: hex(rp + 80, 32),
    record: hex(rp + 112, 32),
  });
}

check(receipts.length === 3, "three records were appended", `got ${receipts.length}`);
check(receipts[0]?.seq === 1 && receipts[1]?.seq === 2 && receipts[2]?.seq === 3, "sequence numbers are 1,2,3",
  receipts.map(r => r.seq).join(","));
check(receipts[0]?.prev === "0".repeat(64), "the first record's prev is the zero hash (genesis)");
check(receipts.every(r => r.event !== r.payload), "the event hash is not just the payload hash");
check(new Set(receipts.map(r => r.payload)).size === 3, "each payload produced a distinct payload hash");
check(receipts.every(r => r.time !== "0"), "an ingest time was assigned by the engine");

// The chain claim: record N's prev_event_hash equals record N-1's event hash. This is the property
// that makes the log tamper-evident, so it is asserted rather than printed.
let brokenAt = -1;
for (let i = 1; i < receipts.length; i++) if (receipts[i].prev !== receipts[i - 1].event) { brokenAt = i; break; }
check(brokenAt === -1, "every record links to its predecessor", brokenAt === -1 ? "" : `record ${brokenAt + 1} does not link`);

const rpt = scratch(REPORT);
const vrc = ex.wormdb_append_log_verify(db, logId.ptr, logId.len, rpt);
check(vrc === 0, "append_log_verify returns 0", `rc=${vrc}`);
const count = dv().getUint32(rpt + 0, true);
const lastSeq = Number(dv().getBigUint64(rpt + 8, true));
const head = hex(rpt + 16, 32);
check(count === 3, "verify reports three records", `count=${count}`);
check(lastSeq === 3, "verify reports last_seq 3", `last_seq=${lastSeq}`);
// The head is compared against the LAST EVENT hash. Verified in the browser run, and asserted here
// so a change in what "head" means fails loudly instead of being noticed by eye.
check(head === receipts.at(-1).event, "the reported head hash equals the last record's event hash",
  `head=${head.slice(0, 12)} event=${receipts.at(-1).event.slice(0, 12)}`);
check(head !== "0".repeat(64), "the head hash is not the zero hash");

finish();
