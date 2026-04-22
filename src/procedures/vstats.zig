//! Built-in VSTATS procedure — vector index statistics
//!
//! Returns statistics about stored vectors in a namespace.
//! EXEC vstats [<namespace>]
//!
//! - namespace: key prefix (default: "vec:")
//!
//! Returns JSON:
//!   {"count":1234,"namespace":"vec:","dimensions":1536,"bq_count":1234}

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
    var json: std.ArrayListUnmanaged(u8) = .{};
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

    try json.append(ctx.allocator, '}');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}
