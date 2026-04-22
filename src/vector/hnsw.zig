//! HNSW (Hierarchical Navigable Small World) graph index.
//!
//! In-memory approximate nearest-neighbor search. MVP implementation:
//!   - Fixed cosine distance (1 − cos_sim). L2/dot variants deferred.
//!   - Owned aligned vector storage (copy on insert).
//!   - Single-metric, single-dimension per index (captured on first insert).
//!   - No internal concurrency: caller serializes inserts and may run
//!     concurrent searches as long as no insert is in flight.
//!
//! Reference: Malkov & Yashunin 2018, arXiv:1603.09320
//!   Algorithm 1 — insert
//!   Algorithm 2 — search_layer
//!   Algorithm 4 — select_neighbors_heuristic (preferred over Alg. 3)
//!   Algorithm 5 — search_knn (top-level kNN)

const std = @import("std");
const distance = @import("distance.zig");

pub const HnswError = error{
    DimensionMismatch,
    EmptyIndex,
    OutOfMemory,
};

pub const HnswParams = struct {
    /// Max neighbors per node at levels > 0.
    m: u32 = 16,
    /// Max neighbors at level 0 (paper: 2×m).
    m_max0: u32 = 32,
    /// Candidate-list size during insert (quality ↔ build speed).
    ef_construction: u32 = 200,
    /// Level-assignment factor. Paper recommends 1/ln(m).
    /// For m=16: 1/ln(16) ≈ 0.3607.
    ml: f32 = 0.3606737602222409,
    /// Deterministic RNG seed for level sampling. Change per instance in
    /// production if you want independent layer distributions.
    seed: u64 = 0xC0FFEE,
};

/// Result from `search`. `id` is the internal node index; map back to the
/// caller's key via whatever side table you maintained at insert time.
pub const SearchResult = struct {
    id: u32,
    /// Cosine distance (1 − cosine_similarity); lower = closer.
    dist: f32,
};

/// A neighbor list. Fixed capacity per level (M at >0, M_max0 at 0).
/// Stored as a flat slice with an explicit count so we can truncate without
/// reallocating during connection-pruning.
const NeighborList = struct {
    items: []u32,
    count: u32,
};

const Node = struct {
    /// Owned aligned vector bytes. `vector.len == hnsw.dim`.
    vector: []align(16) f32,
    /// Highest level this node participates in.
    level: u8,
    /// `neighbors[lc]` is the neighbor list at level `lc` for `lc ∈ [0, level]`.
    /// Outer slice length is `level + 1`.
    neighbors: []NeighborList,
};

/// Priority queue element for both insert and search.
const PQItem = struct {
    id: u32,
    dist: f32,
};

fn pqMinOrder(_: void, a: PQItem, b: PQItem) std.math.Order {
    return std.math.order(a.dist, b.dist);
}

fn pqMaxOrder(_: void, a: PQItem, b: PQItem) std.math.Order {
    return std.math.order(b.dist, a.dist);
}

const MinPQ = std.PriorityQueue(PQItem, void, pqMinOrder);
const MaxPQ = std.PriorityQueue(PQItem, void, pqMaxOrder);

