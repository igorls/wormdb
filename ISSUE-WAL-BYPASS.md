# BUG: `store.setUnsafe` incorrectly writes to WAL when persistence is `.full`

## Description
According to `wormdb/.agent/skills/wormdb-procedures/SKILL.md`:
> `ctx.set()` calls `store.setUnsafe()` which writes WITHOUT WAL logging. Procedure mutations are NOT persisted to the WAL. This is by design for performance — but means procedure-written data survives only until the next snapshot (if persistence is enabled).

However, looking at the implementation in `src/storage/store.zig`:
`setUnsafe` calls `setInternalLocked`.
`setInternalLocked` contains the following logic:
```zig
        const entry = if (self.config.persistence == .full) blk: {
            self.wal_enqueue_mutex.lock();
            const e = self.wal.?.appendSet(key, value, .{ .is_worm = is_worm, .is_deleted = false }, timestamp) catch {
```
This unconditionally enqueues the write to the WAL as long as `self.config.persistence == .full`. The `is_worm` flag is serialized, but the record is still written and will be replayed on startup.

## Impact
This breaks the documented design intent. Hot balances and counters updated via `ctx.set()` inside procedures are currently incurring WAL IO overhead. 
While this accidentally prevents data loss on crash in `.full` mode, it defeats the performance optimization of `setUnsafe`.

## Proposed Fix
`setInternalLocked` (or a separate internal function for `setUnsafe`) should conditionally bypass WAL logging for non-WORM keys when called via the unsafe path, or the `persistence` configuration should be respected strictly for WORM vs non-WORM writes.
