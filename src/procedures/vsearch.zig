//! Built-in VSEARCH procedure — brute-force vector similarity search
//!
//! Scans all vectors under a namespace prefix, computes similarity to a
//! query vector, optionally applies time-decay scoring, and returns the
//! top-K most similar entries as JSON.
//!
//! EXEC vsearch <query_key> <top_k> [<namespace>] [<metric>] [<decay>]
//!
//! - query_key:  key holding the query vector (raw f32 bytes)
//! - top_k:      max results to return (1–100)
//! - namespace:  key prefix to search (default: "vec:")
//! - metric:     distance metric: "cosine" (default), "dot", "l2"
//! - decay:      temporal decay factor (0.0 = no decay, default; higher = more recency bias)
//!
//! Returns JSON array sorted by descending score:
//!   [{"k":"vec:ns:id","s":0.95,"ts":1709...}, ...]
//!
//! The score includes both semantic similarity and optional temporal recency.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");

const MAX_TOP_K: usize = 100;
const DEFAULT_NAMESPACE: []const u8 = "vec:";

/// Distance metric selector.
const Metric = enum {
    cosine,
    dot,
    l2,

    fn fromStr(s: []const u8) Metric {
        if (std.mem.eql(u8, s, "dot")) return .dot;
        if (std.mem.eql(u8, s, "l2")) return .l2;
        return .cosine;
    }
};

/// A single search result candidate.
const Candidate = struct {
    key: []const u8,
    score: f32,
    timestamp: u64,
};

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // ── Parse arguments ──────────────────────────────────────────
    const query_key = ctx.arg(0) orelse
        return ctx.err("vsearch requires at least 2 args: <query_key> <top_k> [namespace] [metric] [decay]");

    const top_k_raw = ctx.argInt(usize, 1) orelse
        return ctx.err("vsearch: top_k must be a positive integer");

    const top_k = @min(if (top_k_raw == 0) @as(usize, 10) else top_k_raw, MAX_TOP_K);

    const namespace = ctx.arg(2) orelse DEFAULT_NAMESPACE;

    const metric = if (ctx.arg(3)) |m| Metric.fromStr(m) else Metric.cosine;

    // Decay factor λ: final_score = (1-λ)×similarity + λ×recency
    // where recency = exp(-age_hours / 168) (half-life ≈ 1 week)
    var decay: f32 = 0.0;
    if (ctx.arg(4)) |d| {
        decay = std.fmt.parseFloat(f32, d) catch 0.0;
        decay = @min(@max(decay, 0.0), 1.0);
    }

    // ── Load query vector ────────────────────────────────────────
    ctx.lockKey(query_key);
    const query_bytes = ctx.get(query_key) orelse
        return ctx.err("vsearch: query key not found");

    const query_vec = distance.bytesToF32(query_bytes) orelse
        return ctx.err("vsearch: query value is not a valid f32 vector (byte length must be multiple of 4)");

    // ── Scan namespace for candidates ────────────────────────────
    // Use the store's prefix scan to get all matching keys.
    // This locks each shard independently — safe and non-blocking.
    const scan_results = try ctx.scan(namespace, 0); // 0 = no limit

    // ── Build min-heap of top-K candidates ───────────────────────
    var heap: std.ArrayListUnmanaged(Candidate) = .{};

    const now_ms = ctx.timestamp();

    for (scan_results) |entry| {
        // Skip the query key itself
        if (std.mem.eql(u8, entry.key, query_key)) continue;

        // Parse vector from value bytes
        const vec = distance.bytesToF32(entry.value) orelse continue;

        // Compute raw similarity
        const raw_sim = switch (metric) {
            .cosine => distance.cosine(query_vec, vec),
            .dot => distance.dot(query_vec, vec),
            .l2 => blk: {
                // L2: invert so higher = more similar (for ranking)
                const d = distance.l2Squared(query_vec, vec);
                break :blk 1.0 / (1.0 + d);
            },
        };

        // Apply temporal decay if requested
        const score = if (decay > 0.0) blk: {
            const age_ms = if (now_ms > entry.timestamp) now_ms - entry.timestamp else 0;
            const age_hours: f32 = @as(f32, @floatFromInt(age_ms)) / 3_600_000.0;
            // Exponential decay with ~1 week half-life (168 hours)
            const recency = @exp(-age_hours / 168.0);
            break :blk (1.0 - decay) * raw_sim + decay * recency;
        } else raw_sim;

        // Maintain top-K via simple insertion (fine for brute-force Phase 1)
        try heap.append(ctx.allocator, .{
            .key = entry.key,
            .score = score,
            .timestamp = entry.timestamp,
        });
    }

    // Sort descending by score
    std.sort.heap(Candidate, heap.items, {}, struct {
        fn greaterThan(_: void, a: Candidate, b: Candidate) bool {
            return a.score > b.score;
        }
    }.greaterThan);

    // Trim to top_k
    const result_count = @min(heap.items.len, top_k);
    const results = heap.items[0..result_count];

    // ── Build JSON response ──────────────────────────────────────
    var json: std.ArrayListUnmanaged(u8) = .{};
    try json.append(ctx.allocator, '[');

    for (results, 0..) |r, idx| {
        if (idx > 0) try json.append(ctx.allocator, ',');

        try json.appendSlice(ctx.allocator, "{\"k\":\"");
        try appendJsonEscaped(&json, ctx.allocator, r.key);
        try json.appendSlice(ctx.allocator, "\",\"s\":");

        // Score with 6 decimal places
        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "{d:.6}", .{r.score}) catch "0";
        try json.appendSlice(ctx.allocator, score_str);

        try json.appendSlice(ctx.allocator, ",\"ts\":");
        var ts_buf: [20]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{r.timestamp}) catch "0";
        try json.appendSlice(ctx.allocator, ts_str);

        try json.append(ctx.allocator, '}');
    }

    try json.append(ctx.allocator, ']');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

/// Escape a string for safe JSON embedding.
fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try list.appendSlice(alloc, "\\u00");
                    const hex = "0123456789abcdef";
                    try list.append(alloc, hex[c >> 4]);
                    try list.append(alloc, hex[c & 0x0f]);
                } else {
                    try list.append(alloc, c);
                }
            },
        }
    }
}