pub const Hnsw = struct {
    allocator: std.mem.Allocator,
    params: HnswParams,
    /// Vector dimension, captured on first insert. 0 means "no nodes yet".
    dim: usize,
    nodes: std.ArrayListUnmanaged(Node),
    entry_point: ?u32,
    /// Highest level across all nodes.
    top_level: u8,
    rng: std.Random.Xoshiro256,

    pub fn init(allocator: std.mem.Allocator, params: HnswParams) Hnsw {
        return .{
            .allocator = allocator,
            .params = params,
            .dim = 0,
            .nodes = .empty,
            .entry_point = null,
            .top_level = 0,
            .rng = std.Random.Xoshiro256.init(params.seed),
        };
    }

    pub fn deinit(self: *Hnsw) void {
        for (self.nodes.items) |*node| {
            for (node.neighbors) |nl| self.allocator.free(nl.items);
            self.allocator.free(node.neighbors);
            self.allocator.free(node.vector);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn len(self: *const Hnsw) usize {
        return self.nodes.items.len;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Distance                                          ║
    // ╚═══════════════════════════════════════════════════╝

    /// Cosine distance: 1 − cos_sim(a, b). Range [0, 2]. Smaller = closer.
    /// Returns 1.0 for degenerate (zero-norm) inputs — safer than NaN.
    inline fn cosineDistance(a: []align(1) const f32, b: []align(1) const f32) f32 {
        const sim = distance.cosine(a, b);
        return 1.0 - sim;
    }

    inline fn distToNode(self: *const Hnsw, query: []align(1) const f32, node_id: u32) f32 {
        const node = &self.nodes.items[node_id];
        const v: []align(1) const f32 = @ptrCast(node.vector);
        return cosineDistance(query, v);
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Level sampling                                    ║
    // ╚═══════════════════════════════════════════════════╝

    fn sampleLevel(self: *Hnsw) u8 {
        const r = self.rng.random().float(f32);
        // Clamp r to avoid log(0). Strictly positive.
        const r_clamped = @max(r, std.math.floatMin(f32));
        const raw = -@log(r_clamped) * self.params.ml;
        // Cap at 31 for sanity (vanishingly small probability anyway).
        return @min(31, @as(u8, @intFromFloat(raw)));
    }

    fn maxNeighborsAtLevel(self: *const Hnsw, lc: u8) u32 {
        return if (lc == 0) self.params.m_max0 else self.params.m;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Node allocation                                   ║
    // ╚═══════════════════════════════════════════════════╝

    fn allocateNode(self: *Hnsw, vector: []const f32, level: u8) !Node {
        // Aligned vector buffer (16-byte alignment sufficient for AVX2 loads).
        const vec_buf = try self.allocator.alignedAlloc(f32, .@"16", vector.len);
        errdefer self.allocator.free(vec_buf);
        @memcpy(vec_buf, vector);

        // Per-level neighbor lists, length = level + 1.
        const levels_count = @as(usize, level) + 1;
        const neighbors = try self.allocator.alloc(NeighborList, levels_count);
        errdefer self.allocator.free(neighbors);

        // Allocate each level's buffer. On failure, free what we've done.
        var allocated: usize = 0;
        errdefer {
            for (neighbors[0..allocated]) |nl| self.allocator.free(nl.items);
        }
        for (neighbors, 0..) |*nl, lc| {
            const cap = self.maxNeighborsAtLevel(@intCast(lc));
            nl.* = .{
                .items = try self.allocator.alloc(u32, cap),
                .count = 0,
            };
            allocated += 1;
        }

        return .{ .vector = vec_buf, .level = level, .neighbors = neighbors };
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Algorithm 2 — search_layer                        ║
    // ╚═══════════════════════════════════════════════════╝

    /// Beam-search over one level. Starting from `entry_ids`, explore up to
    /// `ef` closest candidates to `query` at level `lc`. Returns the set
    /// (as a max-heap so the furthest is at the root) for further use by
    /// caller. Caller owns the returned MaxPQ and must deinit it.
    ///
    /// `visited` is a caller-supplied scratch bit-set sized to `nodes.len`;
    /// it is cleared at entry. Reuse across calls avoids reallocation.
    fn searchLayer(
        self: *Hnsw,
        query: []align(1) const f32,
        entry_ids: []const u32,
        ef: usize,
        lc: u8,
        visited: *std.DynamicBitSetUnmanaged,
    ) !MaxPQ {
        // Reset visited (caller guarantees it's sized for current nodes.len).
        visited.unsetAll();

        var candidates: MinPQ = .empty;
        defer candidates.deinit(self.allocator);

        var w: MaxPQ = .empty;
        errdefer w.deinit(self.allocator);

        // Seed both heaps with the entry points.
        for (entry_ids) |ep| {
            if (ep >= self.nodes.items.len) continue;
            const d = self.distToNode(query, ep);
            try candidates.push(self.allocator, .{ .id = ep, .dist = d });
            try w.push(self.allocator, .{ .id = ep, .dist = d });
            visited.set(ep);
        }

        while (candidates.pop()) |c| {
            // Termination: if the closest unexplored candidate is further
            // than our worst kept neighbor, the beam can't improve.
            const furthest_dist = if (w.peek()) |f| f.dist else std.math.inf(f32);
            if (c.dist > furthest_dist and w.count() >= ef) break;

            const node = &self.nodes.items[c.id];
            if (lc > node.level) continue; // defensive
            const nbrs = node.neighbors[lc];
            for (nbrs.items[0..nbrs.count]) |nb_id| {
                if (visited.isSet(nb_id)) continue;
                visited.set(nb_id);

                const d = self.distToNode(query, nb_id);
                const worst = if (w.peek()) |f| f.dist else std.math.inf(f32);

                if (d < worst or w.count() < ef) {
                    try candidates.push(self.allocator, .{ .id = nb_id, .dist = d });
                    try w.push(self.allocator, .{ .id = nb_id, .dist = d });
                    if (w.count() > ef) _ = w.pop();
                }
            }
        }

        return w;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Algorithm 4 — select_neighbors (heuristic)        ║
    // ╚═══════════════════════════════════════════════════╝

    /// Given a candidate set `w` (a max-heap), pick at most `m_target`
    /// neighbors using the diversity-preserving heuristic: a candidate is
    /// kept only if it is closer to the query than it is to any already-
    /// selected neighbor.
    ///
    /// Returns the selected IDs via `out_buf`; returns the number written.
    fn selectNeighborsHeuristic(
        self: *Hnsw,
        w: *MaxPQ,
        m_target: u32,
        out_buf: []u32,
    ) !usize {
        // Drain w into a slice sorted by distance ascending.
        const cand_count = w.count();
        var sorted = try self.allocator.alloc(PQItem, cand_count);
        defer self.allocator.free(sorted);

        // MaxPQ.pop yields descending; fill from the back to get ascending.
        var i: usize = cand_count;
        while (i > 0) : (i -= 1) {
            sorted[i - 1] = w.pop().?;
        }

        var selected: usize = 0;
        outer: for (sorted) |cand| {
            if (selected >= m_target) break;
            // Keep cand only if it is closer to the query than to any
            // already-selected neighbor.
            const cand_vec: []align(1) const f32 = @ptrCast(self.nodes.items[cand.id].vector);
            for (out_buf[0..selected]) |sid| {
                const s_vec: []align(1) const f32 = @ptrCast(self.nodes.items[sid].vector);
                const d_to_selected = cosineDistance(cand_vec, s_vec);
                if (d_to_selected < cand.dist) continue :outer;
            }
            out_buf[selected] = cand.id;
            selected += 1;
        }
        return selected;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Algorithm 1 — insert                              ║
    // ╚═══════════════════════════════════════════════════╝

    /// Insert a vector. Returns the assigned node ID.
    ///
    /// Thread safety: caller must serialize inserts. Searches on the same
    /// graph from other threads are unsafe during insert (the graph shape
    /// is mutating).
    pub fn insert(self: *Hnsw, vector: []const f32) !u32 {
        if (self.dim == 0) {
            self.dim = vector.len;
        } else if (vector.len != self.dim) {
            return error.DimensionMismatch;
        }

        const new_level = self.sampleLevel();
        const new_id: u32 = @intCast(self.nodes.items.len);

        // Allocate + insert the node into the flat array.
        const node = try self.allocateNode(vector, new_level);
        errdefer {
            for (node.neighbors) |nl| self.allocator.free(nl.items);
            self.allocator.free(node.neighbors);
            self.allocator.free(node.vector);
        }
        try self.nodes.append(self.allocator, node);

        // First node: becomes the entry point. No neighbors to connect.
        if (self.entry_point == null) {
            self.entry_point = new_id;
            self.top_level = new_level;
            return new_id;
        }

        // Scratch bit-set for search_layer; sized once to cover new node too.
        var visited = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.nodes.items.len);
        defer visited.deinit(self.allocator);

        const query_vec: []align(1) const f32 = @ptrCast(node.vector);

        // ── Phase 1: descend from top to new_level+1 with ef=1 ──
        var current_ep: u32 = self.entry_point.?;
        var lc: i32 = self.top_level;
        while (lc > new_level) : (lc -= 1) {
            var w = try self.searchLayer(
                query_vec,
                &.{current_ep},
                1,
                @intCast(lc),
                &visited,
            );
            defer w.deinit(self.allocator);
            // ef=1, so only one candidate — pull it out.
            if (w.peek()) |best| current_ep = best.id;
        }

        // ── Phase 2: for each level ≤ new_level, search and connect ──
        var eps: std.ArrayListUnmanaged(u32) = .empty;
        defer eps.deinit(self.allocator);
        try eps.append(self.allocator, current_ep);

        // Buffer reused for selectNeighborsHeuristic output.
        const max_m = @max(self.params.m, self.params.m_max0);
        const sel_buf = try self.allocator.alloc(u32, max_m);
        defer self.allocator.free(sel_buf);

        lc = @min(@as(i32, self.top_level), @as(i32, new_level));
        while (lc >= 0) : (lc -= 1) {
            const level: u8 = @intCast(lc);
            var w = try self.searchLayer(
                query_vec,
                eps.items,
                self.params.ef_construction,
                level,
                &visited,
            );
            // Re-seed eps for next level from the candidate set before we consume w.
            eps.clearRetainingCapacity();
            {
                var it = w.iterator();
                while (it.next()) |item| try eps.append(self.allocator, item.id);
            }

            const m_target = self.maxNeighborsAtLevel(level);
            const n_selected = try self.selectNeighborsHeuristic(&w, m_target, sel_buf);
            w.deinit(self.allocator);

            // Connect new_id → selected neighbors at this level.
            const self_nbrs = &self.nodes.items[new_id].neighbors[level];
            for (sel_buf[0..n_selected]) |nb_id| {
                self_nbrs.items[self_nbrs.count] = nb_id;
                self_nbrs.count += 1;
            }

            // Add back-edges and prune if over capacity.
            for (sel_buf[0..n_selected]) |nb_id| {
                try self.addBackEdge(nb_id, new_id, level, query_vec);
            }
        }

        // Promote entry point if this node reaches a new max level.
        if (new_level > self.top_level) {
            self.top_level = new_level;
            self.entry_point = new_id;
        }

        return new_id;
    }

    /// Add an edge from `nb_id` back to `new_id` at level `lc`. If the
    /// neighbor list overflows, re-select via the heuristic from its full
    /// neighborhood (existing ones + new candidate).
    fn addBackEdge(
        self: *Hnsw,
        nb_id: u32,
        new_id: u32,
        lc: u8,
        _: []align(1) const f32, // query context not needed; we prune relative to nb_id
    ) !void {
        const nb_node = &self.nodes.items[nb_id];
        const nb_nbrs = &nb_node.neighbors[lc];
        const cap = self.maxNeighborsAtLevel(lc);

        if (nb_nbrs.count < cap) {
            nb_nbrs.items[nb_nbrs.count] = new_id;
            nb_nbrs.count += 1;
            return;
        }

        // Over capacity — prune by running the heuristic against (existing + new)
        // from nb_id's perspective.
        var candidates: MaxPQ = .empty;
        defer candidates.deinit(self.allocator);

        const nb_vec: []align(1) const f32 = @ptrCast(nb_node.vector);
        for (nb_nbrs.items[0..nb_nbrs.count]) |id| {
            const other_vec: []align(1) const f32 = @ptrCast(self.nodes.items[id].vector);
            const d = cosineDistance(nb_vec, other_vec);
            try candidates.push(self.allocator, .{ .id = id, .dist = d });
        }
        const new_vec: []align(1) const f32 = @ptrCast(self.nodes.items[new_id].vector);
        const d_new = cosineDistance(nb_vec, new_vec);
        try candidates.push(self.allocator, .{ .id = new_id, .dist = d_new });

        const sel_buf = try self.allocator.alloc(u32, cap);
        defer self.allocator.free(sel_buf);

        // Heuristic select uses the query perspective — but here the "query"
        // is nb_id itself. Run a local variant inline.
        const n_selected = try self.selectNeighborsFrom(nb_id, &candidates, cap, sel_buf);

        // Replace nb's neighbor list with the selected set.
        nb_nbrs.count = @intCast(n_selected);
        @memcpy(nb_nbrs.items[0..n_selected], sel_buf[0..n_selected]);
    }

    /// Heuristic variant where the "query" is a specific node (not an
    /// external query vector). Used by addBackEdge's pruning.
    fn selectNeighborsFrom(
        self: *Hnsw,
        center_id: u32,
        w: *MaxPQ,
        m_target: u32,
        out_buf: []u32,
    ) !usize {
        const cand_count = w.count();
        var sorted = try self.allocator.alloc(PQItem, cand_count);
        defer self.allocator.free(sorted);

        var i: usize = cand_count;
        while (i > 0) : (i -= 1) {
            sorted[i - 1] = w.pop().?;
        }

        _ = center_id; // the dists in PQItem are already relative to center_id
        var selected: usize = 0;
        outer: for (sorted) |cand| {
            if (selected >= m_target) break;
            const cand_vec: []align(1) const f32 = @ptrCast(self.nodes.items[cand.id].vector);
            for (out_buf[0..selected]) |sid| {
                const s_vec: []align(1) const f32 = @ptrCast(self.nodes.items[sid].vector);
                const d_to_selected = cosineDistance(cand_vec, s_vec);
                if (d_to_selected < cand.dist) continue :outer;
            }
            out_buf[selected] = cand.id;
            selected += 1;
        }
        return selected;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Algorithm 5 — search_knn                          ║
    // ╚═══════════════════════════════════════════════════╝

    /// k-NN search. Fills `out` with up to `k` results sorted by ascending
    /// distance. Returns the number of results written (≤ k; may be < k if
    /// the index has fewer nodes).
    ///
    /// `ef` controls recall/speed. Typical values: 50 (fast, ~90% recall)
    /// to 200 (slower, ~98% recall). Must be ≥ k.
    pub fn search(
        self: *Hnsw,
        query: []align(1) const f32,
        k: usize,
        ef: usize,
        out: []SearchResult,
    ) !usize {
        if (self.entry_point == null) return 0;
        if (k == 0) return 0;
        if (self.dim != 0 and query.len != self.dim) return error.DimensionMismatch;
        const effective_ef = @max(ef, k);

        var visited = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, self.nodes.items.len);
        defer visited.deinit(self.allocator);

        // ── Greedy descend from top level with ef=1 ──
        var current_ep: u32 = self.entry_point.?;
        var lc: i32 = self.top_level;
        while (lc > 0) : (lc -= 1) {
            var w = try self.searchLayer(query, &.{current_ep}, 1, @intCast(lc), &visited);
            defer w.deinit(self.allocator);
            if (w.peek()) |best| current_ep = best.id;
        }

        // ── Final layer with full ef ──
        var w = try self.searchLayer(query, &.{current_ep}, effective_ef, 0, &visited);
        defer w.deinit(self.allocator);

        // Drain into `out`, ascending by distance. MaxPQ pops furthest first,
        // so walk backwards.
        const n = @min(k, w.count());
        // We may have more than n in w (up to ef). Discard the extras first.
        while (w.count() > n) _ = w.pop();
        var idx: usize = n;
        while (idx > 0) : (idx -= 1) {
            const top = w.pop().?;
            out[idx - 1] = .{ .id = top.id, .dist = top.dist };
        }
        return n;
    }
};

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

const testing = std.testing;

test "hnsw: empty index returns zero results" {
    var h = Hnsw.init(testing.allocator, .{});
    defer h.deinit();

    var out: [5]SearchResult = undefined;
    const q = [_]f32{ 1, 0, 0, 0 };
    const n = try h.search(&q, 5, 50, &out);
    try testing.expectEqual(@as(usize, 0), n);
}

test "hnsw: single node returns itself" {
    var h = Hnsw.init(testing.allocator, .{});
    defer h.deinit();

    const v = [_]f32{ 1, 0, 0, 0 };
    const id = try h.insert(&v);
    try testing.expectEqual(@as(u32, 0), id);

    var out: [5]SearchResult = undefined;
    const n = try h.search(&v, 5, 50, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 0), out[0].id);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0].dist, 1e-5);
}

test "hnsw: dimension mismatch" {
    var h = Hnsw.init(testing.allocator, .{});
    defer h.deinit();

    _ = try h.insert(&[_]f32{ 1, 0, 0 });
    try testing.expectError(error.DimensionMismatch, h.insert(&[_]f32{ 1, 0, 0, 0 }));

    var out: [1]SearchResult = undefined;
    try testing.expectError(error.DimensionMismatch, h.search(&[_]f32{ 1, 0 }, 1, 50, &out));
}

test "hnsw: recall on synthetic clusters" {
    // 200 vectors in 32 dims across 4 tight clusters. For a query placed at
    // one cluster center, the true top-10 should be the 10 closest points
    // to that center — a small fraction of the dataset.
    var h = Hnsw.init(testing.allocator, .{ .m = 16, .ef_construction = 200 });
    defer h.deinit();

    const dim: usize = 32;
    const n_per_cluster: usize = 50;
    const n_clusters: usize = 4;
    const total = n_per_cluster * n_clusters;

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rand = prng.random();

    // Cluster centers — one-hot-ish on different axes.
    var centers: [n_clusters][dim]f32 = undefined;
    for (&centers, 0..) |*c, i| {
        @memset(c, 0);
        c[i * (dim / n_clusters)] = 1.0;
    }

    // Insert clustered vectors; record which cluster each id belongs to.
    var cluster_of: [total]usize = undefined;
    var id: usize = 0;
    for (&centers, 0..) |c, ci| {
        for (0..n_per_cluster) |_| {
            var v: [dim]f32 = undefined;
            for (0..dim) |d| {
                v[d] = c[d] + 0.05 * (rand.float(f32) - 0.5);
            }
            const gotten = try h.insert(&v);
            cluster_of[gotten] = ci;
            id += 1;
        }
    }

    // Query = cluster-0 center. All 10 returned should be cluster 0.
    const q = centers[0];
    var out: [10]SearchResult = undefined;
    const n = try h.search(&q, 10, 100, &out);
    try testing.expectEqual(@as(usize, 10), n);

    var correct: usize = 0;
    for (out[0..n]) |r| {
        if (cluster_of[r.id] == 0) correct += 1;
    }
    // With ef=100 and tight clusters, recall should be close to 100%.
    // Accept ≥ 9/10 to tolerate any minor algorithmic quirks.
    try testing.expect(correct >= 9);
}

test "hnsw: results sorted by distance ascending" {
    var h = Hnsw.init(testing.allocator, .{});
    defer h.deinit();

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    const dim: usize = 16;
    const n: usize = 100;
    for (0..n) |_| {
        var v: [dim]f32 = undefined;
        for (&v) |*x| x.* = rand.floatNorm(f32);
        _ = try h.insert(&v);
    }

    var q: [dim]f32 = undefined;
    for (&q) |*x| x.* = rand.floatNorm(f32);

    var out: [10]SearchResult = undefined;
    const got = try h.search(&q, 10, 50, &out);
    try testing.expect(got > 0);
    for (1..got) |i| {
        try testing.expect(out[i - 1].dist <= out[i].dist);
    }
}

test "hnsw: distinct levels are sampled" {
    var h = Hnsw.init(testing.allocator, .{ .m = 16 });
    defer h.deinit();

    var seen_levels = [_]bool{false} ** 32;
    for (0..500) |_| {
        const lv = h.sampleLevel();
        seen_levels[lv] = true;
    }
    // Expect level 0 overwhelmingly, but also some ≥1.
    try testing.expect(seen_levels[0]);
    var at_least_one_above_zero = false;
    for (1..32) |i| {
        if (seen_levels[i]) at_least_one_above_zero = true;
    }
    try testing.expect(at_least_one_above_zero);
}

test "hnsw: recall vs brute-force on random data" {
    // Rigorous recall: build an HNSW index over N random vectors, then for
    // several queries compute the brute-force top-10 and compare against
    // HNSW's top-10. Recall@10 should be ≥ 0.9 with ef_search=100 on
    // normal-distributed data.
    const alloc = testing.allocator;
    var h = Hnsw.init(alloc, .{ .m = 16, .ef_construction = 200 });
    defer h.deinit();

    const dim: usize = 48;
    const n: usize = 400;
    const k: usize = 10;

    // Store all vectors for brute-force verification.
    const all_vecs = try alloc.alloc(f32, n * dim);
    defer alloc.free(all_vecs);

    var prng = std.Random.DefaultPrng.init(0xABCDEF);
    const rand = prng.random();
    for (all_vecs) |*x| x.* = rand.floatNorm(f32);

    // Insert.
    for (0..n) |i| {
        const slice = all_vecs[i * dim ..][0..dim];
        _ = try h.insert(slice);
    }

    // Run multiple queries and aggregate recall.
    const n_queries: usize = 20;
    var total_correct: usize = 0;

    for (0..n_queries) |_| {
        var q: [48]f32 = undefined;
        for (&q) |*x| x.* = rand.floatNorm(f32);

        // Brute-force top-k.
        var bf_dists = try alloc.alloc(f32, n);
        defer alloc.free(bf_dists);
        var bf_ids = try alloc.alloc(u32, n);
        defer alloc.free(bf_ids);
        for (0..n) |i| {
            const v = all_vecs[i * dim ..][0..dim];
            const v_align: []align(1) const f32 = @ptrCast(v);
            bf_dists[i] = 1.0 - distance.cosine(&q, v_align);
            bf_ids[i] = @intCast(i);
        }
        // Partial sort: find top-k by distance ascending.
        for (0..k) |i| {
            var min_idx = i;
            for (i + 1..n) |j| {
                if (bf_dists[j] < bf_dists[min_idx]) min_idx = j;
            }
            std.mem.swap(f32, &bf_dists[i], &bf_dists[min_idx]);
            std.mem.swap(u32, &bf_ids[i], &bf_ids[min_idx]);
        }
        const ground_truth = bf_ids[0..k];

        // HNSW top-k.
        var hnsw_out: [k]SearchResult = undefined;
        const got = try h.search(&q, k, 100, &hnsw_out);
        try testing.expectEqual(k, got);

        // Count overlap.
        for (hnsw_out[0..got]) |r| {
            for (ground_truth) |gt| {
                if (r.id == gt) {
                    total_correct += 1;
                    break;
                }
            }
        }
    }

    const recall = @as(f32, @floatFromInt(total_correct)) / @as(f32, @floatFromInt(n_queries * k));
    std.debug.print("[hnsw recall test] recall@{d} = {d:.3} ({d}/{d})\n", .{
        k,
        recall,
        total_correct,
        n_queries * k,
    });
    // Accept ≥ 0.85 on small random dataset; production workloads typically
    // hit 0.95+ with larger N and clustered embeddings.
    try testing.expect(recall >= 0.85);
}

test "hnsw: k larger than index size returns all" {
    var h = Hnsw.init(testing.allocator, .{});
    defer h.deinit();

    for (0..5) |i| {
        var v = [_]f32{ 0, 0, 0, 0 };
        v[i % 4] = @floatFromInt(i + 1);
        _ = try h.insert(&v);
    }

    var out: [50]SearchResult = undefined;
    const q = [_]f32{ 1, 0, 0, 0 };
    const n = try h.search(&q, 50, 50, &out);
    try testing.expectEqual(@as(usize, 5), n);
}
