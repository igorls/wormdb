//! Built-in KV_STATS procedure
//!
//! Aggregate analytics counters under shard locks.
//! EXEC kv_stats
//!
//! Locks both stats:reads and stats:writes shards, then returns
//! a consistent snapshot of both counters.
//! Returns: "reads=<n>\nwrites=<n>"
//!
//! Without a procedure, reading these two counters separately could
//! yield an inconsistent snapshot if writes happen between GETs.

const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // Lock both stat shards for a consistent read
    ctx.lockKeys2("stats:reads", "stats:writes");

    const reads = ctx.getInt(i64, "stats:reads") orelse 0;
    const writes = ctx.getInt(i64, "stats:writes") orelse 0;

    const result = ctx.fmt("reads={d}\nwrites={d}", .{ reads, writes });
    return ctx.value(result);
}
