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
//! EXEC vsearch <query_key> <top_k> [<namespace>] [<metric>] [<decay>] [<mode>] [<decay_tau_hours>] [<ef>]
//!
//! - query_key:  key holding the query vector (raw f32 bytes)
//! - top_k:      max results to return (1–100)
//! - namespace:  key prefix to search (default: "vec:")
//! - metric:     "cosine" (default), "dot", "l2"
//! - decay:      temporal decay factor (0.0 = no decay)
//! - mode:       "auto" (default — HNSW if index exists, else BQ prefilter,
//!               else brute-force) or "exact" (always brute-force)
//! - decay_tau_hours: temporal decay time constant (default: 168)
//! - ef:         optional HNSW search beam width (default: 128; accepts "<N>" or "ef=<N>")
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
const rabitq = @import("../vector/rabitq.zig");
const topk_mod = @import("../vector/topk.zig");
const hnsw_mod = @import("../vector/hnsw.zig");
const metric_mod = @import("../vector/metric.zig");
const Store = @import("../storage/store.zig").Store;

pub const Metric = metric_mod.Metric;

pub const MAX_TOP_K: usize = 100;
pub const DEFAULT_NAMESPACE: []const u8 = "vec:";
const BQ_PREFIX: []const u8 = "bq:";
const STAGE1_OVERSAMPLE: usize = 20;
/// Default HNSW search beam width (`ef`) when no explicit `ef` argument is passed.
pub const DEFAULT_HNSW_EF: usize = 128;
pub const DEFAULT_DECAY_TAU_HOURS: f32 = 168.0; // ~1 week time constant

pub const Mode = enum {
    /// HNSW graph search if an index exists, else RaBitQ/BQ prefilter,
    /// else brute-force. The "normal" path. The BQ fallback always
    /// reranks the top-M candidates with full-precision distances.
    auto,
    /// Full-precision brute-force scan over the namespace. No BQ, no HNSW.
    exact,
    /// Force the quantized prefilter path. When the namespace has
    /// RaBitQ params installed and metric=l2, scores candidates via
    /// the unbiased estimator with NO rerank — returns the top-K
    /// directly from estimated distances. Otherwise falls back to
    /// Hamming + exact rerank.
    bq,
    /// Quantized prefilter followed by full-precision rerank of the
    /// top-M candidates. Same recall as `auto` when BQ is the chosen
    /// dispatch; exposed as an explicit mode so benchmarks can A/B
    /// pure-estimator vs estimator-plus-rerank.
    bq_rerank,

    pub fn fromStr(s: []const u8) Mode {
        if (std.mem.eql(u8, s, "exact")) return .exact;
        if (std.mem.eql(u8, s, "bq")) return .bq;
        if (std.mem.eql(u8, s, "bq_rerank")) return .bq_rerank;
        return .auto;
    }
};

pub const Candidate = struct {
    key: []const u8, // arena-owned copy
    score: f32,
    timestamp: u64,
};

fn candidateScore(c: Candidate) f32 {
    return c.score;
}

pub const TopKCandidate = topk_mod.TopK(Candidate, candidateScore);

/// Search parameters shared by `execute` (query-by-key), `executeLocalRaw`
/// (query passed inline over replication) and `vsearch_cluster` (coordinator).
pub const SearchParams = struct {
    top_k: usize,
    namespace: []const u8,
    metric: Metric,
    decay: f32,
    mode: Mode,
    decay_tau_hours: f32,
    ef: ?usize = null,
};

// ╔═══════════════════════════════════════════════════╗
// ║  Shared helpers                                    ║
// ╚═══════════════════════════════════════════════════╝

pub fn parseDecayTauHours(raw: []const u8) ?f32 {
    const tau = std.fmt.parseFloat(f32, raw) catch return null;
    if (!std.math.isFinite(tau) or tau <= 0.0) return null;
    return tau;
}

pub fn parseEfArg(raw: []const u8) ?usize {
    const trimmed = if (std.mem.startsWith(u8, raw, "ef=")) raw["ef=".len..] else raw;
    const val = std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (val == 0) return null;
    return val;
}

