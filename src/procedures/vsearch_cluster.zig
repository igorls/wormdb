//! Built-in VSEARCH_CLUSTER procedure — cluster-wide scatter-gather
//! vector search (#67).
//!
//! EXEC vsearch_cluster <query_key> <top_k> [namespace] [metric] [decay]
//!                      [mode] [decay_tau_hours] [max_peers] [include_self]
//!
//! - query_key:   key holding the query vector locally (raw f32 bytes) —
//!                same as `vsearch`; the coordinator resolves the vector
//!                and forwards its BYTES to peers, so peers never need
//!                the key.
//! - top_k:       max results to return (1–100)
//! - namespace / metric / decay / mode / decay_tau_hours: as `vsearch`
//! - max_peers:   bounded fan-out (default 16, 0 = local only)
//! - include_self: "0" to skip the local search (default: include)
//!
//! Runs the local search (shared core with `vsearch`), scatters
//! `EXEC vsearch_local_raw` sub-queries to alive peers over one-shot
//! replication connections (Cluster.scatterVsearch), then merges all
//! per-node top-K lists: dedup by key keeping the max score (keys are
//! globally replicated, so most collide), sort by descending score, cap
//! at top_k. Per-peer k = global k, which is provably sufficient — the
//! global top-K is a subset of the union of per-node top-Ks.
//!
//! Degrades gracefully: single-node (no cluster attached) returns local
//! results with peers_queried=0 / partial=false; per-peer failures yield
//! partial results with partial=true.
//!
//! Returns JSON:
//!   {"items":[{"k":"vec:ns:id","s":0.95,"ts":1709...,"src":"local"|"peer"},...],
//!    "peers_queried":N,"peers_failed":N,"partial":false}
//!
//! Authorization: identical to `vsearch` — the executor's capability
//! chokepoint gates `EXEC` by procedure name (op=.exec, target=
//! "vsearch_cluster"); the procedure itself performs no additional
//! namespace check because `vsearch` performs none. Deliberately NOT in
//! tcp.zig's replication allow-list: peers may only be asked for
//! `vsearch_local_raw`, which never re-scatters, so fan-out loops are
//! impossible.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const vsearch = @import("vsearch.zig");
const distance = @import("../vector/distance.zig");
const cluster_mod = @import("../cluster/mod.zig");

pub const Metric = vsearch.Metric;

const DEFAULT_MAX_PEERS: usize = 16;

