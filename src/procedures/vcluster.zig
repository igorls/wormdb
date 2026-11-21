//! Built-in VCLUSTER procedure — in-DB HNSW k-NN graph, near-duplicate
//! Union-Find stacks, and 2-phase Louvain community detection in compiled Zig.
//!
//! EXEC vcluster <namespace> [options_json]
//!
//! options_json (optional):
//! {
//!   "k": 16,
//!   "ef": 64,
//!   "min_sim": 0.40,
//!   "resolution": 1.15,
//!   "min_cluster_size": 0,       // 0 = auto: clamp(round(sqrt(N)/3), 4, 24)
//!   "dedup_sim": 0.93,           // Union-Find near-duplicate threshold
//!   "merge_sim": 0.78,           // centroid cosine threshold for merge candidates
//!   "meta_prefix": "meta:",      // optional companion metadata prefix
//!   "exclude_field": "trashed",  // skip items where meta[exclude_field] == true
//!   "dedup_group_field": "mediaType" // only stack items with matching group value
//! }
//!
//! Returns compact JSON:
//! {
//!   "count": N,
//!   "elapsed_ms": 420,
//!   "keys": ["1","2",...],       // stripped suffixes (key[namespace.len..])
//!   "labels": [0,0,1,-1,...],    // cluster index per item (-1 = unclustered)
//!   "stacks": [[0,4,9],...],     // near-duplicate groups (size >= 2, cover first)
//!   "clusters": [
//!     {"id":0,"size":184,"cohesion":0.782,"medoids":[0,15,42,88,103,144]}
//!   ],
//!   "merge_candidates": [{"a":0,"b":5,"sim":0.842}]
//! }

const std = @import("std");
const compat = @import("../core/compat.zig");
const Ctx = @import("context.zig").Ctx;
const Store = @import("../storage/store.zig").Store;
const distance = @import("../vector/distance.zig");
const hnsw_mod = @import("../vector/hnsw.zig");
const index_mod = @import("../vector/index.zig");

const NamespaceRegistry = index_mod.NamespaceRegistry;

const Edge = struct {
    to: u32,
    sim: f32,
    w: f32,
};