inline fn applyDecay(raw_sim: f32, timestamp: u64, decay: f32, now_ms: u64, decay_tau_hours: f32) f32 {
    if (decay <= 0.0) return raw_sim;
    const age_ms = if (now_ms > timestamp) now_ms - timestamp else 0;
    const age_hours: f32 = @as(f32, @floatFromInt(age_ms)) / 3_600_000.0;
    const recency = @exp(-age_hours / decay_tau_hours);
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

const IndexModule = @import("../vector/index.zig");

const STACK_QUERY_BYTES: usize = 6144; // 1536 × f32 (covers OpenAI embeddings on stack)
const STACK_DIM_CAP: usize = 1536;
const STACK_CODE_BYTES: usize = 256; // up to 2048-dim BQ code

inline fn precomputeInvQueryNorm(metric: Metric, q: []align(1) const f32) f32 {
    if (metric != .cosine) return 0.0;
    const qn = distance.l2Norm(q);
    if (qn > 0.0) {
        const inv = 1.0 / qn;
        return if (std.math.isFinite(inv)) inv else 0.0;
    }
    return 0.0;
}

inline fn computeExactSimWithNorm(
    metric: Metric,
    q: []align(1) const f32,
    inv_q_norm: f32,
    v: []align(1) const f32,
) f32 {
    return switch (metric) {
        .cosine => distance.cosineWithQueryNorm(q, inv_q_norm, v),
        .dot => distance.dot(q, v),
        .l2 => 1.0 / (1.0 + distance.l2Squared(q, v)),
    };
}

inline fn hnswDistToSim(metric: Metric, dist: f32) f32 {
    return switch (metric) {
        .cosine => 1.0 - dist,
        .dot => -dist,
        .l2 => 1.0 / (1.0 + dist),
    };
}

fn readKeyInto(
    ctx: *Ctx,
    key: []const u8,
    stack_buf: []align(16) u8,
    heap_out: *?[]align(16) u8,
) !?[]const u8 {
    heap_out.* = null;
    switch (ctx.getInto(key, stack_buf)) {
        .hit => |slice| return slice,
        .miss => return null,
        .too_small => |needed| {
            const b = try ctx.allocator.alignedAlloc(u8, .@"16", needed);
            errdefer ctx.allocator.free(b);
            switch (ctx.getInto(key, b)) {
                .hit => |slice| {
                    heap_out.* = b;
                    return slice;
                },
                .miss => {
                    ctx.allocator.free(b);
                    return null;
                },
                .too_small => {
                    ctx.allocator.free(b);
                    const exact = (try ctx.getCopy(key)) orelse return null;
                    // Re-copy into 16B-aligned buffer if needed for caller consistency
                    const b2 = try ctx.allocator.alignedAlloc(u8, .@"16", exact.len);
                    @memcpy(b2, exact);
                    ctx.allocator.free(exact);
                    heap_out.* = b2;
                    return b2;
                },
            }
        },
    }
}

fn buildBqPrefix(
    allocator: std.mem.Allocator,
    namespace: []const u8,
    stack_buf: []u8,
    heap_out: *?[]u8,
) ![]const u8 {
    heap_out.* = null;
    const total = BQ_PREFIX.len + namespace.len;
    const dst: []u8 = if (total <= stack_buf.len)
        stack_buf[0..total]
    else blk: {
        const b = try allocator.alloc(u8, total);
        heap_out.* = b;
        break :blk b;
    };
    @memcpy(dst[0..BQ_PREFIX.len], BQ_PREFIX);
    @memcpy(dst[BQ_PREFIX.len..total], namespace);
    return dst;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Stage 1 — BQ Hamming scan (KV fallback)           ║
// ╚═══════════════════════════════════════════════════╝

const BQScanCtx = struct {
    query_bq: []const u8,
    query_key: []const u8,
    decay: f32,
    decay_tau_hours: f32,
    now_ms: u64,
    heap: *TopKCandidate,
    allocator: std.mem.Allocator,
    oom: bool,
    saw_any: usize,
    code_bytes: usize,
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

    if (bq_value.len != sc.code_bytes) return .cont;

    if (bq_key.len <= BQ_PREFIX.len) return .cont;
    const vec_key = bq_key[BQ_PREFIX.len..];

    if (sc.query_key.len != 0 and std.mem.eql(u8, vec_key, sc.query_key)) return .cont;

    sc.saw_any += 1;

    const ham_dist = distance.hamming(sc.query_bq, bq_value);
    const total_bits: f32 = @floatFromInt(sc.code_bytes * 8);
    const sim = 1.0 - @as(f32, @floatFromInt(ham_dist)) / total_bits;
    const score = applyDecay(sim, timestamp, sc.decay, sc.now_ms, sc.decay_tau_hours);

    if (!(score > sc.heap.thresholdScore())) return .cont;

    const key_copy = sc.allocator.dupe(u8, vec_key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.heap.push(.{ .key = key_copy, .score = score, .timestamp = timestamp });
    return .cont;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Stage 1 — RaBitQ 4-bit estimator scan (KV fallback)║
// ╚═══════════════════════════════════════════════════╝

const RabitqScanCtx = struct {
    pq: rabitq.PreparedQuery,
    query_key: []const u8,
    dim: usize,
    decay: f32,
    decay_tau_hours: f32,
    now_ms: u64,
    heap: *TopKCandidate,
    allocator: std.mem.Allocator,
    oom: bool,
    saw_any: usize,
    cosine_score: bool,
};

fn onRabitqMatch(
    raw_ctx: *anyopaque,
    bq_key: []const u8,
    bq_value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = is_worm;
    const sc: *RabitqScanCtx = @ptrCast(@alignCast(raw_ctx));

    if (bq_key.len <= BQ_PREFIX.len) return .cont;
    const vec_key = bq_key[BQ_PREFIX.len..];
    if (sc.query_key.len != 0 and std.mem.eql(u8, vec_key, sc.query_key)) return .cont;

    // Only process RaBitQ-format entries; skip legacy 16-byte codes silently.
    const enc = rabitq.parse(bq_value, sc.dim) orelse return .cont;
    sc.saw_any += 1;

    const d2_est = rabitq.estimateL2Sq4Bit(&sc.pq, enc.code, enc.l2_norm, enc.corr);
    const d2_clamped: f32 = if (d2_est < 0.0) 0.0 else d2_est;

    const raw_sim: f32 = if (sc.cosine_score) blk: {
        const cos_est = 1.0 - d2_clamped * 0.5;
        const cos_clamped: f32 = if (cos_est > 1.0) 1.0 else if (cos_est < -1.0) -1.0 else cos_est;
        break :blk (cos_clamped + 1.0) * 0.5;
    } else 1.0 / (1.0 + d2_clamped);

    const score = applyDecay(raw_sim, timestamp, sc.decay, sc.now_ms, sc.decay_tau_hours);

    if (!(score > sc.heap.thresholdScore())) return .cont;

    const key_copy = sc.allocator.dupe(u8, vec_key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.heap.push(.{ .key = key_copy, .score = score, .timestamp = timestamp });
    return .cont;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Exact (brute-force) scan (KV fallback)            ║
// ╚═══════════════════════════════════════════════════╝

const ExactScanCtx = struct {
    query_key: []const u8,
    query_vec: []align(1) const f32,
    inv_q_norm: f32,
    metric: Metric,
    decay: f32,
    decay_tau_hours: f32,
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

    if (sc.query_key.len != 0 and std.mem.eql(u8, key, sc.query_key)) return .cont;

    const vec = distance.bytesToF32(value) orelse return .cont;
    if (vec.len != sc.query_vec.len) return .cont;

    const raw_sim = computeExactSimWithNorm(sc.metric, sc.query_vec, sc.inv_q_norm, vec);
    const score = applyDecay(raw_sim, timestamp, sc.decay, sc.now_ms, sc.decay_tau_hours);

    if (!(score > sc.heap.thresholdScore())) return .cont;

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

fn computeEf(k_req: usize, top_k: usize, ef_override: ?usize) usize {
    return if (ef_override) |custom_ef|
        @max(k_req, custom_ef)
    else
        @max(k_req, @max(top_k * 2, DEFAULT_HNSW_EF));
}

fn runHnswDispatch(
    ctx: *Ctx,
    query_key: []const u8,
    ns_idx: *IndexModule.NamespaceIndex,
    query_vec: []align(1) const f32,
    top_k: usize,
    metric: Metric,
    decay: f32,
    decay_tau_hours: f32,
    ef_override: ?usize,
    now_ms: u64,
    store_synced: bool,
    heap: *TopKCandidate,
) !bool {
    const k_req = if (decay > 0.0)
        top_k * STAGE1_OVERSAMPLE
    else if (store_synced)
        top_k
    else
        top_k + 8;
    const ef = computeEf(k_req, top_k, ef_override);

    var raw_stack: [128]IndexModule.IndexSearchResult = undefined;
    var raw_heap: ?[]IndexModule.IndexSearchResult = null;
    defer if (raw_heap) |b| ctx.allocator.free(b);
    const raw_buf: []IndexModule.IndexSearchResult = if (k_req <= raw_stack.len)
        raw_stack[0..k_req]
    else blk: {
        const b = try ctx.allocator.alloc(IndexModule.IndexSearchResult, k_req);
        raw_heap = b;
        break :blk b;
    };

    var scratch_stack: [128]hnsw_mod.SearchResult = undefined;
    var scratch_heap: ?[]hnsw_mod.SearchResult = null;
    defer if (scratch_heap) |b| ctx.allocator.free(b);
    const hnsw_scratch: []hnsw_mod.SearchResult = if (k_req <= scratch_stack.len)
        scratch_stack[0..k_req]
    else blk: {
        const b = try ctx.allocator.alloc(hnsw_mod.SearchResult, k_req);
        scratch_heap = b;
        break :blk b;
    };

    var cands_stack: [128]Candidate = undefined;
    var cands_heap: ?[]Candidate = null;
    defer if (cands_heap) |b| ctx.allocator.free(b);
    const cands: []Candidate = if (k_req <= cands_stack.len)
        cands_stack[0..k_req]
    else blk: {
        const b = try ctx.allocator.alloc(Candidate, k_req);
        cands_heap = b;
        break :blk b;
    };

    var n_cands: usize = 0;
    {
        ns_idx.lock.lockShared();
        defer ns_idx.lock.unlockShared();

        if (ns_idx.len() == 0) return false;
        const exclude_id: ?u32 = if (query_key.len != 0) ns_idx.nodeIdFor(query_key) else null;
        const n_found = try ns_idx.searchLockedWithExclude(query_vec, k_req, ef, exclude_id, raw_buf, hnsw_scratch);
        if (n_found == 0) return false;

        for (raw_buf[0..n_found]) |r| {
            if (query_key.len != 0 and std.mem.eql(u8, r.key, query_key)) continue;

            const raw_sim = hnswDistToSim(metric, r.dist);
            const score = applyDecay(raw_sim, r.timestamp, decay, now_ms, decay_tau_hours);
            cands[n_cands] = .{
                .key = try ctx.allocator.dupe(u8, r.key),
                .score = score,
                .timestamp = r.timestamp,
            };
            n_cands += 1;
        }
    }

    // Index lock is released. When `store_synced` (store.vector_registry == reg),
    // every DEL/SET already tombstoned `ns_idx` synchronously, so skip 18× store.exists()!
    if (store_synced) {
        for (cands[0..n_cands]) |cand| {
            if (!(cand.score > heap.thresholdScore())) continue;
            heap.push(cand);
        }
    } else {
        for (cands[0..n_cands]) |cand| {
            if (!(cand.score > heap.thresholdScore())) continue;
            if (!ctx.store.exists(cand.key) and ctx.store.sstHit(cand.key) == null) continue;
            heap.push(cand);
        }
    }

    return true;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Fast formatting & JSON emission                   ║
// ╚═══════════════════════════════════════════════════╝

/// Fast base-10 formatter for `u64` timestamps and counters.
pub fn appendU64Dec(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, val: u64) !void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = val;
    if (v == 0) {
        try list.append(alloc, '0');
        return;
    }
    while (v > 0) {
        i -= 1;
        buf[i] = @as(u8, @intCast(v % 10)) + '0';
        v /= 10;
    }
    try list.appendSlice(alloc, buf[i..]);
}

/// Fast fixed-point `{d:.6}` formatter for finite scores with `|x| <= 1e6`;
/// falls back to `std.fmt.bufPrint` for extreme magnitudes or non-finite values.
pub fn appendScoreFixed6(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, val: f32) !void {
    if (!std.math.isFinite(val) or @abs(val) > 1_000_000.0) {
        var fbuf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&fbuf, "{d:.6}", .{val}) catch "0";
        try list.appendSlice(alloc, s);
        return;
    }

    const neg = val < 0.0;
    const scaled: u64 = @intFromFloat(@round(@abs(@as(f64, val)) * 1_000_000.0));
    const int_part: u64 = scaled / 1_000_000;
    const frac_part: u64 = scaled % 1_000_000;

    var buf: [32]u8 = undefined;
    var pos: usize = 0;
    if (neg and scaled != 0) {
        buf[pos] = '-';
        pos += 1;
    }

    // Integer digits.
    if (int_part == 0) {
        buf[pos] = '0';
        pos += 1;
    } else {
        var tmp: [20]u8 = undefined;
        var ti: usize = tmp.len;
        var iv = int_part;
        while (iv > 0) {
            ti -= 1;
            tmp[ti] = @as(u8, @intCast(iv % 10)) + '0';
            iv /= 10;
        }
        const int_len = tmp.len - ti;
        @memcpy(buf[pos..][0..int_len], tmp[ti..]);
        pos += int_len;
    }

    buf[pos] = '.';
    pos += 1;

    // 6 fractional digits (zero-padded).
    var fv = frac_part;
    var fi: usize = 6;
    while (fi > 0) {
        fi -= 1;
        buf[pos + fi] = @as(u8, @intCast(fv % 10)) + '0';
        fv /= 10;
    }
    pos += 6;

    try list.appendSlice(alloc, buf[0..pos]);
}

fn emitJson(ctx: *Ctx, results: []const Candidate) !Ctx.Result {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    var cap: usize = 2;
    for (results) |r| cap += r.key.len + 44;
    try json.ensureTotalCapacity(ctx.allocator, cap);

    try json.append(ctx.allocator, '[');
    for (results, 0..) |r, idx| {
        if (idx > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"k\":\"");
        try appendJsonEscaped(&json, ctx.allocator, r.key);
        try json.appendSlice(ctx.allocator, "\",\"s\":");
        try appendScoreFixed6(&json, ctx.allocator, r.score);
        try json.appendSlice(ctx.allocator, ",\"ts\":");
        try appendU64Dec(&json, ctx.allocator, r.timestamp);
        try json.append(ctx.allocator, '}');
    }
    try json.append(ctx.allocator, ']');
    return ctx.valueOwned(try json.toOwnedSlice(ctx.allocator));
}

fn emitJsonFromScored(ctx: *Ctx, results: []const IndexModule.IndexScoredResult) !Ctx.Result {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    var cap: usize = 2;
    for (results) |r| cap += r.key.len + 44;
    try json.ensureTotalCapacity(ctx.allocator, cap);

    try json.append(ctx.allocator, '[');
    for (results, 0..) |r, idx| {
        if (idx > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"k\":\"");
        try appendJsonEscaped(&json, ctx.allocator, r.key);
        try json.appendSlice(ctx.allocator, "\",\"s\":");
        try appendScoreFixed6(&json, ctx.allocator, r.score);
        try json.appendSlice(ctx.allocator, ",\"ts\":");
        try appendU64Dec(&json, ctx.allocator, r.timestamp);
        try json.append(ctx.allocator, '}');
    }
    try json.append(ctx.allocator, ']');
    return ctx.valueOwned(try json.toOwnedSlice(ctx.allocator));
}

fn emitJsonFromHnsw(ctx: *Ctx, results: []const IndexModule.IndexSearchResult, metric: Metric) !Ctx.Result {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    var cap: usize = 2;
    for (results) |r| cap += r.key.len + 44;
    try json.ensureTotalCapacity(ctx.allocator, cap);

    try json.append(ctx.allocator, '[');
    for (results, 0..) |r, idx| {
        if (idx > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"k\":\"");
        try appendJsonEscaped(&json, ctx.allocator, r.key);
        try json.appendSlice(ctx.allocator, "\",\"s\":");
        try appendScoreFixed6(&json, ctx.allocator, hnswDistToSim(metric, r.dist));
        try json.appendSlice(ctx.allocator, ",\"ts\":");
        try appendU64Dec(&json, ctx.allocator, r.timestamp);
        try json.append(ctx.allocator, '}');
    }
    try json.append(ctx.allocator, ']');
    return ctx.valueOwned(try json.toOwnedSlice(ctx.allocator));
}

/// Direct zero-key-dupe serving path when `store_synced` and `sst_count == 0`
/// and caller ALREADY holds `ns_idx.lock.lockShared()`. Returns `null` when
/// caller must fall back to `runSearch` (e.g. `decay > 0` on HNSW, `needs_kv_rerank`,
/// empty/incomplete index, or legacy/mixed KV corpus).
fn serveDirectLocked(
    ctx: *Ctx,
    ns_idx: *IndexModule.NamespaceIndex,
    query_vec: []align(1) const f32,
    exclude_id: ?u32,
    params: SearchParams,
    now_ms: u64,
) !?Ctx.Result {
    const top_k = params.top_k;
    const metric = params.metric;
    const decay = params.decay;
    const mode = params.mode;

    // 1. HNSW direct zero-copy path (auto mode, matching metric, no decay).
    if (mode == .auto and ns_idx.metric == metric and decay <= 0.0 and ns_idx.len() > 0) {
        if (ns_idx.dim == null or ns_idx.dim.? == query_vec.len) {
            const ef = computeEf(top_k, top_k, params.ef);
            var raw_stack: [MAX_TOP_K]IndexModule.IndexSearchResult = undefined;
            var scratch_stack: [MAX_TOP_K]hnsw_mod.SearchResult = undefined;
            const n_found = try ns_idx.searchLockedWithExclude(
                query_vec,
                top_k,
                ef,
                exclude_id,
                raw_stack[0..top_k],
                scratch_stack[0..top_k],
            );
            if (n_found > 0 or ns_idx.complete_with_store) {
                return try emitJsonFromHnsw(ctx, raw_stack[0..n_found], metric);
            }
        }
    }

    // 2. Quantized slab direct path (RaBitQ FastScan32 or Legacy BQ 4-way Hamming).
    if (mode == .auto or mode == .bq or mode == .bq_rerank) {
        // Only take slab in auto mode when HNSW wasn't eligible (metric mismatch / empty HNSW).
        const hnsw_would_run = (mode == .auto and ns_idx.metric == metric and ns_idx.len() > 0);
        if (!hnsw_would_run) {
            if (ns_idx.rabitq_params != null) {
                const rabitq_metric_ok = (metric == .cosine and ns_idx.metric == .cosine) or
                    (metric == .l2 and ns_idx.metric != .cosine);
                if (rabitq_metric_ok and ns_idx.canUseRabitqSlabLocked(query_vec.len)) {
                    const rerank = (mode != .bq);
                    if (!rerank or ns_idx.canRerankFromHnswLocked(metric)) {
                        var slab_out: [MAX_TOP_K]IndexModule.IndexScoredResult = undefined;
                        if (try ns_idx.searchRabitqLocked(
                            query_vec,
                            exclude_id,
                            top_k,
                            STAGE1_OVERSAMPLE,
                            metric,
                            decay,
                            now_ms,
                            params.decay_tau_hours,
                            rerank,
                            slab_out[0..top_k],
                            ctx.allocator,
                        )) |res| {
                            if (!res.needs_kv_rerank) {
                                return try emitJsonFromScored(ctx, slab_out[0..res.count]);
                            }
                        }
                    }
                } else if (!rabitq_metric_ok and ns_idx.canUseExactSlabLocked(query_vec.len, metric)) {
                    var slab_out: [MAX_TOP_K]IndexModule.IndexScoredResult = undefined;
                    const n_found = try ns_idx.searchExactLocked(
                        query_vec,
                        exclude_id,
                        top_k,
                        metric,
                        decay,
                        now_ms,
                        params.decay_tau_hours,
                        slab_out[0..top_k],
                        ctx.allocator,
                    );
                    return try emitJsonFromScored(ctx, slab_out[0..n_found]);
                }
            } else if (ns_idx.canUseBqSlabLocked(query_vec.len) and ns_idx.canRerankFromHnswLocked(metric)) {
                var slab_out: [MAX_TOP_K]IndexModule.IndexScoredResult = undefined;
                if (try ns_idx.searchBqLocked(
                    query_vec,
                    exclude_id,
                    top_k,
                    STAGE1_OVERSAMPLE,
                    metric,
                    decay,
                    now_ms,
                    params.decay_tau_hours,
                    true,
                    slab_out[0..top_k],
                    ctx.allocator,
                )) |res| {
                    if (!res.needs_kv_rerank) {
                        return try emitJsonFromScored(ctx, slab_out[0..res.count]);
                    }
                }
            }
        }
    }

    // 3. Exact contiguous f32 slab direct path.
    if (mode == .exact and ns_idx.canUseExactSlabLocked(query_vec.len, metric)) {
        var slab_out: [MAX_TOP_K]IndexModule.IndexScoredResult = undefined;
        const n_found = try ns_idx.searchExactLocked(
            query_vec,
            exclude_id,
            top_k,
            metric,
            decay,
            now_ms,
            params.decay_tau_hours,
            slab_out[0..top_k],
            ctx.allocator,
        );
        return try emitJsonFromScored(ctx, slab_out[0..n_found]);
    }

    return null;
}

pub fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 0x20) "" else null,
        };
        if (esc) |seq| {
            if (i > start) try list.appendSlice(alloc, s[start..i]);
            if (seq.len > 0) {
                try list.appendSlice(alloc, seq);
            } else {
                const hex = "0123456789abcdef";
                const u_esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try list.appendSlice(alloc, &u_esc);
            }
            start = i + 1;
        }
    }
    if (start < s.len) try list.appendSlice(alloc, s[start..]);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Entry point                                       ║
// ╚═══════════════════════════════════════════════════╝

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // ── Parse args ───────────────────────────────────────────────
    const query_key = ctx.arg(0) orelse
        return ctx.err("vsearch requires at least 2 args: <query_key> <top_k> [namespace] [metric] [decay] [mode] [decay_tau_hours] [ef]");

    const top_k_raw = ctx.argInt(usize, 1) orelse
        return ctx.err("vsearch: top_k must be a positive integer");

    const top_k = @min(if (top_k_raw == 0) @as(usize, 10) else top_k_raw, MAX_TOP_K);
    const namespace = ctx.arg(2) orelse DEFAULT_NAMESPACE;
    const metric: Metric = if (ctx.arg(3)) |m|
        Metric.fromStr(m) orelse Metric.cosine
    else
        Metric.cosine;

    var decay: f32 = 0.0;
    if (ctx.arg(4)) |d| {
        decay = std.fmt.parseFloat(f32, d) catch 0.0;
        decay = @min(@max(decay, 0.0), 1.0);
    }

    const mode = if (ctx.arg(5)) |m| Mode.fromStr(m) else Mode.auto;
    const decay_tau_hours = if (ctx.arg(6)) |raw|
        parseDecayTauHours(raw) orelse return ctx.err("vsearch: decay_tau_hours must be positive")
    else
        DEFAULT_DECAY_TAU_HOURS;

    const ef_override: ?usize = if (ctx.arg(7)) |raw_ef|
        parseEfArg(raw_ef) orelse return ctx.err("vsearch: ef must be a positive integer")
    else
        null;

    // ── Authorize: the query key is read, the namespace is scanned ──
    try ctx.requireRead(query_key);
    try ctx.requirePrefix(namespace, .read);

    const search_params = SearchParams{
        .top_k = top_k,
        .namespace = namespace,
        .metric = metric,
        .decay = decay,
        .mode = mode,
        .decay_tau_hours = decay_tau_hours,
        .ef = ef_override,
    };
    const now_ms: u64 = if (decay > 0.0) ctx.timestamp() else 0;

    // Hoist registry lookup once for the entire query.
    const reg_opt = ctx.vector_registry;
    const store_synced = (reg_opt != null and ctx.store.vector_registry == reg_opt);
    const ns_idx_opt: ?*IndexModule.NamespaceIndex = if (reg_opt) |reg| reg.get(namespace) else null;

    // ── Zero-shard-lock ultra-fast path ──────────────────────────
    // When `query_key` lives inside `ns_idx` (synchronized with Store, no SSTs,
    // no pending async writes, and HNSW vector space matches `metric`), read the
    // 64B-aligned query directly from `hnsw.getVector` and serve inside ONE
    // `ShardedRwLock.lockShared()` → 0 shard locks, 0 query copies, 0 key dupes.
    if (ns_idx_opt) |ns_idx| {
        if (store_synced and ctx.store.sst_count == 0 and std.mem.startsWith(u8, query_key, namespace)) {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();
            if (ns_idx.pendingAsyncCount() == 0 and ns_idx.canRerankFromHnswLocked(metric)) {
                if (ns_idx.nodeIdFor(query_key)) |qid| {
                    if (!ns_idx.isTombstoned(qid)) {
                        const q_aligned = ns_idx.hnsw.getVector(qid);
                        if (q_aligned.len > 0) {
                            if (try serveDirectLocked(ctx, ns_idx, q_aligned, qid, search_params, now_ms)) |res| {
                                return res;
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Load query vector into 16B-aligned stack buffer (zero alloc for dim <= 1536) ──
    var q_stack: [STACK_QUERY_BYTES]u8 align(16) = undefined;
    var q_heap: ?[]align(16) u8 = null;
    defer if (q_heap) |b| ctx.allocator.free(b);

    const query_bytes = (try readKeyInto(ctx, query_key, &q_stack, &q_heap)) orelse
        return ctx.err("vsearch: query key not found");

    const query_vec = distance.bytesToF32(query_bytes) orelse
        return ctx.err("vsearch: query value is not a valid f32 vector (byte length must be multiple of 4)");

    // ── Direct slab / HNSW path for external query key (0 key dupes) ──
    if (ns_idx_opt) |ns_idx| {
        if (store_synced and ctx.store.sst_count == 0) {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();
            const exclude_id = ns_idx.nodeIdFor(query_key);
            if (try serveDirectLocked(ctx, ns_idx, query_vec, exclude_id, search_params, now_ms)) |res| {
                return res;
            }
        }
    }

    // ── Stack-allocated final top-K heap + shared search core ────
    var final_buf: [MAX_TOP_K]Candidate = undefined;
    var final_heap = TopKCandidate.init(final_buf[0..top_k]);

    if (try runSearchWithIndex(ctx, query_key, query_vec, search_params, ns_idx_opt, store_synced, now_ms, &final_heap)) |msg| {
        return ctx.err(msg);
    }

    return emitJson(ctx, final_heap.sortedDesc());
}

/// Shared search core — HNSW → BQ/RaBitQ slab or KV prefilter → Exact slab or
/// brute-force dispatch, populating `final_heap` with the top-K candidates.
pub fn runSearch(
    ctx: *Ctx,
    query_key: []const u8,
    query_vec: []align(1) const f32,
    params: SearchParams,
    final_heap: *TopKCandidate,
) anyerror!?[]const u8 {
    const reg_opt = ctx.vector_registry;
    const store_synced = (reg_opt != null and ctx.store.vector_registry == reg_opt);
    const ns_idx_opt: ?*IndexModule.NamespaceIndex = if (reg_opt) |reg| reg.get(params.namespace) else null;
    const now_ms: u64 = if (params.decay > 0.0) ctx.timestamp() else 0;
    return runSearchWithIndex(ctx, query_key, query_vec, params, ns_idx_opt, store_synced, now_ms, final_heap);
}

fn runSearchWithIndex(
    ctx: *Ctx,
    query_key: []const u8,
    query_vec: []align(1) const f32,
    params: SearchParams,
    ns_idx_opt: ?*IndexModule.NamespaceIndex,
    store_synced: bool,
    now_ms: u64,
    final_heap: *TopKCandidate,
) anyerror!?[]const u8 {
    const top_k = params.top_k;
    const namespace = params.namespace;
    const metric = params.metric;
    const decay = params.decay;
    const mode = params.mode;
    const decay_tau_hours = params.decay_tau_hours;

    // ── Stage 1A: HNSW (auto mode, namespace has matching index) ──
    if (mode == .auto) {
        if (ns_idx_opt) |ns_idx| {
            if (ns_idx.metric == metric) {
                if (try runHnswDispatch(
                    ctx,
                    query_key,
                    ns_idx,
                    query_vec,
                    top_k,
                    metric,
                    decay,
                    decay_tau_hours,
                    params.ef,
                    now_ms,
                    store_synced,
                    final_heap,
                )) {
                    return null;
                }
            } else {
                std.log.debug("vsearch: metric mismatch in '{s}' (index={s}, query={s}); using BQ fallback", .{
                    namespace, ns_idx.metric.name(), metric.name(),
                });
            }
        }
    }

    const inv_q_norm = precomputeInvQueryNorm(metric, query_vec);
    const use_in_index_slabs = store_synced and ctx.store.sst_count == 0;

    // ── Stage 1B: Quantized prefilter (in-index slab first, deadlock-free KV fallback) ──
    if (mode == .auto or mode == .bq or mode == .bq_rerank) {
        // Step 1: Try in-index RaBitQ / BQ slab OR retain refcounted RaBitQ handle,
        // ALWAYS releasing `ns_idx.lockShared()` BEFORE any Store shard access!
        var rq_handle: ?*IndexModule.RabitqParamsHandle = null;
        defer if (rq_handle) |h| h.release();
        var has_params = false;

        const KvRerankCand = struct { key: []const u8, timestamp: u64 };
        var kv_rerank_cands: ?[]KvRerankCand = null;
        defer if (kv_rerank_cands) |buf| ctx.allocator.free(buf);
        var kv_rerank_count: usize = 0;

        if (ns_idx_opt) |idx| {
            idx.lock.lockShared();
            var unlocked = false;
            defer if (!unlocked) idx.lock.unlockShared();

            has_params = (idx.rabitq_params != null);
            const exclude_id: ?u32 = if (query_key.len != 0) idx.nodeIdFor(query_key) else null;

            if (has_params) {
                const rabitq_metric_ok = (metric == .cosine and idx.metric == .cosine) or
                    (metric == .l2 and idx.metric != .cosine);
                if (rabitq_metric_ok) {
                    if (use_in_index_slabs and idx.canUseRabitqSlabLocked(query_vec.len)) {
                        const rerank = (mode != .bq);
                        const need_stage1_out = rerank and !idx.canRerankFromHnswLocked(metric);
                        const out_cap = if (need_stage1_out) @min(idx.liveCount(), top_k * STAGE1_OVERSAMPLE) else top_k;
                        var slab_stack: [128]IndexModule.IndexScoredResult = undefined;
                        var slab_heap: ?[]IndexModule.IndexScoredResult = null;
                        defer if (slab_heap) |b| ctx.allocator.free(b);
                        const slab_buf: []IndexModule.IndexScoredResult = if (out_cap <= slab_stack.len)
                            slab_stack[0..out_cap]
                        else blk: {
                            const b = try ctx.allocator.alloc(IndexModule.IndexScoredResult, out_cap);
                            slab_heap = b;
                            break :blk b;
                        };
                        if (try idx.searchRabitqLocked(
                            query_vec,
                            exclude_id,
                            top_k,
                            STAGE1_OVERSAMPLE,
                            metric,
                            decay,
                            now_ms,
                            decay_tau_hours,
                            rerank,
                            slab_buf,
                            ctx.allocator,
                        )) |res| {
                            if (!res.needs_kv_rerank) {
                                for (slab_buf[0..res.count]) |r| {
                                    final_heap.push(.{
                                        .key = try ctx.allocator.dupe(u8, r.key),
                                        .score = r.score,
                                        .timestamp = r.timestamp,
                                    });
                                }
                                return null;
                            }
                            const cbuf = try ctx.allocator.alloc(KvRerankCand, res.count);
                            kv_rerank_cands = cbuf;
                            for (slab_buf[0..res.count], 0..) |r, ci| {
                                cbuf[ci] = .{
                                    .key = try ctx.allocator.dupe(u8, r.key),
                                    .timestamp = r.timestamp,
                                };
                            }
                            kv_rerank_count = res.count;
                        }
                    } else {
                        // KV fallback: retain refcounted params handle BEFORE unlocking!
                        rq_handle = idx.acquireRabitqHandleLocked();
                    }
                }
            } else if (use_in_index_slabs and idx.canUseBqSlabLocked(query_vec.len)) {
                const need_stage1_out = !idx.canRerankFromHnswLocked(metric);
                const out_cap = if (need_stage1_out) @min(idx.liveCount(), top_k * STAGE1_OVERSAMPLE) else top_k;
                var slab_stack: [128]IndexModule.IndexScoredResult = undefined;
                var slab_heap: ?[]IndexModule.IndexScoredResult = null;
                defer if (slab_heap) |b| ctx.allocator.free(b);
                const slab_buf: []IndexModule.IndexScoredResult = if (out_cap <= slab_stack.len)
                    slab_stack[0..out_cap]
                else blk: {
                    const b = try ctx.allocator.alloc(IndexModule.IndexScoredResult, out_cap);
                    slab_heap = b;
                    break :blk b;
                };
                if (try idx.searchBqLocked(
                    query_vec,
                    exclude_id,
                    top_k,
                    STAGE1_OVERSAMPLE,
                    metric,
                    decay,
                    now_ms,
                    decay_tau_hours,
                    true,
                    slab_buf,
                    ctx.allocator,
                )) |res| {
                    if (!res.needs_kv_rerank) {
                        for (slab_buf[0..res.count]) |r| {
                            final_heap.push(.{
                                .key = try ctx.allocator.dupe(u8, r.key),
                                .score = r.score,
                                .timestamp = r.timestamp,
                            });
                        }
                        return null;
                    }
                    const cbuf = try ctx.allocator.alloc(KvRerankCand, res.count);
                    kv_rerank_cands = cbuf;
                    for (slab_buf[0..res.count], 0..) |r, ci| {
                        cbuf[ci] = .{
                            .key = try ctx.allocator.dupe(u8, r.key),
                            .timestamp = r.timestamp,
                        };
                    }
                    kv_rerank_count = res.count;
                }
            }

            idx.lock.unlockShared();
            unlocked = true;
        }

        // Deferred KV Stage-2 rerank (e.g. `.cosine` namespace queried with `.l2`/`.dot`):
        // runs completely outside `ns_idx.lock`!
        if (kv_rerank_cands) |cbuf| {
            var val_stack: [STACK_QUERY_BYTES]u8 align(16) = undefined;
            for (cbuf[0..kv_rerank_count]) |cand| {
                var val_heap: ?[]align(16) u8 = null;
                defer if (val_heap) |b| ctx.allocator.free(b);
                const vec_bytes = (try readKeyInto(ctx, cand.key, &val_stack, &val_heap)) orelse continue;
                const vec = distance.bytesToF32(vec_bytes) orelse continue;
                if (vec.len != query_vec.len) continue;
                const raw_sim = computeExactSimWithNorm(metric, query_vec, inv_q_norm, vec);
                const score = applyDecay(raw_sim, cand.timestamp, decay, now_ms, decay_tau_hours);
                if (!(score > final_heap.thresholdScore())) continue;
                final_heap.push(.{ .key = cand.key, .score = score, .timestamp = cand.timestamp });
            }
            return null;
        }

        // Case 2: RaBitQ KV fallback (ZERO index locks held during scan or rerank!).
        if (rq_handle) |handle| {
            const p = handle.params;
            if (p.dim == query_vec.len) {
                const dim = query_vec.len;
                const stage1_size = top_k * STAGE1_OVERSAMPLE;
                const stage1_buf = try ctx.allocator.alloc(Candidate, stage1_size);
                defer ctx.allocator.free(stage1_buf);
                var stage1_heap = TopKCandidate.init(stage1_buf);

                var bq_prefix_stack: [256]u8 = undefined;
                var bq_prefix_heap: ?[]u8 = null;
                defer if (bq_prefix_heap) |b| ctx.allocator.free(b);
                const bq_prefix = try buildBqPrefix(ctx.allocator, namespace, &bq_prefix_stack, &bq_prefix_heap);

                var q_res_stack: [STACK_DIM_CAP]f32 = undefined;
                var q_rot_stack: [STACK_DIM_CAP]f32 = undefined;
                var q_norm_stack: [STACK_DIM_CAP]f32 = undefined;
                var q_res_heap: ?[]f32 = null;
                defer if (q_res_heap) |b| ctx.allocator.free(b);
                var q_rot_heap: ?[]f32 = null;
                defer if (q_rot_heap) |b| ctx.allocator.free(b);
                var q_norm_heap: ?[]f32 = null;
                defer if (q_norm_heap) |b| ctx.allocator.free(b);

                const q_residual: []f32 = if (dim <= STACK_DIM_CAP) q_res_stack[0..dim] else blk: {
                    const b = try ctx.allocator.alloc(f32, dim);
                    q_res_heap = b;
                    break :blk b;
                };
                const q_rot_unit: []f32 = if (dim <= STACK_DIM_CAP) q_rot_stack[0..dim] else blk: {
                    const b = try ctx.allocator.alloc(f32, dim);
                    q_rot_heap = b;
                    break :blk b;
                };
                const prepare_input: []align(1) const f32 = if (metric == .cosine) blk: {
                    const nb: []f32 = if (dim <= STACK_DIM_CAP) q_norm_stack[0..dim] else blk2: {
                        const b = try ctx.allocator.alloc(f32, dim);
                        q_norm_heap = b;
                        break :blk2 b;
                    };
                    _ = rabitq.normalizeInto(query_vec, nb);
                    break :blk @ptrCast(nb);
                } else query_vec;

                const cb = rabitq.codeBytes(dim);
                const plane_bytes = 4 * cb;
                var plane_stack: [4 * STACK_CODE_BYTES]u8 = undefined;
                var plane_heap: ?[]u8 = null;
                defer if (plane_heap) |b| ctx.allocator.free(b);
                const plane_buf: []u8 = if (plane_bytes <= plane_stack.len) plane_stack[0..plane_bytes] else blk: {
                    const b = try ctx.allocator.alloc(u8, plane_bytes);
                    plane_heap = b;
                    break :blk b;
                };
                const pq = rabitq.prepareQueryFull(prepare_input, p, q_residual, q_rot_unit, plane_buf);

                var rq_sc = RabitqScanCtx{
                    .pq = pq,
                    .query_key = query_key,
                    .dim = dim,
                    .decay = decay,
                    .decay_tau_hours = decay_tau_hours,
                    .now_ms = now_ms,
                    .heap = &stage1_heap,
                    .allocator = ctx.allocator,
                    .oom = false,
                    .saw_any = 0,
                    .cosine_score = (metric == .cosine),
                };
                try ctx.scanCallback(bq_prefix, @ptrCast(&rq_sc), onRabitqMatch);
                if (rq_sc.oom) return "vsearch: out of memory during BQ stage";

                if (rq_sc.saw_any > 0) {
                    const skip_rerank = (mode == .bq);
                    const candidates = stage1_heap.sortedDesc();
                    if (skip_rerank) {
                        for (candidates) |cand| {
                            final_heap.push(.{ .key = cand.key, .score = cand.score, .timestamp = cand.timestamp });
                        }
                    } else {
                        var val_stack: [STACK_QUERY_BYTES]u8 align(16) = undefined;
                        for (candidates) |cand| {
                            var val_heap: ?[]align(16) u8 = null;
                            defer if (val_heap) |b| ctx.allocator.free(b);
                            const vec_bytes = (try readKeyInto(ctx, cand.key, &val_stack, &val_heap)) orelse continue;
                            const vec = distance.bytesToF32(vec_bytes) orelse continue;
                            if (vec.len != query_vec.len) continue;
                            const raw_sim = computeExactSimWithNorm(metric, query_vec, inv_q_norm, vec);
                            const score = applyDecay(raw_sim, cand.timestamp, decay, now_ms, decay_tau_hours);
                            if (!(score > final_heap.thresholdScore())) continue;
                            final_heap.push(.{ .key = cand.key, .score = score, .timestamp = cand.timestamp });
                        }
                    }
                    return null;
                }
            }
        }

        // Case 3: no RaBitQ params installed → legacy Hamming KV fallback.
        if (!has_params) {
            const query_bq_size = distance.binaryQuantizedSize(query_vec.len);
            var q_bq_stack: [STACK_CODE_BYTES]u8 = undefined;
            var q_bq_heap: ?[]u8 = null;
            defer if (q_bq_heap) |b| ctx.allocator.free(b);
            const query_bq: []u8 = if (query_bq_size <= q_bq_stack.len) q_bq_stack[0..query_bq_size] else blk: {
                const b = try ctx.allocator.alloc(u8, query_bq_size);
                q_bq_heap = b;
                break :blk b;
            };
            distance.binaryQuantize(query_vec, query_bq);

            const stage1_size = top_k * STAGE1_OVERSAMPLE;
            const stage1_buf = try ctx.allocator.alloc(Candidate, stage1_size);
            defer ctx.allocator.free(stage1_buf);
            var stage1_heap = TopKCandidate.init(stage1_buf);

            var bq_prefix_stack: [256]u8 = undefined;
            var bq_prefix_heap: ?[]u8 = null;
            defer if (bq_prefix_heap) |b| ctx.allocator.free(b);
            const bq_prefix = try buildBqPrefix(ctx.allocator, namespace, &bq_prefix_stack, &bq_prefix_heap);

            var bq_sc = BQScanCtx{
                .query_bq = query_bq,
                .query_key = query_key,
                .decay = decay,
                .decay_tau_hours = decay_tau_hours,
                .now_ms = now_ms,
                .heap = &stage1_heap,
                .allocator = ctx.allocator,
                .oom = false,
                .saw_any = 0,
                .code_bytes = query_bq_size,
            };
            try ctx.scanCallback(bq_prefix, @ptrCast(&bq_sc), onBQMatch);
            if (bq_sc.oom) return "vsearch: out of memory during BQ stage";

            if (bq_sc.saw_any > 0) {
                const candidates = stage1_heap.sortedDesc();
                var val_stack: [STACK_QUERY_BYTES]u8 align(16) = undefined;
                for (candidates) |cand| {
                    var val_heap: ?[]align(16) u8 = null;
                    defer if (val_heap) |b| ctx.allocator.free(b);
                    const vec_bytes = (try readKeyInto(ctx, cand.key, &val_stack, &val_heap)) orelse continue;
                    const vec = distance.bytesToF32(vec_bytes) orelse continue;
                    if (vec.len != query_vec.len) continue;
                    const raw_sim = computeExactSimWithNorm(metric, query_vec, inv_q_norm, vec);
                    const score = applyDecay(raw_sim, cand.timestamp, decay, now_ms, decay_tau_hours);
                    if (!(score > final_heap.thresholdScore())) continue;
                    final_heap.push(.{ .key = cand.key, .score = score, .timestamp = cand.timestamp });
                }
                return null;
            }
        }
    }

    // ── Exact path: contiguous HNSW vector slab when guaranteed complete ──
    if (use_in_index_slabs) {
        if (ns_idx_opt) |ns_idx| {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();
            if (ns_idx.canUseExactSlabLocked(query_vec.len, metric)) {
                const exclude_id: ?u32 = if (query_key.len != 0) ns_idx.nodeIdFor(query_key) else null;
                var slab_out: [MAX_TOP_K]IndexModule.IndexScoredResult = undefined;
                const n_found = try ns_idx.searchExactLocked(
                    query_vec,
                    exclude_id,
                    top_k,
                    metric,
                    decay,
                    now_ms,
                    decay_tau_hours,
                    slab_out[0..top_k],
                    ctx.allocator,
                );
                for (slab_out[0..n_found]) |r| {
                    final_heap.push(.{
                        .key = try ctx.allocator.dupe(u8, r.key),
                        .score = r.score,
                        .timestamp = r.timestamp,
                    });
                }
                return null;
            }
        }
    }

    // ── Brute-force KV fallback (with precomputed inv_q_norm) ────
    var exact_sc = ExactScanCtx{
        .query_key = query_key,
        .query_vec = query_vec,
        .inv_q_norm = inv_q_norm,
        .metric = metric,
        .decay = decay,
        .decay_tau_hours = decay_tau_hours,
        .now_ms = now_ms,
        .heap = final_heap,
        .allocator = ctx.allocator,
        .oom = false,
    };
    try ctx.scanCallback(namespace, @ptrCast(&exact_sc), onExactMatch);
    if (exact_sc.oom) return "vsearch: out of memory during exact scan";

    return null;
}

// ╔═══════════════════════════════════════════════════╗
// ║  vsearch_local_raw — inline-query peer sub-search  ║
// ╚═══════════════════════════════════════════════════╝

pub fn executeLocalRaw(ctx: *Ctx) anyerror!Ctx.Result {
    const query_b64 = ctx.arg(0) orelse
        return ctx.err("vsearch_local_raw requires at least 2 args: <query_b64> <top_k> [namespace] [metric] [decay] [mode] [decay_tau_hours] [ef]");

    const top_k_raw = ctx.argInt(usize, 1) orelse
        return ctx.err("vsearch_local_raw: top_k must be a positive integer");

    const top_k = @min(if (top_k_raw == 0) @as(usize, 10) else top_k_raw, MAX_TOP_K);
    const namespace = ctx.arg(2) orelse DEFAULT_NAMESPACE;
    const metric: Metric = if (ctx.arg(3)) |m|
        Metric.fromStr(m) orelse Metric.cosine
    else
        Metric.cosine;

    var decay: f32 = 0.0;
    if (ctx.arg(4)) |d| {
        decay = std.fmt.parseFloat(f32, d) catch 0.0;
        decay = @min(@max(decay, 0.0), 1.0);
    }

    const mode = if (ctx.arg(5)) |m| Mode.fromStr(m) else Mode.auto;
    const decay_tau_hours = if (ctx.arg(6)) |raw|
        parseDecayTauHours(raw) orelse return ctx.err("vsearch_local_raw: decay_tau_hours must be positive")
    else
        DEFAULT_DECAY_TAU_HOURS;
    const ef_override: ?usize = if (ctx.arg(7)) |raw|
        parseEfArg(raw) orelse return ctx.err("vsearch_local_raw: ef must be a positive integer")
    else
        null;

    // ── Authorize: results come from the whole namespace ──
    try ctx.requirePrefix(namespace, .read);

    // ── Decode inline query vector into 16B-aligned stack buffer ──
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(query_b64) catch
        return ctx.err("vsearch_local_raw: query is not valid base64");

    var dec_stack: [STACK_QUERY_BYTES]u8 align(16) = undefined;
    var dec_heap: ?[]align(16) u8 = null;
    defer if (dec_heap) |b| ctx.allocator.free(b);
    const decoded: []u8 = if (decoded_len <= dec_stack.len)
        dec_stack[0..decoded_len]
    else blk: {
        const b = try ctx.allocator.alignedAlloc(u8, .@"16", decoded_len);
        dec_heap = b;
        break :blk b;
    };
    decoder.decode(decoded, query_b64) catch
        return ctx.err("vsearch_local_raw: query is not valid base64");

    const query_vec = distance.bytesToF32(decoded) orelse
        return ctx.err("vsearch_local_raw: query is not a valid f32 vector (byte length must be a positive multiple of 4)");

    const search_params = SearchParams{
        .top_k = top_k,
        .namespace = namespace,
        .metric = metric,
        .decay = decay,
        .mode = mode,
        .decay_tau_hours = decay_tau_hours,
        .ef = ef_override,
    };
    const now_ms: u64 = if (decay > 0.0) ctx.timestamp() else 0;
    const reg_opt = ctx.vector_registry;
    const store_synced = (reg_opt != null and ctx.store.vector_registry == reg_opt);
    const ns_idx_opt: ?*IndexModule.NamespaceIndex = if (reg_opt) |reg| reg.get(namespace) else null;

    // Direct zero-key-dupe path when synchronized with Store.
    if (ns_idx_opt) |ns_idx| {
        if (store_synced and ctx.store.sst_count == 0) {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();
            if (try serveDirectLocked(ctx, ns_idx, query_vec, null, search_params, now_ms)) |res| {
                return res;
            }
        }
    }

    var final_buf: [MAX_TOP_K]Candidate = undefined;
    var final_heap = TopKCandidate.init(final_buf[0..top_k]);

    if (try runSearchWithIndex(ctx, "", query_vec, search_params, ns_idx_opt, store_synced, now_ms, &final_heap)) |msg| {
        return ctx.err(msg);
    }

    return emitJson(ctx, final_heap.sortedDesc());
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

const testing = std.testing;
const Config = @import("../core/config.zig").Config;

/// Pack a slice of f32s as little-endian bytes — the stored vector format.
fn testPackF32(allocator: std.mem.Allocator, vals: []const f32) ![]u8 {
    const buf = try allocator.alloc(u8, vals.len * 4);
    for (vals, 0..) |v, i| {
        const bits: u32 = @bitCast(v);
        std.mem.writeInt(u32, buf[i * 4 ..][0..4], bits, .little);
    }
    return buf;
}

fn testRunProc(
    store: *Store,
    proc: *const fn (ctx: *Ctx) anyerror!Ctx.Result,
    args: []const []const u8,
    arena: std.mem.Allocator,
) !Ctx.Result {
    var ctx = Ctx.init(store, args, arena, null, null, null, null);
    defer ctx.deinit();
    return try proc(&ctx);
}

test "vsearch_local_raw: parity with stored-key vsearch" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Candidate vectors in the searched namespace.
    try store.set("vec:t:a", try testPackF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 }), false);
    try store.set("vec:t:b", try testPackF32(arena, &[_]f32{ 0.9, 0.1, 0.0, 0.0 }), false);
    try store.set("vec:t:c", try testPackF32(arena, &[_]f32{ 0.0, 1.0, 0.0, 0.0 }), false);
    // Query vector stored OUTSIDE the namespace so both paths score the
    // exact same candidate set (vsearch excludes its own query key from
    // results; the raw path has no key to exclude).
    const query = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    try store.set("qvec", try testPackF32(arena, &query), false);

    const via_key = try testRunProc(&store, execute, &.{ "qvec", "2", "vec:t:" }, arena);
    try testing.expect(via_key == .value);

    const query_bytes = try testPackF32(arena, &query);
    const b64 = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(query_bytes.len));
    _ = std.base64.standard.Encoder.encode(b64, query_bytes);

    const via_raw = try testRunProc(&store, executeLocalRaw, &.{ b64, "2", "vec:t:" }, arena);
    try testing.expect(via_raw == .value);

    // Byte-identical JSON: same candidates, same scores, same order.
    try testing.expectEqualStrings(via_key.value.?, via_raw.value.?);
    // Sanity: best match first.
    try testing.expect(std.mem.startsWith(u8, via_raw.value.?, "[{\"k\":\"vec:t:a\""));
}

test "vsearch_local_raw: parity holds for exact mode and l2 metric" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try store.set("vec:t:a", try testPackF32(arena, &[_]f32{ 1.0, 2.0, 3.0, 4.0 }), false);
    try store.set("vec:t:b", try testPackF32(arena, &[_]f32{ 4.0, 3.0, 2.0, 1.0 }), false);
    const query = [_]f32{ 1.0, 2.0, 3.0, 5.0 };
    try store.set("qvec", try testPackF32(arena, &query), false);

    const via_key = try testRunProc(&store, execute, &.{ "qvec", "5", "vec:t:", "l2", "0", "exact" }, arena);
    try testing.expect(via_key == .value);

    const query_bytes = try testPackF32(arena, &query);
    const b64 = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(query_bytes.len));
    _ = std.base64.standard.Encoder.encode(b64, query_bytes);
    const via_raw = try testRunProc(&store, executeLocalRaw, &.{ b64, "5", "vec:t:", "l2", "0", "exact" }, arena);
    try testing.expect(via_raw == .value);

    try testing.expectEqualStrings(via_key.value.?, via_raw.value.?);
}

test "vsearch_local_raw: rejects invalid base64 and bad vector lengths" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Invalid base64 alphabet.
    const bad_b64 = try testRunProc(&store, executeLocalRaw, &.{ "!!!not-base64!!!", "5" }, arena);
    try testing.expect(bad_b64 == .err);

    // Valid base64, but 3 bytes — not a multiple of 4.
    var b64_buf: [8]u8 = undefined;
    const short = std.base64.standard.Encoder.encode(&b64_buf, "abc");
    const bad_len = try testRunProc(&store, executeLocalRaw, &.{ short, "5" }, arena);
    try testing.expect(bad_len == .err);

    // Missing top_k.
    const no_topk = try testRunProc(&store, executeLocalRaw, &.{"QUFBQQ=="}, arena);
    try testing.expect(no_topk == .err);
}

fn testRunProcWithRegistry(
    store: *Store,
    proc: *const fn (ctx: *Ctx) anyerror!Ctx.Result,
    args: []const []const u8,
    arena: std.mem.Allocator,
    registry: *IndexModule.NamespaceRegistry,
) !Ctx.Result {
    var ctx = Ctx.init(store, args, arena, null, null, null, registry);
    defer ctx.deinit();
    return try proc(&ctx);
}

test "vsearch: HNSW path excludes the query's own key" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var registry = IndexModule.NamespaceRegistry.init(testing.allocator, .{});
    defer registry.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Store + HNSW index in lockstep, with the query key INSIDE the searched
    // namespace — the shape the parity tests above deliberately avoid.
    const q = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const near = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
    const far = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    const ns_idx = try registry.getOrCreate("vec:t:", .cosine);
    inline for (.{
        .{ "vec:t:q", &q },
        .{ "vec:t:near", &near },
        .{ "vec:t:far", &far },
    }) |entry| {
        try store.set(entry[0], try testPackF32(arena, entry[1]), false);
        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        _ = try ns_idx.insertLocked(entry[0], entry[1], 1_700_000_000_000);
    }

    // Guard: auto mode must serve this query from the HNSW index — a silent
    // fall-through to BQ/brute-force (which already exclude) would mask a
    // regression here. Fall-through only happens on a missing index, empty
    // index, or metric mismatch; pin all three.
    try testing.expect(registry.get("vec:t:") == ns_idx);
    try testing.expectEqual(@as(usize, 3), ns_idx.len());
    try testing.expectEqual(Metric.cosine, ns_idx.metric);

    // top_k=1 is the sharpest failure: pre-fix the self-hit (score 1.0) was
    // the single result, so "nearest neighbor" always answered the query key.
    const top1 = try testRunProcWithRegistry(&store, execute, &.{ "vec:t:q", "1", "vec:t:" }, arena, &registry);
    try testing.expect(top1 == .value);
    try testing.expect(std.mem.startsWith(u8, top1.value.?, "[{\"k\":\"vec:t:near\""));

    // Full result set: neighbors present, self absent.
    const top3 = try testRunProcWithRegistry(&store, execute, &.{ "vec:t:q", "3", "vec:t:" }, arena, &registry);
    try testing.expect(top3 == .value);
    try testing.expect(std.mem.indexOf(u8, top3.value.?, "\"k\":\"vec:t:q\"") == null);
    try testing.expect(std.mem.indexOf(u8, top3.value.?, "\"k\":\"vec:t:near\"") != null);
    try testing.expect(std.mem.indexOf(u8, top3.value.?, "\"k\":\"vec:t:far\"") != null);
}

test "vsearch: plain DEL and raw SET synchronize with HNSW index" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var registry = IndexModule.NamespaceRegistry.init(testing.allocator, .{});
    defer registry.deinit();
    store.vector_registry = &registry;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const q = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const a = [_]f32{ 0.95, 0.05, 0.0, 0.0 };
    const b = [_]f32{ 0.6, 0.8, 0.0, 0.0 };
    const c = [_]f32{ 0.0, 1.0, 0.0, 0.0 };

    try store.set("qvec", try testPackF32(arena, &q), false);
    const ns_idx = try registry.getOrCreate("vec:t:", .cosine);
    inline for (.{
        .{ "vec:t:a", &a },
        .{ "vec:t:b", &b },
        .{ "vec:t:c", &c },
    }) |entry| {
        try store.setWithTimestampNoVectorSync(entry[0], try testPackF32(arena, entry[1]), false, 1_700_000_000_000);
        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        _ = try ns_idx.insertLocked(entry[0], entry[1], 1_700_000_000_000);
    }

    // 1. Plain DEL on vec:t:a must tombstone it in HNSW and exclude it from results.
    _ = try store.delete("vec:t:a");
    try testing.expectEqual(@as(usize, 2), ns_idx.liveCount());

    const after_del = try testRunProcWithRegistry(&store, execute, &.{ "qvec", "3", "vec:t:" }, arena, &registry);
    try testing.expect(after_del == .value);
    try testing.expect(std.mem.indexOf(u8, after_del.value.?, "\"k\":\"vec:t:a\"") == null);
    try testing.expect(std.mem.startsWith(u8, after_del.value.?, "[{\"k\":\"vec:t:b\""));

    // 2. Raw SET overwriting vec:t:c with the top-scoring vector must refresh HNSW AND bq:vec:t:c.
    const c_updated = [_]f32{ 0.99, 0.01, -0.01, -0.01 };
    try store.set("vec:t:c", try testPackF32(arena, &c_updated), false);
    try testing.expect(store.exists("bq:vec:t:c"));
    const after_set = try testRunProcWithRegistry(&store, execute, &.{ "qvec", "3", "vec:t:" }, arena, &registry);
    try testing.expect(after_set == .value);
    try testing.expect(std.mem.startsWith(u8, after_set.value.?, "[{\"k\":\"vec:t:c\""));

    const q_bq = [_]f32{ 1.0, 1.0, -1.0, -1.0 };
    try store.set("qvec_bq", try testPackF32(arena, &q_bq), false);
    try store.set("vec:t:b", try testPackF32(arena, &[_]f32{ -1.0, -1.0, 1.0, 1.0 }), false);
    const after_set_bq = try testRunProcWithRegistry(&store, execute, &.{ "qvec_bq", "2", "vec:t:", "cosine", "0", "bq" }, arena, &registry);
    try testing.expect(after_set_bq == .value);
    try testing.expect(std.mem.startsWith(u8, after_set_bq.value.?, "[{\"k\":\"vec:t:c\""));

    // 3. Raw SET overwriting vec:t:c with non-vector payload must tombstone its HNSW entry and remove bq:vec:t:c.
    try store.set("vec:t:c", "not-a-float-vector!", false);
    try testing.expect(!store.exists("bq:vec:t:c"));
    const after_bad_set = try testRunProcWithRegistry(&store, execute, &.{ "qvec", "3", "vec:t:" }, arena, &registry);
    try testing.expect(after_bad_set == .value);
    try testing.expect(std.mem.indexOf(u8, after_bad_set.value.?, "\"k\":\"vec:t:c\"") == null);
}

test "vsearch: optional ef argument accepts integer or ef=<N> and rejects 0" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var registry = IndexModule.NamespaceRegistry.init(testing.allocator, .{});
    defer registry.deinit();
    store.vector_registry = &registry;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const q = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const a = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
    try store.set("qvec", try testPackF32(arena, &q), false);
    _ = try registry.getOrCreate("vec:t:", .cosine);
    try store.set("vec:t:a", try testPackF32(arena, &a), false);

    const ok_num = try testRunProcWithRegistry(
        &store,
        execute,
        &.{ "qvec", "1", "vec:t:", "cosine", "0", "auto", "168", "64" },
        arena,
        &registry,
    );
    try testing.expect(ok_num == .value);

    const ok_kv = try testRunProcWithRegistry(
        &store,
        execute,
        &.{ "qvec", "1", "vec:t:", "cosine", "0", "auto", "168", "ef=200" },
        arena,
        &registry,
    );
    try testing.expect(ok_kv == .value);

    const bad_zero = try testRunProcWithRegistry(
        &store,
        execute,
        &.{ "qvec", "1", "vec:t:", "cosine", "0", "auto", "168", "0" },
        arena,
        &registry,
    );
    try testing.expect(bad_zero == .err);
}