/// A candidate in the coordinator's merge set, tagged with its source.
pub const MergedItem = struct {
    key: []const u8,
    score: f32,
    timestamp: u64,
    local: bool,
};

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    // ── Parse args (0..6 match vsearch exactly) ─────────────────
    const query_key = ctx.arg(0) orelse
        return ctx.err("vsearch_cluster requires at least 2 args: <query_key> <top_k> [namespace] [metric] [decay] [mode] [decay_tau_hours] [max_peers] [include_self]");

    const top_k_raw = ctx.argInt(usize, 1) orelse
        return ctx.err("vsearch_cluster: top_k must be a positive integer");

    const top_k = @min(if (top_k_raw == 0) @as(usize, 10) else top_k_raw, vsearch.MAX_TOP_K);
    const namespace = ctx.arg(2) orelse vsearch.DEFAULT_NAMESPACE;
    const metric: Metric = if (ctx.arg(3)) |m|
        Metric.fromStr(m) orelse Metric.cosine
    else
        Metric.cosine;

    var decay: f32 = 0.0;
    if (ctx.arg(4)) |d| {
        decay = std.fmt.parseFloat(f32, d) catch 0.0;
        decay = @min(@max(decay, 0.0), 1.0);
    }

    const mode_str = ctx.arg(5) orelse "auto";
    const mode = vsearch.Mode.fromStr(mode_str);
    const decay_tau_hours = if (ctx.arg(6)) |raw|
        vsearch.parseDecayTauHours(raw) orelse return ctx.err("vsearch_cluster: decay_tau_hours must be positive")
    else
        vsearch.DEFAULT_DECAY_TAU_HOURS;

    const max_peers = ctx.argInt(usize, 7) orelse DEFAULT_MAX_PEERS;
    const include_self = blk: {
        const raw = ctx.arg(8) orelse break :blk true;
        break :blk !std.mem.eql(u8, raw, "0");
    };

    // ── Resolve the query vector locally (same path as vsearch) ──
    const query_bytes = (try ctx.getCopy(query_key)) orelse
        return ctx.err("vsearch_cluster: query key not found");

    const query_vec = distance.bytesToF32(query_bytes) orelse
        return ctx.err("vsearch_cluster: query value is not a valid f32 vector (byte length must be multiple of 4)");

    // ── Local search via the shared core ────────────────────────
    var local_candidates: []vsearch.Candidate = &.{};
    if (include_self) {
        const local_buf = try ctx.allocator.alloc(vsearch.Candidate, top_k);
        var local_heap = vsearch.TopKCandidate.init(local_buf);
        if (try vsearch.runSearch(ctx, query_key, query_vec, .{
            .top_k = top_k,
            .namespace = namespace,
            .metric = metric,
            .decay = decay,
            .mode = mode,
            .decay_tau_hours = decay_tau_hours,
        }, &local_heap)) |msg| return ctx.err(msg);
        local_candidates = local_heap.sortedDesc();
    }

    // ── Scatter to peers (no-op single-node / max_peers=0) ──────
    var peers_queried: usize = 0;
    var peers_failed: usize = 0;
    var scatter_errored = false;
    var remote_items: []const cluster_mod.node.ScatterItem = &.{};

    if (ctx.cluster) |c| {
        if (max_peers > 0) {
            if (c.scatterVsearch(ctx.allocator, query_vec, .{
                .top_k = top_k,
                .namespace = namespace,
                .metric = metric.name(),
                .decay = decay,
                .mode = mode_str,
                .decay_tau_hours = decay_tau_hours,
                .max_peers = max_peers,
            })) |scatter| {
                remote_items = scatter.items;
                peers_queried = scatter.peers_queried;
                peers_failed = scatter.peers_failed;
            } else |e| {
                // Total scatter failure (e.g. OOM): degrade to local-only,
                // flagged partial so the caller knows peers were skipped.
                std.log.warn("vsearch_cluster: scatter failed: {s}", .{@errorName(e)});
                scatter_errored = true;
            }
        }
    }

    // ── Merge local + remote through the shared dedup ───────────
    const local_merged = try ctx.allocator.alloc(MergedItem, local_candidates.len);
    for (local_candidates, 0..) |cand, i| {
        local_merged[i] = .{ .key = cand.key, .score = cand.score, .timestamp = cand.timestamp, .local = true };
    }
    const remote_merged = try ctx.allocator.alloc(MergedItem, remote_items.len);
    for (remote_items, 0..) |item, i| {
        remote_merged[i] = .{ .key = item.key, .score = item.score, .timestamp = item.timestamp, .local = false };
    }

    const lists = [_][]const MergedItem{ local_merged, remote_merged };
    const merged = try mergeCandidates(ctx.allocator, lists[0..], top_k, query_key);

    const partial = scatter_errored or peers_failed > 0;
    return emitClusterJson(ctx, merged, peers_queried, peers_failed, partial);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Merge (pure)                                      ║
// ╚═══════════════════════════════════════════════════╝

/// Merge per-node candidate lists into one global top-K: dedup by key
/// keeping the entry with the HIGHER score (strict `>`, so on a tie the
/// earliest list wins — local is passed first, so local wins ties), sort
/// by descending score, cap at `top_k`.
///
/// `exclude_key` drops the coordinator's query key from EVERY list ("" drops
/// nothing). The local search already excludes it, but peers search by inline
/// vector (`vsearch_local_raw`, query_key="") and on a replicated namespace
/// every peer holds the query's stored copy — an exact-match self-hit that
/// only the coordinator can recognize. This merge is the one place that
/// knows the key.
///
/// Pure function over its inputs; the returned slice is allocated with
/// `allocator` (caller frees; arena in the procedure path). Keys are
/// borrowed from the input items.
pub fn mergeCandidates(
    allocator: std.mem.Allocator,
    lists: []const []const MergedItem,
    top_k: usize,
    exclude_key: []const u8,
) ![]MergedItem {
    var index = std.StringHashMap(usize).init(allocator);
    defer index.deinit();
    var acc: std.ArrayListUnmanaged(MergedItem) = .empty;
    defer acc.deinit(allocator);

    for (lists) |list| {
        for (list) |item| {
            if (exclude_key.len != 0 and std.mem.eql(u8, item.key, exclude_key)) continue;
            if (index.get(item.key)) |i| {
                if (item.score > acc.items[i].score) acc.items[i] = item;
            } else {
                try acc.append(allocator, item);
                try index.put(item.key, acc.items.len - 1);
            }
        }
    }

    std.sort.heap(MergedItem, acc.items, {}, struct {
        fn greater(_: void, a: MergedItem, b: MergedItem) bool {
            return a.score > b.score;
        }
    }.greater);

    const n = @min(acc.items.len, top_k);
    return try allocator.dupe(MergedItem, acc.items[0..n]);
}

