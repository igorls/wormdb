//! Built-in VSEARCH_FILTERED procedure — in-DB HNSW search with companion
//! metadata filtering and optional field deduplication in one round-trip.
//!
//! EXEC vsearch_filtered <query_b64> <top_k> <namespace> <meta_prefix> [options_json]
//!
//! - query_b64:    base64-encoded raw little-endian f32 query vector
//! - top_k:        desired post-filter result count (1..500)
//! - namespace:    vector namespace prefix (e.g. "vec:fused:")
//! - meta_prefix:  companion JSON metadata prefix (e.g. "meta:"). For a vector
//!                 key `<namespace><id>`, metadata is looked up at `<meta_prefix><id>`.
//! - options_json: optional JSON object:
//!   {
//!     "metric": "cosine"|"dot"|"l2",
//!     "ef": 192,
//!     "oversample": 8,
//!     "eq": { "mediaType": "image", "clusterId": 4 },
//!     "neq": { "trashed": true },
//!     "prefix": { "relPath": "portraits/" },
//!     "min": { "sharpness": 35.0 },
//!     "max": { "nsfwScore": 0.4 },
//!     "dedup_field": "takeStackId",
//!     "include_meta": false
//!   }
//!
//! Returns JSON array sorted by descending score:
//!   [{"k":"vec:fused:123","s":0.9123,"ts":1709...}, ...]
//! (or with `"m":<raw_meta_json>` when `include_meta` is true).

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const Store = @import("../storage/store.zig").Store;
const distance = @import("../vector/distance.zig");
const hnsw_mod = @import("../vector/hnsw.zig");
const index_mod = @import("../vector/index.zig");
const metric_mod = @import("../vector/metric.zig");
const topk_mod = @import("../vector/topk.zig");

const Metric = metric_mod.Metric;
const NamespaceRegistry = index_mod.NamespaceRegistry;

pub const MAX_TOP_K: usize = 500;
const MAX_OVERSAMPLE_CANDIDATES: usize = 4000;
const STACK_QUERY_BYTES: usize = 6144; // covers up to d=1536 f32s on stack (16B aligned)
const STACK_CAND_CAP: usize = 256;
const STACK_PRED_CAP: usize = 16;
const STACK_META_CAP: usize = 4096;

const RawCandidate = struct {
    key: []u8,
    score: f32,
    timestamp: u64,
};

fn rawCandidateScore(c: RawCandidate) f32 {
    return c.score;
}

const TopKRaw = topk_mod.TopK(RawCandidate, rawCandidateScore);

const PredOp = enum {
    eq,
    neq,
    prefix,
    min,
    max,
};

const ExpectedVal = union(enum) {
    null_val,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    string_val: []const u8,
    /// Array/object in `eq`/`neq`: `eq` always fails; `neq` never rejects.
    unsupported,
};

const FilterPred = struct {
    field: []const u8,
    op: PredOp,
    val: ExpectedVal,
};

const CompiledFilters = struct {
    preds: []const FilterPred,
    required_mask: u64,
    pending_mask: u64,
    dedup_field: ?[]const u8,
    use_bitmask: bool,
};

const DedupVal = union(enum) {
    none,
    int: i64,
    str_stack: usize,
    str_heap: []u8,
};

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const query_b64 = ctx.arg(0) orelse return ctx.err("vsearch_filtered requires: <query_b64> <top_k> <namespace> <meta_prefix> [options_json]");
    const top_k_raw = ctx.argInt(usize, 1) orelse return ctx.err("vsearch_filtered: invalid top_k");
    const namespace = ctx.arg(2) orelse return ctx.err("vsearch_filtered: missing namespace");
    const meta_prefix = ctx.arg(3) orelse return ctx.err("vsearch_filtered: missing meta_prefix");
    const opts_raw = ctx.arg(4);

    if (top_k_raw == 0 or top_k_raw > MAX_TOP_K) {
        return ctx.err("vsearch_filtered: top_k must be between 1 and 500");
    }

    try ctx.requirePrefix(namespace, .read);
    if (meta_prefix.len > 0) {
        try ctx.requirePrefix(meta_prefix, .read);
    }

    // Decode base64 query vector into a 16B-aligned stack buffer when <= 6144B (d <= 1536).
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(query_b64) catch {
        return ctx.err("vsearch_filtered: invalid base64 query");
    };
    if (decoded_len == 0 or decoded_len % 4 != 0) {
        return ctx.err("vsearch_filtered: invalid query vector byte length");
    }
    var query_stack: [STACK_QUERY_BYTES]u8 align(16) = undefined;
    var query_heap: ?[]u8 = null;
    defer if (query_heap) |qh| ctx.allocator.free(qh);
    const query_bytes: []u8 = if (decoded_len <= query_stack.len)
        query_stack[0..decoded_len]
    else blk: {
        const buf = try ctx.allocator.alloc(u8, decoded_len);
        query_heap = buf;
        break :blk buf;
    };
    std.base64.standard.Decoder.decode(query_bytes, query_b64) catch {
        return ctx.err("vsearch_filtered: base64 decode failed");
    };
    const query_vec = distance.bytesToF32(query_bytes) orelse {
        return ctx.err("vsearch_filtered: invalid f32 query vector");
    };

    // Parse optional options_json once and compile predicates into a flat slice.
    var metric: Metric = .cosine;
    var ef_opt: ?usize = null;
    var oversample_mult: usize = 8;
    var dedup_field: ?[]const u8 = null;
    var include_meta = false;

    var parsed_opts: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_opts) |*p| p.deinit();

    var eq_obj: ?std.json.ObjectMap = null;
    var neq_obj: ?std.json.ObjectMap = null;
    var prefix_obj: ?std.json.ObjectMap = null;
    var min_obj: ?std.json.ObjectMap = null;
    var max_obj: ?std.json.ObjectMap = null;

    if (opts_raw) |raw| {
        if (raw.len > 0) {
            parsed_opts = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{}) catch {
                return ctx.err("vsearch_filtered: invalid options_json");
            };
            if (parsed_opts.?.value != .object) {
                return ctx.err("vsearch_filtered: options_json must be an object");
            }
            const root = parsed_opts.?.value.object;
            if (root.get("metric")) |mv| {
                if (mv == .string) {
                    metric = Metric.fromStr(mv.string) orelse return ctx.err("vsearch_filtered: unknown metric");
                }
            }
            if (root.get("ef")) |ev| {
                if (ev == .integer and ev.integer > 0) {
                    ef_opt = @intCast(ev.integer);
                }
            }
            if (root.get("oversample")) |ov| {
                if (ov == .integer and ov.integer >= 1) {
                    oversample_mult = @min(@as(usize, @intCast(ov.integer)), 64);
                }
            }
            if (root.get("dedup_field")) |dv| {
                if (dv == .string and dv.string.len > 0) {
                    dedup_field = dv.string;
                }
            }
            if (root.get("include_meta")) |iv| {
                if (iv == .bool) include_meta = iv.bool;
            }
            if (root.get("eq")) |v| if (v == .object) {
                eq_obj = v.object;
            };
            if (root.get("neq")) |v| if (v == .object) {
                neq_obj = v.object;
            };
            if (root.get("prefix")) |v| if (v == .object) {
                prefix_obj = v.object;
            };
            if (root.get("min")) |v| if (v == .object) {
                min_obj = v.object;
            };
            if (root.get("max")) |v| if (v == .object) {
                max_obj = v.object;
            };
        }
    }

    const has_filters = (eq_obj != null and eq_obj.?.count() > 0) or
        (neq_obj != null and neq_obj.?.count() > 0) or
        (prefix_obj != null and prefix_obj.?.count() > 0) or
        (min_obj != null and min_obj.?.count() > 0) or
        (max_obj != null and max_obj.?.count() > 0) or
        dedup_field != null;

    var pred_stack: [STACK_PRED_CAP]FilterPred = undefined;
    var pred_heap: std.ArrayListUnmanaged(FilterPred) = .empty;
    defer pred_heap.deinit(ctx.allocator);

    const compiled = try compileFilters(
        ctx.allocator,
        &pred_stack,
        &pred_heap,
        eq_obj,
        neq_obj,
        prefix_obj,
        min_obj,
        max_obj,
        dedup_field,
    );

    const raw_fetch_k = if (has_filters)
        @min(MAX_OVERSAMPLE_CANDIDATES, @max(top_k_raw * oversample_mult, 64))
    else
        top_k_raw;

    // Stage 1: Fetch candidate keys from HNSW (or bounded TopK exact scan fallback)
    // with NO shard locks nested inside ns_idx.lock.
    var cand_stack: [STACK_CAND_CAP]RawCandidate = undefined;
    var cand_heap: ?[]RawCandidate = null;
    defer if (cand_heap) |ch| ctx.allocator.free(ch);
    var cand_slice: []RawCandidate = &.{};
    defer for (cand_slice) |c| ctx.allocator.free(c.key);

    var used_hnsw = false;
    if (ctx.vector_registry) |reg| {
        if (reg.get(namespace)) |ns_idx| {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();

            if (ns_idx.metric == metric and ns_idx.liveCount() > 0) {
                if (ns_idx.dim) |d| {
                    if (d == query_vec.len) {
                        used_hnsw = true;
                        const k_clamped = @min(raw_fetch_k, ns_idx.liveCount());
                        const ef = @max(ef_opt orelse @max(k_clamped * 2, 128), k_clamped);

                        var idx_out_stack: [STACK_CAND_CAP]index_mod.IndexSearchResult = undefined;
                        var idx_out_heap: ?[]index_mod.IndexSearchResult = null;
                        defer if (idx_out_heap) |b| ctx.allocator.free(b);
                        const idx_out: []index_mod.IndexSearchResult = if (k_clamped <= idx_out_stack.len)
                            idx_out_stack[0..k_clamped]
                        else blk: {
                            const b = try ctx.allocator.alloc(index_mod.IndexSearchResult, k_clamped);
                            idx_out_heap = b;
                            break :blk b;
                        };

                        var scratch_stack: [STACK_CAND_CAP]hnsw_mod.SearchResult = undefined;
                        var scratch_heap: ?[]hnsw_mod.SearchResult = null;
                        defer if (scratch_heap) |b| ctx.allocator.free(b);
                        const hnsw_scratch: []hnsw_mod.SearchResult = if (k_clamped <= scratch_stack.len)
                            scratch_stack[0..k_clamped]
                        else blk: {
                            const b = try ctx.allocator.alloc(hnsw_mod.SearchResult, k_clamped);
                            scratch_heap = b;
                            break :blk b;
                        };

                        const found = try ns_idx.searchLocked(query_vec, k_clamped, ef, idx_out, hnsw_scratch);

                        const dst: []RawCandidate = if (found <= cand_stack.len)
                            cand_stack[0..found]
                        else blk: {
                            const b = try ctx.allocator.alloc(RawCandidate, found);
                            cand_heap = b;
                            break :blk b;
                        };

                        var filled: usize = 0;
                        errdefer for (dst[0..filled]) |c| ctx.allocator.free(c.key);
                        for (idx_out[0..found]) |r| {
                            dst[filled] = .{
                                .key = try ctx.allocator.dupe(u8, r.key),
                                .score = metric.distToScore(r.dist),
                                .timestamp = r.timestamp,
                            };
                            filled += 1;
                        }
                        cand_slice = dst[0..filled];
                    }
                }
            }
        }
    }

    // Fallback: bounded TopK brute-force scan with precomputed query norm for cosine.
    var bf_inv_q_norm: f32 = 0.0;
    var bf_dim_matched: usize = 0;
    if (!used_hnsw) {
        bf_inv_q_norm = if (metric == .cosine) blk: {
            const qn = distance.l2Norm(query_vec);
            if (qn > 0.0) {
                const inv = 1.0 / qn;
                break :blk if (std.math.isFinite(inv)) inv else 0.0;
            }
            break :blk 0.0;
        } else 0.0;

        const heap_buf: []RawCandidate = if (raw_fetch_k <= cand_stack.len)
            cand_stack[0..raw_fetch_k]
        else blk: {
            const b = try ctx.allocator.alloc(RawCandidate, raw_fetch_k);
            cand_heap = b;
            break :blk b;
        };
        var topk_heap = TopKRaw.init(heap_buf);
        errdefer for (topk_heap.buf[0..topk_heap.len()]) |c| ctx.allocator.free(c.key);

        const ScanCtx = struct {
            query: []align(1) const f32,
            inv_q_norm: f32,
            metric: Metric,
            allocator: std.mem.Allocator,
            heap: *TopKRaw,
            dim_matched: usize = 0,
            oom: bool = false,

            fn onEntry(raw: *anyopaque, key: []const u8, val: []const u8, ts: u64, _: bool) Store.ScanAction {
                const self: *@This() = @ptrCast(@alignCast(raw));
                const vec = distance.bytesToF32(val) orelse return .cont;
                if (vec.len != self.query.len) return .cont;
                const score: f32 = switch (self.metric) {
                    .cosine => distance.cosineWithQueryNorm(self.query, self.inv_q_norm, vec),
                    .dot => distance.dot(self.query, vec),
                    .l2 => 1.0 / (1.0 + distance.l2Squared(self.query, vec)),
                };
                if (std.math.isNan(score)) return .cont;
                self.dim_matched += 1;
                // Negated `>` rejects NaN as well as scores <= thresholdScore().
                if (!(score > self.heap.thresholdScore())) return .cont;
                const k_copy = self.allocator.dupe(u8, key) catch {
                    self.oom = true;
                    return .stop;
                };
                // When full, buf[0] is guaranteed to be evicted by `push`; free its key now
                // so we stay leak-free even under non-arena allocators.
                if (self.heap.len() == self.heap.capacity()) {
                    self.allocator.free(self.heap.buf[0].key);
                }
                self.heap.push(.{ .key = k_copy, .score = score, .timestamp = ts });
                return .cont;
            }
        };
        var sctx = ScanCtx{
            .query = query_vec,
            .inv_q_norm = bf_inv_q_norm,
            .metric = metric,
            .allocator = ctx.allocator,
            .heap = &topk_heap,
        };
        ctx.scanCallback(namespace, @ptrCast(&sctx), ScanCtx.onEntry);
        if (sctx.oom) return error.OutOfMemory;
        bf_dim_matched = sctx.dim_matched;
        cand_slice = topk_heap.sortedDesc();
    }

    // Stage 2: With HNSW lock released, stream-filter + dedup against companion metadata
    // keys in Store via zero-copy `ctx.readWithCallback`.
    // Reusable seen-flags buffer only when >63 predicates exceed the u64 bitmask.
    var seen_req_heap: ?[]bool = null;
    defer if (seen_req_heap) |s| ctx.allocator.free(s);
    if (!compiled.use_bitmask) {
        seen_req_heap = try ctx.allocator.alloc(bool, compiled.preds.len);
    }

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    const est_per_item: usize = if (include_meta) 256 else 72;
    const est_items = @min(top_k_raw, cand_slice.len);
    try json.ensureTotalCapacity(ctx.allocator, est_items * est_per_item + 2);
    try json.append(ctx.allocator, '[');

    const emitted = try emitFilteredCandidates(
        ctx,
        cand_slice,
        top_k_raw,
        namespace,
        meta_prefix,
        has_filters,
        compiled,
        seen_req_heap,
        include_meta,
        &json,
    );

    // Exact brute-force fallback: if brute-force Stage 1 was capped at `raw_fetch_k` and
    // selective filters or dedup left us short of `top_k_raw` while more vectors remain
    // in `namespace`, run an exact full-corpus filtered pass (no nested shard locks) so
    // brute-force NEVER drops valid matches.
    if (!used_hnsw and has_filters and emitted < top_k_raw and bf_dim_matched > raw_fetch_k and meta_prefix.len > 0) {
        json.clearRetainingCapacity();
        try json.append(ctx.allocator, '[');
        if (ctx.countKeys(meta_prefix) <= bf_dim_matched * 4 + 256) {
            try runExactBruteForceViaMetaPrefilter(
                ctx,
                query_vec,
                bf_inv_q_norm,
                metric,
                top_k_raw,
                namespace,
                meta_prefix,
                compiled,
                seen_req_heap,
                include_meta,
                &json,
            );
        } else {
            try runExactBruteForceViaNamespaceSort(
                ctx,
                query_vec,
                bf_inv_q_norm,
                metric,
                top_k_raw,
                namespace,
                meta_prefix,
                compiled,
                seen_req_heap,
                include_meta,
                &json,
            );
        }
    }

    try json.append(ctx.allocator, ']');
    return ctx.valueOwned(try json.toOwnedSlice(ctx.allocator));
}

