//! Built-in VSEARCH procedure — two-stage vector similarity search
//!
//! Stage 1 (coarse): Hamming rank against pre-computed binary-quantized (BQ)
//! hashes at `bq:<namespace>*`. Keeps the top-M = K × oversample candidates.
//! Stage 2 (refine): `getCopy` each candidate's full vector, recompute exact
//! cosine/dot/l2, return top-K.
//!
//! The Hamming path is ~16–29× faster than full cosine on typical embedding
//! dimensions (see src/vector/bench.zig), so 2-stage with 10× oversample is
//! roughly an order of magnitude faster than brute-force while maintaining
//! >95% recall on natural embedding distributions.
//!
//! EXEC vsearch <query_key> <top_k> [<namespace>] [<metric>] [<decay>] [<mode>]
//!
//! - query_key:  key holding the query vector (raw f32 bytes)
//! - top_k:      max results to return (1–100)
//! - namespace:  key prefix to search (default: "vec:")
//! - metric:     "cosine" (default), "dot", "l2"
//! - decay:      temporal decay factor (0.0 = no decay)
//! - mode:       "auto" (default — BQ prefilter if hashes exist, else
//!               brute-force) or "exact" (always brute-force)
//!
//! Returns JSON array sorted by descending score:
//!   [{"k":"vec:ns:id","s":0.95,"ts":1709...}, ...]
//!
//! Auto mode limitation: vectors inserted bypassing `vinsert` (i.e. a raw
//! SET with no accompanying `bq:` hash) are invisible to stage 1. Pass
//! `mode=exact` to force a brute-force scan in mixed-data namespaces.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");
const topk_mod = @import("../vector/topk.zig");
const hnsw_mod = @import("../vector/hnsw.zig");
const Store = @import("../storage/store.zig").Store;

const MAX_TOP_K: usize = 100;
const DEFAULT_NAMESPACE: []const u8 = "vec:";
const BQ_PREFIX: []const u8 = "bq:";
const STAGE1_OVERSAMPLE: usize = 10;
/// HNSW ef (beam width) factor relative to M (= top_k × STAGE1_OVERSAMPLE).
/// HNSW recall tracks ef closely; we reuse the same oversample budget so
/// the stage-1→stage-2 shape stays consistent across dispatch paths.
const HNSW_EF_SEARCH_FACTOR: usize = 1;
const DECAY_TIME_CONSTANT_HOURS: f32 = 168.0; // ~1 week time constant

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