// ╔═══════════════════════════════════════════════════╗
// ║  JSON emission                                     ║
// ╚═══════════════════════════════════════════════════╝

fn emitClusterJson(
    ctx: *Ctx,
    items: []const MergedItem,
    peers_queried: usize,
    peers_failed: usize,
    partial: bool,
) !Ctx.Result {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(ctx.allocator, "{\"items\":[");
    for (items, 0..) |r, idx| {
        if (idx > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"k\":\"");
        try vsearch.appendJsonEscaped(&json, ctx.allocator, r.key);
        try json.appendSlice(ctx.allocator, "\",\"s\":");

        var score_buf: [32]u8 = undefined;
        const score_str = std.fmt.bufPrint(&score_buf, "{d:.6}", .{r.score}) catch "0";
        try json.appendSlice(ctx.allocator, score_str);

        try json.appendSlice(ctx.allocator, ",\"ts\":");
        var ts_buf: [20]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{r.timestamp}) catch "0";
        try json.appendSlice(ctx.allocator, ts_str);

        try json.appendSlice(ctx.allocator, ",\"src\":\"");
        try json.appendSlice(ctx.allocator, if (r.local) "local" else "peer");
        try json.appendSlice(ctx.allocator, "\"}");
    }
    try json.appendSlice(ctx.allocator, "],\"peers_queried\":");
    try appendUsize(&json, ctx.allocator, peers_queried);
    try json.appendSlice(ctx.allocator, ",\"peers_failed\":");
    try appendUsize(&json, ctx.allocator, peers_failed);
    try json.appendSlice(ctx.allocator, ",\"partial\":");
    try json.appendSlice(ctx.allocator, if (partial) "true" else "false");
    try json.append(ctx.allocator, '}');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

fn appendUsize(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: usize) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(allocator, s);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

const testing = std.testing;
const Store = @import("../storage/store.zig").Store;
const Config = @import("../core/config.zig").Config;

test "mergeCandidates: dedup keeps max score across lists" {
    const a = [_]MergedItem{
        .{ .key = "k1", .score = 0.5, .timestamp = 1, .local = true },
        .{ .key = "k2", .score = 0.9, .timestamp = 2, .local = true },
    };
    const b = [_]MergedItem{
        .{ .key = "k1", .score = 0.8, .timestamp = 3, .local = false }, // beats local 0.5
        .{ .key = "k3", .score = 0.1, .timestamp = 4, .local = false },
    };
    const lists = [_][]const MergedItem{ a[0..], b[0..] };
    const merged = try mergeCandidates(testing.allocator, lists[0..], 10, "");
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 3), merged.len);
    // Descending order: k2 (0.9), k1 (0.8 — peer copy won), k3 (0.1).
    try testing.expectEqualStrings("k2", merged[0].key);
    try testing.expectEqualStrings("k1", merged[1].key);
    try testing.expectApproxEqAbs(@as(f32, 0.8), merged[1].score, 1e-6);
    try testing.expect(!merged[1].local); // higher-scoring peer copy kept
    try testing.expectEqual(@as(u64, 3), merged[1].timestamp);
    try testing.expectEqualStrings("k3", merged[2].key);
}

test "mergeCandidates: tie keeps the first-seen (local) entry" {
    const a = [_]MergedItem{
        .{ .key = "k1", .score = 0.7, .timestamp = 1, .local = true },
    };
    const b = [_]MergedItem{
        .{ .key = "k1", .score = 0.7, .timestamp = 99, .local = false },
    };
    const lists = [_][]const MergedItem{ a[0..], b[0..] };
    const merged = try mergeCandidates(testing.allocator, lists[0..], 10, "");
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expect(merged[0].local);
    try testing.expectEqual(@as(u64, 1), merged[0].timestamp);
}

test "mergeCandidates: caps at top_k after dedup" {
    const a = [_]MergedItem{
        .{ .key = "k1", .score = 0.3, .timestamp = 1, .local = true },
        .{ .key = "k2", .score = 0.9, .timestamp = 2, .local = true },
        .{ .key = "k3", .score = 0.6, .timestamp = 3, .local = true },
    };
    const lists = [_][]const MergedItem{a[0..]};
    const merged = try mergeCandidates(testing.allocator, lists[0..], 2, "");
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqualStrings("k2", merged[0].key);
    try testing.expectEqualStrings("k3", merged[1].key);
}

test "mergeCandidates: empty input yields empty output" {
    const lists = [_][]const MergedItem{};
    const merged = try mergeCandidates(testing.allocator, lists[0..], 5, "");
    defer testing.allocator.free(merged);
    try testing.expectEqual(@as(usize, 0), merged.len);
}