fn emitCandidateJson(
    json: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    cand: RawCandidate,
    include_meta: bool,
    meta_slice: ?[]const u8,
    emitted: usize,
) !void {
    if (emitted > 0) try json.append(alloc, ',');
    try json.appendSlice(alloc, "{\"k\":\"");
    try appendJsonEscaped(json, alloc, cand.key);
    try json.appendSlice(alloc, "\",\"s\":");
    try appendScore6(json, alloc, cand.score);
    try json.appendSlice(alloc, ",\"ts\":");
    var ts_buf: [24]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{cand.timestamp}) catch "0";
    try json.appendSlice(alloc, ts_str);
    if (include_meta) {
        if (meta_slice) |mr| {
            try json.appendSlice(alloc, ",\"m\":");
            try json.appendSlice(alloc, mr);
        }
    }
    try json.append(alloc, '}');
}

fn emitFilteredCandidates(
    ctx: *Ctx,
    cand_slice: []const RawCandidate,
    top_k_raw: usize,
    namespace: []const u8,
    meta_prefix: []const u8,
    has_filters: bool,
    compiled: CompiledFilters,
    seen_req_heap: ?[]bool,
    include_meta: bool,
    json: *std.ArrayListUnmanaged(u8),
) !usize {
    var seen_dedup_int: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer seen_dedup_int.deinit(ctx.allocator);
    var seen_dedup_str: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen_dedup_str.keyIterator();
        while (it.next()) |k| ctx.allocator.free(k.*);
        seen_dedup_str.deinit(ctx.allocator);
    }

    var emitted: usize = 0;
    var meta_key_stack: [512]u8 = undefined;
    var meta_copy_stack: [STACK_META_CAP]u8 = undefined;
    var dedup_str_stack: [256]u8 = undefined;

    for (cand_slice) |cand| {
        if (emitted >= top_k_raw) break;

        var meta_slice: ?[]const u8 = null;
        var meta_heap_owned: ?[]u8 = null;
        defer if (meta_heap_owned) |mh| ctx.allocator.free(mh);

        if (has_filters or include_meta) {
            var meta_key_heap: ?[]u8 = null;
            defer if (meta_key_heap) |mkh| ctx.allocator.free(mkh);

            const meta_key_opt: ?[]const u8 = if (meta_prefix.len > 0 and std.mem.startsWith(u8, cand.key, namespace)) blk: {
                const suffix = cand.key[namespace.len..];
                const total_len = meta_prefix.len + suffix.len;
                if (total_len <= meta_key_stack.len) {
                    @memcpy(meta_key_stack[0..meta_prefix.len], meta_prefix);
                    @memcpy(meta_key_stack[meta_prefix.len..total_len], suffix);
                    break :blk meta_key_stack[0..total_len];
                }
                const hk = try ctx.allocator.alloc(u8, total_len);
                @memcpy(hk[0..meta_prefix.len], meta_prefix);
                @memcpy(hk[meta_prefix.len..total_len], suffix);
                meta_key_heap = hk;
                break :blk hk;
            } else null;

            if (has_filters) {
                const mk = meta_key_opt orelse continue;

                const ProbeCtx = struct {
                    filters: CompiledFilters,
                    include_meta: bool,
                    alloc: std.mem.Allocator,
                    seen_req: ?[]bool,
                    dedup_str_buf: []u8,
                    meta_copy_buf: []u8,
                    matched: bool = false,
                    dedup: DedupVal = .none,
                    meta_stack_len: usize = 0,
                    meta_heap: ?[]u8 = null,
                    oom: bool = false,

                    fn onMeta(self: *@This(), raw_m: []const u8) void {
                        const eval = evalMetaJson(
                            raw_m,
                            self.filters,
                            self.seen_req,
                            self.dedup_str_buf,
                            self.alloc,
                            self.include_meta,
                        );
                        if (eval.oom) {
                            self.oom = true;
                            return;
                        }
                        if (!eval.matched) return;
                        self.matched = true;
                        self.dedup = eval.dedup;

                        if (self.include_meta) {
                            if (raw_m.len <= self.meta_copy_buf.len) {
                                @memcpy(self.meta_copy_buf[0..raw_m.len], raw_m);
                                self.meta_stack_len = raw_m.len;
                            } else {
                                self.meta_heap = self.alloc.dupe(u8, raw_m) catch {
                                    self.oom = true;
                                    self.matched = false;
                                    return;
                                };
                            }
                        }
                    }
                };

                var probe = ProbeCtx{
                    .filters = compiled,
                    .include_meta = include_meta,
                    .alloc = ctx.allocator,
                    .seen_req = seen_req_heap,
                    .dedup_str_buf = &dedup_str_stack,
                    .meta_copy_buf = &meta_copy_stack,
                };
                defer if (probe.dedup == .str_heap) ctx.allocator.free(probe.dedup.str_heap);
                defer if (probe.meta_heap) |mh| ctx.allocator.free(mh);

                if (!ctx.readWithCallback(mk, &probe, ProbeCtx.onMeta)) continue;
                if (probe.oom) return error.OutOfMemory;
                if (!probe.matched) continue;

                // Apply deduplication after releasing the shard lock.
                switch (probe.dedup) {
                    .none => {},
                    .int => |iv| {
                        const gop = try seen_dedup_int.getOrPut(ctx.allocator, iv);
                        if (gop.found_existing) continue;
                    },
                    .str_stack => |slen| {
                        const s = dedup_str_stack[0..slen];
                        if (seen_dedup_str.contains(s)) continue;
                        const s_copy = try ctx.allocator.dupe(u8, s);
                        errdefer ctx.allocator.free(s_copy);
                        try seen_dedup_str.put(ctx.allocator, s_copy, {});
                    },
                    .str_heap => |hs| {
                        if (seen_dedup_str.contains(hs)) continue;
                        // Transfer ownership directly into seen_dedup_str.
                        try seen_dedup_str.put(ctx.allocator, hs, {});
                        probe.dedup = .none;
                    },
                }

                if (include_meta) {
                    if (probe.meta_heap) |mh| {
                        meta_heap_owned = mh;
                        meta_slice = mh;
                        probe.meta_heap = null;
                    } else {
                        meta_slice = meta_copy_stack[0..probe.meta_stack_len];
                    }
                }
            } else if (include_meta) {
                if (meta_key_opt) |mk| {
                    switch (ctx.getInto(mk, &meta_copy_stack)) {
                        .hit => |s| meta_slice = s,
                        .too_small => {
                            if (try ctx.getCopy(mk)) |s| {
                                meta_heap_owned = @constCast(s);
                                meta_slice = s;
                            }
                        },
                        .miss => {},
                    }
                }
            }
        }

        try emitCandidateJson(json, ctx.allocator, cand, include_meta, meta_slice, emitted);
        emitted += 1;
    }

    return emitted;
}