const WeightedEdge = struct {
    to: u32,
    w: f32,
};

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const start_ms = compat.nowMs();
    const namespace = ctx.arg(0) orelse return ctx.err("vcluster requires: <namespace> [options_json]");
    try ctx.requirePrefix(namespace, .read);

    var k_nbr: usize = 16;
    var ef_opt: ?usize = null;
    var min_sim: f32 = 0.40;
    var resolution: f64 = 1.15;
    var min_cluster_size_opt: usize = 0;
    var dedup_sim: f32 = 0.93;
    var merge_sim: f32 = 0.78;
    var meta_prefix: ?[]const u8 = null;
    var exclude_field: ?[]const u8 = null;
    var dedup_group_field: ?[]const u8 = null;

    var parsed_opts: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_opts) |*p| p.deinit();

    if (ctx.arg(1)) |raw| {
        if (raw.len > 0 and raw[0] == '{') {
            parsed_opts = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{}) catch {
                return ctx.err("vcluster: invalid options_json");
            };
            if (parsed_opts.?.value != .object) return ctx.err("vcluster: options_json must be an object");
            const obj = parsed_opts.?.value.object;
            if (obj.get("k")) |v| if (v == .integer and v.integer >= 2) {
                k_nbr = @min(@as(usize, @intCast(v.integer)), 64);
            };
            if (obj.get("ef")) |v| if (v == .integer and v.integer >= 8) {
                ef_opt = @min(@as(usize, @intCast(v.integer)), 512);
            };
            if (obj.get("min_sim")) |v| if (jsonF64(v)) |f| {
                min_sim = @floatCast(std.math.clamp(f, 0.0, 0.99));
            };
            if (obj.get("resolution")) |v| if (jsonF64(v)) |f| {
                resolution = std.math.clamp(f, 0.1, 10.0);
            };
            if (obj.get("min_cluster_size")) |v| if (v == .integer and v.integer >= 0) {
                min_cluster_size_opt = @intCast(v.integer);
            };
            if (obj.get("dedup_sim")) |v| if (jsonF64(v)) |f| {
                dedup_sim = @floatCast(std.math.clamp(f, 0.5, 1.0));
            };
            if (obj.get("merge_sim")) |v| if (jsonF64(v)) |f| {
                merge_sim = @floatCast(std.math.clamp(f, 0.3, 1.0));
            };
            if (obj.get("meta_prefix")) |v| if (v == .string and v.string.len > 0) {
                meta_prefix = v.string;
            };
            if (obj.get("exclude_field")) |v| if (v == .string and v.string.len > 0) {
                exclude_field = v.string;
            };
            if (obj.get("dedup_group_field")) |v| if (v == .string and v.string.len > 0) {
                dedup_group_field = v.string;
            };
        } else if (raw.len > 0) {
            if (std.fmt.parseInt(usize, raw, 10)) |kv| {
                k_nbr = std.math.clamp(kv, 2, 64);
            } else |_| {}
        }
    }

    if (meta_prefix) |mp| {
        try ctx.requirePrefix(mp, .read);
    }

    // Step 1 (BEFORE locking HNSW): collect optional exclusions & dedup groups from metadata.
    var excluded_map = std.StringHashMapUnmanaged(void).empty;
    var dedup_group_map = std.StringHashMapUnmanaged(u64).empty;
    if (meta_prefix) |mp| {
        if (exclude_field != null or dedup_group_field != null) {
            const MetaScanCtx = struct {
                prefix_len: usize,
                exclude_needle: ?[]const u8,
                group_needle: ?[]const u8,
                allocator: std.mem.Allocator,
                excluded: *std.StringHashMapUnmanaged(void),
                groups: *std.StringHashMapUnmanaged(u64),
                oom: bool = false,

                fn onEntry(raw_ctx: *anyopaque, key: []const u8, val: []const u8, _: u64, _: bool) Store.ScanAction {
                    const self: *@This() = @ptrCast(@alignCast(raw_ctx));
                    if (key.len <= self.prefix_len) return .cont;
                    const suffix = key[self.prefix_len..];
                    if (self.exclude_needle) |needle| {
                        if (std.mem.indexOf(u8, val, needle) != null) {
                            const s_copy = self.allocator.dupe(u8, suffix) catch {
                                self.oom = true;
                                return .stop;
                            };
                            self.excluded.put(self.allocator, s_copy, {}) catch {
                                self.oom = true;
                                return .stop;
                            };
                            return .cont;
                        }
                    }
                    if (self.group_needle) |gneedle| {
                        if (std.mem.indexOf(u8, val, gneedle)) |pos| {
                            const start = pos + gneedle.len;
                            if (std.mem.indexOfScalar(u8, val[start..], '"')) |end_rel| {
                                const gval = val[start .. start + end_rel];
                                const s_copy = self.allocator.dupe(u8, suffix) catch {
                                    self.oom = true;
                                    return .stop;
                                };
                                const h = std.hash.Wyhash.hash(0, gval);
                                self.groups.put(self.allocator, s_copy, h) catch {
                                    self.oom = true;
                                    return .stop;
                                };
                            }
                        }
                    }
                    return .cont;
                }
            };

            const ex_needle = if (exclude_field) |ef|
                try std.fmt.allocPrint(ctx.allocator, "\"{s}\":true", .{ef})
            else
                null;
            const gr_needle = if (dedup_group_field) |gf|
                try std.fmt.allocPrint(ctx.allocator, "\"{s}\":\"", .{gf})
            else
                null;

            var mctx = MetaScanCtx{
                .prefix_len = mp.len,
                .exclude_needle = ex_needle,
                .group_needle = gr_needle,
                .allocator = ctx.allocator,
                .excluded = &excluded_map,
                .groups = &dedup_group_map,
            };
            ctx.scanCallback(mp, @ptrCast(&mctx), MetaScanCtx.onEntry);
            if (mctx.oom) return error.OutOfMemory;
        }
    }

    const reg = ctx.vector_registry orelse return ctx.err("vcluster: vector registry unavailable");
    const ns_idx = reg.get(namespace) orelse return ctx.value("{\"count\":0,\"elapsed_ms\":0,\"keys\":[],\"labels\":[],\"stacks\":[],\"clusters\":[],\"merge_candidates\":[]}");

    const alloc = ctx.allocator;
    ns_idx.lock.lockShared();
    defer ns_idx.lock.unlockShared();

    const total_nodes = ns_idx.hnsw.len();
    const dim = ns_idx.dim orelse 0;
    if (total_nodes == 0 or dim == 0) {
        return ctx.value("{\"count\":0,\"elapsed_ms\":0,\"keys\":[],\"labels\":[],\"stacks\":[],\"clusters\":[],\"merge_candidates\":[]}");
    }

    // Collect active nodes
    const nid_to_idx = try alloc.alloc(i32, total_nodes);
    @memset(nid_to_idx, -1);

    var active_nids: std.ArrayListUnmanaged(u32) = .empty;
    var active_suffixes: std.ArrayListUnmanaged([]const u8) = .empty;
    var active_vecs: std.ArrayListUnmanaged([]align(16) const f32) = .empty;
    var active_groups: std.ArrayListUnmanaged(u64) = .empty;
    try active_nids.ensureTotalCapacity(alloc, ns_idx.liveCount());
    try active_suffixes.ensureTotalCapacity(alloc, ns_idx.liveCount());
    try active_vecs.ensureTotalCapacity(alloc, ns_idx.liveCount());
    try active_groups.ensureTotalCapacity(alloc, ns_idx.liveCount());

    for (0..total_nodes) |nid| {
        if (ns_idx.isTombstoned(@intCast(nid))) continue;
        const full_key = ns_idx.keys.items[nid];
        const suffix = if (std.mem.startsWith(u8, full_key, namespace)) full_key[namespace.len..] else full_key;
        if (excluded_map.count() > 0 and excluded_map.contains(suffix)) continue;
        const vec = ns_idx.hnsw.nodes.items[nid].vector;
        if (vec.len != dim) continue;

        const idx: i32 = @intCast(active_nids.items.len);
        nid_to_idx[nid] = idx;
        active_nids.appendAssumeCapacity(@intCast(nid));
        active_suffixes.appendAssumeCapacity(suffix);
        active_vecs.appendAssumeCapacity(vec);
        active_groups.appendAssumeCapacity(dedup_group_map.get(suffix) orelse 0);
    }

    const n = active_nids.items.len;
    if (n == 0) {
        return ctx.value("{\"count\":0,\"elapsed_ms\":0,\"keys\":[],\"labels\":[],\"stacks\":[],\"clusters\":[],\"merge_candidates\":[]}");
    }

    // Step 2: Build symmetric k-NN graph using in-memory HNSW
    const k_query = @min(k_nbr + 1, n);
    const ef = @max(ef_opt orelse @max(k_query * 3, 48), k_query);
    const scratch = try alloc.alloc(hnsw_mod.SearchResult, k_query);
    const filter: ?*const std.bit_set.Dynamic = if (ns_idx.tombstone_count > 0) &ns_idx.tombstones else null;

    const adj = try alloc.alloc(std.ArrayListUnmanaged(Edge), n);
    for (adj) |*list| list.* = .empty;

    for (0..n) |i| {
        const found = try ns_idx.hnsw.search(active_vecs.items[i], k_query, ef, scratch, filter);
        for (scratch[0..found]) |hit| {
            const j_signed = nid_to_idx[hit.id];
            if (j_signed < 0) continue;
            const j: usize = @intCast(j_signed);
            if (j == i) continue;
            const sim = ns_idx.metric.distToScore(hit.dist);
            const w: f32 = if (sim >= min_sim) blk: {
                const d = @max(@as(f32, 0.01), sim - (min_sim - 0.05));
                break :blk d * d;
            } else 0.0;
            try upsertEdge(alloc, &adj[i], @intCast(j), sim, w);
            try upsertEdge(alloc, &adj[j], @intCast(i), sim, w);
        }
    }

    // Step 3: Near-duplicate Union-Find take-stacks
    const uf_parent = try alloc.alloc(u32, n);
    for (0..n) |i| uf_parent[i] = @intCast(i);

    for (0..n) |i| {
        for (adj[i].items) |e| {
            if (e.to > i and e.sim >= dedup_sim) {
                if (dedup_group_field != null and active_groups.items[i] != active_groups.items[e.to]) continue;
                ufUnite(uf_parent, @intCast(i), e.to);
            }
        }
    }

    var stack_map = std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)).empty;
    for (0..n) |i| {
        const root = ufFind(uf_parent, @intCast(i));
        const gop = try stack_map.getOrPut(alloc, root);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(alloc, @intCast(i));
    }

    const stack_id_of = try alloc.alloc(u32, n);
    @memset(stack_id_of, 0);
    var stacks: std.ArrayListUnmanaged([]u32) = .empty;
    {
        var sit = stack_map.valueIterator();
        while (sit.next()) |members| {
            if (members.items.len < 2) continue;
            // Choose cover: highest degree in k-NN graph (tiebreak: lowest index)
            var best_pos: usize = 0;
            var best_deg: usize = adj[members.items[0]].items.len;
            for (members.items[1..], 1..) |m_idx, pos| {
                const deg = adj[m_idx].items.len;
                if (deg > best_deg) {
                    best_deg = deg;
                    best_pos = pos;
                }
            }
            if (best_pos != 0) std.mem.swap(u32, &members.items[0], &members.items[best_pos]);
            const sid: u32 = @intCast(stacks.items.len + 1);
            for (members.items) |m_idx| stack_id_of[m_idx] = sid;
            try stacks.append(alloc, members.items);
        }
    }

    // Step 4: 2-phase Louvain community detection on positive-weight edges
    const raw_labels = try runLouvain(alloc, adj, resolution);

    // Step 5: Absorb tiny communities and renumber 0..C-1 by descending size
    const auto_min: usize = std.math.clamp(@as(usize, @intFromFloat(@round(@sqrt(@as(f64, @floatFromInt(n))) / 3.0))), 4, 24);
    const min_cluster_size = if (min_cluster_size_opt > 0) min_cluster_size_opt else if (n < 16) 2 else auto_min;

    const labels = try absorbAndCompactClusters(alloc, adj, raw_labels, min_cluster_size);

    // Count clusters
    var max_label: i32 = -1;
    for (labels) |lb| {
        if (lb > max_label) max_label = lb;
    }
    const num_clusters: usize = if (max_label >= 0) @intCast(max_label + 1) else 0;

    // Group members per cluster
    const cluster_members = try alloc.alloc(std.ArrayListUnmanaged(u32), num_clusters);
    for (cluster_members) |*cm| cm.* = .empty;
    for (labels, 0..) |lb, i| {
        if (lb >= 0) {
            try cluster_members[@intCast(lb)].append(alloc, @intCast(i));
        }
    }

    // Step 6: Compute normalized centroids, cohesion, and top-6 diverse medoids per cluster
    const centroids = try alloc.alloc([]f32, num_clusters);
    const cohesions = try alloc.alloc(f32, num_clusters);
    const medoids = try alloc.alloc([]u32, num_clusters);

    const ScoredMember = struct { idx: u32, sim: f32 };
    for (0..num_clusters) |c| {
        const members = cluster_members[c].items;
        const cent = try alloc.alloc(f32, dim);
        @memset(cent, 0.0);
        for (members) |m_idx| {
            const v = active_vecs.items[m_idx];
            for (0..dim) |d| cent[d] += v[d];
        }
        var norm_sq: f64 = 0.0;
        for (cent) |x| norm_sq += @as(f64, x) * @as(f64, x);
        const inv_norm: f32 = if (norm_sq > 1e-12) @floatCast(1.0 / @sqrt(norm_sq)) else 0.0;
        for (cent) |*x| x.* *= inv_norm;
        centroids[c] = cent;

        const scored = try alloc.alloc(ScoredMember, members.len);
        var sim_sum: f64 = 0.0;
        for (members, 0..) |m_idx, pos| {
            const s = distance.cosine(active_vecs.items[m_idx], cent);
            scored[pos] = .{ .idx = m_idx, .sim = s };
            sim_sum += s;
        }
        cohesions[c] = if (members.len > 0) @floatCast(sim_sum / @as(f64, @floatFromInt(members.len))) else 0.0;

        std.sort.heap(ScoredMember, scored, {}, struct {
            fn desc(_: void, a: ScoredMember, b: ScoredMember) bool {
                return a.sim > b.sim;
            }
        }.desc);

        // Pick up to 6 diverse exemplars: top 4 stack-deduped + 50th & 75th percentile
        var picked: std.ArrayListUnmanaged(u32) = .empty;
        var seen_stacks = std.AutoHashMapUnmanaged(u32, void).empty;
        for (scored) |sm| {
            if (picked.items.len >= 4) break;
            const st = stack_id_of[sm.idx];
            if (st > 0 and seen_stacks.contains(st)) continue;
            if (st > 0) try seen_stacks.put(alloc, st, {});
            try picked.append(alloc, sm.idx);
        }
        const fracs = [_]f32{ 0.5, 0.75, 0.25, 0.9 };
        for (fracs) |frac| {
            if (picked.items.len >= 6 or picked.items.len >= scored.len) break;
            const pos = @min(scored.len - 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(scored.len)) * frac)));
            const cand = scored[pos].idx;
            if (std.mem.indexOfScalar(u32, picked.items, cand) == null) {
                try picked.append(alloc, cand);
            }
        }
        for (scored) |sm| {
            if (picked.items.len >= 6) break;
            if (std.mem.indexOfScalar(u32, picked.items, sm.idx) == null) {
                try picked.append(alloc, sm.idx);
            }
        }
        medoids[c] = picked.items;
    }

    // Step 7: Pairwise centroid merge candidates
    const MergePair = struct { a: u32, b: u32, sim: f32 };
    var merge_pairs: std.ArrayListUnmanaged(MergePair) = .empty;
    for (0..num_clusters) |a| {
        var b = a + 1;
        while (b < num_clusters) : (b += 1) {
            const s = distance.cosine(centroids[a], centroids[b]);
            if (s >= merge_sim) {
                try merge_pairs.append(alloc, .{ .a = @intCast(a), .b = @intCast(b), .sim = s });
            }
        }
    }
    std.sort.heap(MergePair, merge_pairs.items, {}, struct {
        fn desc(_: void, x: MergePair, y: MergePair) bool {
            return x.sim > y.sim;
        }
    }.desc);
    const merge_emit_len = @min(merge_pairs.items.len, 200);

    // Step 8: Serialize compact JSON response
    const elapsed_ms = @max(0, compat.nowMs() - start_ms);
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.ensureTotalCapacity(alloc, n * 16 + num_clusters * 96 + 256);

    var num_buf: [48]u8 = undefined;
    try json.appendSlice(alloc, "{\"count\":");
    try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch "0");
    try json.appendSlice(alloc, ",\"elapsed_ms\":");
    try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{elapsed_ms}) catch "0");

    try json.appendSlice(alloc, ",\"keys\":[");
    for (active_suffixes.items, 0..) |suf, i| {
        if (i > 0) try json.append(alloc, ',');
        try json.append(alloc, '"');
        try appendJsonEscaped(&json, alloc, suf);
        try json.append(alloc, '"');
    }

    try json.appendSlice(alloc, "],\"labels\":[");
    for (labels, 0..) |lb, i| {
        if (i > 0) try json.append(alloc, ',');
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{lb}) catch "-1");
    }

    try json.appendSlice(alloc, "],\"stacks\":[");
    for (stacks.items, 0..) |st, si| {
        if (si > 0) try json.append(alloc, ',');
        try json.append(alloc, '[');
        for (st, 0..) |m_idx, mi| {
            if (mi > 0) try json.append(alloc, ',');
            try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{m_idx}) catch "0");
        }
        try json.append(alloc, ']');
    }

    try json.appendSlice(alloc, "],\"clusters\":[");
    for (0..num_clusters) |c| {
        if (c > 0) try json.append(alloc, ',');
        try json.appendSlice(alloc, "{\"id\":");
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{c}) catch "0");
        try json.appendSlice(alloc, ",\"size\":");
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{cluster_members[c].items.len}) catch "0");
        try json.appendSlice(alloc, ",\"cohesion\":");
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d:.4}", .{cohesions[c]}) catch "0");
        try json.appendSlice(alloc, ",\"medoids\":[");
        for (medoids[c], 0..) |m_idx, mi| {
            if (mi > 0) try json.append(alloc, ',');
            try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{m_idx}) catch "0");
        }
        try json.appendSlice(alloc, "]}");
    }

    try json.appendSlice(alloc, "],\"merge_candidates\":[");
    for (merge_pairs.items[0..merge_emit_len], 0..) |mp, mi| {
        if (mi > 0) try json.append(alloc, ',');
        try json.appendSlice(alloc, "{\"a\":");
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{mp.a}) catch "0");
        try json.appendSlice(alloc, ",\"b\":");
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{mp.b}) catch "0");
        try json.appendSlice(alloc, ",\"sim\":");
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d:.4}", .{mp.sim}) catch "0");
        try json.append(alloc, '}');
    }
    try json.appendSlice(alloc, "]}");

    return ctx.value(try json.toOwnedSlice(alloc));
}

