# Sandboxed procedures

> **Status: spike.** Works end to end and is tested, but the limits listed at the bottom are real.

Built-in procedures are Zig compiled into the server. A **sandboxed procedure** is a wasm module
installed at runtime instead: anyone with write access to a key prefix can ship code that runs
inside the database, next to the data, without being able to touch anything else.

Each module is the **law** of one **scope** (a key prefix). Every call:

- sees only keys under its scope: the keys a law names are relative, and the host prepends the scope;
- is deterministic: integer-only wasm, no clock, no randomness, a fresh instance per call;
- is metered: one unit of fuel per instruction, 10,000,000 per call;
- is all or nothing: its writes are kept only if it ends cleanly;
- is logged: one WORM record per committed call, chained by hash, so anyone can replay the log
  and check that the scope holds exactly what the law produced.

## EXEC

| Procedure | Arguments | Returns |
| --- | --- | --- |
| `sandbox_install` | `<scope> <module>` (wasm bytes, or their hex) | the module's sha256 |
| `sandbox_call` | `<scope> <entry> [args...]` | what the law passed to `ret` |
| `sandbox_replay` | `<scope>` | `ok <calls> <chain>`, or an error naming the first call or key that differs |

`sandbox_install` needs write access to the scope. A scope may not be empty, may not start with
`sbx:`, and may not overlap another scope (one may not be a prefix of the other). Installing again
replaces the scope's law; earlier log records keep the hash of the law they ran under.

A failed call answers `law_failed: <message>` (the law called `fail`) or `law_trapped: <trap>`
(`OutOfFuel`, `MemoryOutOfBounds`, `DivideByZero`, `NoSuchExport`, ...). Neither changes the store
or the log.

## Writing a law

A law is a Zig file compiled to `wasm32-freestanding`. [examples/laws/law.zig](../examples/laws/law.zig)
declares the host calls and wraps them; [examples/laws/ford_toll.zig](../examples/laws/ford_toll.zig)
is a complete law:

```zig
const law = @import("law.zig");

export fn set_rate() void {
    const rate = law.argInt(0) orelse law.failWith("set_rate needs <percent>");
    if (rate < 0 or rate > 100) law.failWith("rate must be 0 to 100");
    law.setInt("rate", rate);
    law.retInt(rate);
}
```

Each exported function with no parameters is an entry point. Build the samples with `zig build laws`
(output in `zig-out/bin/`), or by hand:

```bash
zig build-exe ford_toll.zig -target wasm32-freestanding -mcpu=mvp -O ReleaseSmall -fno-entry -rdynamic
```

The Ford Toll compiles to under 2 KB.

## Host calls

Imported from the module `wormdb`. Pointers and lengths are into the law's own memory; keys are
relative to the scope.

| Call | Signature | Does |
| --- | --- | --- |
| `arg_count` | `() -> i32` | number of call arguments |
| `arg` | `(index, out, cap) -> i32` | copies an argument; returns its full length, or -1 |
| `get` | `(key, key_len, out, cap) -> i32` | copies a value (this call's own writes first); full length, or -1 |
| `set` | `(key, key_len, val, val_len) -> i32` | 0, or -1 when a limit is hit |
| `del` | `(key, key_len) -> i32` | 0, or -1 when a limit is hit |
| `ret` | `(ptr, len)` | sets the call's answer |
| `fail` | `(ptr, len)` | ends the call; nothing it wrote is kept |

Accepted wasm: the integer subset of wasm 1.0, plus sign extension and bulk memory. Refused at
install: any float type or instruction, a start function, any import outside `wormdb`, or one whose
signature differs from the table above.

## Replay

`sandbox_replay` reads the scope's log in order, re-runs every call on an empty scratch store, and
checks each call's writes against the digest in its record, the hash chain, the head, and finally
the live scope against the scratch one, key by key. A write made to the scope behind the law's back
(say, a raw `SET`) shows up as `state differs from the law at '<key>'`.

## Limits

| What | Limit |
| --- | --- |
| Fuel per call | 10,000,000 instructions (host calls cost 100, plus 1 per 2 bytes they move) |
| Memory | 64 pages (4 MiB) |
| Value / label / call stacks | 16,384 / 4,096 / 256 |
| Key under the scope | 512 bytes |
| Value | 64 KiB |
| Writes per call | 4,096 |

## Keys

`id` is the hex of the first 16 bytes of sha256(scope).

| Key | Holds |
| --- | --- |
| `sbx:mod:<sha256>` | module bytes (WORM, content-addressed) |
| `sbx:scope:<id>` | the scope |
| `sbx:law:<id>` | sha256 of the scope's current law |
| `sbx:log:<id>:<seq>` | one record per committed call (WORM), seq zero-padded from 1 |
| `sbx:head:<id>` | `<seq> <chain hex>` |

## Not done yet

- Operand types are not validated. The interpreter bounds-checks its stacks and memory instead, so
  a badly typed module computes garbage inside its sandbox but cannot leave it.
- One process-wide lock orders every sandboxed call; per-scope ordering would scale better.
- The log record, the writes and the head are three durable writes. A crash between them is caught
  by replay, not prevented.
- A scope is assumed empty before its first call; replay starts from nothing.
- Modules are decoded on every call, and the interpreter reads bytecode directly. Fine for laws of a
  few KB; a decoded-module cache and a pre-decoded instruction stream are the obvious next steps.
- Who may install a law is plain write access to the scope. Anything richer (votes, quorums) belongs
  to the application on top.