const StoredDedup = union(enum) {
    none,
    int: i64,
    str: []u8,
};

/// Exact two-pass brute-force filtered search (zero nested shard locks):
///   Pass 1: scan `meta_prefix` with zero-DOM `evalMetaJson` to collect matching
///           suffixes + extracted `dedup_field` values.
///   Pass 2: scan `namespace`, scoring ONLY vectors whose suffix matched Pass 1,
///           maintaining a bounded `TopK(top_k_raw)` for unstacked items and per-group
///           max-score maps for `dedup_field` items (provably exact top-K without an
///           O(N log N) sort or Stage-2 metadata re-parse).
fn runExactBruteForceViaMetaPrefilter(
    ctx: *Ctx,
    query_vec: []align(1) const f32,
    inv_q_norm: f32,
    metric: Metric,
    top_k_raw: usize,
    namespace: []const u8,
    meta_prefix: []const u8,
    compiled: CompiledFilters,
    seen_req_heap: ?[]bool,
    include_meta: bool,
    json: *std.ArrayListUnmanaged(u8),
) !void {
    const alloc = ctx.allocator;

    var matched_map: std.StringHashMapUnmanaged(StoredDedup) = .empty;
    defer {
        var it = matched_map.iterator();
        while (it.next()) |kv| {
            alloc.free(kv.key_ptr.*);
            if (kv.value_ptr.* == .str) alloc.free(kv.value_ptr.str);
        }
        matched_map.deinit(alloc);
    }

    var dedup_str_stack: [256]u8 = undefined;

    // Pass 1: stream-filter `meta_prefix` (only holds one shard lock at a time, no nested calls).
    const MetaScanCtx = struct {
        meta_prefix: []const u8,
        filters: CompiledFilters,
        seen_req: ?[]bool,
        dedup_str_buf: []u8,
        validate_full: bool,
        alloc: std.mem.Allocator,
        matched: *std.StringHashMapUnmanaged(StoredDedup),
        oom: bool = false,

        fn onMetaEntry(raw: *anyopaque, key: []const u8, val: []const u8, _: u64, _: bool) Store.ScanAction {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!std.mem.startsWith(u8, key, self.meta_prefix)) return .cont;
            const suffix = key[self.meta_prefix.len..];

            const eval = evalMetaJson(
                val,
                self.filters,
                self.seen_req,
                self.dedup_str_buf,
                self.alloc,
                self.validate_full,
            );
            if (eval.oom) {
                self.oom = true;
                return .stop;
            }
            if (!eval.matched) return .cont;

            const stored_dedup: StoredDedup = switch (eval.dedup) {
                .none => .none,
                .int => |iv| .{ .int = iv },
                .str_stack => |slen| .{ .str = self.alloc.dupe(u8, self.dedup_str_buf[0..slen]) catch {
                    self.oom = true;
                    return .stop;
                } },
                .str_heap => |hs| .{ .str = hs },
            };

            const suffix_copy = self.alloc.dupe(u8, suffix) catch {
                if (stored_dedup == .str) self.alloc.free(stored_dedup.str);
                self.oom = true;
                return .stop;
            };
            self.matched.put(self.alloc, suffix_copy, stored_dedup) catch {
                self.alloc.free(suffix_copy);
                if (stored_dedup == .str) self.alloc.free(stored_dedup.str);
                self.oom = true;
                return .stop;
            };
            return .cont;
        }
    };

    var mctx = MetaScanCtx{
        .meta_prefix = meta_prefix,
        .filters = compiled,
        .seen_req = seen_req_heap,
        .dedup_str_buf = &dedup_str_stack,
        .validate_full = include_meta,
        .alloc = alloc,
        .matched = &matched_map,
    };
    ctx.scanCallback(meta_prefix, @ptrCast(&mctx), MetaScanCtx.onMetaEntry);
    if (mctx.oom) return error.OutOfMemory;
    if (matched_map.count() == 0) return;

    // Pass 2: scan `namespace`, scoring ONLY matched suffixes into bounded TopK(top_k_raw)
    // plus per-group max-score maps when `dedup_field != null`.
    var win_stack: [STACK_CAND_CAP]RawCandidate = undefined;
    var win_heap: ?[]RawCandidate = null;
    defer if (win_heap) |wh| alloc.free(wh);
    const heap_buf: []RawCandidate = if (top_k_raw <= win_stack.len)
        win_stack[0..top_k_raw]
    else blk: {
        const b = try alloc.alloc(RawCandidate, top_k_raw);
        win_heap = b;
        break :blk b;
    };
    var topk_heap = TopKRaw.init(heap_buf);
    defer for (topk_heap.buf[0..topk_heap.len()]) |c| alloc.free(c.key);

    var best_int: std.AutoHashMapUnmanaged(i64, RawCandidate) = .empty;
    defer {
        var it = best_int.valueIterator();
        while (it.next()) |v| alloc.free(v.key);
        best_int.deinit(alloc);
    }
    // Keys borrow `.str` slices owned by `matched_map` (outlives `best_str`).
    var best_str: std.StringHashMapUnmanaged(RawCandidate) = .empty;
    defer {
        var it = best_str.valueIterator();
        while (it.next()) |v| alloc.free(v.key);
        best_str.deinit(alloc);
    }

    const VecScanCtx = struct {
        namespace: []const u8,
        query: []align(1) const f32,
        inv_q_norm: f32,
        metric: Metric,
        alloc: std.mem.Allocator,
        matched: *const std.StringHashMapUnmanaged(StoredDedup),
        heap: *TopKRaw,
        best_int: *std.AutoHashMapUnmanaged(i64, RawCandidate),
        best_str: *std.StringHashMapUnmanaged(RawCandidate),
        oom: bool = false,

        fn onVecEntry(raw: *anyopaque, key: []const u8, val: []const u8, ts: u64, _: bool) Store.ScanAction {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!std.mem.startsWith(u8, key, self.namespace)) return .cont;
            const suffix = key[self.namespace.len..];
            const dval = self.matched.get(suffix) orelse return .cont;

            const vec = distance.bytesToF32(val) orelse return .cont;
            if (vec.len != self.query.len) return .cont;
            const score: f32 = switch (self.metric) {
                .cosine => distance.cosineWithQueryNorm(self.query, self.inv_q_norm, vec),
                .dot => distance.dot(self.query, vec),
                .l2 => 1.0 / (1.0 + distance.l2Squared(self.query, vec)),
            };
            if (std.math.isNan(score)) return .cont;

            switch (dval) {
                .none => {
                    if (!(score > self.heap.thresholdScore())) return .cont;
                    const k_copy = self.alloc.dupe(u8, key) catch {
                        self.oom = true;
                        return .stop;
                    };
                    if (self.heap.len() == self.heap.capacity()) {
                        self.alloc.free(self.heap.buf[0].key);
                    }
                    self.heap.push(.{ .key = k_copy, .score = score, .timestamp = ts });
                },
                .int => |iv| {
                    const gop = self.best_int.getOrPut(self.alloc, iv) catch {
                        self.oom = true;
                        return .stop;
                    };
                    if (gop.found_existing) {
                        if (!(score > gop.value_ptr.score)) return .cont;
                        const k_copy = self.alloc.dupe(u8, key) catch {
                            self.oom = true;
                            return .stop;
                        };
                        self.alloc.free(gop.value_ptr.key);
                        gop.value_ptr.* = .{ .key = k_copy, .score = score, .timestamp = ts };
                    } else {
                        const k_copy = self.alloc.dupe(u8, key) catch {
                            _ = self.best_int.remove(iv);
                            self.oom = true;
                            return .stop;
                        };
                        gop.value_ptr.* = .{ .key = k_copy, .score = score, .timestamp = ts };
                    }
                },
                .str => |sv| {
                    const gop = self.best_str.getOrPut(self.alloc, sv) catch {
                        self.oom = true;
                        return .stop;
                    };
                    if (gop.found_existing) {
                        if (!(score > gop.value_ptr.score)) return .cont;
                        const k_copy = self.alloc.dupe(u8, key) catch {
                            self.oom = true;
                            return .stop;
                        };
                        self.alloc.free(gop.value_ptr.key);
                        gop.value_ptr.* = .{ .key = k_copy, .score = score, .timestamp = ts };
                    } else {
                        const k_copy = self.alloc.dupe(u8, key) catch {
                            _ = self.best_str.remove(sv);
                            self.oom = true;
                            return .stop;
                        };
                        gop.value_ptr.* = .{ .key = k_copy, .score = score, .timestamp = ts };
                    }
                },
            }
            return .cont;
        }
    };

    var vctx = VecScanCtx{
        .namespace = namespace,
        .query = query_vec,
        .inv_q_norm = inv_q_norm,
        .metric = metric,
        .alloc = alloc,
        .matched = &matched_map,
        .heap = &topk_heap,
        .best_int = &best_int,
        .best_str = &best_str,
    };
    ctx.scanCallback(namespace, @ptrCast(&vctx), VecScanCtx.onVecEntry);
    if (vctx.oom) return error.OutOfMemory;

    // Infallible merge of per-group dedup winners into the final TopK(top_k_raw) heap.
    {
        var it = best_int.valueIterator();
        while (it.next()) |cand_ptr| {
            const cand = cand_ptr.*;
            if (cand.score > topk_heap.thresholdScore()) {
                if (topk_heap.len() == topk_heap.capacity()) {
                    alloc.free(topk_heap.buf[0].key);
                }
                topk_heap.push(cand);
            } else {
                alloc.free(cand.key);
            }
        }
        best_int.clearRetainingCapacity();
    }
    {
        var it = best_str.valueIterator();
        while (it.next()) |cand_ptr| {
            const cand = cand_ptr.*;
            if (cand.score > topk_heap.thresholdScore()) {
                if (topk_heap.len() == topk_heap.capacity()) {
                    alloc.free(topk_heap.buf[0].key);
                }
                topk_heap.push(cand);
            } else {
                alloc.free(cand.key);
            }
        }
        best_str.clearRetainingCapacity();
    }

    const winners = topk_heap.sortedDesc();
    var meta_key_stack: [512]u8 = undefined;
    var meta_copy_stack: [STACK_META_CAP]u8 = undefined;

    for (winners, 0..) |cand, emitted| {
        var meta_slice: ?[]const u8 = null;
        var meta_heap_owned: ?[]u8 = null;
        defer if (meta_heap_owned) |mh| alloc.free(mh);

        if (include_meta and std.mem.startsWith(u8, cand.key, namespace)) {
            const suffix = cand.key[namespace.len..];
            const total_len = meta_prefix.len + suffix.len;
            var meta_key_heap: ?[]u8 = null;
            defer if (meta_key_heap) |mkh| alloc.free(mkh);

            const mk: []const u8 = if (total_len <= meta_key_stack.len) blk: {
                @memcpy(meta_key_stack[0..meta_prefix.len], meta_prefix);
                @memcpy(meta_key_stack[meta_prefix.len..total_len], suffix);
                break :blk meta_key_stack[0..total_len];
            } else blk: {
                const hk = try alloc.alloc(u8, total_len);
                @memcpy(hk[0..meta_prefix.len], meta_prefix);
                @memcpy(hk[meta_prefix.len..total_len], suffix);
                meta_key_heap = hk;
                break :blk hk;
            };

            switch (ctx.getInto(mk, &meta_copy_stack)) {
                .hit => |s| meta_slice = s,
                .too_small => {
                    if (try ctx.getCopy(mk)) |s| {
                        meta_heap_owned = @constCast(s);
                        meta_slice = s;
                    }
                },
                .miss => {},
            }
        }

        try emitCandidateJson(json, alloc, cand, include_meta, meta_slice, emitted);
    }
}