test "mergeCandidates: excludes the coordinator's query key from peer lists" {
    // Replicated-namespace shape: the local list already excludes the query
    // key (HNSW/BQ/exact paths all filter it), but every peer returns its
    // stored copy of the query as an exact-match self-hit at score 1.0.
    const local = [_]MergedItem{
        .{ .key = "vec:s:near", .score = 0.99, .timestamp = 1, .local = true },
    };
    const peer = [_]MergedItem{
        .{ .key = "vec:s:q", .score = 1.0, .timestamp = 2, .local = false }, // self-hit
        .{ .key = "vec:s:far", .score = 0.1, .timestamp = 3, .local = false },
    };
    const lists = [_][]const MergedItem{ local[0..], peer[0..] };
    const merged = try mergeCandidates(testing.allocator, lists[0..], 10, "vec:s:q");
    defer testing.allocator.free(merged);

    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqualStrings("vec:s:near", merged[0].key);
    try testing.expectEqualStrings("vec:s:far", merged[1].key);
}

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
    args: []const []const u8,
    arena: std.mem.Allocator,
) !Ctx.Result {
    var ctx = Ctx.init(store, args, arena, null, null, null, null);
    defer ctx.deinit();
    return try execute(&ctx);
}

test "vsearch_cluster: single-node returns local results, peers_queried=0, partial=false" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try store.set("vec:t:a", try testPackF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 }), false);
    try store.set("vec:t:b", try testPackF32(arena, &[_]f32{ 0.9, 0.1, 0.0, 0.0 }), false);
    try store.set("vec:t:c", try testPackF32(arena, &[_]f32{ 0.0, 1.0, 0.0, 0.0 }), false);
    try store.set("qvec", try testPackF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 }), false);

    const result = try testRunProc(&store, &.{ "qvec", "2", "vec:t:" }, arena);
    try testing.expect(result == .value);
    const json = result.value.?;

    // JSON shape.
    try testing.expect(std.mem.startsWith(u8, json, "{\"items\":["));
    try testing.expect(std.mem.indexOf(u8, json, "\"peers_queried\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"peers_failed\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"partial\":false") != null);

    // Local results, best first, tagged src=local.
    try testing.expect(std.mem.indexOf(u8, json, "\"k\":\"vec:t:a\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"k\":\"vec:t:b\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"k\":\"vec:t:c\"") == null); // top_k=2
    try testing.expect(std.mem.indexOf(u8, json, "\"src\":\"local\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"src\":\"peer\"") == null);
    // Ordering: vec:t:a (exact match) before vec:t:b.
    try testing.expect(std.mem.indexOf(u8, json, "vec:t:a").? < std.mem.indexOf(u8, json, "vec:t:b").?);
}

test "vsearch_cluster: include_self=0 single-node yields empty items" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try store.set("vec:t:a", try testPackF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 }), false);
    try store.set("qvec", try testPackF32(arena, &[_]f32{ 1.0, 0.0, 0.0, 0.0 }), false);

    const result = try testRunProc(&store, &.{ "qvec", "5", "vec:t:", "cosine", "0", "auto", "168", "16", "0" }, arena);
    try testing.expect(result == .value);
    try testing.expectEqualStrings(
        "{\"items\":[],\"peers_queried\":0,\"peers_failed\":0,\"partial\":false}",
        result.value.?,
    );
}

test "vsearch_cluster: missing query key errors" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try testRunProc(&store, &.{ "nope", "5" }, arena);
    try testing.expect(result == .err);
}

test "emitClusterJson: escapes keys and renders src/partial fields" {
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = Ctx.init(&store, &.{}, arena, null, null, null, null);
    defer ctx.deinit();

    const items = [_]MergedItem{
        .{ .key = "vec:t:\"q\"", .score = 0.5, .timestamp = 42, .local = true },
        .{ .key = "vec:t:b", .score = 0.25, .timestamp = 7, .local = false },
    };
    const result = try emitClusterJson(&ctx, items[0..], 3, 1, true);
    try testing.expect(result == .value);
    try testing.expectEqualStrings(
        "{\"items\":[{\"k\":\"vec:t:\\\"q\\\"\",\"s\":0.500000,\"ts\":42,\"src\":\"local\"}," ++
            "{\"k\":\"vec:t:b\",\"s\":0.250000,\"ts\":7,\"src\":\"peer\"}]," ++
            "\"peers_queried\":3,\"peers_failed\":1,\"partial\":true}",
        result.value.?,
    );
}
