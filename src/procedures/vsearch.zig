//! Built-in VSEARCH procedure — brute-force vector similarity search
//!
//! Scans all vectors under a namespace prefix via a callback iterator (no
//! arena copies), ranks candidates through a bounded top-K min-heap, and
//! returns the K highest-scoring entries as JSON.
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
//! The score combines semantic similarity with optional temporal recency.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");
const topk_mod = @import("../vector/topk.zig");
const Store = @import("../storage/store.zig").Store;

const MAX_TOP_K: usize = 100;
const DEFAULT_NAMESPACE: []const u8 = "vec:";

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

const Candidate = struct {
    key: []const u8, // arena-owned copy
    score: f32,
    timestamp: u64,
};

fn candidateScore(c: Candidate) f32 {
    return c.score;
}

const TopKCandidate = topk_mod.TopK(Candidate, candidateScore);

/// State passed through the scan callback. The callback is a top-level
/// function with no closure — it unpacks the context from *anyopaque.
const ScanCtx = struct {
    query_key: []const u8,
    query_vec: []align(1) const f32,
    metric: Metric,
    decay: f32,
    now_ms: u64,
    heap: *TopKCandidate,
    allocator: std.mem.Allocator,
    oom: bool,
};

fn onMatch(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = is_worm;
    const sc: *ScanCtx = @ptrCast(@alignCast(raw_ctx));

    // Skip the query key itself.
    if (std.mem.eql(u8, key, sc.query_key)) return .cont;

    // Parse vector; skip non-vector or dim-mismatched values.
    const vec = distance.bytesToF32(value) orelse return .cont;
    if (vec.len != sc.query_vec.len) return .cont;

    const raw_sim = switch (sc.metric) {
        .cosine => distance.cosine(sc.query_vec, vec),
        .dot => distance.dot(sc.query_vec, vec),
        .l2 => blk: {
            // Invert so higher = more similar (for ranking).
            const d = distance.l2Squared(sc.query_vec, vec);
            break :blk 1.0 / (1.0 + d);
        },
    };

    const score = if (sc.decay > 0.0) blk: {
        const age_ms = if (sc.now_ms > timestamp) sc.now_ms - timestamp else 0;
        const age_hours: f32 = @as(f32, @floatFromInt(age_ms)) / 3_600_000.0;
        // Exponential decay, time constant = 168h (half-life ≈ 116h).
        const recency = @exp(-age_hours / 168.0);
        break :blk (1.0 - sc.decay) * raw_sim + sc.decay * recency;
    } else raw_sim;

    // Admission check before duping the key — avoids O(N) arena allocs
    // when most candidates won't make the heap.
    if (score <= sc.heap.thresholdScore()) return .cont;

    const key_copy = sc.allocator.dupe(u8, key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.heap.push(.{ .key = key_copy, .score = score, .timestamp = timestamp });
    return .cont;
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // ── Parse arguments ──────────────────────────────────────────
    const query_key = ctx.arg(0) orelse
        return ctx.err("vsearch requires at least 2 args: <query_key> <top_k> [namespace] [metric] [decay]");

    const top_k_raw = ctx.argInt(usize, 1) orelse
        return ctx.err("vsearch: top_k must be a positive integer");

    const top_k = @min(if (top_k_raw == 0) @as(usize, 10) else top_k_raw, MAX_TOP_K);

    const namespace = ctx.arg(2) orelse DEFAULT_NAMESPACE;

    const metric = if (ctx.arg(3)) |m| Metric.fromStr(m) else Metric.cosine;

    var decay: f32 = 0.0;
    if (ctx.arg(4)) |d| {
        decay = std.fmt.parseFloat(f32, d) catch 0.0;
        decay = @min(@max(decay, 0.0), 1.0);
    }

    // ── Load query vector into arena (locks internally) ──────────
    // Must copy before scan — scanPrefixCallback locks every shard and
    // would deadlock against a held query-shard lock.
    const query_bytes = (try ctx.getCopy(query_key)) orelse
        return ctx.err("vsearch: query key not found");

    const query_vec = distance.bytesToF32(query_bytes) orelse
        return ctx.err("vsearch: query value is not a valid f32 vector (byte length must be multiple of 4)");

    // ── Bounded top-K heap ───────────────────────────────────────
    const heap_buf = try ctx.allocator.alloc(Candidate, top_k);
    var heap = TopKCandidate.init(heap_buf);

    // ── Callback scan (borrowed slices, zero bulk copies) ────────
    var sc = ScanCtx{
        .query_key = query_key,
        .query_vec = query_vec,
        .metric = metric,
        .decay = decay,
        .now_ms = ctx.timestamp(),
        .heap = &heap,
        .allocator = ctx.allocator,
        .oom = false,
    };
    ctx.scanCallback(namespace, @ptrCast(&sc), onMatch);
    if (sc.oom) return ctx.err("vsearch: out of memory during scan");

    const results = heap.sortedDesc();

    // ── JSON response ────────────────────────────────────────────
    var json: std.ArrayListUnmanaged(u8) = .{};
    try json.append(ctx.allocator, '[');
    for (results, 0..) |r, idx| {
        if (idx > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"k\":\"");
        try appendJsonEscaped(&json, ctx.allocator, r.key);
        try json.appendSlice(ctx.allocator, "\",\"s\":");

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