/// Alternate exact brute-force fallback used when `meta_prefix` is much larger than
/// `namespace`: collects and sorts all dim-matched vectors in `namespace`, then runs
/// the exact Stage-2 streaming filter until `top_k_raw` items are emitted.
fn runExactBruteForceViaNamespaceSort(
    ctx: *Ctx,
    query_vec: []align(1) const f32,
    inv_q_norm: f32,
    metric: Metric,
    top_k_raw: usize,
    namespace: []const u8,
    meta_prefix: []const u8,
    compiled: CompiledFilters,
    seen_req_heap: ?[]bool,
    include_meta: bool,
    json: *std.ArrayListUnmanaged(u8),
) !void {
    const alloc = ctx.allocator;
    var all_cands: std.ArrayListUnmanaged(RawCandidate) = .empty;
    defer {
        for (all_cands.items) |c| alloc.free(c.key);
        all_cands.deinit(alloc);
    }

    const FullScanCtx = struct {
        query: []align(1) const f32,
        inv_q_norm: f32,
        metric: Metric,
        alloc: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(RawCandidate),
        oom: bool = false,

        fn onEntry(raw: *anyopaque, key: []const u8, val: []const u8, ts: u64, _: bool) Store.ScanAction {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const vec = distance.bytesToF32(val) orelse return .cont;
            if (vec.len != self.query.len) return .cont;
            const score: f32 = switch (self.metric) {
                .cosine => distance.cosineWithQueryNorm(self.query, self.inv_q_norm, vec),
                .dot => distance.dot(self.query, vec),
                .l2 => 1.0 / (1.0 + distance.l2Squared(self.query, vec)),
            };
            if (std.math.isNan(score)) return .cont;
            const k_copy = self.alloc.dupe(u8, key) catch {
                self.oom = true;
                return .stop;
            };
            self.list.append(self.alloc, .{ .key = k_copy, .score = score, .timestamp = ts }) catch {
                self.alloc.free(k_copy);
                self.oom = true;
                return .stop;
            };
            return .cont;
        }
    };

    var fctx = FullScanCtx{
        .query = query_vec,
        .inv_q_norm = inv_q_norm,
        .metric = metric,
        .alloc = alloc,
        .list = &all_cands,
    };
    ctx.scanCallback(namespace, @ptrCast(&fctx), FullScanCtx.onEntry);
    if (fctx.oom) return error.OutOfMemory;

    std.sort.heap(RawCandidate, all_cands.items, {}, struct {
        fn desc(_: void, a: RawCandidate, b: RawCandidate) bool {
            return a.score > b.score;
        }
    }.desc);

    _ = try emitFilteredCandidates(
        ctx,
        all_cands.items,
        top_k_raw,
        namespace,
        meta_prefix,
        true,
        compiled,
        seen_req_heap,
        include_meta,
        json,
    );
}

fn jsonAsFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |iv| @floatFromInt(iv),
        .float => |fv| fv,
        else => null,
    };
}

fn toExpectedVal(v: std.json.Value) ExpectedVal {
    return switch (v) {
        .null => .null_val,
        .bool => |b| .{ .bool_val = b },
        .integer => |iv| .{ .int_val = iv },
        .float => |fv| .{ .float_val = fv },
        .string => |sv| .{ .string_val = sv },
        else => .unsupported,
    };
}