fn upsertEdge(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(Edge), to: u32, sim: f32, w: f32) !void {
    for (list.items) |*e| {
        if (e.to == to) {
            if (sim > e.sim) e.sim = sim;
            if (w > e.w) e.w = w;
            return;
        }
    }
    try list.append(alloc, .{ .to = to, .sim = sim, .w = w });
}

fn ufFind(parent: []u32, x_in: u32) u32 {
    var x = x_in;
    while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    return x;
}

fn ufUnite(parent: []u32, a: u32, b: u32) void {
    const ra = ufFind(parent, a);
    const rb = ufFind(parent, b);
    if (ra != rb) parent[rb] = ra;
}

/// 2-phase Louvain modularity optimization on weighted undirected graph.
fn runLouvain(alloc: std.mem.Allocator, base_adj: []const std.ArrayListUnmanaged(Edge), resolution: f64) ![]u32 {
    const orig_n = base_adj.len;
    const orig_comm = try alloc.alloc(u32, orig_n);
    for (0..orig_n) |i| orig_comm[i] = @intCast(i);

    // Build level-0 weighted adjacency (only w > 0)
    var cur_n: usize = orig_n;
    var cur_adj = try alloc.alloc(std.ArrayListUnmanaged(WeightedEdge), cur_n);
    for (0..cur_n) |i| {
        cur_adj[i] = .empty;
        for (base_adj[i].items) |e| {
            if (e.w > 0.0) {
                try cur_adj[i].append(alloc, .{ .to = e.to, .w = e.w });
            }
        }
    }

    var level: usize = 0;
    while (level < 4) : (level += 1) {
        const ki = try alloc.alloc(f64, cur_n);
        const tot = try alloc.alloc(f64, cur_n);
        const comm = try alloc.alloc(u32, cur_n);
        var m2: f64 = 0.0;

        for (0..cur_n) |i| {
            var deg: f64 = 0.0;
            for (cur_adj[i].items) |e| deg += e.w;
            ki[i] = deg;
            tot[i] = deg;
            comm[i] = @intCast(i);
            m2 += deg;
        }
        if (m2 <= 1e-12) break;

        var neigh_weights = std.AutoHashMapUnmanaged(u32, f64).empty;
        var any_level_move = false;
        var pass: usize = 0;
        while (pass < 25) : (pass += 1) {
            var moved = false;
            for (0..cur_n) |i| {
                const k_i = ki[i];
                if (k_i <= 0.0) continue;
                const old_c = comm[i];

                neigh_weights.clearRetainingCapacity();
                for (cur_adj[i].items) |e| {
                    if (e.to == i) continue;
                    const nc = comm[e.to];
                    const gop = try neigh_weights.getOrPut(alloc, nc);
                    if (gop.found_existing) {
                        gop.value_ptr.* += e.w;
                    } else {
                        gop.value_ptr.* = e.w;
                    }
                }

                tot[old_c] -= k_i;
                const w_old = neigh_weights.get(old_c) orelse 0.0;
                var best_c = old_c;
                var best_gain: f64 = w_old - resolution * (tot[old_c] * k_i) / m2;

                var nit = neigh_weights.iterator();
                while (nit.next()) |kv| {
                    const cand_c = kv.key_ptr.*;
                    const gain = kv.value_ptr.* - resolution * (tot[cand_c] * k_i) / m2;
                    if (gain > best_gain + 1e-12 or (@abs(gain - best_gain) <= 1e-12 and cand_c < best_c)) {
                        best_gain = gain;
                        best_c = cand_c;
                    }
                }

                tot[best_c] += k_i;
                if (best_c != old_c) {
                    comm[i] = best_c;
                    moved = true;
                    any_level_move = true;
                }
            }
            if (!moved) break;
        }

        if (!any_level_move) break;

        // Compact communities at this level -> super_id
        var remap = std.AutoHashMapUnmanaged(u32, u32).empty;
        var next_super: u32 = 0;
        for (0..cur_n) |i| {
            const gop = try remap.getOrPut(alloc, comm[i]);
            if (!gop.found_existing) {
                gop.value_ptr.* = next_super;
                next_super += 1;
            }
            comm[i] = gop.value_ptr.*;
        }

        // Propagate to original nodes
        for (0..orig_n) |i| {
            orig_comm[i] = comm[orig_comm[i]];
        }

        if (next_super == cur_n or next_super <= 1) break;

        // Coarsen graph
        const new_n: usize = next_super;
        const new_adj = try alloc.alloc(std.ArrayListUnmanaged(WeightedEdge), new_n);
        for (new_adj) |*list| list.* = .empty;

        const edge_maps = try alloc.alloc(std.AutoHashMapUnmanaged(u32, f32), new_n);
        for (edge_maps) |*m| m.* = .empty;

        for (0..cur_n) |u| {
            const cu = comm[u];
            for (cur_adj[u].items) |e| {
                const cv = comm[e.to];
                const gop = try edge_maps[cu].getOrPut(alloc, cv);
                if (gop.found_existing) {
                    gop.value_ptr.* += e.w;
                } else {
                    gop.value_ptr.* = e.w;
                }
            }
        }
        for (0..new_n) |cu| {
            var eit = edge_maps[cu].iterator();
            while (eit.next()) |kv| {
                try new_adj[cu].append(alloc, .{ .to = kv.key_ptr.*, .w = kv.value_ptr.* });
            }
        }
        cur_n = new_n;
        cur_adj = new_adj;
    }

    return orig_comm;
}

