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

const Metric = metric_mod.Metric;
const NamespaceRegistry = index_mod.NamespaceRegistry;

pub const MAX_TOP_K: usize = 500;
const MAX_OVERSAMPLE_CANDIDATES: usize = 4000;

const RawCandidate = struct {
    key: []u8,
    score: f32,
    timestamp: u64,
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

    // Decode base64 query vector
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(query_b64) catch {
        return ctx.err("vsearch_filtered: invalid base64 query");
    };
    if (decoded_len == 0 or decoded_len % 4 != 0) {
        return ctx.err("vsearch_filtered: invalid query vector byte length");
    }
    const query_bytes = try ctx.allocator.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(query_bytes, query_b64) catch {
        return ctx.err("vsearch_filtered: base64 decode failed");
    };
    const query_vec = distance.bytesToF32(query_bytes) orelse {
        return ctx.err("vsearch_filtered: invalid f32 query vector");
    };

    // Parse optional options_json
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

    const raw_fetch_k = if (has_filters)
        @min(MAX_OVERSAMPLE_CANDIDATES, @max(top_k_raw * oversample_mult, 64))
    else
        top_k_raw;

    // Stage 1: Fetch candidate keys from HNSW (or exact scan fallback) with NO shard locks nested.
    var candidates: std.ArrayListUnmanaged(RawCandidate) = .empty;

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
                        const idx_out = try ctx.allocator.alloc(index_mod.IndexSearchResult, k_clamped);
                        const hnsw_scratch = try ctx.allocator.alloc(hnsw_mod.SearchResult, k_clamped);
                        const found = try ns_idx.searchLocked(query_vec, k_clamped, ef, idx_out, hnsw_scratch);

                        try candidates.ensureTotalCapacity(ctx.allocator, found);
                        for (idx_out[0..found]) |r| {
                            candidates.appendAssumeCapacity(.{
                                .key = try ctx.allocator.dupe(u8, r.key),
                                .score = metric.distToScore(r.dist),
                                .timestamp = r.timestamp,
                            });
                        }
                    }
                }
            }
        }
    }

    // Fallback: brute-force scan if HNSW index isn't present for this namespace
    if (!used_hnsw) {
        const ScanCtx = struct {
            query: []align(1) const f32,
            metric: Metric,
            allocator: std.mem.Allocator,
            list: *std.ArrayListUnmanaged(RawCandidate),
            oom: bool = false,
            fn onEntry(raw: *anyopaque, key: []const u8, val: []const u8, ts: u64, _: bool) Store.ScanAction {
                const self: *@This() = @ptrCast(@alignCast(raw));
                const vec = distance.bytesToF32(val) orelse return .cont;
                if (vec.len != self.query.len) return .cont;
                const score: f32 = switch (self.metric) {
                    .cosine => distance.cosine(self.query, vec),
                    .dot => distance.dot(self.query, vec),
                    .l2 => 1.0 / (1.0 + distance.l2Squared(self.query, vec)),
                };
                const k_copy = self.allocator.dupe(u8, key) catch {
                    self.oom = true;
                    return .stop;
                };
                self.list.append(self.allocator, .{ .key = k_copy, .score = score, .timestamp = ts }) catch {
                    self.oom = true;
                    return .stop;
                };
                return .cont;
            }
        };
        var sctx = ScanCtx{
            .query = query_vec,
            .metric = metric,
            .allocator = ctx.allocator,
            .list = &candidates,
        };
        ctx.scanCallback(namespace, @ptrCast(&sctx), ScanCtx.onEntry);
        if (sctx.oom) return error.OutOfMemory;
        std.sort.heap(RawCandidate, candidates.items, {}, struct {
            fn desc(_: void, a: RawCandidate, b: RawCandidate) bool {
                return a.score > b.score;
            }
        }.desc);
    }

    // Stage 2: With HNSW lock released, filter + dedup against companion metadata keys in Store.
    var seen_dedup = std.StringHashMapUnmanaged(void).empty;
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(ctx.allocator, '[');

    var emitted: usize = 0;
    var meta_key_buf: [512]u8 = undefined;

    for (candidates.items) |cand| {
        if (emitted >= top_k_raw) break;

        var meta_raw: ?[]const u8 = null;
        if (has_filters or include_meta) {
            if (meta_prefix.len > 0 and std.mem.startsWith(u8, cand.key, namespace)) {
                const suffix = cand.key[namespace.len..];
                const meta_key = std.fmt.bufPrint(&meta_key_buf, "{s}{s}", .{ meta_prefix, suffix }) catch null;
                if (meta_key) |mk| {
                    meta_raw = try ctx.getCopy(mk);
                }
            }
        }

        if (has_filters) {
            const raw_m = meta_raw orelse continue;
            var parsed_m = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw_m, .{}) catch continue;
            defer parsed_m.deinit();
            if (parsed_m.value != .object) continue;
            const mobj = parsed_m.value.object;

            if (!matchesMeta(mobj, eq_obj, neq_obj, prefix_obj, min_obj, max_obj)) continue;

            if (dedup_field) |df| {
                if (mobj.get(df)) |dv| {
                    if (formatDedupKey(ctx.allocator, dv)) |dkey| {
                        if (seen_dedup.contains(dkey)) continue;
                        try seen_dedup.put(ctx.allocator, dkey, {});
                    }
                }
            }
        }

        if (emitted > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"k\":\"");
        try appendJsonEscaped(&json, ctx.allocator, cand.key);
        try json.appendSlice(ctx.allocator, "\",\"s\":");
        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "{d:.6}", .{cand.score}) catch "0";
        try json.appendSlice(ctx.allocator, score_str);
        try json.appendSlice(ctx.allocator, ",\"ts\":");
        var ts_buf: [24]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{cand.timestamp}) catch "0";
        try json.appendSlice(ctx.allocator, ts_str);
        if (include_meta) {
            if (meta_raw) |mr| {
                try json.appendSlice(ctx.allocator, ",\"m\":");
                try json.appendSlice(ctx.allocator, mr);
            }
        }
        try json.append(ctx.allocator, '}');
        emitted += 1;
    }

    try json.append(ctx.allocator, ']');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