fn compileFilters(
    alloc: std.mem.Allocator,
    pred_stack: *[STACK_PRED_CAP]FilterPred,
    pred_heap: *std.ArrayListUnmanaged(FilterPred),
    eq_obj: ?std.json.ObjectMap,
    neq_obj: ?std.json.ObjectMap,
    prefix_obj: ?std.json.ObjectMap,
    min_obj: ?std.json.ObjectMap,
    max_obj: ?std.json.ObjectMap,
    dedup_field: ?[]const u8,
) !CompiledFilters {
    var upper_count: usize = 0;
    if (eq_obj) |o| upper_count += o.count();
    if (neq_obj) |o| upper_count += o.count();
    if (prefix_obj) |o| upper_count += o.count();
    if (min_obj) |o| upper_count += o.count();
    if (max_obj) |o| upper_count += o.count();

    const use_heap = upper_count > STACK_PRED_CAP;
    if (use_heap) {
        try pred_heap.ensureTotalCapacity(alloc, upper_count);
    }

    var count: usize = 0;
    const appendPred = struct {
        fn add(
            heap_mode: bool,
            stack_buf: *[STACK_PRED_CAP]FilterPred,
            heap_list: *std.ArrayListUnmanaged(FilterPred),
            n: *usize,
            p: FilterPred,
        ) void {
            if (heap_mode) {
                heap_list.appendAssumeCapacity(p);
            } else {
                stack_buf[n.*] = p;
            }
            n.* += 1;
        }
    }.add;

    if (eq_obj) |eq| {
        var it = eq.iterator();
        while (it.next()) |kv| {
            appendPred(use_heap, pred_stack, pred_heap, &count, .{
                .field = kv.key_ptr.*,
                .op = .eq,
                .val = toExpectedVal(kv.value_ptr.*),
            });
        }
    }
    if (neq_obj) |neq| {
        var it = neq.iterator();
        while (it.next()) |kv| {
            const ev = toExpectedVal(kv.value_ptr.*);
            if (ev == .unsupported) continue; // jsonValuesEqual(_, array/object) is always false -> neq never fails
            appendPred(use_heap, pred_stack, pred_heap, &count, .{
                .field = kv.key_ptr.*,
                .op = .neq,
                .val = ev,
            });
        }
    }
    if (prefix_obj) |pref| {
        var it = pref.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .string) continue;
            appendPred(use_heap, pred_stack, pred_heap, &count, .{
                .field = kv.key_ptr.*,
                .op = .prefix,
                .val = .{ .string_val = kv.value_ptr.string },
            });
        }
    }
    if (min_obj) |mn| {
        var it = mn.iterator();
        while (it.next()) |kv| {
            const bound = jsonAsFloat(kv.value_ptr.*) orelse continue;
            appendPred(use_heap, pred_stack, pred_heap, &count, .{
                .field = kv.key_ptr.*,
                .op = .min,
                .val = .{ .float_val = bound },
            });
        }
    }
    if (max_obj) |mx| {
        var it = mx.iterator();
        while (it.next()) |kv| {
            const bound = jsonAsFloat(kv.value_ptr.*) orelse continue;
            appendPred(use_heap, pred_stack, pred_heap, &count, .{
                .field = kv.key_ptr.*,
                .op = .max,
                .val = .{ .float_val = bound },
            });
        }
    }

    const preds: []const FilterPred = if (use_heap) pred_heap.items else pred_stack[0..count];
    const use_bitmask = preds.len <= 63;
    var required_mask: u64 = 0;
    var pending_mask: u64 = 0;
    if (use_bitmask) {
        for (preds, 0..) |p, i| {
            const bit = @as(u64, 1) << @as(u6, @intCast(i));
            pending_mask |= bit;
            if (p.op != .neq) required_mask |= bit;
        }
        if (dedup_field != null) {
            pending_mask |= (@as(u64, 1) << 63);
        }
    }

    return .{
        .preds = preds,
        .required_mask = required_mask,
        .pending_mask = pending_mask,
        .dedup_field = dedup_field,
        .use_bitmask = use_bitmask,
    };
}

const TokenSlice = struct {
    slice: []const u8,
    heap_owned: bool,
};

const ScanFieldError = error{
    EndOfObject,
    InvalidJson,
    OutOfMemory,
};

/// Read the next object key string (or report `EndOfObject`). Fast path returns a
/// zero-copy slice into the scanner input when the key contains no JSON escapes.
fn nextObjectKey(
    scanner: *std.json.Scanner,
    unesc_buf: []u8,
    fallback_alloc: std.mem.Allocator,
) ScanFieldError!TokenSlice {
    const first = scanner.next() catch return error.InvalidJson;
    switch (first) {
        .object_end => return error.EndOfObject,
        .string => |s| return .{ .slice = s, .heap_owned = false },
        .partial_string,
        .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4,
        => return finishEscapedString(scanner, first, unesc_buf, fallback_alloc),
        else => return error.InvalidJson,
    }
}

/// Read a string value token (fast zero-copy slice when unescaped; stack-unescaped
/// into `unesc_buf` or heap-allocated if longer when escaped).
fn nextStringValue(
    scanner: *std.json.Scanner,
    unesc_buf: []u8,
    fallback_alloc: std.mem.Allocator,
) ScanFieldError!TokenSlice {
    const first = scanner.next() catch return error.InvalidJson;
    switch (first) {
        .string => |s| return .{ .slice = s, .heap_owned = false },
        .partial_string,
        .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4,
        => return finishEscapedString(scanner, first, unesc_buf, fallback_alloc),
        else => return error.InvalidJson,
    }
}

fn finishEscapedString(
    scanner: *std.json.Scanner,
    first_tok: std.json.Token,
    unesc_buf: []u8,
    fallback_alloc: std.mem.Allocator,
) ScanFieldError!TokenSlice {
    var stack_len: usize = 0;
    var heap_list: std.ArrayListUnmanaged(u8) = .empty;
    var using_heap = false;
    errdefer if (using_heap) heap_list.deinit(fallback_alloc);

    const appendChunk = struct {
        fn call(
            chunk: []const u8,
            buf: []u8,
            slen: *usize,
            list: *std.ArrayListUnmanaged(u8),
            in_heap: *bool,
            alloc: std.mem.Allocator,
        ) error{OutOfMemory}!void {
            if (!in_heap.*) {
                if (slen.* + chunk.len <= buf.len) {
                    @memcpy(buf[slen.*..][0..chunk.len], chunk);
                    slen.* += chunk.len;
                    return;
                }
                try list.ensureTotalCapacity(alloc, slen.* + chunk.len);
                list.appendSliceAssumeCapacity(buf[0..slen.*]);
                in_heap.* = true;
            }
            try list.appendSlice(alloc, chunk);
        }
    }.call;

    var tok = first_tok;
    while (true) {
        switch (tok) {
            .partial_string => |s| try appendChunk(s, unesc_buf, &stack_len, &heap_list, &using_heap, fallback_alloc),
            .partial_string_escaped_1 => |b| try appendChunk(b[0..], unesc_buf, &stack_len, &heap_list, &using_heap, fallback_alloc),
            .partial_string_escaped_2 => |b| try appendChunk(b[0..], unesc_buf, &stack_len, &heap_list, &using_heap, fallback_alloc),
            .partial_string_escaped_3 => |b| try appendChunk(b[0..], unesc_buf, &stack_len, &heap_list, &using_heap, fallback_alloc),
            .partial_string_escaped_4 => |b| try appendChunk(b[0..], unesc_buf, &stack_len, &heap_list, &using_heap, fallback_alloc),
            .string => |s| {
                try appendChunk(s, unesc_buf, &stack_len, &heap_list, &using_heap, fallback_alloc);
                if (using_heap) {
                    return .{ .slice = try heap_list.toOwnedSlice(fallback_alloc), .heap_owned = true };
                }
                return .{ .slice = unesc_buf[0..stack_len], .heap_owned = false };
            },
            else => return error.InvalidJson,
        }
        tok = scanner.next() catch return error.InvalidJson;
    }
}

fn nextNumberSlice(
    scanner: *std.json.Scanner,
    num_buf: []u8,
    fallback_alloc: std.mem.Allocator,
) ScanFieldError!TokenSlice {
    const first = scanner.next() catch return error.InvalidJson;
    switch (first) {
        .number => |s| return .{ .slice = s, .heap_owned = false },
        .partial_number => |s| {
            var stack_len: usize = 0;
            var heap_list: std.ArrayListUnmanaged(u8) = .empty;
            var using_heap = false;
            errdefer if (using_heap) heap_list.deinit(fallback_alloc);

            var tok: std.json.Token = .{ .partial_number = s };
            while (true) {
                const chunk = switch (tok) {
                    .partial_number => |p| p,
                    .number => |p| p,
                    else => return error.InvalidJson,
                };
                if (!using_heap) {
                    if (stack_len + chunk.len <= num_buf.len) {
                        @memcpy(num_buf[stack_len..][0..chunk.len], chunk);
                        stack_len += chunk.len;
                    } else {
                        try heap_list.ensureTotalCapacity(fallback_alloc, stack_len + chunk.len);
                        heap_list.appendSliceAssumeCapacity(num_buf[0..stack_len]);
                        try heap_list.appendSlice(fallback_alloc, chunk);
                        using_heap = true;
                    }
                } else {
                    try heap_list.appendSlice(fallback_alloc, chunk);
                }
                if (tok == .number) {
                    if (using_heap) {
                        return .{ .slice = try heap_list.toOwnedSlice(fallback_alloc), .heap_owned = true };
                    }
                    return .{ .slice = num_buf[0..stack_len], .heap_owned = false };
                }
                tok = scanner.next() catch return error.InvalidJson;
            }
        },
        else => return error.InvalidJson,
    }
}

const EvalOutcome = struct {
    matched: bool = false,
    dedup: DedupVal = .none,
    oom: bool = false,
};

/// Single-pass zero-DOM metadata filter over a top-level JSON object.
/// Uses a stack-backed `FixedBufferAllocator` for `std.json.Scanner`'s container
/// bitstack (0 heap allocs for nesting depth <= ~2000), short-circuits on the
/// first failed predicate, and skips unreferenced fields via `scanner.skipValue`.
fn evalMetaJson(
    raw_json: []const u8,
    filters: CompiledFilters,
    seen_req_opt: ?[]bool,
    dedup_str_buf: []u8,
    fallback_alloc: std.mem.Allocator,
    validate_full_object: bool,
) EvalOutcome {
    var stack_mem: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_mem);
    return evalMetaJsonWithAlloc(
        raw_json,
        filters,
        seen_req_opt,
        dedup_str_buf,
        fba.allocator(),
        fallback_alloc,
        validate_full_object,
    ) catch |err| switch (err) {
        error.BitStackOverflow => evalMetaJsonWithAlloc(
            raw_json,
            filters,
            seen_req_opt,
            dedup_str_buf,
            fallback_alloc,
            fallback_alloc,
            validate_full_object,
        ) catch return .{ .oom = true },
        error.OutOfMemory => return .{ .oom = true },
    };
}