test "vsearch E2E: vrabitq + mode=bq & bq_rerank (L2, cosine, dot fallthrough)" {
    const vector_ops = @import("vector_ops.zig");
    const vrabitq = @import("vrabitq.zig");
    const alloc = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for ([_]Metric{ .l2, .cosine }) |ns_metric| {
        var store = try Store.init(alloc, Config{ .persistence = .none });
        defer store.deinit();
        var reg = IndexModule.NamespaceRegistry.init(alloc, .{ .m = 8, .ef_construction = 40 });
        defer reg.deinit();
        store.vector_registry = &reg;

        const ns = if (ns_metric == .l2) "vec:e2e_l2:" else "vec:e2e_cos:";
        const dim: usize = 64;
        var prng = std.Random.DefaultPrng.init(0xC0FFEE1234);
        const rand = prng.random();
        var key_buf: [64]u8 = undefined;
        var vec_buf: [dim]f32 = undefined;

        // 40 vectors (>32 so FastScan32 packs 1 full block + 8-vector tail).
        for (0..40) |i| {
            for (&vec_buf) |*x| x.* = rand.floatNorm(f32);
            if (i == 17) {
                @memset(&vec_buf, 0.0);
                vec_buf[0] = 5.0;
                vec_buf[1] = 1.0;
            }
            const k = std.fmt.bufPrint(&key_buf, "{s}{d}", .{ ns, i }) catch unreachable;
            try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
                .key = k,
                .vector = std.mem.sliceAsBytes(&vec_buf),
                .worm = false,
                .namespace = ns,
                .metric = ns_metric,
                .timestamp = 1_700_000_000_000 + i,
                .replicate = false,
            });
        }

        // Query aligned with item 17.
        var q_vec: [dim]f32 = @splat(0.0);
        q_vec[0] = 5.0;
        q_vec[1] = 1.0;
        try store.set("q_target", std.mem.sliceAsBytes(&q_vec), false);

        // Run vrabitq on the namespace.
        const rq_res = try testRunProcWithRegistry(&store, vrabitq.execute, &.{ ns, "123" }, arena, &reg);
        try testing.expect(rq_res == .value);

        const mname = ns_metric.name();
        const want_k = std.fmt.bufPrint(&key_buf, "\"k\":\"{s}17\"", .{ns}) catch unreachable;

        // 1. mode=bq (pure FastScan32 RaBitQ estimator, no rerank)
        const res_bq = try testRunProcWithRegistry(&store, execute, &.{ "q_target", "5", ns, mname, "0", "bq" }, arena, &reg);
        try testing.expect(res_bq == .value);
        try testing.expect(std.mem.indexOf(u8, res_bq.value.?, want_k) != null);

        // 2. mode=bq_rerank (FastScan32 + zero-copy HNSW slab rerank)
        const res_rr = try testRunProcWithRegistry(&store, execute, &.{ "q_target", "5", ns, mname, "0", "bq_rerank" }, arena, &reg);
        try testing.expect(res_rr == .value);
        try testing.expect(std.mem.startsWith(u8, res_rr.value.?, try std.fmt.allocPrint(arena, "[{{{s}", .{want_k})));

        // 3. mode=bq with dot metric falls through to exact (dot is unsupported by RaBitQ).
        const res_dot = try testRunProcWithRegistry(&store, execute, &.{ "q_target", "5", ns, "dot", "0", "bq" }, arena, &reg);
        try testing.expect(res_dot == .value);
        try testing.expect(std.mem.startsWith(u8, res_dot.value.?, try std.fmt.allocPrint(arena, "[{{{s}", .{want_k})));
    }
}

