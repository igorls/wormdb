//! Built-in VSTATS procedure — vector index statistics
//!
//! Returns statistics about stored vectors in a namespace.
//! EXEC vstats [<namespace>]
//!
//! - namespace: key prefix (default: "vec:")
//!
//! Returns JSON:
//!   {
//!     "namespace":"vec:",
//!     "count":1234,              ← live entries in the store
//!     "inserts":1250,            ← per-node vinsert counter (local, not replicated)
//!     "dimensions":1536,         ← derived from the first vector
//!     "bq_count":1234,           ← BQ hash companion count
//!     "hnsw": {                  ← present only when an HNSW index exists
//!       "metric":"cosine",
//!       "nodes":1234,            ← total graph nodes (live + tombstoned)
//!       "live":1200,             ← nodes eligible for search results
//!       "tombstones":34,         ← deleted nodes awaiting rebuild
//!       "tombstone_ratio":0.0276
//!     }
//!   }
//!
//! When `tombstone_ratio` crosses ~25%, run `EXEC vreindex <namespace>`
//! to reclaim memory and fully discard tombstoned nodes.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");

const DEFAULT_NAMESPACE: []const u8 = "vec:";

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const namespace = ctx.arg(0) orelse DEFAULT_NAMESPACE;

    // Count vectors via prefix scan (lightweight — no value copying)
    const vec_count = ctx.countKeys(namespace);

    // Count BQ hashes
    const bq_prefix = ctx.fmt("bq:{s}", .{namespace});
    var bq_prefix_copy: [512]u8 = undefined;
    const bp_len = @min(bq_prefix.len, bq_prefix_copy.len);
    @memcpy(bq_prefix_copy[0..bp_len], bq_prefix[0..bp_len]);
    const bq_count = ctx.countKeys(bq_prefix_copy[0..bp_len]);

    // Try to detect dimensions from first vector
    var dimensions: usize = 0;
    const first_vec = try ctx.scan(namespace, 1);
    if (first_vec.len > 0) {
        if (distance.bytesToF32(first_vec[0].value)) |vec| {
            dimensions = vec.len;
        }
    }

    // Stored count (from vinsert tracking) — lives under the reserved
    // __meta: prefix, outside any user-visible namespace.
    const stats_key = ctx.fmt("__meta:{s}count", .{namespace});
    var stats_copy: [512]u8 = undefined;
    const stk_len = stats_key.len;
    @memcpy(stats_copy[0..stk_len], stats_key);
    ctx.lockKey(stats_copy[0..stk_len]);
    const insert_count = ctx.getInt(i64, stats_copy[0..stk_len]) orelse 0;

    // Build JSON
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(ctx.allocator, "{\"count\":");
    var buf: [20]u8 = undefined;
    var str = std.fmt.bufPrint(&buf, "{d}", .{vec_count}) catch "0";
    try json.appendSlice(ctx.allocator, str);

    try json.appendSlice(ctx.allocator, ",\"inserts\":");
    str = std.fmt.bufPrint(&buf, "{d}", .{insert_count}) catch "0";
    try json.appendSlice(ctx.allocator, str);

    try json.appendSlice(ctx.allocator, ",\"namespace\":\"");
    try json.appendSlice(ctx.allocator, namespace);

    try json.appendSlice(ctx.allocator, "\",\"dimensions\":");
    str = std.fmt.bufPrint(&buf, "{d}", .{dimensions}) catch "0";
    try json.appendSlice(ctx.allocator, str);

    try json.appendSlice(ctx.allocator, ",\"bq_count\":");
    str = std.fmt.bufPrint(&buf, "{d}", .{bq_count}) catch "0";
    try json.appendSlice(ctx.allocator, str);

    // HNSW block — only if a registered index exists for this namespace.
    if (ctx.vector_registry) |reg| {
        if (reg.get(namespace)) |ns_idx| {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();

            const total = ns_idx.len();
            const live = ns_idx.liveCount();
            const tombs = ns_idx.tombstone_count;
            const ratio: f32 = if (total == 0)
                0.0
            else
                @as(f32, @floatFromInt(tombs)) / @as(f32, @floatFromInt(total));

            try json.appendSlice(ctx.allocator, ",\"hnsw\":{\"metric\":\"");
            try json.appendSlice(ctx.allocator, ns_idx.metric.name());
            try json.appendSlice(ctx.allocator, "\",\"nodes\":");
            str = std.fmt.bufPrint(&buf, "{d}", .{total}) catch "0";
            try json.appendSlice(ctx.allocator, str);

            try json.appendSlice(ctx.allocator, ",\"live\":");
            str = std.fmt.bufPrint(&buf, "{d}", .{live}) catch "0";
            try json.appendSlice(ctx.allocator, str);

            try json.appendSlice(ctx.allocator, ",\"tombstones\":");
            str = std.fmt.bufPrint(&buf, "{d}", .{tombs}) catch "0";
            try json.appendSlice(ctx.allocator, str);

            try json.appendSlice(ctx.allocator, ",\"tombstone_ratio\":");
            str = std.fmt.bufPrint(&buf, "{d:.4}", .{ratio}) catch "0";
            try json.appendSlice(ctx.allocator, str);

            try json.appendSlice(ctx.allocator, ",\"async\":");
            try json.appendSlice(ctx.allocator, if (ns_idx.async_mode) "true" else "false");
            try json.appendSlice(ctx.allocator, ",\"pending\":");
            str = std.fmt.bufPrint(&buf, "{d}", .{ns_idx.pendingAsyncCount()}) catch "0";
            try json.appendSlice(ctx.allocator, str);

            // Report RaBitQ params state so operators can confirm
            // `EXEC vrabitq` has run and check the seed used.
            if (ns_idx.rabitq_params) |p| {
                try json.appendSlice(ctx.allocator, ",\"rabitq\":{\"dim\":");
                str = std.fmt.bufPrint(&buf, "{d}", .{p.dim}) catch "0";
                try json.appendSlice(ctx.allocator, str);
                try json.appendSlice(ctx.allocator, ",\"seed\":");
                str = std.fmt.bufPrint(&buf, "{d}", .{p.seed}) catch "0";
                try json.appendSlice(ctx.allocator, str);
                try json.append(ctx.allocator, '}');
            } else {
                try json.appendSlice(ctx.allocator, ",\"rabitq\":null");
            }

            try json.append(ctx.allocator, '}');
        }
    }

    try json.append(ctx.allocator, '}');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}
