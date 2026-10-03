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
| `ctx.set(key, value)`    | Write raw bytes through the unsafe in-memory path  |
| `ctx.setDurable(key, value)` | Write through WAL and replicate to peers      |
| `ctx.setDurableWorm(key, value)` | Durable write with the WORM bit set       |
| `ctx.setInt(key, value)` | Write integer as string through `ctx.set`          |
| `ctx.exists(key)`        | Check if key exists                                |
| `ctx.del(key)`           | Delete key through the unsafe in-memory path       |
| `ctx.deleteDurable(key)` | Delete through WAL, WORM check, and replication    |
| `ctx.getCopy(key)`       | Lock, copy, and unlock a value for long-lived reads |

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
| `ctx.eql(a, b)`        | Compare two byte slices                         |
| `ctx.randomHex(n)`     | Generate random hex string of `n` bytes         |
| `ctx.timestamp()`      | Current server timestamp in milliseconds        |
| `ctx.identity()`       | Authenticated SCT subject, if present           |
| `ctx.permits(op, target)` | Check the caller's SCT capability, or true for trusted/internal callers |
| `ctx.requireNamespace(ns, access)` | Enforce scoped memory namespace access (`read`, `write`, `delete`) |
| `ctx.publish(c, msg)`  | Best-effort pub/sub event from inside a procedure |

::: warning
`ctx.set()`, `ctx.setInt()`, and `ctx.del()` bypass the WAL, WORM checks, and replication. Use `ctx.setDurable*()` and `ctx.deleteDurable()` when procedure-written data must survive crashes and replicate like normal client writes.
:::

Durable writes temporarily release held shard locks before the store write and cluster replication call, then re-acquire them in sorted order. This avoids deadlocks with anti-entropy scans that may need to lock every shard.

## Built-In Procedures

The registry currently includes several procedure families:

| Family | Procedures |
| ------ | ---------- |
| Atomic KV | `increment`, `transfer`, `kv_put`, `kv_get`, `kv_stats`, `scan` |
| Collaboration demos | `chat_send`, `chat_history` |
| Vector search | `vinsert`, `vsearch`, `vsim`, `vstats`, `vreindex`, `vrabitq`, `vdelete`, `vnsdrop` |
| Agent memory | `mem_init`, `mem_add`, `mem_meta_set`, `mem_bulk_add`, `mem_get`, `mem_query`, `mem_range`, `mem_stats`, `mem_verify`, `mem_drop`, `mem_reset_index`, `mem_capabilities` |
| Auth | `auth_mint_scoped` |
| Verifiable logs | `append_log_append`, `append_log_verify`, `append_log_mmr_proof`, `append_log_mmr_verify`, `append_log_checkpoint`, `append_log_proof_bundle`, `append_log_proof_verify`, `append_log_witness`, `append_log_witness_request`, `append_log_witness_import`, `append_log_witness_verify` |
| Proof diagnostics | `proof_prefix_root` |

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

### Vector Procedures

See [Vector Search](/architecture/vector-search) for the full vector procedure surface. The important operational procedures are:

- `vstats` — inspect namespace dimensions, HNSW state, tombstones, and RaBitQ params.
- `vreindex` — rebuild HNSW from durable `vec:*` keys.
- `vrabitq` — install RaBitQ params and re-encode `bq:*` companions.
- `vdelete` / `vnsdrop` — tombstone or drop vector namespaces.

### Agent Memory Procedures

See [Agent Memory](/architecture/agent-memory) for the `mem_*` surface. These procedures compose WORM docs, metadata, vector inserts, pub/sub, and embedder-id enforcement for AI memory stores.

### Verifiable Log Procedures

See [Verifiable Append Log](/protocol/append-log) for the canonical envelope and procedure response formats.

- `append_log_append` — append opaque payload bytes to a named WORM log and return sequence/hash metadata.
- `append_log_verify` — scan a log and verify contiguous sequences, WORM protection, payload hashes, event hashes, and hash-chain links.
- `append_log_mmr_proof` — return hex-encoded MMR inclusion proof bytes for a stored log sequence.
- `append_log_mmr_verify` — verify record hash/root/proof bytes without reading the database.
- `append_log_checkpoint` — create and WORM-store a signed checkpoint over an append-log sequence range.
- `append_log_witness` / `append_log_witness_request` / `append_log_witness_import` / `append_log_witness_verify` — countersign, request live peer countersignatures, import, and verify WORM witness records for checkpoint roots.
- `append_log_proof_bundle` — export canonical record bytes, hashes, inclusion paths, and checkpoint metadata as stable JSON.
- `append_log_proof_verify` — verify a record hash and MMR proof against a stored signed checkpoint.
- `proof_prefix_root` — compute a deterministic `prefix-sha256-v1` root over sorted key/value/timestamp entries for diagnostics and cluster anti-entropy.

### Domain Procedures

External domain packages register additional procedures at startup via their manifests (`registerDomains()`); they share the same registry and `EXEC` dispatch, and are typically reached through the gateway's `/api/...` routes. See [Gateways](/operations/gateways).

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