test "vsearch E2E: cosine namespace queried with l2/dot (pre- and post-vrabitq) preserves raw magnitude" {
    const vector_ops = @import("vector_ops.zig");
    const vrabitq = @import("vrabitq.zig");
    const alloc = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try Store.init(alloc, Config{ .persistence = .none });
    defer store.deinit();
    var reg = IndexModule.NamespaceRegistry.init(alloc, .{ .m = 8, .ef_construction = 40 });
    defer reg.deinit();
    store.vector_registry = &reg;

    const ns = "vec:cos_raw:";
    // Same direction [1, 0, ...], VERY different magnitudes:
    //   v_small = [1, 0, ...]  (unit norm = [1, 0])
    //   v_huge  = [100, 0, ...] (unit norm = [1, 0] — IDENTICAL in cosine HNSW!)
    // Query = [100, 0, ...] → under L2 and DOT, v_huge MUST beat v_small decisively!
    // If HNSW unit-normalized slab were mistakenly used, v_small and v_huge would tie!
    var v_small: [16]f32 = @splat(0.0);
    v_small[0] = 1.0;
    var v_huge: [16]f32 = @splat(0.0);
    v_huge[0] = 100.0;
    var v_other: [16]f32 = @splat(0.0);
    v_other[1] = 1.0;

    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:cos_raw:small",
        .vector = std.mem.sliceAsBytes(&v_small),
        .worm = false,
        .namespace = ns,
        .metric = .cosine,
        .timestamp = 10,
        .replicate = false,
    });
    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:cos_raw:huge",
        .vector = std.mem.sliceAsBytes(&v_huge),
        .worm = false,
        .namespace = ns,
        .metric = .cosine,
        .timestamp = 20,
        .replicate = false,
    });
    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:cos_raw:other",
        .vector = std.mem.sliceAsBytes(&v_other),
        .worm = false,
        .namespace = ns,
        .metric = .cosine,
        .timestamp = 30,
        .replicate = false,
    });
    try store.set("q_huge", std.mem.sliceAsBytes(&v_huge), false);

    // Pre-vrabitq: legacy BQ slab must defer to KV rerank, exact must use KV scan.
    inline for ([_][]const u8{ "auto", "bq", "bq_rerank", "exact" }) |mode_s| {
        const res_l2 = try testRunProcWithRegistry(&store, execute, &.{ "q_huge", "2", ns, "l2", "0", mode_s }, arena, &reg);
        try testing.expect(res_l2 == .value);
        try testing.expect(std.mem.startsWith(u8, res_l2.value.?, "[{\"k\":\"vec:cos_raw:huge\",\"s\":1.000000"));

        const res_dot = try testRunProcWithRegistry(&store, execute, &.{ "q_huge", "2", ns, "dot", "0", mode_s }, arena, &reg);
        try testing.expect(res_dot == .value);
        try testing.expect(std.mem.startsWith(u8, res_dot.value.?, "[{\"k\":\"vec:cos_raw:huge\",\"s\":10000.000000"));
    }

    // Post-vrabitq: cosine RaBitQ params installed → L2/dot queries MUST fall through to exact KV.
    const rq_res = try testRunProcWithRegistry(&store, vrabitq.execute, &.{ ns, "7" }, arena, &reg);
    try testing.expect(rq_res == .value);

    inline for ([_][]const u8{ "auto", "bq", "bq_rerank", "exact" }) |mode_s| {
        const res_l2 = try testRunProcWithRegistry(&store, execute, &.{ "q_huge", "2", ns, "l2", "0", mode_s }, arena, &reg);
        try testing.expect(res_l2 == .value);
        try testing.expect(std.mem.startsWith(u8, res_l2.value.?, "[{\"k\":\"vec:cos_raw:huge\",\"s\":1.000000"));

        const res_dot = try testRunProcWithRegistry(&store, execute, &.{ "q_huge", "2", ns, "dot", "0", mode_s }, arena, &reg);
        try testing.expect(res_dot == .value);
        try testing.expect(std.mem.startsWith(u8, res_dot.value.?, "[{\"k\":\"vec:cos_raw:huge\",\"s\":10000.000000"));
    }
}

