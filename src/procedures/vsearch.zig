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
//! EXEC vsearch <query_key> <top_k> [<namespace>] [<metric>] [<decay>] [<mode>] [<decay_tau_hours>]
//!
//! - query_key:  key holding the query vector (raw f32 bytes)
//! - top_k:      max results to return (1–100)
//! - namespace:  key prefix to search (default: "vec:")
//! - metric:     "cosine" (default), "dot", "l2"
//! - decay:      temporal decay factor (0.0 = no decay)
//! - mode:       "auto" (default — BQ prefilter if hashes exist, else
//!               brute-force) or "exact" (always brute-force)
//! - decay_tau_hours: temporal decay time constant (default: 168)
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
/// HNSW ef (beam width) factor relative to M (= top_k × STAGE1_OVERSAMPLE).
/// HNSW recall tracks ef closely; we reuse the same oversample budget so
/// the stage-1→stage-2 shape stays consistent across dispatch paths.
const HNSW_EF_SEARCH_FACTOR: usize = 1;
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
};

// ╔═══════════════════════════════════════════════════╗
// ║  Shared helpers                                    ║
// ╚═══════════════════════════════════════════════════╝

pub fn parseDecayTauHours(raw: []const u8) ?f32 {
    const tau = std.fmt.parseFloat(f32, raw) catch return null;
    if (!std.math.isFinite(tau) or tau <= 0.0) return null;
    return tau;
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

// ╔═══════════════════════════════════════════════════╗
// ║  Stage 1 — BQ Hamming scan                         ║
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
    /// Length of the pure-code format this scan accepts. Entries of
    /// any other size are skipped — in particular we must NOT treat a
    /// 24B RaBitQ entry as a 16B legacy code even though the byte
    /// prefix "looks like" a code. The semantics differ: legacy codes
    /// are `sign(v[i])`; RaBitQ codes are `sign(R·(v-c)/||v-c||)[i]`.
    /// Hamming between the two bit distributions is uncorrelated.
    code_bytes: usize,
};

