//! Built-in VINSERT procedure — vector insert with optional WORM
//!
//! Stores a vector with metadata and optional binary quantization hash.
//! EXEC vinsert <key> <vector_bytes> [<worm>] [<namespace>]
//!
//! - key:           vector identifier (e.g., "memory-001")
//! - vector_bytes:  raw f32 byte array (the embedding)
//! - worm:          "1" to make immutable (default: "1" — vectors are WORM by default)
//! - namespace:     prefix namespace (default: "vec:")
//!
//! The procedure:
//! 1. Validates the vector bytes (must be multiple of 4 / valid f32 array)
//! 2. Stores the vector at vec:<namespace>:<key>
//! 3. Stores a binary-quantized hash at bq:<namespace>:<key> (for fast pre-filtering)
//! 4. Increments vec:stats:count
//! 5. Returns OK
//!
//! Key layout:
//!   vec:ns:id      → raw f32 bytes (the full vector)
//!   bq:ns:id       → binary-quantized hash (1 bit per dimension)
//!   vec:stats:count → total vectors inserted

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");

const DEFAULT_NAMESPACE: []const u8 = "vec:";

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // ── Parse arguments ──────────────────────────────────────────
    const id = ctx.arg(0) orelse
        return ctx.err("vinsert requires at least 2 args: <key> <vector_bytes> [worm] [namespace]");

    const vec_bytes = ctx.arg(1) orelse
        return ctx.err("vinsert requires at least 2 args: <key> <vector_bytes> [worm] [namespace]");

    // Validate vector bytes
    if (vec_bytes.len == 0 or vec_bytes.len % 4 != 0)
        return ctx.err("vinsert: vector must be a non-empty f32 byte array (length multiple of 4)");

    // WORM by default — vectors are immutable embeddings
    const is_worm = if (ctx.arg(2)) |w| !std.mem.eql(u8, w, "0") else true;

    const namespace = ctx.arg(3) orelse DEFAULT_NAMESPACE;

    // ── Build keys ───────────────────────────────────────────────
    const vec_key = ctx.fmt("{s}{s}", .{ namespace, id });
    var vec_key_copy: [512]u8 = undefined;
    const vk_len = @min(vec_key.len, vec_key_copy.len);
    @memcpy(vec_key_copy[0..vk_len], vec_key[0..vk_len]);
    const vec_key_stable = vec_key_copy[0..vk_len];

    const bq_key = ctx.fmt("bq:{s}{s}", .{ namespace, id });
    var bq_key_copy: [512]u8 = undefined;
    const bq_len = @min(bq_key.len, bq_key_copy.len);
    @memcpy(bq_key_copy[0..bq_len], bq_key[0..bq_len]);
    const bq_key_stable = bq_key_copy[0..bq_len];

    const stats_key = ctx.fmt("{s}stats:count", .{namespace});
    var stats_key_copy: [512]u8 = undefined;
    const sk_len = @min(stats_key.len, stats_key_copy.len);
    @memcpy(stats_key_copy[0..sk_len], stats_key[0..sk_len]);
    const stats_key_stable = stats_key_copy[0..sk_len];

    // ── Lock all involved shards ────────────────────────────────
    ctx.lockKey(vec_key_stable);
    ctx.lockKey(bq_key_stable);
    ctx.lockKey(stats_key_stable);

    // ── Check if key already exists (WORM check) ─────────────────
    if (ctx.exists(vec_key_stable))
        return ctx.err("vinsert: key already exists (vectors are immutable)");

    // ── Store the vector ─────────────────────────────────────────
    if (is_worm) {
        try ctx.setDurableWorm(vec_key_stable, vec_bytes);
    } else {
        try ctx.setDurable(vec_key_stable, vec_bytes);
    }

    // ── Store binary-quantized hash for fast pre-filtering ───────
    const vec = distance.bytesToF32(vec_bytes).?; // already validated above
    const bq_size = distance.binaryQuantizedSize(vec.len);
    const bq_buf = try ctx.allocator.alloc(u8, bq_size);
    distance.binaryQuantize(vec, bq_buf);

    if (is_worm) {
        try ctx.setDurableWorm(bq_key_stable, bq_buf);
    } else {
        try ctx.setDurable(bq_key_stable, bq_buf);
    }

    // ── Increment vector count ───────────────────────────────────
    const count = ctx.getInt(i64, stats_key_stable) orelse 0;
    ctx.setInt(stats_key_stable, count + 1);

    return ctx.ok();
}
