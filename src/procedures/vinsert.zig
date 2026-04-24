//! Built-in VINSERT procedure — thin wrapper over `vector_ops.applyVinsert`.
//!
//! EXEC vinsert <key> <vector_bytes> [<worm>] [<namespace>] [<metric>]
//!
//! - key:           vector identifier (e.g., "memory-001")
//! - vector_bytes:  raw f32 byte array (the embedding)
//! - worm:          "1" to make immutable (default: "1" — WORM by default)
//! - namespace:     prefix namespace (default: "vec:")
//! - metric:        "cosine" (default), "dot", "l2"
//!
//! The procedure builds the full vec key (`<namespace><id>`), parses the
//! metric, and delegates the store + BQ + HNSW + event + replicate sequence
//! to `vector_ops.applyVinsert`. Wire-level VINSERT frames go through the
//! same helper via the executor, so all three entry points (procedure,
//! wire command from client, wire command from replication peer) share
//! identical semantics.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const vector_ops = @import("vector_ops.zig");
const Metric = @import("../vector/metric.zig").Metric;

const DEFAULT_NAMESPACE: []const u8 = "vec:";

// Bounds keep the constructed key under the shared buffer sizes used
// elsewhere. These are belt-and-suspenders; applyVinsert also validates.
const MAX_ID_LEN: usize = 256;
const MAX_NAMESPACE_LEN: usize = 128;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const id = ctx.arg(0) orelse
        return ctx.err("vinsert requires at least 2 args: <key> <vector_bytes> [worm] [namespace] [metric]");

    const vec_bytes = ctx.arg(1) orelse
        return ctx.err("vinsert requires at least 2 args: <key> <vector_bytes> [worm] [namespace] [metric]");

    if (id.len == 0 or id.len > MAX_ID_LEN)
        return ctx.err("vinsert: id must be 1..256 bytes");

    const is_worm = if (ctx.arg(2)) |w| !std.mem.eql(u8, w, "0") else true;

    const namespace = ctx.arg(3) orelse DEFAULT_NAMESPACE;
    if (namespace.len > MAX_NAMESPACE_LEN)
        return ctx.err("vinsert: namespace too long (max 128 bytes)");

    const metric: Metric = if (ctx.arg(4)) |s|
        Metric.fromStr(s) orelse return ctx.err("vinsert: unknown metric (use cosine|dot|l2)")
    else
        .cosine;

    // Build the full vec key into a stable scratch buffer (the procedure
    // allocator is arena-owned, so the slice outlives this call).
    const vec_key = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ namespace, id });
    defer ctx.allocator.free(vec_key);

    vector_ops.applyVinsert(
        ctx.store,
        ctx.cluster,
        ctx.event_bus,
        ctx.vector_registry,
        ctx.allocator,
        .{
            .key = vec_key,
            .vector = vec_bytes,
            .worm = is_worm,
            .namespace = namespace,
            .metric = metric,
            .timestamp = ctx.timestamp(),
            .replicate = true,
        },
    ) catch |err| {
        return switch (err) {
            error.InvalidVectorBytes => ctx.err("vinsert: vector must be a non-empty f32 byte array (length multiple of 4)"),
            error.WormViolation => ctx.err("vinsert: key already exists (vectors are immutable)"),
            error.DimensionMismatch => ctx.err("vinsert: vector dimension does not match the namespace's frozen dim"),
            else => ctx.err(ctx.fmt("vinsert: {s}", .{@errorName(err)})),
        };
    };

    // Bump the local per-node insert counter (kept for vstats.inserts).
    // Not replicated by design — each node tracks its own direct inserts.
    const stats_key = try std.fmt.allocPrint(ctx.allocator, "__meta:{s}count", .{namespace});
    defer ctx.allocator.free(stats_key);
    ctx.lockKey(stats_key);
    const count = ctx.getInt(i64, stats_key) orelse 0;
    ctx.setInt(stats_key, count + 1);

    return ctx.ok();
}