test "vsearch E2E: mixed legacy 16B/24B KV fallback and lost-params crash fallback" {
    const vector_ops = @import("vector_ops.zig");
    const vrabitq = @import("vrabitq.zig");
    const alloc = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try Store.init(alloc, Config{ .persistence = .none });
    defer store.deinit();
    var reg = IndexModule.NamespaceRegistry.init(alloc, .{ .m = 8, .ef_construction = 40 });
    defer reg.deinit();
    store.vector_registry = &reg;

    const ns = "vec:mix:";
    const dim: usize = 128;
    var v1: [dim]f32 = @splat(0.1);
    v1[0] = 5.0;
    var v2: [dim]f32 = @splat(0.1);
    v2[1] = 5.0;
    var v3: [dim]f32 = @splat(0.1);
    v3[2] = 5.0;

    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:mix:a",
        .vector = std.mem.sliceAsBytes(&v1),
        .worm = false,
        .namespace = ns,
        .metric = .l2,
        .timestamp = 10,
        .replicate = false,
    });
    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:mix:b",
        .vector = std.mem.sliceAsBytes(&v2),
        .worm = false,
        .namespace = ns,
        .metric = .l2,
        .timestamp = 20,
        .replicate = false,
    });
    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:mix:c",
        .vector = std.mem.sliceAsBytes(&v3),
        .worm = false,
        .namespace = ns,
        .metric = .l2,
        .timestamp = 30,
        .replicate = false,
    });
    try store.set("q_mix", std.mem.sliceAsBytes(&v1), false);

    // Run vrabitq so all bq:* become 24-byte RaBitQ entries.
    const rq_res = try testRunProcWithRegistry(&store, vrabitq.execute, &.{ ns, "55" }, arena, &reg);
    try testing.expect(rq_res == .value);

    // 1. Mixed corpus: overwrite bq:vec:mix:c with a legacy 16B code and mark rq_slab unsynced
    //    (exercising deadlock-free RaBitQ KV fallback skipping legacy 16B cleanly).
    var legacy_bq: [16]u8 = undefined;
    distance.binaryQuantize(&v3, &legacy_bq);
    try store.setWithTimestampNoVectorSync("bq:vec:mix:c", &legacy_bq, false, 30);
    const idx = reg.get(ns).?;
    idx.lock.lock();
    idx.rq_slab.synced = false;
    idx.lock.unlock();

    const mixed_res = try testRunProcWithRegistry(&store, execute, &.{ "q_mix", "2", ns, "l2", "0", "bq_rerank" }, arena, &reg);
    try testing.expect(mixed_res == .value);
    try testing.expect(std.mem.startsWith(u8, mixed_res.value.?, "[{\"k\":\"vec:mix:a\""));
    try testing.expect(std.mem.indexOf(u8, mixed_res.value.?, "vec:mix:c") == null);

    // 2. Lost-params crash fallback: drop registry entry while 24B bq:* entries remain in KV.
    //    Ensure bq:vec:mix:c is also 24B so ALL entries are 24B, forcing saw_any == 0 -> exact KV.
    const bq_a = (try store.getValueDupe("bq:vec:mix:a", alloc)).?;
    defer alloc.free(bq_a);
    try store.setWithTimestampNoVectorSync("bq:vec:mix:c", bq_a, false, 30);
    reg.remove(ns);

    const lost_res = try testRunProcWithRegistry(&store, execute, &.{ "q_mix", "2", ns, "l2", "0", "auto" }, arena, &reg);
    try testing.expect(lost_res == .value);
    try testing.expect(std.mem.startsWith(u8, lost_res.value.?, "[{\"k\":\"vec:mix:a\""));
}