const Mode = enum {
    auto, // BQ prefilter if available, else brute-force
    exact, // brute-force only

    fn fromStr(s: []const u8) Mode {
        if (std.mem.eql(u8, s, "exact")) return .exact;
        return .auto;
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

// ╔═══════════════════════════════════════════════════╗
// ║  Shared helpers                                    ║
// ╚═══════════════════════════════════════════════════╝

inline fn applyDecay(raw_sim: f32, timestamp: u64, decay: f32, now_ms: u64) f32 {
    if (decay <= 0.0) return raw_sim;
    const age_ms = if (now_ms > timestamp) now_ms - timestamp else 0;
    const age_hours: f32 = @as(f32, @floatFromInt(age_ms)) / 3_600_000.0;
    const recency = @exp(-age_hours / DECAY_TIME_CONSTANT_HOURS);
    return (1.0 - decay) * raw_sim + decay * recency;
}

inline fn computeExactSim(metric: Metric, q: []align(1) const f32, v: []align(1) const f32) f32 {
    return switch (metric) {
        .cosine => distance.cosine(q, v),
        .dot => distance.dot(q, v),
        .l2 => blk: {
            // Invert L2 distance so higher = more similar (for ranking).
            const d = distance.l2Squared(q, v);
            break :blk 1.0 / (1.0 + d);
        },
    };
}

// ╔═══════════════════════════════════════════════════╗
// ║  Stage 1 — BQ Hamming scan                         ║
// ╚═══════════════════════════════════════════════════╝

const BQScanCtx = struct {
    query_bq: []const u8,
    query_key: []const u8,
    decay: f32,
    now_ms: u64,
    heap: *TopKCandidate,
    allocator: std.mem.Allocator,
    oom: bool,
    saw_any: usize,
};

fn onBQMatch(
    raw_ctx: *anyopaque,
    bq_key: []const u8,
    bq_value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = is_worm;
    const sc: *BQScanCtx = @ptrCast(@alignCast(raw_ctx));
    sc.saw_any += 1;

    // Derive the vec key by stripping the 3-byte "bq:" prefix.
    if (bq_key.len <= BQ_PREFIX.len) return .cont;
    const vec_key = bq_key[BQ_PREFIX.len..];

    if (std.mem.eql(u8, vec_key, sc.query_key)) return .cont;

    // Different-dim vectors produce different-sized BQ hashes — skip.
    if (bq_value.len != sc.query_bq.len) return .cont;

    const ham_dist = distance.hamming(sc.query_bq, bq_value);
    const total_bits: f32 = @floatFromInt(bq_value.len * 8);
    const sim = 1.0 - @as(f32, @floatFromInt(ham_dist)) / total_bits;
    const score = applyDecay(sim, timestamp, sc.decay, sc.now_ms);

    if (score <= sc.heap.thresholdScore()) return .cont;

    const key_copy = sc.allocator.dupe(u8, vec_key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.heap.push(.{ .key = key_copy, .score = score, .timestamp = timestamp });
    return .cont;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Exact (brute-force) scan                          ║
// ╚═══════════════════════════════════════════════════╝

const ExactScanCtx = struct {
    query_key: []const u8,
    query_vec: []align(1) const f32,
    metric: Metric,
    decay: f32,
    now_ms: u64,
    heap: *TopKCandidate,
    allocator: std.mem.Allocator,
    oom: bool,
};

fn onExactMatch(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = is_worm;
    const sc: *ExactScanCtx = @ptrCast(@alignCast(raw_ctx));

    if (std.mem.eql(u8, key, sc.query_key)) return .cont;

    const vec = distance.bytesToF32(value) orelse return .cont;
    if (vec.len != sc.query_vec.len) return .cont;

    const raw_sim = computeExactSim(sc.metric, sc.query_vec, vec);
    const score = applyDecay(raw_sim, timestamp, sc.decay, sc.now_ms);

    if (score <= sc.heap.thresholdScore()) return .cont;

    const key_copy = sc.allocator.dupe(u8, key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.heap.push(.{ .key = key_copy, .score = score, .timestamp = timestamp });
    return .cont;
}

// ╔═══════════════════════════════════════════════════╗
// ║  HNSW dispatch                                     ║
// ╚═══════════════════════════════════════════════════╝

const IndexModule = @import("../vector/index.zig");

/// Stage 1 via HNSW + stage 2 exact refine. Returns true if the heap was
/// populated from HNSW; false if the index is empty (caller falls back to
/// BQ or brute-force).
///
/// Holds `ns_idx.lock` in shared mode only while reading the stage-1
/// candidate set and duping keys — then releases before `ctx.getCopy`
/// calls, which lock shards. Short critical section, no lock interleaving
/// with store shards.
fn runHnswDispatch(
    ctx: *Ctx,
    ns_idx: *IndexModule.NamespaceIndex,
    query_vec: []align(1) const f32,
    top_k: usize,
    metric: Metric,
    decay: f32,
    now_ms: u64,
    heap: *TopKCandidate,
) !bool {
    const stage1_size = top_k * STAGE1_OVERSAMPLE;

    // Scratch buffers for the HNSW call.
    const raw_buf = try ctx.allocator.alloc(IndexModule.IndexSearchResult, stage1_size);
    const hnsw_scratch = try ctx.allocator.alloc(hnsw_mod.SearchResult, stage1_size);
    const ef = stage1_size * HNSW_EF_SEARCH_FACTOR;

    const n_stage1 = blk: {
        ns_idx.lock.lockShared();
        defer ns_idx.lock.unlockShared();
        if (ns_idx.len() == 0) break :blk @as(usize, 0);
        break :blk try ns_idx.searchLocked(query_vec, stage1_size, ef, raw_buf, hnsw_scratch);
    };

    if (n_stage1 == 0) return false;

    // Dupe keys out of the index before touching the store — the borrowed
    // key slices are only valid under the read-lock, and we released it.
    const stage1_keys = try ctx.allocator.alloc([]u8, n_stage1);
    const stage1_ts = try ctx.allocator.alloc(u64, n_stage1);
    {
        ns_idx.lock.lockShared();
        defer ns_idx.lock.unlockShared();
        // n_stage1 <= ns_idx.len() at entry; the only mutation that can have
        // happened in the gap is an insert, which only appends — existing
        // indices remain valid.
        for (raw_buf[0..n_stage1], 0..) |r, i| {
            stage1_keys[i] = try ctx.allocator.dupe(u8, r.key);
            stage1_ts[i] = r.timestamp;
        }
    }

    // Stage 2: exact refine (no index lock held).
    for (0..n_stage1) |i| {
        const vec_bytes = (try ctx.getCopy(stage1_keys[i])) orelse continue;
        const vec = distance.bytesToF32(vec_bytes) orelse continue;
        if (vec.len != query_vec.len) continue;

        const raw_sim = computeExactSim(metric, query_vec, vec);
        const score = applyDecay(raw_sim, stage1_ts[i], decay, now_ms);

        heap.push(.{ .key = stage1_keys[i], .score = score, .timestamp = stage1_ts[i] });
    }

    return true;
}

// ╔═══════════════════════════════════════════════════╗
// ║  JSON emission                                     ║
// ╚═══════════════════════════════════════════════════╝

fn emitJson(ctx: *Ctx, results: []const Candidate) !Ctx.Result {
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

// ╔═══════════════════════════════════════════════════╗
// ║  Entry point                                       ║
// ╚═══════════════════════════════════════════════════╝

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // ── Parse args ───────────────────────────────────────────────
    const query_key = ctx.arg(0) orelse
        return ctx.err("vsearch requires at least 2 args: <query_key> <top_k> [namespace] [metric] [decay] [mode]");

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

    const mode = if (ctx.arg(5)) |m| Mode.fromStr(m) else Mode.auto;

    // ── Load query vector (locks internally, safe before scans) ──
    const query_bytes = (try ctx.getCopy(query_key)) orelse
        return ctx.err("vsearch: query key not found");

    const query_vec = distance.bytesToF32(query_bytes) orelse
        return ctx.err("vsearch: query value is not a valid f32 vector (byte length must be multiple of 4)");

    // ── Allocate final top-K heap (shared by both paths) ─────────
    const final_buf = try ctx.allocator.alloc(Candidate, top_k);
    var final_heap = TopKCandidate.init(final_buf);

    const now_ms = ctx.timestamp();

    // ── Stage 1A: HNSW (auto mode, namespace has registered index) ──
    // Preferred path when available — ~5-50× faster than BQ at large N.
    // Stage-1 ranking uses cosine distance regardless of the user's metric;
    // stage-2 refine re-ranks with the requested metric. The oversample
    // matches the BQ path so the refine phase sees a consistent candidate
    // budget across dispatch strategies.
    if (mode == .auto) {
        if (ctx.vector_registry) |reg| {
            if (reg.get(namespace)) |ns_idx| {
                if (try runHnswDispatch(
                    ctx,
                    ns_idx,
                    query_vec,
                    top_k,
                    metric,
                    decay,
                    now_ms,
                    &final_heap,
                )) {
                    return emitJson(ctx, final_heap.sortedDesc());
                }
                // runHnswDispatch returned false → index is empty; fall
                // through to BQ / brute-force paths.
            }
        }
    }

    // ── Stage 1B: BQ prefilter (auto mode only) ──────────────────
    if (mode == .auto) {
        const query_bq_size = distance.binaryQuantizedSize(query_vec.len);
        const query_bq = try ctx.allocator.alloc(u8, query_bq_size);
        distance.binaryQuantize(query_vec, query_bq);

        const stage1_size = top_k * STAGE1_OVERSAMPLE;
        const stage1_buf = try ctx.allocator.alloc(Candidate, stage1_size);
        var stage1_heap = TopKCandidate.init(stage1_buf);

        // Construct bq prefix in the arena so it outlives the scan call.
        const bq_prefix = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ BQ_PREFIX, namespace });

        var bq_sc = BQScanCtx{
            .query_bq = query_bq,
            .query_key = query_key,
            .decay = decay,
            .now_ms = now_ms,
            .heap = &stage1_heap,
            .allocator = ctx.allocator,
            .oom = false,
            .saw_any = 0,
        };
        ctx.scanCallback(bq_prefix, @ptrCast(&bq_sc), onBQMatch);
        if (bq_sc.oom) return ctx.err("vsearch: out of memory during BQ stage");

        if (bq_sc.saw_any > 0) {
            // ── Stage 2: exact refine on top-M ───────────────────
            const candidates = stage1_heap.sortedDesc();
            for (candidates) |cand| {
                const vec_bytes = (try ctx.getCopy(cand.key)) orelse continue;
                const vec = distance.bytesToF32(vec_bytes) orelse continue;
                if (vec.len != query_vec.len) continue;

                const raw_sim = computeExactSim(metric, query_vec, vec);
                const score = applyDecay(raw_sim, cand.timestamp, decay, now_ms);

                // `cand.key` is already arena-owned — reuse directly.
                final_heap.push(.{ .key = cand.key, .score = score, .timestamp = cand.timestamp });
            }

            return emitJson(ctx, final_heap.sortedDesc());
        }
        // Fall through: no BQ hashes exist in this namespace → brute-force.
    }

    // ── Brute-force path (mode=exact or auto-fallback) ───────────
    var exact_sc = ExactScanCtx{
        .query_key = query_key,
        .query_vec = query_vec,
        .metric = metric,
        .decay = decay,
        .now_ms = now_ms,
        .heap = &final_heap,
        .allocator = ctx.allocator,
        .oom = false,
    };
    ctx.scanCallback(namespace, @ptrCast(&exact_sc), onExactMatch);
    if (exact_sc.oom) return ctx.err("vsearch: out of memory during exact scan");

    return emitJson(ctx, final_heap.sortedDesc());
}