// TODO(tests): procedure-level integration tests for vsearch don't
// exist in this codebase yet. Three cross-format correctness cases
// rely on `onBQMatch` / `onRabitqMatch` silently rejecting the wrong
// size: (a) metric=cosine with RaBitQ params installed, (b) restart
// without snapshot so params are lost but bq entries are still 24B,
// (c) legacy 16B entries present in a namespace that later got
// vrabitq'd. Each currently relies on code review; adding a harness
// that boots a Ctx + Store + Registry would let all three regress
// loudly.
fn onBQMatch(
    raw_ctx: *anyopaque,
    bq_key: []const u8,
    bq_value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = is_worm;
    const sc: *BQScanCtx = @ptrCast(@alignCast(raw_ctx));

    // Skip anything that isn't the exact legacy format. RaBitQ entries
    // (code_bytes + 8) are rotated-residual signs and are meaningless
    // under naive sign(query) Hamming — if a namespace is entirely
    // RaBitQ-format but params got lost (crash-without-snapshot), we
    // want `saw_any == 0` so the caller falls through to brute-force.
    if (bq_value.len != sc.code_bytes) return .cont;

    // Derive the vec key by stripping the 3-byte "bq:" prefix.
    if (bq_key.len <= BQ_PREFIX.len) return .cont;
    const vec_key = bq_key[BQ_PREFIX.len..];

    if (std.mem.eql(u8, vec_key, sc.query_key)) return .cont;

    sc.saw_any += 1;

    const ham_dist = distance.hamming(sc.query_bq, bq_value);
    const total_bits: f32 = @floatFromInt(sc.code_bytes * 8);
    const sim = 1.0 - @as(f32, @floatFromInt(ham_dist)) / total_bits;
    const score = applyDecay(sim, timestamp, sc.decay, sc.now_ms, sc.decay_tau_hours);

    if (score <= sc.heap.thresholdScore()) return .cont;

    const key_copy = sc.allocator.dupe(u8, vec_key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.heap.push(.{ .key = key_copy, .score = score, .timestamp = timestamp });
    return .cont;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Stage 1 — RaBitQ estimator scan (L2 only)         ║
// ╚═══════════════════════════════════════════════════╝

const RabitqScanCtx = struct {
    q_rot_unit: []const f32,
    q_l2: f32,
    query_key: []const u8,
    code_bytes: usize,
    dim: usize,
    decay: f32,
    decay_tau_hours: f32,
    now_ms: u64,
    heap: *TopKCandidate,
    allocator: std.mem.Allocator,
    oom: bool,
    saw_any: usize,
    /// True iff the namespace was vrabitq'd in cosine mode (vectors
    /// pre-normalized to the unit sphere). Converts the estimator's
    /// L2² output to cosine via `cos = 1 - L²/2` instead of the
    /// generic `1/(1+d²)` mapping. Cosine score is in [-1, 1] so we
    /// shift to [0, 1] to keep the TopK heap semantics consistent.
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
    sc.saw_any += 1;

    if (bq_key.len <= BQ_PREFIX.len) return .cont;
    const vec_key = bq_key[BQ_PREFIX.len..];
    if (std.mem.eql(u8, vec_key, sc.query_key)) return .cont;

    // Only process RaBitQ-format entries; skip legacy 16-byte codes
    // silently — they were written before `vrabitq` ran on this namespace.
    const enc = rabitq.parse(bq_value, sc.dim) orelse return .cont;

    const d2_est = rabitq.estimateL2Sq(sc.q_rot_unit, sc.q_l2, enc.code, enc.l2_norm, enc.corr);
    const d2_clamped: f32 = if (d2_est < 0.0) 0.0 else d2_est;

    const raw_sim: f32 = if (sc.cosine_score) blk: {
        // On the unit sphere: L²(q, v) = 2(1 - q·v), so q·v = 1 - L²/2.
        // Map cosine ∈ [-1, 1] to score ∈ [0, 1] via (cos + 1) / 2.
        const cos_est = 1.0 - d2_clamped * 0.5;
        const cos_clamped: f32 = if (cos_est > 1.0) 1.0 else if (cos_est < -1.0) -1.0 else cos_est;
        break :blk (cos_clamped + 1.0) * 0.5;
    } else 1.0 / (1.0 + d2_clamped);

    const score = applyDecay(raw_sim, timestamp, sc.decay, sc.now_ms, sc.decay_tau_hours);

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

    if (std.mem.eql(u8, key, sc.query_key)) return .cont;

    const vec = distance.bytesToF32(value) orelse return .cont;
    if (vec.len != sc.query_vec.len) return .cont;

    const raw_sim = computeExactSim(sc.metric, sc.query_vec, vec);
    const score = applyDecay(raw_sim, timestamp, sc.decay, sc.now_ms, sc.decay_tau_hours);

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
    query_key: []const u8,
    ns_idx: *IndexModule.NamespaceIndex,
    query_vec: []align(1) const f32,
    top_k: usize,
    metric: Metric,
    decay: f32,
    decay_tau_hours: f32,
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
        // The query's own stored entry is never a result — mirrors the
        // BQ/RaBitQ/brute-force scan paths and the runSearch contract.
        if (std.mem.eql(u8, stage1_keys[i], query_key)) continue;
        const vec_bytes = (try ctx.getCopy(stage1_keys[i])) orelse continue;
        const vec = distance.bytesToF32(vec_bytes) orelse continue;
        if (vec.len != query_vec.len) continue;

        const raw_sim = computeExactSim(metric, query_vec, vec);
        const score = applyDecay(raw_sim, stage1_ts[i], decay, now_ms, decay_tau_hours);

        heap.push(.{ .key = stage1_keys[i], .score = score, .timestamp = stage1_ts[i] });
    }

    return true;
}

// ╔═══════════════════════════════════════════════════╗
// ║  JSON emission                                     ║
// ╚═══════════════════════════════════════════════════╝

fn emitJson(ctx: *Ctx, results: []const Candidate) !Ctx.Result {
    var json: std.ArrayListUnmanaged(u8) = .empty;
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

pub fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
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
        return ctx.err("vsearch requires at least 2 args: <query_key> <top_k> [namespace] [metric] [decay] [mode] [decay_tau_hours]");

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

    // ── Load query vector (locks internally, safe before scans) ──
    const query_bytes = (try ctx.getCopy(query_key)) orelse
        return ctx.err("vsearch: query key not found");

    const query_vec = distance.bytesToF32(query_bytes) orelse
        return ctx.err("vsearch: query value is not a valid f32 vector (byte length must be multiple of 4)");

    // ── Allocate final top-K heap and run the shared search core ──
    const final_buf = try ctx.allocator.alloc(Candidate, top_k);
    var final_heap = TopKCandidate.init(final_buf);

    if (try runSearch(ctx, query_key, query_vec, .{
        .top_k = top_k,
        .namespace = namespace,
        .metric = metric,
        .decay = decay,
        .mode = mode,
        .decay_tau_hours = decay_tau_hours,
    }, &final_heap)) |msg| return ctx.err(msg);

    return emitJson(ctx, final_heap.sortedDesc());
}

/// Shared search core — HNSW → BQ/RaBitQ prefilter → brute-force dispatch,
/// populating `final_heap` with the top-K candidates for an *inline* query
/// vector. `query_key` is only used to exclude the query's own stored entry
/// from the candidate set (pass "" when the query has no local key, e.g.
/// a scatter sub-query arriving over replication).
///
/// Returns null on success; on a soft failure (OOM inside a scan callback)
/// returns the error message the caller should surface via `ctx.err` —
/// preserving the exact error strings the pre-refactor `vsearch` emitted.
pub fn runSearch(
    ctx: *Ctx,
    query_key: []const u8,
    query_vec: []align(1) const f32,
    params: SearchParams,
    final_heap: *TopKCandidate,
) anyerror!?[]const u8 {
    const top_k = params.top_k;
    const namespace = params.namespace;
    const metric = params.metric;
    const decay = params.decay;
    const mode = params.mode;
    const decay_tau_hours = params.decay_tau_hours;

    const now_ms = ctx.timestamp();

    // ── Stage 1A: HNSW (auto mode, namespace has matching index) ──
    // Preferred path when available — ~5-50× faster than BQ at large N.
    // The namespace's HNSW must have been built with the same metric the
    // caller is querying with; mismatches fall through to BQ, which
    // doesn't depend on the graph's distance choice. Stage-2 refine
    // re-ranks with the caller's metric regardless.
    if (mode == .auto) {
        if (ctx.vector_registry) |reg| {
            if (reg.get(namespace)) |ns_idx| {
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
                        now_ms,
                        final_heap,
                    )) {
                        return null;
                    }
                    // runHnswDispatch returned false → index is empty; fall
                    // through to BQ / brute-force paths.
                }
                // Metric mismatch: fall through, log at debug level to help
                // operators notice un-indexed query shapes.
                if (ns_idx.metric != metric) {
                    std.log.debug("vsearch: metric mismatch in '{s}' (index={s}, query={s}); using BQ fallback", .{
                        namespace, ns_idx.metric.name(), metric.name(),
                    });
                }
            }
        }
    }

    // ── Stage 1B: Quantized prefilter ───────────────────────────
    // Enters when caller explicitly asked for bq/bq_rerank OR when auto
    // mode fell through (no HNSW, metric mismatch). Full exact mode
    // skips this and goes straight to the brute-force scan below.
    //
    // Dispatch:
    //   - RaBitQ params installed + metric=l2 → unbiased estimator
    //   - No RaBitQ params → legacy Hamming prefilter (works for any metric)
    //   - RaBitQ params installed + metric≠l2 → SKIP quantized path.
    //     The stored codes are `sign(R·(v-c)/||v-c||)`, uncorrelated with
    //     `sign(query)`, so naive-Hamming on a non-rotated query would
    //     return near-random top-M. Fall through to brute-force; users
    //     querying cosine/dot on a RaBitQ namespace pay the full-precision
    //     scan cost until a per-metric encoder is added.
    if (mode == .auto or mode == .bq or mode == .bq_rerank) {
        const ns_idx_opt: ?*IndexModule.NamespaceIndex =
            if (ctx.vector_registry) |reg| reg.get(namespace) else null;

        // Branch on whether RaBitQ params are installed. The lock is
        // held for the full stage-1 scan in the RaBitQ branch so a
        // concurrent `EXEC vrabitq` can't free the params out from
        // under us (it takes the exclusive lock via setRabitqParams).
        // The scan itself only touches store shard locks, not the
        // namespace lock, so the extended critical section doesn't
        // risk deadlock.
        const has_params = blk: {
            if (ns_idx_opt) |idx| {
                idx.lock.lockShared();
                const got = idx.rabitq_params != null;
                if (!got) idx.lock.unlockShared();
                break :blk got;
            }
            break :blk false;
        };

        // Case 1: params installed but metric is unsupported by the
        // estimator → drop BQ entirely. Today only L2 and cosine are
        // wired; dot product is deferred (would need per-vector inner
        // product factors stored at encode time).
        const rabitq_metric_ok = (metric == .l2) or (metric == .cosine);
        if (has_params and !rabitq_metric_ok) {
            ns_idx_opt.?.lock.unlockShared();
            // Fall through (no `return`) so the brute-force block runs.
        } else if (has_params) {
            // Case 2: RaBitQ estimator path (L2 or cosine).
            defer ns_idx_opt.?.lock.unlockShared();
            const p = ns_idx_opt.?.rabitq_params.?;
            if (p.dim != query_vec.len) {
                // Dim mismatch — shouldn't happen in practice (freeze
                // is shared with the graph), but skip the BQ stage and
                // fall through to brute-force if it does.
            } else {
                const stage1_size = top_k * STAGE1_OVERSAMPLE;
                const stage1_buf = try ctx.allocator.alloc(Candidate, stage1_size);
                var stage1_heap = TopKCandidate.init(stage1_buf);

                const bq_prefix = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ BQ_PREFIX, namespace });

                const dim = query_vec.len;
                const q_residual = try ctx.allocator.alloc(f32, dim);
                const q_rot_unit = try ctx.allocator.alloc(f32, dim);

                // Cosine namespaces pre-normalized at encode time, so
                // the query also normalizes before residual/rotation
                // computation. The estimator's L2² output then maps to
                // cosine via `cos = 1 - L²/2` on the unit sphere.
                const prepare_input: []align(1) const f32 = if (metric == .cosine) blk: {
                    const norm_buf = try ctx.allocator.alloc(f32, dim);
                    if (!rabitq.normalizeInto(query_vec, norm_buf)) {
                        // Zero query — degenerate; treat as if all
                        // candidates are equidistant.
                    }
                    break :blk @ptrCast(norm_buf);
                } else query_vec;

                const q_l2 = rabitq.prepareQuery(prepare_input, p, q_residual, q_rot_unit);

                var rq_sc = RabitqScanCtx{
                    .q_rot_unit = q_rot_unit,
                    .q_l2 = q_l2,
                    .query_key = query_key,
                    .code_bytes = rabitq.codeBytes(dim),
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
                ctx.scanCallback(bq_prefix, @ptrCast(&rq_sc), onRabitqMatch);

                if (rq_sc.oom) return "vsearch: out of memory during BQ stage";

                if (rq_sc.saw_any > 0) {
                    const skip_rerank = (mode == .bq);
                    const candidates = stage1_heap.sortedDesc();
                    if (skip_rerank) {
                        for (candidates) |cand| {
                            final_heap.push(.{ .key = cand.key, .score = cand.score, .timestamp = cand.timestamp });
                        }
                    } else {
                        for (candidates) |cand| {
                            const vec_bytes = (try ctx.getCopy(cand.key)) orelse continue;
                            const vec = distance.bytesToF32(vec_bytes) orelse continue;
                            if (vec.len != query_vec.len) continue;
                            const raw_sim = computeExactSim(metric, query_vec, vec);
                            const score = applyDecay(raw_sim, cand.timestamp, decay, now_ms, decay_tau_hours);
                            final_heap.push(.{ .key = cand.key, .score = score, .timestamp = cand.timestamp });
                        }
                    }
                    return null;
                }
                // Fall through (empty namespace → brute-force).
            }
        }

        // Case 3: no params installed → legacy Hamming prefilter.
        if (!has_params) {
            const query_bq_size = distance.binaryQuantizedSize(query_vec.len);
            const query_bq = try ctx.allocator.alloc(u8, query_bq_size);
            distance.binaryQuantize(query_vec, query_bq);

            const stage1_size = top_k * STAGE1_OVERSAMPLE;
            const stage1_buf = try ctx.allocator.alloc(Candidate, stage1_size);
            var stage1_heap = TopKCandidate.init(stage1_buf);

            const bq_prefix = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ BQ_PREFIX, namespace });

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
            ctx.scanCallback(bq_prefix, @ptrCast(&bq_sc), onBQMatch);
            if (bq_sc.oom) return "vsearch: out of memory during BQ stage";

            if (bq_sc.saw_any > 0) {
                const candidates = stage1_heap.sortedDesc();
                for (candidates) |cand| {
                    const vec_bytes = (try ctx.getCopy(cand.key)) orelse continue;
                    const vec = distance.bytesToF32(vec_bytes) orelse continue;
                    if (vec.len != query_vec.len) continue;
                    const raw_sim = computeExactSim(metric, query_vec, vec);
                    const score = applyDecay(raw_sim, cand.timestamp, decay, now_ms, decay_tau_hours);
                    final_heap.push(.{ .key = cand.key, .score = score, .timestamp = cand.timestamp });
                }
                return null;
            }
            // Fall through to brute-force when no bq:* entries exist.
        }

        // All reachable BQ branches have either returned a result or
        // fallen through to brute-force below.
    }

    // ── Brute-force path (mode=exact or auto-fallback) ───────────
    var exact_sc = ExactScanCtx{
        .query_key = query_key,
        .query_vec = query_vec,
        .metric = metric,
        .decay = decay,
        .decay_tau_hours = decay_tau_hours,
        .now_ms = now_ms,
        .heap = final_heap,
        .allocator = ctx.allocator,
        .oom = false,
    };
    ctx.scanCallback(namespace, @ptrCast(&exact_sc), onExactMatch);
    if (exact_sc.oom) return "vsearch: out of memory during exact scan";

    return null;
}