test "vsearch E2E: temporal decay > 0 promotes newer neighbor across HNSW, slab, and exact modes" {
    const vector_ops = @import("vector_ops.zig");
    const alloc = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try Store.init(alloc, Config{ .persistence = .none });
    defer store.deinit();
    var reg = IndexModule.NamespaceRegistry.init(alloc, .{ .m = 8, .ef_construction = 40 });
    defer reg.deinit();
    store.vector_registry = &reg;

    const ns = "vec:dec:";
    const q = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const v_old_near = [_]f32{ 0.99, 0.14, 0.0, 0.0 }; // cos ≈ 0.99, ancient timestamp
    const v_new_mid = [_]f32{ 0.85, 0.52, 0.0, 0.0 }; // cos ≈ 0.85, brand-new timestamp

    const now_ms: u64 = @intCast(@max(@as(i64, 0), @import("../core/compat.zig").nowMs()));
    const old_ts: u64 = if (now_ms > 30 * 24 * 3_600_000) now_ms - 30 * 24 * 3_600_000 else 1;

    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:dec:old",
        .vector = std.mem.sliceAsBytes(&v_old_near),
        .worm = false,
        .namespace = ns,
        .metric = .cosine,
        .timestamp = old_ts,
        .replicate = false,
    });
    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:dec:new",
        .vector = std.mem.sliceAsBytes(&v_new_mid),
        .worm = false,
        .namespace = ns,
        .metric = .cosine,
        .timestamp = now_ms,
        .replicate = false,
    });
    try store.set("q_dec", std.mem.sliceAsBytes(&q), false);

    // Without decay: vec:dec:old wins.
    const no_dec = try testRunProcWithRegistry(&store, execute, &.{ "q_dec", "2", ns, "cosine", "0", "auto" }, arena, &reg);
    try testing.expect(no_dec == .value);
    try testing.expect(std.mem.startsWith(u8, no_dec.value.?, "[{\"k\":\"vec:dec:old\""));

    // With strong decay (0.5, tau=24h): vec:dec:new wins across auto, bq_rerank, and exact!
    inline for ([_][]const u8{ "auto", "bq_rerank", "exact" }) |mode_s| {
        const with_dec = try testRunProcWithRegistry(&store, execute, &.{ "q_dec", "2", ns, "cosine", "0.5", mode_s, "24" }, arena, &reg);
        try testing.expect(with_dec == .value);
        try testing.expect(std.mem.startsWith(u8, with_dec.value.?, "[{\"k\":\"vec:dec:new\""));
    }
}