fn evalMetaJsonWithAlloc(
    raw_json: []const u8,
    filters: CompiledFilters,
    seen_req_opt: ?[]bool,
    dedup_str_buf: []u8,
    scanner_alloc: std.mem.Allocator,
    fallback_alloc: std.mem.Allocator,
    validate_full_object: bool,
) error{ BitStackOverflow, OutOfMemory }!EvalOutcome {
    var out = EvalOutcome{};
    defer if (!out.matched and out.dedup == .str_heap) {
        fallback_alloc.free(out.dedup.str_heap);
        out.dedup = .none;
    };

    var scanner = std.json.Scanner.initCompleteInput(scanner_alloc, raw_json);
    defer scanner.deinit();

    const first = scanner.next() catch |err| switch (err) {
        error.OutOfMemory => return error.BitStackOverflow,
        else => return out,
    };
    if (first != .object_begin) return out;

    var required_mask = filters.required_mask;
    var pending_mask = filters.pending_mask;
    if (seen_req_opt) |sr| {
        @memset(sr, false);
    }

    var key_unesc_buf: [256]u8 = undefined;
    var val_unesc_buf: [512]u8 = undefined;
    const preds = filters.preds;

    while (true) {
        const key_tok = nextObjectKey(&scanner, &key_unesc_buf, fallback_alloc) catch |err| switch (err) {
            error.EndOfObject => break,
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => return out,
        };
        defer if (key_tok.heap_owned) fallback_alloc.free(key_tok.slice);
        const field_name = key_tok.slice;

        var wants_field = false;
        for (preds) |p| {
            if (std.mem.eql(u8, p.field, field_name)) {
                wants_field = true;
                break;
            }
        }
        const is_dedup = if (filters.dedup_field) |df| std.mem.eql(u8, df, field_name) else false;

        if (!wants_field and !is_dedup) {
            scanner.skipValue() catch |err| switch (err) {
                error.OutOfMemory => return error.BitStackOverflow,
                else => return out,
            };
            continue;
        }

        const vtype = scanner.peekNextTokenType() catch return out;
        switch (vtype) {
            .null => {
                _ = scanner.next() catch return out;
                if (!evalPredsOnSimple(preds, field_name, .null_val, filters.use_bitmask, &required_mask, &pending_mask, seen_req_opt)) {
                    return out;
                }
                if (is_dedup) {
                    if (out.dedup == .str_heap) fallback_alloc.free(out.dedup.str_heap);
                    out.dedup = .none;
                    if (filters.use_bitmask) pending_mask &= ~(@as(u64, 1) << 63);
                }
            },
            .true, .false => {
                const tok = scanner.next() catch return out;
                const bval = (tok == .true);
                if (!evalPredsOnSimple(preds, field_name, .{ .bool_val = bval }, filters.use_bitmask, &required_mask, &pending_mask, seen_req_opt)) {
                    return out;
                }
                if (is_dedup) {
                    if (out.dedup == .str_heap) fallback_alloc.free(out.dedup.str_heap);
                    out.dedup = .none;
                    if (filters.use_bitmask) pending_mask &= ~(@as(u64, 1) << 63);
                }
            },
            .number => {
                const num_tok = nextNumberSlice(&scanner, &val_unesc_buf, fallback_alloc) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return out,
                };
                defer if (num_tok.heap_owned) fallback_alloc.free(num_tok.slice);

                const parsed_i = std.fmt.parseInt(i64, num_tok.slice, 10) catch null;
                const parsed_f: f64 = if (parsed_i) |iv|
                    @floatFromInt(iv)
                else
                    std.fmt.parseFloat(f64, num_tok.slice) catch return out;

                if (!evalPredsOnNumber(preds, field_name, parsed_i, parsed_f, filters.use_bitmask, &required_mask, &pending_mask, seen_req_opt)) {
                    return out;
                }
                if (is_dedup) {
                    if (out.dedup == .str_heap) fallback_alloc.free(out.dedup.str_heap);
                    if (parsed_i) |iv| {
                        out.dedup = if (iv != 0) .{ .int = iv } else .none;
                    } else {
                        out.dedup = .none;
                    }
                    if (filters.use_bitmask) pending_mask &= ~(@as(u64, 1) << 63);
                }
            },
            .string => {
                const str_tok = nextStringValue(&scanner, &val_unesc_buf, fallback_alloc) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return out,
                };
                defer if (str_tok.heap_owned) fallback_alloc.free(str_tok.slice);

                if (!evalPredsOnString(preds, field_name, str_tok.slice, filters.use_bitmask, &required_mask, &pending_mask, seen_req_opt)) {
                    return out;
                }
                if (is_dedup) {
                    if (out.dedup == .str_heap) fallback_alloc.free(out.dedup.str_heap);
                    if (str_tok.slice.len == 0) {
                        out.dedup = .none;
                    } else if (str_tok.slice.len <= dedup_str_buf.len) {
                        @memcpy(dedup_str_buf[0..str_tok.slice.len], str_tok.slice);
                        out.dedup = .{ .str_stack = str_tok.slice.len };
                    } else {
                        out.dedup = .{ .str_heap = try fallback_alloc.dupe(u8, str_tok.slice) };
                    }
                    if (filters.use_bitmask) pending_mask &= ~(@as(u64, 1) << 63);
                }
            },
            .object_begin, .array_begin => {
                scanner.skipValue() catch |err| switch (err) {
                    error.OutOfMemory => return error.BitStackOverflow,
                    else => return out,
                };
                if (!evalPredsOnSimple(preds, field_name, .unsupported, filters.use_bitmask, &required_mask, &pending_mask, seen_req_opt)) {
                    return out;
                }
                if (is_dedup) {
                    if (out.dedup == .str_heap) fallback_alloc.free(out.dedup.str_heap);
                    out.dedup = .none;
                    if (filters.use_bitmask) pending_mask &= ~(@as(u64, 1) << 63);
                }
            },
            else => return out,
        }

        if (!validate_full_object and filters.use_bitmask and pending_mask == 0) {
            out.matched = true;
            return out;
        }
    }

    if (validate_full_object) {
        // Ensure no trailing garbage after the root JSON object when raw metadata will be embedded.
        const end_tok = scanner.next() catch return out;
        if (end_tok != .end_of_document) return out;
    }

    if (filters.use_bitmask) {
        out.matched = (required_mask == 0);
    } else {
        const sr = seen_req_opt.?;
        var all_met = true;
        for (preds, 0..) |p, i| {
            if (p.op != .neq and !sr[i]) {
                all_met = false;
                break;
            }
        }
        out.matched = all_met;
    }
    return out;
}

inline fn markPredSatisfied(
    i: usize,
    use_bitmask: bool,
    required_mask: *u64,
    pending_mask: *u64,
    seen_req: ?[]bool,
) void {
    if (use_bitmask) {
        const bit = @as(u64, 1) << @as(u6, @intCast(i));
        required_mask.* &= ~bit;
        pending_mask.* &= ~bit;
    } else {
        seen_req.?[i] = true;
    }
}