fn absorbAndCompactClusters(
    alloc: std.mem.Allocator,
    adj: []const std.ArrayListUnmanaged(Edge),
    raw_labels: []const u32,
    min_size: usize,
) ![]i32 {
    const n = raw_labels.len;
    var counts = std.AutoHashMapUnmanaged(u32, usize).empty;
    for (raw_labels) |lb| {
        const gop = try counts.getOrPut(alloc, lb);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }

    const assigned = try alloc.alloc(i64, n);
    for (raw_labels, 0..) |lb, i| {
        if ((counts.get(lb) orelse 0) >= min_size) {
            assigned[i] = @intCast(lb);
        } else {
            // Find strongest connected valid community
            var scores = std.AutoHashMapUnmanaged(u32, f32).empty;
            for (adj[i].items) |e| {
                const nlb = raw_labels[e.to];
                if ((counts.get(nlb) orelse 0) < min_size) continue;
                const gop = try scores.getOrPut(alloc, nlb);
                if (gop.found_existing) gop.value_ptr.* += e.sim else gop.value_ptr.* = e.sim;
            }
            var best_lb: i64 = -1;
            var best_s: f32 = 0.0;
            var sit = scores.iterator();
            while (sit.next()) |kv| {
                if (kv.value_ptr.* > best_s) {
                    best_s = kv.value_ptr.*;
                    best_lb = @intCast(kv.key_ptr.*);
                }
            }
            assigned[i] = best_lb;
        }
    }

    // Count final communities and sort descending by size
    var final_counts = std.AutoHashMapUnmanaged(i64, usize).empty;
    for (assigned) |lb| {
        if (lb < 0) continue;
        const gop = try final_counts.getOrPut(alloc, lb);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }

    const Pair = struct { old_id: i64, size: usize };
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    var fit = final_counts.iterator();
    while (fit.next()) |kv| {
        try pairs.append(alloc, .{ .old_id = kv.key_ptr.*, .size = kv.value_ptr.* });
    }
    std.sort.heap(Pair, pairs.items, {}, struct {
        fn desc(_: void, a: Pair, b: Pair) bool {
            if (a.size != b.size) return a.size > b.size;
            return a.old_id < b.old_id;
        }
    }.desc);

    var compact_map = std.AutoHashMapUnmanaged(i64, i32).empty;
    for (pairs.items, 0..) |p, new_id| {
        try compact_map.put(alloc, p.old_id, @intCast(new_id));
    }

    const out = try alloc.alloc(i32, n);
    for (assigned, 0..) |lb, i| {
        out[i] = if (lb < 0) -1 else (compact_map.get(lb) orelse -1);
    }
    return out;
}

