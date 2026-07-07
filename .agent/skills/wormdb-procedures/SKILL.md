---
name: wormdb-procedures
description: Streamline the development of WormDB stored procedures — scaffolding, registration, testing, and best practices for the compiled-in Zig procedure engine.
---

# WormDB Procedures — Development Skill

Create, register, and test stored procedures for WormDB. Procedures are compiled Zig functions that execute server-side with direct store access under automatic shard locking — enabling atomic multi-key operations in a single network round-trip.

## Architecture Overview

```
Client (Bun/TS)                        Server (Zig)
─────────────────                      ────────────────
EXEC <name> <args...>                  wire.zig: parse EXEC frame
  → wire.ts encodes frame      →      executor.zig: lookup in registry
  → TCP WormWire binary               registry.zig: name → fn pointer
                                       context.zig: Ctx wraps Store + args
                                       <your_procedure>.zig: execute(ctx)
                                       auto-unlock shard locks on return
```

**Key files:**

| File                          | Purpose                                                  |
| ----------------------------- | -------------------------------------------------------- |
| `src/procedures/context.zig`  | The `Ctx` API — arguments, locking, store ops, responses |
| `src/procedures/registry.zig` | Comptime procedure table (name → function pointer)       |
| `src/procedures/mod.zig`      | Module re-exports                                        |
| `src/server/executor.zig`     | EXEC command dispatch (lines 139-148)                    |
| `src/core/types.zig`          | `Command.ExecParams`, `Response` types                   |

## The Ctx API Reference

Every procedure receives `*Ctx` and returns `anyerror!Ctx.Result` (which is `Response`).

### Arguments

```zig
ctx.arg(0)              // ?[]const u8 — positional arg by index
ctx.argInt(i64, 1)      // ?i64 — parse arg as integer type T
ctx.argCount()          // usize — total number of args
```

### Locking

```zig
ctx.lockKey(key)            // Lock shard for key (safe to call multiple times)
ctx.lockKeys2(key_a, key_b) // Lock two shards in deterministic order (deadlock-safe)
```

> **CRITICAL**: All locks auto-release on procedure return via `ctx.deinit()` (called by executor). You NEVER manually unlock.

> **IMPORTANT**: Max 16 shard locks per procedure call (`MAX_LOCKS = 16`). Exceeding silently does nothing.

### Store Access

```zig
ctx.get(key)                // ?[]const u8 — raw value (caller must hold shard lock)
ctx.getInt(i64, key)        // ?i64 — parse stored value as integer
ctx.set(key, value)         // void — write raw bytes (bypasses WAL, direct shard write)
ctx.setInt(key, int_val)    // void — write integer as string (uses scratch buffer)
ctx.exists(key)             // bool — check key existence
ctx.del(key)                // void — delete key (bypasses WORM check!)
ctx.getTimestamp(key)        // ?u64 — entry timestamp in ms since epoch
```

> **WARNING**: `ctx.set()` calls `store.setUnsafe()` which writes WITHOUT WAL logging. Procedure mutations are NOT persisted to the WAL. This is by design for performance — but means procedure-written data survives only until the next snapshot (if persistence is enabled).

> **WARNING**: `ctx.del()` bypasses WORM immutability checks. Use with care — this is intentional for internal procedures that need to clean up state.

### Responses

```zig
ctx.ok()            // Response.ok — success, no payload
ctx.err("message")  // Response.err — error with message (arena-allocated)
ctx.value(data)     // Response.value — success with byte payload (arena-allocated)
ctx.valueInt(42)    // Response.value — integer as string (uses scratch buffer)
```

### Utilities

```zig
ctx.fmt("key:{s}:{d}", .{name, id})  // []const u8 — format string (512B scratch buffer)
ctx.timestamp()                       // u64 — current server time (ms since epoch)
ctx.eql(a, b)                         // bool — byte slice equality
ctx.randomHex(16)                     // []const u8 — random hex string (fmt scratch buffer)
```

> **NOTE**: `ctx.fmt()` and `ctx.randomHex()` share the 512-byte `fmt_buf`. Calling one invalidates the previous result. Copy the slice if you need to keep it.