test "vsearch E2E: pre-existing KV vec/bq keys before getOrCreate are preserved on mode=bq_rerank and vreindex restores slab" {
    const vector_ops = @import("vector_ops.zig");
    const vreindex = @import("vreindex.zig");
    const alloc = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try Store.init(alloc, Config{ .persistence = .none });
    defer store.deinit();
    var reg = IndexModule.NamespaceRegistry.init(alloc, .{ .m = 8, .ef_construction = 32 });
    defer reg.deinit();
    store.vector_registry = &reg;

    const ns = "vec:pre:";
    const v_old = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const v_new = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    var bq_old: [1]u8 = undefined;
    distance.binaryQuantize(&v_old, &bq_old);

    // Pre-existing vec + bq entries written BEFORE the namespace index exists.
    try store.set("vec:pre:old", std.mem.sliceAsBytes(&v_old), false);
    try store.set("bq:vec:pre:old", &bq_old, false);
    try store.set("q_pre", std.mem.sliceAsBytes(&v_old), false);

    // Now insert a new vector via applyVinsert (creates index on non-empty prefix -> incomplete).
    try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
        .key = "vec:pre:new",
        .vector = std.mem.sliceAsBytes(&v_new),
        .worm = false,
        .namespace = ns,
        .metric = .cosine,
        .timestamp = 100,
        .replicate = false,
    });

    const idx = reg.get(ns).?;
    {
        idx.lock.lockShared();
        defer idx.lock.unlockShared();
        try testing.expect(!idx.complete_with_store);
        try testing.expect(!idx.bq_slab.synced);
        try testing.expect(!idx.canUseBqSlabLocked(4));
    }

    // mode=bq_rerank must fall back to KV scan and find vec:pre:old (not silently drop it!).
    const before_reindex = try testRunProcWithRegistry(&store, execute, &.{ "q_pre", "2", ns, "cosine", "0", "bq_rerank" }, arena, &reg);
    try testing.expect(before_reindex == .value);
    try testing.expect(std.mem.startsWith(u8, before_reindex.value.?, "[{\"k\":\"vec:pre:old\""));

    // Running vreindex rebuilds complete index and re-enables the fast BQ slab.
    const ri = try testRunProcWithRegistry(&store, vreindex.execute, &.{ns}, arena, &reg);
    try testing.expect(ri == .value);
    {
        idx.lock.lockShared();
        defer idx.lock.unlockShared();
        try testing.expect(idx.complete_with_store);
        try testing.expect(idx.bq_slab.synced);
        try testing.expect(idx.canUseBqSlabLocked(4));
    }

    const after_reindex = try testRunProcWithRegistry(&store, execute, &.{ "q_pre", "2", ns, "cosine", "0", "bq_rerank" }, arena, &reg);
    try testing.expect(after_reindex == .value);
    try testing.expect(std.mem.startsWith(u8, after_reindex.value.?, "[{\"k\":\"vec:pre:old\""));
}