fn jsonF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |iv| @floatFromInt(iv),
        .float => |fv| fv,
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

test "vcluster separates two orthogonal clusters and detects near-duplicate stack" {
    const testing = std.testing;
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();
    var store = try Store.initWithRegistry(testing.allocator, .{ .persistence = .none }, &reg);
    defer store.deinit();

    const ns_idx = try reg.getOrCreate("vec:test:", .cosine);
    ns_idx.lock.lock();
    // Cluster A around [1, 0, 0, 0] (with items 1 & 2 near-identical for take-stack)
    const a_vecs = [_][4]f32{
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.999, 0.04, 0.0, 0.0 },
        .{ 0.96, 0.28, 0.0, 0.0 },
        .{ 0.94, 0.0, 0.34, 0.0 },
        .{ 0.95, 0.15, 0.27, 0.0 },
    };
    // Cluster B around [0, 0, 0, 1]
    const b_vecs = [_][4]f32{
        .{ 0.0, 0.0, 0.0, 1.0 },
        .{ 0.0, 0.1, 0.0, 0.995 },
        .{ 0.0, 0.0, 0.2, 0.98 },
        .{ 0.0, 0.2, 0.1, 0.974 },
        .{ 0.0, 0.15, 0.15, 0.977 },
    };
    var kbuf: [32]u8 = undefined;
    for (a_vecs, 0..) |v, i| {
        const k = try std.fmt.bufPrint(&kbuf, "vec:test:a{d}", .{i});
        _ = try ns_idx.insertLocked(k, &v, 100 + i);
    }
    for (b_vecs, 0..) |v, i| {
        const k = try std.fmt.bufPrint(&kbuf, "vec:test:b{d}", .{i});
        _ = try ns_idx.insertLocked(k, &v, 200 + i);
    }
    ns_idx.lock.unlock();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = &[_][]const u8{ "vec:test:", "{\"k\":5,\"min_cluster_size\":3,\"dedup_sim\":0.99}" };
    var ctx = Ctx.init(&store, args, arena.allocator(), null, null, null, &reg);
    defer ctx.deinit();

    const res = try execute(&ctx);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, res.value.?, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 10), root.get("count").?.integer);
    try testing.expectEqual(@as(usize, 2), root.get("clusters").?.array.items.len);
    try testing.expect(root.get("stacks").?.array.items.len >= 1);
}
