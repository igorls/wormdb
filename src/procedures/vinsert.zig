//! Built-in VINSERT procedure — vector insert with optional WORM
//!
//! Stores a vector with metadata and optional binary quantization hash.
//! EXEC vinsert <key> <vector_bytes> [<worm>] [<namespace>] [<metric>]
//!
//! - key:           vector identifier (e.g., "memory-001")
//! - vector_bytes:  raw f32 byte array (the embedding)
//! - worm:          "1" to make immutable (default: "1" — vectors are WORM by default)
//! - namespace:     prefix namespace (default: "vec:")
//! - metric:        distance metric for this namespace's HNSW index.
//!                  "cosine" (default), "dot", "l2". Captured on the first
//!                  insert into a namespace; subsequent inserts under the
//!                  same namespace must use the same metric or the HNSW
//!                  update is skipped (the store+BQ writes still succeed).
//!
//! The procedure:
//! 1. Validates the vector bytes (must be multiple of 4 / valid f32 array)
//! 2. Stores the vector at vec:<namespace>:<key>
//! 3. Stores a binary-quantized hash at bq:<namespace>:<key> (for fast pre-filtering)
//! 4. Increments vec:stats:count
//! 5. Returns OK
//!
//! Key layout:
//!   vec:ns:id             → raw f32 bytes (the full vector)
//!   bq:vec:ns:id          → binary-quantized hash (1 bit per dimension)
//!   __meta:vec:ns:count   → total vectors inserted (reserved __meta: prefix
//!                           keeps stats out of any user-scannable namespace)

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");
const Metric = @import("../vector/metric.zig").Metric;

const DEFAULT_NAMESPACE: []const u8 = "vec:";

// Max length for the user-supplied id. Keeps formatted keys well under the
// ctx.fmt scratch buffer (512B) across "vec:", "bq:vec:", "__meta:vec:" forms.
const MAX_ID_LEN: usize = 256;
const MAX_NAMESPACE_LEN: usize = 128;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // ── Parse arguments ──────────────────────────────────────────
    const id = ctx.arg(0) orelse
        return ctx.err("vinsert requires at least 2 args: <key> <vector_bytes> [worm] [namespace]");

    const vec_bytes = ctx.arg(1) orelse
        return ctx.err("vinsert requires at least 2 args: <key> <vector_bytes> [worm] [namespace]");

    if (id.len == 0 or id.len > MAX_ID_LEN)
        return ctx.err("vinsert: id must be 1..256 bytes");

    // Validate vector bytes
    if (vec_bytes.len == 0 or vec_bytes.len % 4 != 0)
        return ctx.err("vinsert: vector must be a non-empty f32 byte array (length multiple of 4)");

    // WORM by default — vectors are immutable embeddings
    const is_worm = if (ctx.arg(2)) |w| !std.mem.eql(u8, w, "0") else true;

    const namespace = ctx.arg(3) orelse DEFAULT_NAMESPACE;
    if (namespace.len > MAX_NAMESPACE_LEN)
        return ctx.err("vinsert: namespace too long (max 128 bytes)");

    // Metric is per-namespace: first insert locks it in.
    const metric: Metric = if (ctx.arg(4)) |s|
        Metric.fromStr(s) orelse return ctx.err("vinsert: unknown metric (use cosine|dot|l2)")
    else
        .cosine;

    // ── Build keys ───────────────────────────────────────────────
    const vec_key = ctx.fmt("{s}{s}", .{ namespace, id });
    var vec_key_copy: [512]u8 = undefined;
    const vk_len = vec_key.len;
    @memcpy(vec_key_copy[0..vk_len], vec_key);
    const vec_key_stable = vec_key_copy[0..vk_len];

    const bq_key = ctx.fmt("bq:{s}{s}", .{ namespace, id });
    var bq_key_copy: [512]u8 = undefined;
    const bq_len = bq_key.len;
    @memcpy(bq_key_copy[0..bq_len], bq_key);
    const bq_key_stable = bq_key_copy[0..bq_len];

    // Stats key lives under __meta: — never scanned by vsearch, so it can't
    // pollute results even when the count's decimal ASCII happens to parse
    // as a 1-, 2-, or 3-dim f32 vector.
    const stats_key = ctx.fmt("__meta:{s}count", .{namespace});
    var stats_key_copy: [512]u8 = undefined;
    const sk_len = stats_key.len;
    @memcpy(stats_key_copy[0..sk_len], stats_key);
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

    // ── Incrementally update the HNSW index (if enabled) ─────────
    // The `vec` slice reinterprets `vec_bytes` as align(1) f32 — safe
    // because bytesToF32 already validated the length. hnsw.insert copies
    // into aligned storage internally.
    //
    // Failure modes that are logged and swallowed (store + BQ still
    // succeeded; future vsearch can serve via BQ prefilter; EXEC vreindex
    // recovers):
    //   - OOM during graph insert
    //   - Dim mismatch vs prior inserts in the same namespace
    //   - MetricMismatch: caller passed a different metric than the one
    //     the namespace was created with. The store write is authoritative;
    //     the HNSW just stays in sync with whoever created it first.
    if (ctx.vector_registry) |reg| {
        const ns_idx = reg.getOrCreate(namespace, metric) catch |e| blk: {
            std.log.warn("vinsert: getOrCreate for '{s}' (metric={s}) failed: {s}", .{
                namespace, metric.name(), @errorName(e),
            });
            break :blk null;
        };
        if (ns_idx) |idx| {
            idx.lock.lock();
            defer idx.lock.unlock();
            _ = idx.insertLocked(vec_key_stable, vec, ctx.timestamp()) catch |e| {
                std.log.warn("vinsert: HNSW insert for '{s}' failed: {s}", .{ vec_key_stable, @errorName(e) });
            };
        }
    }

    // ── Increment vector count ───────────────────────────────────
    // Local-only counter (ctx.set bypasses cluster replication). Each node
    // maintains its own count; authoritative totals should use `vstats`'s
    // `count` field (derived from a prefix scan) rather than `inserts`.
    const count = ctx.getInt(i64, stats_key_stable) orelse 0;
    ctx.setInt(stats_key_stable, count + 1);

    // ── Emit inserted event ──────────────────────────────────────
    // Channel naming: `<namespace>inserted`. Subscribers on a prefix like
    // `vec:articles:` see every new vector under that namespace; a broader
    // `vec:` subscription catches all vector inserts.
    const event_channel = ctx.fmt("{s}inserted", .{namespace});
    ctx.publish(event_channel, vec_key_stable);

    return ctx.ok();
}
