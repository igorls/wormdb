//! Built-in VSIM procedure — pairwise vector similarity
//!
//! Computes the similarity between two stored vectors.
//! EXEC vsim <key_a> <key_b> [<metric>]
//!
//! - key_a:   key holding vector A (raw f32 bytes)
//! - key_b:   key holding vector B (raw f32 bytes)
//! - metric:  "cosine" (default), "dot", "l2"
//!
//! Returns the similarity score as a string (e.g., "0.953211").

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key_a = ctx.arg(0) orelse
        return ctx.err("vsim requires 2 args: <key_a> <key_b> [metric]");
    const key_b = ctx.arg(1) orelse
        return ctx.err("vsim requires 2 args: <key_a> <key_b> [metric]");

    const metric_str = ctx.arg(2) orelse "cosine";

    // Lock both keys before reading
    ctx.lockKeys2(key_a, key_b);

    const bytes_a = ctx.get(key_a) orelse
        return ctx.err("vsim: key_a not found");
    const bytes_b = ctx.get(key_b) orelse
        return ctx.err("vsim: key_b not found");

    const vec_a = distance.bytesToF32(bytes_a) orelse
        return ctx.err("vsim: key_a is not a valid f32 vector");
    const vec_b = distance.bytesToF32(bytes_b) orelse
        return ctx.err("vsim: key_b is not a valid f32 vector");

    // Both keys are explicit — a dim mismatch is almost always a bug.
    // Fail loudly rather than silently truncating to the shared prefix.
    if (vec_a.len != vec_b.len)
        return ctx.err("vsim: vector dimensions differ (a vs b)");

    const result: f32 = if (std.mem.eql(u8, metric_str, "dot"))
        distance.dot(vec_a, vec_b)
    else if (std.mem.eql(u8, metric_str, "l2"))
        distance.l2(vec_a, vec_b)
    else
        distance.cosine(vec_a, vec_b);

    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d:.6}", .{result}) catch "0";
    return ctx.value(str);
}
