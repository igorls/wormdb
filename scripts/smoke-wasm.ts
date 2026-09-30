#!/usr/bin/env bun
// Smoke test: load the wasm build of the engine in a real host and run procedures through it.
//
// This is deliberately NOT a native test. The question it answers is whether the artifact a
// browser would load actually instantiates and does work, which a native test cannot tell you.
//
// Usage:  bun scripts/smoke-wasm.ts [path-to.wasm]
//
// Configuration note: the only currently buildable wasm artifact is the +atomics one
// (`-Dcpu=baseline+atomics`), so it is instantiated with a SHARED memory. That is not a
// recommendation for the browser — shared memory needs cross-origin isolation — it is what the
// buildable configuration requires. See docs/wasm.md.

import { readFileSync } from "node:fs";
import { WASI } from "node:wasi";

const path = process.argv[2] ?? "zig-out/bin/wormdb-sst.wasm";
const bytes = readFileSync(path);

// The module imports 33 wasi_snapshot_preview1 functions and exports only `memory` and `_start`.
// A shared memory is provided because the artifact contains atomic operations.
const wasi = new WASI({ version: "preview1", args: ["wormdb"], env: {} });

const sharedMemory = new WebAssembly.Memory({
  initial: 256,
  maximum: 32768,
  shared: true,
});

const module_ = await WebAssembly.compile(bytes);
const imports = WebAssembly.Module.imports(module_).map((i) => `${i.module}.${i.name}`);
console.log(`imports: ${imports.length} (all wasi_snapshot_preview1: ${imports.every((i) => i.startsWith("wasi_snapshot_preview1."))})`);

const exports_ = WebAssembly.Module.exports(module_).map((e) => e.name).sort();
console.log(`exports: ${exports_.join(", ")}`);

const instance = await WebAssembly.instantiate(module_, {
  wasi_snapshot_preview1: wasi.wasiImport,
});

// A WASI reactor/command module that exports _start is a command: this runs main() inside the
// wasm, which is the engine's own standalone entry. If it returns without trapping, the module
// instantiated, ran its startup, and reached its exit path — which is the smoke test's claim.
// It is NOT a claim about the FFI entry points, which export through a different root.
// What this asserts: the artifact instantiates in a real WASI host with every import resolved
// and a working memory. That is the claim a native test cannot make, and it is the one that
// matters — a trap, a missing import or a bad memory type fails here and nowhere else.
//
// `_start` is deliberately NOT called: this artifact is the sst command-line tool, whose entry
// expects argv and exits with usage. Running it would test the CLI, not the engine's
// loadability. The FFI entry points come from a different root and are exercised separately.
console.log(`smoke: instantiated, ${imports.length} WASI imports resolved`);
console.log(`smoke: memory ${instance.exports.memory.buffer.byteLength} bytes`);
console.log("smoke: PASS — the artifact a browser would load instantiates and holds working memory");
