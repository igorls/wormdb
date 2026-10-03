# Issue: store.setUnsafe incorrectly writes to WAL in .full persistence mode

**Status:** confirmed in production — caused silent data loss in a fiscal document
numbering sequence (NFS-e Nacional emitter), 2026-07-30.

**Severity:** high. `EXEC increment`, `EXEC transfer` and `EXEC kv_put` are all
non-durable under `--persistence full`. They report success and are lost on the
next restart unless a snapshot happened to run in between.

## Summary

Procedure writes go through `Ctx.set` / `Ctx.setInt`, which call
`Store.setUnsafe` — deliberately **no WAL** ([store.zig:444-453][s1]):

```zig
/// Write without acquiring a lock and **without WAL**. Caller must hold
/// the key shard lock. Used by procedure hot-path (`Ctx.set` / `setInt`).
///
/// On `.full` persistence the durable path is `set` / `setWithTimestamp`
/// (or procedure `setDurable*`). Unsafe writes stay in the live map only
/// until the next snapshot — they must not enqueue WAL records or they
/// would pay WAL IO and be replayed on restart (#88).
pub fn setUnsafe(self: *Store, key: []const u8, value: []const u8, is_worm: bool) StoreError!void
```

The title of this file states the inverse of the actual defect. `setUnsafe` does
**not** write to the WAL; the bug is that the built-in procedures which mutate
user-visible state call it. Errors are additionally swallowed at
[context.zig:299-301][c1]:

```zig
pub fn set(self: *Ctx, key: []const u8, val: []const u8) void {
    self.store.setUnsafe(key, val, false) catch {};
}
```

so a failed write is silent as well as non-durable.

## Blast radius

| Call site | Writes | Correct today? |
| --- | --- | --- |
| [`increment.zig:20`][p1] | the counter itself | **no** |
| [`transfer.zig:26-27`][p2] | both account balances | **no** |
| [`kv_put.zig:34`][p3] | the stored value | **no** |
| [`kv_put.zig:38`][p3], [`kv_get.zig:37`][p4], [`vinsert.zig:86`][p5] | stats counters | acceptable |
| `memory.zig`, `chat_send.zig`, `append_log.zig` | user data | yes — use `setDurable*` |

The procedures added later use `setDurable`; the original built-ins never
migrated. `#88` optimised WAL IO for what were then stats-only writes, and the
semantics were never revisited when `increment`/`transfer`/`kv_put` became
load-bearing.

## Observed failure

A DPS (fiscal document) sequence numbered by `EXEC increment` on key
`nfse:<cnpj>:seq:dps:1`:

- 2026-07-29 18:47 — document 19 issued; counter at 19
- 2026-07-30 00:43 — `wormdb-fiscal` container recreated (`RestartCount=0`)
- 2026-07-31 18:34 — next emission called `increment` and received **1**

Every WORM document, audit stream and mutable config record survived the restart
— those arrive via wire-level `SET` → `Store.set` → WAL. Only the counter was
lost, because only the counter was written by a procedure.

In this case the sequence had already been consumed at the tax authority, so the
next emissions would have silently reused numbers already assigned to authorized
documents. Any consumer using `increment` for identity or ordering has the same
exposure.

## Fix

`setUnsafe` should stay as-is — it is a legitimate primitive for stats and for
callers that already hold the shard lock. The defect is its use by procedures
that mutate user-visible state.

A naive swap to `Ctx.setDurable` is **incorrect** for `increment` and `transfer`:
`setDurable` releases all held shard locks for the duration of the write
([context.zig:308-311][c2]), because `replicateWrite` may trigger an
anti-entropy scan that locks every shard. Dropping the lock between the read and
the write turns a lost counter into a lost update.

The read-modify-write must therefore be atomic at the **store** level, where both
the WAL and the shard locks are owned.

### 1. `Store.incrementDurable(key, delta) StoreError!i64`

Mirror the ordering already proven in `setWithTimestamp`
([store.zig:465-528][s2]) — `wal_enqueue_mutex` held across append+put, shard
lock taken only in short windows:

```
if persistence == .full:
    wal_enqueue_mutex.lock()
    { shard.lock;  current = parseInt(shard.data.get(key) orelse sstHit(key)) orelse 0;  shard.unlock }
    new = current + delta
    entry = wal.appendSet(key, fmt(new), .{ .is_worm = false, .is_deleted = false }, nowMs())
    { shard.lock;  WORM re-check;  shardPutLocked(entry);  shard.unlock }
    wal_enqueue_mutex.unlock()
    maybeSnapshotAndTruncate()
    return new
else:
    shard.lock;  RMW in map;  shard.unlock;  return new
```

Atomicity comes from serialising all durable increments on `wal_enqueue_mutex`,
so no shard lock is held across WAL IO and the existing deadlock constraint is
respected. Follow the same `destroyEntry` + unlock discipline on every error
path.

### 2. `Ctx.incrementDurable(key, delta) !i64`

Thin wrapper performing the same save/release/reacquire dance as `setDurable`,
plus replication when a cluster handle is attached.

### 3. Migrate the call sites

- `increment.zig` → `ctx.incrementDurable`
- `transfer.zig` → needs a two-key durable variant; both writes must land in one
  `wal_enqueue_mutex` critical section or a crash between them can debit without
  crediting
- `kv_put.zig:34` (the value; not the stats counter) → `ctx.setDurable`
- Leave stats counters on `setUnsafe` and say so in a comment, so the split is
  intentional rather than incidental

### 4. Regression tests

Store-level: increment, drop and reopen the `Store`, assert the value survives —
with **no** intervening snapshot, which is the case that fails today. Add the
same for `transfer` and `kv_put`. A concurrency test asserting N threads × M
increments == N*M would have caught the lost-update variant.

## Note for consumers

Until this ships, treat `EXEC increment` as a cache, not a source of truth.
Consumers that need a durable sequence should derive it from durable state — e.g.
seed the counter at boot from the highest value actually recorded in stored
records, taking `max(counter, observed)` and never decreasing.

[s1]: src/storage/store.zig#L444-L453
[s2]: src/storage/store.zig#L465-L528
[c1]: src/procedures/context.zig#L299-L301
[c2]: src/procedures/context.zig#L308-L311
[p1]: src/procedures/increment.zig#L20
[p2]: src/procedures/transfer.zig#L26-L27
[p3]: src/procedures/kv_put.zig#L34
[p4]: src/procedures/kv_get.zig#L37
[p5]: src/procedures/vinsert.zig#L86