fn evalPredsOnSimple(
    preds: []const FilterPred,
    field: []const u8,
    actual: ExpectedVal,
    use_bitmask: bool,
    required_mask: *u64,
    pending_mask: *u64,
    seen_req: ?[]bool,
) bool {
    for (preds, 0..) |p, i| {
        if (!std.mem.eql(u8, p.field, field)) continue;
        switch (p.op) {
            .eq => {
                const eq_ok = switch (actual) {
                    .null_val => p.val == .null_val,
                    .bool_val => |ab| p.val == .bool_val and p.val.bool_val == ab,
                    else => false,
                };
                if (!eq_ok) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .neq => {
                const eq_hit = switch (actual) {
                    .null_val => p.val == .null_val,
                    .bool_val => |ab| p.val == .bool_val and p.val.bool_val == ab,
                    else => false,
                };
                if (eq_hit) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .prefix, .min, .max => return false,
        }
    }
    return true;
}

fn evalPredsOnNumber(
    preds: []const FilterPred,
    field: []const u8,
    actual_i: ?i64,
    actual_f: f64,
    use_bitmask: bool,
    required_mask: *u64,
    pending_mask: *u64,
    seen_req: ?[]bool,
) bool {
    for (preds, 0..) |p, i| {
        if (!std.mem.eql(u8, p.field, field)) continue;
        switch (p.op) {
            .eq => {
                const eq_ok = switch (p.val) {
                    .int_val => |ev| if (actual_i) |ai| ai == ev else @as(f64, @floatFromInt(ev)) == actual_f,
                    .float_val => |ev| ev == actual_f,
                    else => false,
                };
                if (!eq_ok) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .neq => {
                const eq_hit = switch (p.val) {
                    .int_val => |ev| if (actual_i) |ai| ai == ev else @as(f64, @floatFromInt(ev)) == actual_f,
                    .float_val => |ev| ev == actual_f,
                    else => false,
                };
                if (eq_hit) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .min => {
                if (actual_f < p.val.float_val) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .max => {
                if (actual_f > p.val.float_val) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .prefix => return false,
        }
    }
    return true;
}

fn evalPredsOnString(
    preds: []const FilterPred,
    field: []const u8,
    actual_s: []const u8,
    use_bitmask: bool,
    required_mask: *u64,
    pending_mask: *u64,
    seen_req: ?[]bool,
) bool {
    for (preds, 0..) |p, i| {
        if (!std.mem.eql(u8, p.field, field)) continue;
        switch (p.op) {
            .eq => {
                if (p.val != .string_val or !std.mem.eql(u8, actual_s, p.val.string_val)) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .neq => {
                if (p.val == .string_val and std.mem.eql(u8, actual_s, p.val.string_val)) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .prefix => {
                if (!std.mem.startsWith(u8, actual_s, p.val.string_val)) return false;
                markPredSatisfied(i, use_bitmask, required_mask, pending_mask, seen_req);
            },
            .min, .max => return false,
        }
    }
    return true;
}

/// Fast 6-decimal fixed-point formatter for normal finite scores (`|s| <= 1e6`),
/// falling back to `std.fmt.bufPrint` for extreme magnitudes or non-finite values.
fn appendScore6(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, score: f32) !void {
    if (std.math.isFinite(score) and @abs(score) <= 1_000_000.0) {
        const neg = score < 0.0;
        const abs_val: f64 = @abs(@as(f64, score));
        const scaled: u64 = @intFromFloat(@round(abs_val * 1_000_000.0));
        const int_part = scaled / 1_000_000;
        var frac_part = scaled % 1_000_000;

        var buf: [32]u8 = undefined;
        var pos: usize = 0;
        if (neg and scaled != 0) {
            buf[pos] = '-';
            pos += 1;
        }
        // Write integer part
        var int_digits: [16]u8 = undefined;
        var int_len: usize = 0;
        var v = int_part;
        while (true) {
            int_digits[int_len] = @as(u8, @intCast(v % 10)) + '0';
            int_len += 1;
            v /= 10;
            if (v == 0) break;
        }
        while (int_len > 0) {
            int_len -= 1;
            buf[pos] = int_digits[int_len];
            pos += 1;
        }
        buf[pos] = '.';
        pos += 1;
        // Write 6 fractional digits
        var fi: usize = 6;
        while (fi > 0) {
            fi -= 1;
            buf[pos + fi] = @as(u8, @intCast(frac_part % 10)) + '0';
            frac_part /= 10;
        }
        pos += 6;
        try list.appendSlice(alloc, buf[0..pos]);
        return;
    }

    var score_buf: [32]u8 = undefined;
    const score_str = std.fmt.bufPrint(&score_buf, "{d:.6}", .{score}) catch "0";
    try list.appendSlice(alloc, score_str);
}

fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    var chunk_start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 0x20) "" else null,
        };
        if (esc) |e| {
            if (i > chunk_start) try list.appendSlice(alloc, s[chunk_start..i]);
            if (e.len > 0) {
                try list.appendSlice(alloc, e);
            } else {
                const hex = "0123456789abcdef";
                const u_esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try list.appendSlice(alloc, &u_esc);
            }
            chunk_start = i + 1;
        }
    }
    if (chunk_start < s.len) try list.appendSlice(alloc, s[chunk_start..]);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

fn testEncodeVecB64(alloc: std.mem.Allocator, vec: []const f32) ![]u8 {
    const q_bytes = std.mem.sliceAsBytes(vec);
    const b64_len = std.base64.standard.Encoder.calcSize(q_bytes.len);
    const q_b64 = try alloc.alloc(u8, b64_len);
    _ = std.base64.standard.Encoder.encode(q_b64, q_bytes);
    return q_b64;
}

test "vsearch_filtered filters metadata and deduplicates stacks in one call" {
    const testing = std.testing;
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();
    var store = try Store.initWithRegistry(testing.allocator, .{ .persistence = .none }, &reg);
    defer store.deinit();

    const v1 = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const v2 = [_]f32{ 0.99, 0.14, 0.0, 0.0 };
    const v3 = [_]f32{ 0.95, 0.31, 0.0, 0.0 };
    const v4 = [_]f32{ 0.90, 0.43, 0.0, 0.0 };

    const ns_idx = try reg.getOrCreate("vec:vis:", .cosine);
    ns_idx.lock.lock();
    _ = try ns_idx.insertLocked("vec:vis:1", &v1, 100);
    _ = try ns_idx.insertLocked("vec:vis:2", &v2, 101);
    _ = try ns_idx.insertLocked("vec:vis:3", &v3, 102);
    _ = try ns_idx.insertLocked("vec:vis:4", &v4, 103);
    ns_idx.lock.unlock();

    // Item 1 is trashed, item 2 & 3 share stack 7, item 4 is unstacked (stack 0).
    try store.set("meta:1", "{\"mediaType\":\"image\",\"trashed\":true,\"takeStackId\":0,\"sharpness\":90}", false);
    try store.set("meta:2", "{\"mediaType\":\"image\",\"trashed\":false,\"takeStackId\":7,\"sharpness\":80}", false);
    try store.set("meta:3", "{\"mediaType\":\"image\",\"trashed\":false,\"takeStackId\":7,\"sharpness\":75}", false);
    try store.set("meta:4", "{\"mediaType\":\"image\",\"trashed\":false,\"takeStackId\":0,\"sharpness\":60}", false);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const q_b64 = try testEncodeVecB64(alloc, &v1);

    const opts = "{\"eq\":{\"mediaType\":\"image\"},\"neq\":{\"trashed\":true},\"min\":{\"sharpness\":50},\"dedup_field\":\"takeStackId\"}";
    const args = &[_][]const u8{ q_b64, "5", "vec:vis:", "meta:", opts };
    var ctx = Ctx.init(&store, args, alloc, null, null, null, &reg);
    defer ctx.deinit();

    const res = try execute(&ctx);
    const out = res.value.?;
    // Item 1 excluded (trashed), item 3 excluded (duplicate stack 7 after item 2). Only 2 and 4 remain!
    try testing.expect(std.mem.indexOf(u8, out, "\"vec:vis:1\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"vec:vis:2\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"vec:vis:3\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"vec:vis:4\"") != null);
}

test "vsearch_filtered brute-force fallback matches HNSW with prefix, max, neq, include_meta, and dedup" {
    const testing = std.testing;
    var reg = NamespaceRegistry.init(testing.allocator, .{ .m = 8, .ef_construction = 64 });
    defer reg.deinit();
    var store = try Store.initWithRegistry(testing.allocator, .{ .persistence = .none }, &reg);
    defer store.deinit();

    const vecs = [_][4]f32{
        .{ 1.00, 0.00, 0.00, 0.00 }, // 1: trashed=true -> excluded by neq
        .{ 0.99, 0.10, 0.00, 0.00 }, // 2: matches all, stack="stkA" -> PASS #1
        .{ 0.98, 0.15, 0.00, 0.00 }, // 3: matches all, stack="stkA" -> excluded by string dedup
        .{ 0.96, 0.25, 0.00, 0.00 }, // 4: nsfwScore=0.90 -> excluded by max
        .{ 0.94, 0.30, 0.00, 0.00 }, // 5: relPath="landscapes/a.jpg" -> excluded by prefix
        .{ 0.92, 0.35, 0.00, 0.00 }, // 6: trashed missing (neq passes!), stack="" (not deduped) -> PASS #2
        .{ 0.88, 0.45, 0.00, 0.00 }, // 7: stack=null (not deduped), escaped string field -> PASS #3
        .{ 0.80, 0.55, 0.00, 0.00 }, // 8: malformed JSON -> skipped safely
        .{ 0.75, 0.60, 0.00, 0.00 }, // 9: non-object JSON array -> skipped safely
        .{ 0.70, 0.70, 0.00, 0.00 }, // 10: stack=false (not deduped), nested obj/arr skipped -> PASS #4
    };
    const metas = [_][]const u8{
        "{\"mediaType\":\"image\",\"trashed\":true,\"relPath\":\"portraits/1.jpg\",\"sharpness\":80,\"nsfwScore\":0.1,\"stack\":\"stk1\"}",
        "{\"mediaType\":\"image\",\"trashed\":false,\"relPath\":\"portraits/2.jpg\",\"sharpness\":70.5,\"nsfwScore\":0.2,\"stack\":\"stkA\"}",
        "{\"mediaType\":\"image\",\"trashed\":false,\"relPath\":\"portraits/3.jpg\",\"sharpness\":70,\"nsfwScore\":0.2,\"stack\":\"stkA\"}",
        "{\"mediaType\":\"image\",\"trashed\":false,\"relPath\":\"portraits/4.jpg\",\"sharpness\":90,\"nsfwScore\":0.9,\"stack\":\"stk4\"}",
        "{\"mediaType\":\"image\",\"trashed\":false,\"relPath\":\"landscapes/5.jpg\",\"sharpness\":90,\"nsfwScore\":0.1,\"stack\":\"stk5\"}",
        "{\"mediaType\":\"image\",\"relPath\":\"portraits/6.jpg\",\"sharpness\":55,\"nsfwScore\":0.4,\"stack\":\"\"}",
        "{\"mediaType\":\"image\",\"trashed\":false,\"relPath\":\"portraits\\/7.jpg\",\"sharpness\":60,\"nsfwScore\":0.3,\"stack\":null}",
        "{not valid json",
        "[1,2,3]",
        "{\"extra\":{\"nested\":[1,2,{\"x\":true}]},\"mediaType\":\"image\",\"trashed\":false,\"relPath\":\"portraits/10.jpg\",\"sharpness\":50,\"nsfwScore\":0.4,\"stack\":false}",
    };

    const ns_idx = try reg.getOrCreate("vec:hnsw:", .cosine);
    for (vecs, 0..) |v, i| {
        const id = i + 1;
        var k_hnsw: [32]u8 = undefined;
        var k_bf: [32]u8 = undefined;
        var k_meta: [32]u8 = undefined;
        const kh = try std.fmt.bufPrint(&k_hnsw, "vec:hnsw:{d}", .{id});
        const kb = try std.fmt.bufPrint(&k_bf, "vec:bf:{d}", .{id});
        const km = try std.fmt.bufPrint(&k_meta, "meta:{d}", .{id});
        const vbytes = std.mem.sliceAsBytes(&v);

        try store.setWithTimestampNoVectorSync(kh, vbytes, false, 1000 + id);
        ns_idx.lock.lock();
        _ = try ns_idx.insertLocked(kh, &v, 1000 + id);
        ns_idx.lock.unlock();

        try store.setWithTimestampNoVectorSync(kb, vbytes, false, 1000 + id);
        try store.setWithTimestampNoVectorSync(km, metas[i], false, 1000 + id);
    }

    // Use testing.allocator DIRECTLY (not an arena) to prove zero memory leaks!
    const q_b64 = try testEncodeVecB64(testing.allocator, &vecs[0]);
    defer testing.allocator.free(q_b64);

    const opts =
        "{\"metric\":\"cosine\",\"ef\":64,\"oversample\":16," ++
        "\"eq\":{\"mediaType\":\"image\"}," ++
        "\"neq\":{\"trashed\":true}," ++
        "\"prefix\":{\"relPath\":\"portraits/\"}," ++
        "\"min\":{\"sharpness\":50}," ++
        "\"max\":{\"nsfwScore\":0.4}," ++
        "\"dedup_field\":\"stack\"," ++
        "\"include_meta\":true}";

    const hnsw_args = &[_][]const u8{ q_b64, "5", "vec:hnsw:", "meta:", opts };
    var hnsw_ctx = Ctx.init(&store, hnsw_args, testing.allocator, null, null, null, &reg);
    defer hnsw_ctx.deinit();
    const hnsw_res = try execute(&hnsw_ctx);
    defer testing.allocator.free(hnsw_res.value.?);

    const bf_args = &[_][]const u8{ q_b64, "5", "vec:bf:", "meta:", opts };
    var bf_ctx = Ctx.init(&store, bf_args, testing.allocator, null, null, null, &reg);
    defer bf_ctx.deinit();
    const bf_res = try execute(&bf_ctx);
    defer testing.allocator.free(bf_res.value.?);

    // Parse both JSON outputs to verify valid JSON, exact parity, strict descending score order, and embedded metadata.
    const p_hnsw = try std.json.parseFromSlice(std.json.Value, testing.allocator, hnsw_res.value.?, .{});
    defer p_hnsw.deinit();
    const p_bf = try std.json.parseFromSlice(std.json.Value, testing.allocator, bf_res.value.?, .{});
    defer p_bf.deinit();

    const arr_h = p_hnsw.value.array.items;
    const arr_b = p_bf.value.array.items;
    try testing.expectEqual(@as(usize, 4), arr_h.len);
    try testing.expectEqual(arr_h.len, arr_b.len);

    const expected_ids = [_][]const u8{ "2", "6", "7", "10" };
    var prev_score: f64 = std.math.inf(f64);
    for (0..expected_ids.len) |idx| {
        const oh = arr_h[idx].object;
        const ob = arr_b[idx].object;

        const kh = oh.get("k").?.string;
        const kb = ob.get("k").?.string;
        try testing.expect(std.mem.endsWith(u8, kh, expected_ids[idx]));
        try testing.expect(std.mem.endsWith(u8, kb, expected_ids[idx]));

        const sh = jsonAsFloat(oh.get("s").?).?;
        const sb = jsonAsFloat(ob.get("s").?).?;
        try testing.expectApproxEqAbs(sh, sb, 1e-4);
        try testing.expect(sh <= prev_score);
        prev_score = sh;

        // Embedded metadata object must be present and valid.
        try testing.expect(oh.get("m").? == .object);
        try testing.expect(ob.get("m").? == .object);
        try testing.expectEqualStrings("image", oh.get("m").?.object.get("mediaType").?.string);
    }
}

test "vsearch_filtered brute-force TopK evictions and dot/l2 metrics stay leak-free" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    // Insert 120 vectors (> raw_fetch_k=64) so bounded TopK triggers evictions in brute-force mode.
    for (0..120) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * 0.01;
        const v = [_]f32{ @cos(angle), @sin(angle), 0.0, 0.0 };
        var kb: [32]u8 = undefined;
        var km: [32]u8 = undefined;
        var mv: [96]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "vec:ev:{d}", .{i});
        const mkey = try std.fmt.bufPrint(&km, "meta:{d}", .{i});
        const mval = try std.fmt.bufPrint(&mv, "{{\"grp\":{d},\"score\":{d}}}", .{ i % 5, i });
        try store.set(key, std.mem.sliceAsBytes(&v), false);
        try store.set(mkey, mval, false);
    }

    const q = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const q_b64 = try testEncodeVecB64(testing.allocator, &q);
    defer testing.allocator.free(q_b64);

    const Case = struct { opts: []const u8, expected_len: usize };
    for ([_]Case{
        // grp == 0 is ignored by dedup_field -> all 5 matching items returned.
        .{ .opts = "{\"metric\":\"cosine\",\"eq\":{\"grp\":0},\"max\":{\"score\":50},\"dedup_field\":\"grp\"}", .expected_len = 5 },
        // grp == 2 is non-zero -> deduplicated down to 1 highest-scoring item.
        .{ .opts = "{\"metric\":\"cosine\",\"eq\":{\"grp\":2},\"max\":{\"score\":50},\"dedup_field\":\"grp\"}", .expected_len = 1 },
        .{ .opts = "{\"metric\":\"dot\",\"min\":{\"score\":1},\"max\":{\"score\":25}}", .expected_len = 5 },
        .{ .opts = "{\"metric\":\"l2\",\"neq\":{\"grp\":0},\"max\":{\"score\":10}}", .expected_len = 5 },
        .{ .opts = "{\"metric\":\"cosine\",\"include_meta\":true}", .expected_len = 5 },
    }) |c| {
        const args = &[_][]const u8{ q_b64, "5", "vec:ev:", "meta:", c.opts };
        var ctx = Ctx.init(&store, args, testing.allocator, null, null, null, null);
        defer ctx.deinit();
        const res = try execute(&ctx);
        defer testing.allocator.free(res.value.?);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, res.value.?, .{});
        defer parsed.deinit();
        const arr = parsed.value.array.items;
        try testing.expectEqual(c.expected_len, arr.len);
        var prev: f64 = std.math.inf(f64);
        for (arr) |item| {
            const sc = jsonAsFloat(item.object.get("s").?).?;
            try testing.expect(sc <= prev);
            prev = sc;
        }
    }
}

test "vsearch_filtered selective brute-force past raw_fetch_k returns exact top_k matches" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    // 200 vectors sorted monotonically further from q=(1,0,0,0) as i increases.
    // Ranks 0..99 (> raw_fetch_k=64) FAIL eq:mediaType="image".
    // Ranks 100..199 PASS eq, with 100 & 101 sharing stack "dup_s" (100 wins, 101 deduped).
    for (0..200) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * 0.007;
        const v = [_]f32{ @cos(angle), @sin(angle), 0.0, 0.0 };
        var kb: [32]u8 = undefined;
        var km: [32]u8 = undefined;
        var mv: [128]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "vec:sel:{d}", .{i});
        const mkey = try std.fmt.bufPrint(&km, "meta:{d}", .{i});
        const media = if (i < 100) "video" else "image";
        const stack_id = if (i == 100 or i == 101) "dup_s" else if (i == 102) "" else "uniq";
        const mval = if (std.mem.eql(u8, stack_id, "uniq"))
            try std.fmt.bufPrint(&mv, "{{\"mediaType\":\"{s}\",\"stk\":\"s_{d}\"}}", .{ media, i })
        else
            try std.fmt.bufPrint(&mv, "{{\"mediaType\":\"{s}\",\"stk\":\"{s}\"}}", .{ media, stack_id });
        try store.set(key, std.mem.sliceAsBytes(&v), false);
        try store.set(mkey, mval, false);
    }

    const q = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const q_b64 = try testEncodeVecB64(testing.allocator, &q);
    defer testing.allocator.free(q_b64);

    // top_k=5, oversample=8 -> raw_fetch_k=64 (all 64 fail eq -> exact fallback must fire).
    const opts = "{\"metric\":\"cosine\",\"oversample\":8,\"eq\":{\"mediaType\":\"image\"},\"dedup_field\":\"stk\",\"include_meta\":true}";
    const args = &[_][]const u8{ q_b64, "5", "vec:sel:", "meta:", opts };
    var ctx = Ctx.init(&store, args, testing.allocator, null, null, null, null);
    defer ctx.deinit();

    const res = try execute(&ctx);
    defer testing.allocator.free(res.value.?);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, res.value.?, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 5), arr.len);

    // Expected exact winners: 100 (beats 101 on "dup_s"), 102 (empty stk ignored), 103, 104, 105.
    const expected_keys = [_][]const u8{ "vec:sel:100", "vec:sel:102", "vec:sel:103", "vec:sel:104", "vec:sel:105" };
    var prev_score: f64 = std.math.inf(f64);
    for (expected_keys, 0..) |ek, idx| {
        const obj = arr[idx].object;
        try testing.expectEqualStrings(ek, obj.get("k").?.string);
        const sc = jsonAsFloat(obj.get("s").?).?;
        try testing.expect(sc <= prev_score);
        prev_score = sc;
        try testing.expectEqualStrings("image", obj.get("m").?.object.get("mediaType").?.string);
    }
}