> **NOTE**: `ctx.setInt()` uses a separate 32-byte `int_buf` scratch buffer — safe to use alongside `fmt_buf`.

## Step-by-Step: Creating a New Procedure

### 1. Write the Procedure File

Create `src/procedures/<name>.zig`:

```zig
//! Built-in <NAME> procedure
//!
//! <Brief description of what it does>
//! EXEC <name> <arg1> <arg2> [<optional_arg>]
//!
//! - <Behavior note 1>
//! - <Behavior note 2>
//! - Returns <what it returns>

const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // 1. Parse arguments
    const key = ctx.arg(0) orelse return ctx.err("<name> requires at least 1 arg: <usage>");

    // 2. Acquire locks BEFORE any reads
    ctx.lockKey(key);

    // 3. Read state
    const current = ctx.getInt(i64, key) orelse 0;

    // 4. Compute
    const result = current + 1;

    // 5. Write state
    ctx.setInt(key, result);

    // 6. Return response
    return ctx.valueInt(result);
}
```

### 2. Register in the Registry

Edit `src/procedures/registry.zig`:

```diff
 pub const transfer = @import("transfer.zig");
 pub const increment = @import("increment.zig");
+pub const <name> = @import("<name>.zig");

 const PROCEDURES = [_]Entry{
     .{ .name = "transfer", .func = transfer.execute },
     .{ .name = "increment", .func = increment.execute },
+    .{ .name = "<name>", .func = <name>.execute },
 };
```

### 3. Re-export in mod.zig

Edit `src/procedures/mod.zig`:

```diff
 pub const transfer = @import("transfer.zig");
 pub const increment = @import("increment.zig");
+pub const <name> = @import("<name>.zig");
```

### 4. Build and Test

```bash
# Compile (catches type errors, missing imports)
zig build

# Run unit tests
zig build test

# Start server and test via client
zig build run -- --port 6389 --data ./data
bun run apps/bun/src/bin/client.ts EXEC <name> <args...>
```

## Procedure Patterns

### Pattern: Read-Modify-Write (Single Key)

The simplest pattern. Lock one key, read, compute, write back.

```zig
pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse return ctx.err("missing key");
    ctx.lockKey(key);
    const val = ctx.getInt(i64, key) orelse 0;
    ctx.setInt(key, val + 1);
    return ctx.valueInt(val + 1);
}
```

**Example**: `increment.zig`

### Pattern: Atomic Multi-Key Transfer

Lock two keys in deterministic order, validate, then write both. Use `lockKeys2` to avoid deadlocks.

```zig
pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const from = ctx.arg(0) orelse return ctx.err("missing from");
    const to = ctx.arg(1) orelse return ctx.err("missing to");
    const amount = ctx.argInt(i64, 2) orelse return ctx.err("invalid amount");

    if (amount <= 0) return ctx.err("amount must be positive");
    ctx.lockKeys2(from, to);

    const from_bal = ctx.getInt(i64, from) orelse return ctx.err("source not found");
    const to_bal = ctx.getInt(i64, to) orelse return ctx.err("dest not found");
    if (from_bal < amount) return ctx.err("insufficient_funds");

    ctx.setInt(from, from_bal - amount);
    ctx.setInt(to, to_bal + amount);
    return ctx.ok();
}
```

**Example**: `transfer.zig`

### Pattern: Conditional Create (Set-If-Not-Exists)

```zig
pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse return ctx.err("missing key");
    const val = ctx.arg(1) orelse return ctx.err("missing value");

    ctx.lockKey(key);
    if (ctx.exists(key)) return ctx.err("key_already_exists");
    ctx.set(key, val);
    return ctx.ok();
}
```

### Pattern: Compare-And-Swap

```zig
pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse return ctx.err("cas requires 3 args: <key> <expected> <new>");
    const expected = ctx.arg(1) orelse return ctx.err("cas requires 3 args: <key> <expected> <new>");
    const new_val = ctx.arg(2) orelse return ctx.err("cas requires 3 args: <key> <expected> <new>");

    ctx.lockKey(key);
    const current = ctx.get(key) orelse return ctx.err("key_not_found");
    if (!ctx.eql(current, expected)) return ctx.err("cas_conflict");
    ctx.set(key, new_val);
    return ctx.ok();
}
```