// ╔═══════════════════════════════════════════════════╗
// ║  vsearch_local_raw — inline-query peer sub-search  ║
// ╚═══════════════════════════════════════════════════╝
//
// EXEC vsearch_local_raw <query_b64> <top_k> [namespace] [metric] [decay] [mode] [decay_tau_hours]
//
// Same search as `vsearch` but the query vector is passed INLINE as
// standard base64 of the raw little-endian f32 bytes — no key lookup.
// This is the peer-side half of `vsearch_cluster`'s scatter-gather: the
// coordinator holds the query vector; the queried peer may not have it
// stored under any key. Exposed to peers over the replication channel
// (see `isAllowedReplicationProcedure` in src/server/tcp.zig — org-
// authenticated when W2 enforcement is on) and never re-scatters, so
// there is no fan-out loop.
//
// Returns the same JSON array shape as `vsearch`:
//   [{"k":"vec:ns:id","s":0.95,"ts":1709...}, ...]

pub fn executeLocalRaw(ctx: *Ctx) anyerror!Ctx.Result {
    const query_b64 = ctx.arg(0) orelse
        return ctx.err("vsearch_local_raw requires at least 2 args: <query_b64> <top_k> [namespace] [metric] [decay] [mode] [decay_tau_hours]");

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

    // ── Decode the inline query vector (base64 of raw f32 LE bytes) ──
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(query_b64) catch
        return ctx.err("vsearch_local_raw: query is not valid base64");
    const decoded = try ctx.allocator.alloc(u8, decoded_len);
    decoder.decode(decoded, query_b64) catch
        return ctx.err("vsearch_local_raw: query is not valid base64");

    const query_vec = distance.bytesToF32(decoded) orelse
        return ctx.err("vsearch_local_raw: query is not a valid f32 vector (byte length must be a positive multiple of 4)");

    // ── Run the shared search core with no self-key exclusion ──
    // ("" never equals a stored key under a non-empty namespace prefix.)
    const final_buf = try ctx.allocator.alloc(Candidate, top_k);
    var final_heap = TopKCandidate.init(final_buf);

    if (try runSearch(ctx, "", query_vec, .{
        .top_k = top_k,
        .namespace = namespace,
        .metric = metric,
        .decay = decay,
        .mode = mode,
        .decay_tau_hours = decay_tau_hours,
    }, &final_heap)) |msg| return ctx.err(msg);

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