test "vsearch_filtered brute-force dedup exhaustion past raw_fetch_k and NaN resilience" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    // Inject a NaN vector that would previously corrupt TopK eviction if compared with `<=`.
    const nan_vec = [_]f32{ std.math.nan(f32), 0.0, 0.0, 0.0 };
    try store.set("vec:ded:nan", std.mem.sliceAsBytes(&nan_vec), false);
    try store.set("meta:nan", "{\"ok\":true,\"grp\":999}", false);

    // Ranks 0..99 ALL match `ok:true` but share `grp:1` (collapses to single winner: rank 0).
    // Ranks 100..139 have distinct non-zero groups `grp:100..139`.
    for (0..140) |i| {
        const angle: f32 = @as(f32, @floatFromInt(i)) * 0.008;
        const v = [_]f32{ @cos(angle), @sin(angle), 0.0, 0.0 };
        var kb: [32]u8 = undefined;
        var km: [32]u8 = undefined;
        var mv: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&kb, "vec:ded:{d}", .{i});
        const mkey = try std.fmt.bufPrint(&km, "meta:{d}", .{i});
        const grp: usize = if (i < 100) 1 else i;
        const mval = try std.fmt.bufPrint(&mv, "{{\"ok\":true,\"grp\":{d}}}", .{grp});
        try store.set(key, std.mem.sliceAsBytes(&v), false);
        try store.set(mkey, mval, false);
    }

    const q = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const q_b64 = try testEncodeVecB64(testing.allocator, &q);
    defer testing.allocator.free(q_b64);

    // top_k=5, oversample=8 -> raw_fetch_k=64 yields only 1 unique group -> exact fallback fills remaining 4!
    const opts = "{\"metric\":\"cosine\",\"oversample\":8,\"eq\":{\"ok\":true},\"dedup_field\":\"grp\"}";
    const args = &[_][]const u8{ q_b64, "5", "vec:ded:", "meta:", opts };
    var ctx = Ctx.init(&store, args, testing.allocator, null, null, null, null);
    defer ctx.deinit();

    const res = try execute(&ctx);
    defer testing.allocator.free(res.value.?);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, res.value.?, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try testing.expectEqual(@as(usize, 5), arr.len);

    const expected_keys = [_][]const u8{ "vec:ded:0", "vec:ded:100", "vec:ded:101", "vec:ded:102", "vec:ded:103" };
    var prev_score: f64 = std.math.inf(f64);
    for (expected_keys, 0..) |ek, idx| {
        const obj = arr[idx].object;
        try testing.expectEqualStrings(ek, obj.get("k").?.string);
        const sc = jsonAsFloat(obj.get("s").?).?;
        try testing.expect(sc <= prev_score);
        prev_score = sc;
    }
}