### Pattern: Multi-Key Aggregation (Read-Only)

```zig
pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    if (ctx.argCount() == 0) return ctx.err("sum requires at least 1 key");

    var total: i64 = 0;
    for (0..ctx.argCount()) |i| {
        const key = ctx.arg(i).?;
        ctx.lockKey(key);
        total += ctx.getInt(i64, key) orelse 0;
    }
    return ctx.valueInt(total);
}
```

> **NOTE**: Be careful with the 16-lock limit. If you need more than 16 distinct shard keys, redesign to use fewer shards or batch operations.

### Pattern: Key with Generated ID

```zig
pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const prefix = ctx.arg(0) orelse return ctx.err("missing prefix");
    const value = ctx.arg(1) orelse return ctx.err("missing value");

    const id = ctx.randomHex(8);
    // Copy: randomHex uses fmt_buf, and fmt() below would overwrite it
    var id_copy: [16]u8 = undefined;
    @memcpy(id_copy[0..id.len], id);

    const full_key = ctx.fmt("{s}:{s}", .{ prefix, id_copy[0..id.len] });
    ctx.lockKey(full_key);
    ctx.set(full_key, value);
    return ctx.value(full_key);
}
```

## Rules and Hazards

### ⚠️ Lock Before Read

Always call `lockKey`/`lockKeys2` BEFORE any `get`/`getInt`/`exists`/`del`. Reading without the lock is a data race.

### ⚠️ Scans and getCopy Before Locks

Always call `ctx.scan`/`ctx.scanFirst`/`ctx.scanCallback`/`ctx.getCopy`/`ctx.countKeys` BEFORE the first `lockKey`/`lockKeys2`. These helpers acquire shard locks internally; calling them while holding a Ctx shard lock can deadlock the procedure against itself.

### ⚠️ Deterministic Lock Order

When locking multiple keys, ALWAYS use `lockKeys2` for two keys. For 3+ keys, lock by ascending shard index to avoid deadlocks. The simplest approach: lock all keys before any reads.

### ⚠️ Scratch Buffer Lifetimes

`ctx.fmt()` and `ctx.randomHex()` share a 512-byte buffer. Each call overwrites the previous result. If you need multiple formatted values simultaneously, copy the first before generating the second (use `@memcpy` into a stack buffer).

`ctx.setInt()` and `ctx.valueInt()` share a separate 32-byte `int_buf`. Calling one invalidates the previous `int_buf` result.

### ⚠️ No WAL Logging

Procedure writes via `ctx.set()`/`ctx.setInt()` use `store.setUnsafe()` which bypasses WAL. Data is only durable after the next snapshot. If the server crashes before a snapshot, procedure-written data since the last snapshot is **lost**.

### ⚠️ WORM Bypass on Delete

`ctx.del()` directly removes from the shard hashmap without checking `is_worm`. Only use `del` when you intentionally need to remove state that may include WORM entries.

### ⚠️ Error Handling

The procedure signature is `anyerror!Ctx.Result`. If your procedure returns an error (via `try` or explicit `return error.Foo`), the executor catches it and sends `ERR: <error_name>` to the client. Prefer using `ctx.err("message")` for business logic failures since it gives you control over the error message.

## Checklist for New Procedures

- [ ] Created `src/procedures/<name>.zig` with `pub fn execute(ctx: *Ctx) anyerror!Ctx.Result`
- [ ] Added `@import` and entry to `PROCEDURES` in `registry.zig`
- [ ] Added `pub const` re-export in `mod.zig`
- [ ] Validates all required arguments with descriptive error messages
- [ ] Acquires locks BEFORE any store reads/writes
- [ ] Uses `lockKeys2` for two-key operations
- [ ] Handles missing keys gracefully (returns `ctx.err`, not a crash)
- [ ] `zig build` compiles without errors
- [ ] `zig build test` passes
- [ ] Tested via CLI: `bun run apps/bun/src/bin/client.ts EXEC <name> <args...>`
