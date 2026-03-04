# Stored Procedures

WormDB includes a compiled-in procedure engine that runs Zig functions directly inside the server process. Instead of issuing multiple GET/SET commands over the network and managing atomicity in client code, you invoke a single `EXEC` command that acquires shard locks, reads and writes multiple keys, and returns a result — all within one network round-trip.

## Why Server-Side Procedures?

Consider transferring funds between two accounts. Without procedures, a client must:

1. `GET acct:alice` — read balance
2. `GET acct:bob` — read balance
3. Check funds, calculate new balances
4. `SET acct:alice <new_value>` — write debit
5. `SET acct:bob <new_value>` — write credit

Between steps 1 and 4, another client could modify the same keys, causing a race condition. You'd need some form of distributed locking or optimistic concurrency — complexity that the procedure engine eliminates entirely.

With procedures:

```bash
bun run apps/bun/src/bin/client.ts EXEC transfer acct:alice acct:bob 200
# → OK (or ERR: insufficient_funds)
```

One command, atomic execution, no race window.

## The Ctx API

Every procedure receives a `Ctx` object (from `src/procedures/context.zig`) that wraps the store, arguments, and an allocator into a high-level interface:

### Arguments

| Method                 | Description                                       |
| ---------------------- | ------------------------------------------------- |
| `ctx.arg(index)`       | Get argument by position (returns `?[]const u8`)  |
| `ctx.argInt(T, index)` | Parse argument as integer type `T` (returns `?T`) |
| `ctx.argCount()`       | Total number of arguments                         |

### Locking

| Method                        | Description                                                  |
| ----------------------------- | ------------------------------------------------------------ |
| `ctx.lockKey(key)`            | Lock the shard containing `key`. Duplicate calls are safe.   |
| `ctx.lockKeys2(key_a, key_b)` | Lock two shards in deterministic order to prevent deadlocks. |

All locks are automatically released when the procedure returns — you never need to manually unlock.

### Store Access

| Method                   | Description                                        |
| ------------------------ | -------------------------------------------------- |
| `ctx.get(key)`           | Raw value bytes (caller must hold shard lock)      |
| `ctx.getInt(T, key)`     | Parse stored value as integer type `T`             |
| `ctx.set(key, value)`    | Write raw bytes                                    |
| `ctx.setInt(key, value)` | Write integer as string                            |
| `ctx.exists(key)`        | Check if key exists                                |
| `ctx.del(key)`           | Delete key (bypasses WORM for internal procedures) |

### Responses

| Method            | Description                          |
| ----------------- | ------------------------------------ |
| `ctx.ok()`        | Success, no payload                  |
| `ctx.err(msg)`    | Error with message string            |
| `ctx.value(data)` | Success with byte payload            |
| `ctx.valueInt(n)` | Success with integer value as string |

### Utilities

| Method             | Description                             |
| ------------------ | --------------------------------------- |
| `ctx.eql(a, b)`    | Compare two byte slices                 |
| `ctx.randomHex(n)` | Generate random hex string of `n` bytes |

## Built-In Procedures

### `increment`

```text
EXEC increment <key> [<delta>]
```

Atomically increments a key's integer value. If the key doesn't exist, it's initialized to `0` before adding the delta. Delta defaults to `1`.

```bash
bun run apps/bun/src/bin/client.ts EXEC increment counter
# → 1
bun run apps/bun/src/bin/client.ts EXEC increment counter 5
# → 6
bun run apps/bun/src/bin/client.ts EXEC increment counter -3
# → 3
```

**Source**: `src/procedures/increment.zig` — 12 lines of procedure logic.

### `transfer`

```text
EXEC transfer <from_key> <to_key> <amount>
```

Atomically debits one key and credits another. Uses `lockKeys2` for deadlock-safe ordering.

**Error conditions**:

- Amount is not a valid positive integer → `ERR: invalid amount` / `ERR: amount must be positive`
- Source key doesn't exist → `ERR: from account not found`
- Destination key doesn't exist → `ERR: to account not found`
- Source balance < amount → `ERR: insufficient_funds`

```bash
bun run apps/bun/src/bin/client.ts SET acct:a "1000"
bun run apps/bun/src/bin/client.ts SET acct:b "500"
bun run apps/bun/src/bin/client.ts EXEC transfer acct:a acct:b 200
# → OK
```

**Source**: `src/procedures/transfer.zig` — 20 lines of procedure logic.

## Anatomy of a Procedure

Here's the complete source of the `increment` procedure to show how simple the Ctx API makes things:

```zig
const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse
        return ctx.err("increment requires at least 1 arg: <key> [<delta>]");
    const delta = ctx.argInt(i64, 1) orelse 1;

    ctx.lockKey(key);

    const current = ctx.getInt(i64, key) orelse 0;
    const new_val = current + delta;
    ctx.setInt(key, new_val);
    return ctx.valueInt(new_val);
}
```

The pattern is always: **parse arguments → acquire locks → read state → compute → write state → return response**.

## Procedure Registration

Built-in procedures are registered in `src/procedures/registry.zig`. The registry maps string names to function pointers, and the executor looks up procedures by name when processing `EXEC` commands. If a procedure name isn't found, the client receives `ERR: unknown procedure`.