fn jsonValuesEqual(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |av| b == .bool and b.bool == av,
        .integer => |av| switch (b) {
            .integer => |bv| av == bv,
            .float => |bv| @as(f64, @floatFromInt(av)) == bv,
            else => false,
        },
        .float => |av| switch (b) {
            .float => |bv| av == bv,
            .integer => |bv| av == @as(f64, @floatFromInt(bv)),
            else => false,
        },
        .string => |av| b == .string and std.mem.eql(u8, av, b.string),
        else => false,
    };
}

fn jsonAsFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |iv| @floatFromInt(iv),
        .float => |fv| fv,
        else => null,
    };
}

fn matchesMeta(
    mobj: std.json.ObjectMap,
    eq_obj: ?std.json.ObjectMap,
    neq_obj: ?std.json.ObjectMap,
    prefix_obj: ?std.json.ObjectMap,
    min_obj: ?std.json.ObjectMap,
    max_obj: ?std.json.ObjectMap,
) bool {
    if (eq_obj) |eq| {
        var it = eq.iterator();
        while (it.next()) |kv| {
            const actual = mobj.get(kv.key_ptr.*) orelse return false;
            if (!jsonValuesEqual(actual, kv.value_ptr.*)) return false;
        }
    }
    if (neq_obj) |neq| {
        var it = neq.iterator();
        while (it.next()) |kv| {
            if (mobj.get(kv.key_ptr.*)) |actual| {
                if (jsonValuesEqual(actual, kv.value_ptr.*)) return false;
            }
        }
    }
    if (prefix_obj) |pref| {
        var it = pref.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != .string) continue;
            const actual = mobj.get(kv.key_ptr.*) orelse return false;
            if (actual != .string) return false;
            if (!std.mem.startsWith(u8, actual.string, kv.value_ptr.string)) return false;
        }
    }
    if (min_obj) |mn| {
        var it = mn.iterator();
        while (it.next()) |kv| {
            const bound = jsonAsFloat(kv.value_ptr.*) orelse continue;
            const actual = mobj.get(kv.key_ptr.*) orelse return false;
            const aval = jsonAsFloat(actual) orelse return false;
            if (aval < bound) return false;
        }
    }
    if (max_obj) |mx| {
        var it = mx.iterator();
        while (it.next()) |kv| {
            const bound = jsonAsFloat(kv.value_ptr.*) orelse continue;
            const actual = mobj.get(kv.key_ptr.*) orelse return false;
            const aval = jsonAsFloat(actual) orelse return false;
            if (aval > bound) return false;
        }
    }
    return true;
}

/// Format a non-empty, non-zero metadata field value as a dedup token.
/// Zero integers, empty strings, false, and null return null (not deduplicated).
fn formatDedupKey(alloc: std.mem.Allocator, v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .integer => |iv| if (iv == 0) null else std.fmt.allocPrint(alloc, "i:{d}", .{iv}) catch null,
        .string => |sv| if (sv.len == 0) null else alloc.dupe(u8, sv) catch null,
        else => null,
    };
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

    const q_bytes = std.mem.sliceAsBytes(&v1);
    const b64_len = std.base64.standard.Encoder.calcSize(q_bytes.len);
    const q_b64 = try alloc.alloc(u8, b64_len);
    _ = std.base64.standard.Encoder.encode(q_b64, q_bytes);

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
