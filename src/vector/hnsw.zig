//! HNSW (Hierarchical Navigable Small World) graph index.
//!
//! High-performance in-memory approximate nearest-neighbor search:
//!   - Flat 64-byte-aligned contiguous vector slab (zero-padded 16-f32 stride)
//!     and flat 64-byte-aligned level-0 adjacency slab (exact 2 cache lines per
//!     node at default `m_max0 = 32`), with compact upper-layer slab only for
//!     nodes with `level >= 1`.
//!   - Tag-dispatched adaptive SIMD distance kernels (`dotAligned`,
//!     `dotBatch4Aligned`, `l2SquaredAligned`, `l2SquaredBatch4Aligned`):
//!     cosine indexes store unit-normalized vectors so search/build evaluate
//!     pure dot products (zero per-candidate norms/sqrts/divs).
//!   - True greedy hill-climb descent on upper layers (`ef = 1`), 4-way batched
//!     neighbor expansion with filtered multi-line lookahead `@prefetch`,
//!     sparse-reset pooled `SearchScratch` (zero per-query heap allocations),
//!     and mathematically-exact O(1) L0 back-edge pruning fast-skip.
//!   - Thread safety: caller serializes inserts (`lock`) and may run concurrent
//!     searches (`lockShared`) safely via the internal `SearchScratchPool` or
//!     caller-owned `SearchScratch` (`searchWithScratch`).
//!
//! Reference: Malkov & Yashunin 2018, arXiv:1603.09320
//!   Algorithm 1 — insert
//!   Algorithm 2 — search_layer
//!   Algorithm 4 — select_neighbors_heuristic (preferred over Alg. 3)
//!   Algorithm 5 — search_knn (top-level kNN)

const std = @import("std");
const builtin = @import("builtin");
const distance = @import("distance.zig");
const metric_mod = @import("metric.zig");
const topk_mod = @import("topk.zig");

pub const DistFn = metric_mod.DistFn;

/// Self-contained narrow-atomics check matching `src/core/compat.zig` so
/// `zig test src/vector/hnsw.zig` remains standalone-buildable with no parent
/// directory imports AND compiles cleanly for `wasm32-wasi`.
const narrow_atomics = builtin.cpu.arch.isWasm() and !builtin.cpu.has(.wasm, .atomics);

const PoolMutex = struct {
    inner: if (narrow_atomics) struct {} else std.Io.Mutex = if (narrow_atomics) .{} else .init,

    inline fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    inline fn lock(self: *PoolMutex) void {
        if (comptime narrow_atomics) return;
        self.inner.lockUncancelable(io());
    }

    inline fn unlock(self: *PoolMutex) void {
        if (comptime narrow_atomics) return;
        self.inner.unlock(io());
    }
};

pub const HnswError = error{
    DimensionMismatch,
    EmptyIndex,
    OutOfMemory,
    /// A serialized graph references a node whose vector couldn't be
    /// resolved from the surrounding KV state — snapshot is torn.
    MissingVector,
    /// Serialized graph data failed structural validation (unexpected
    /// neighbor counts, etc).
    CorruptGraph,
    /// Reader returned fewer bytes than requested before EOF.
    EndOfStream,
};

fn readAllExact(reader: anytype, dest: []u8) !void {
    var pos: usize = 0;
    while (pos < dest.len) {
        const n = try reader.readAll(dest[pos..]);
        if (n == 0) return error.EndOfStream;
        pos += n;
    }
}

/// Stack-buffered writer used by `writeTo` to coalesce per-field writes into
/// 4 KiB chunks without changing a single output byte.
fn BufferedWriter(comptime InnerPtr: type) type {
    return struct {
        inner: InnerPtr,
        buf: [4096]u8 = undefined,
        pos: usize = 0,

        fn writeAll(self: *@This(), data: []const u8) !void {
            if (data.len <= self.buf.len - self.pos) {
                @memcpy(self.buf[self.pos..][0..data.len], data);
                self.pos += data.len;
                return;
            }
            try self.flush();
            if (data.len >= self.buf.len) {
                try self.inner.writeAll(data);
            } else {
                @memcpy(self.buf[0..data.len], data);
                self.pos = data.len;
            }
        }

        fn flush(self: *@This()) !void {
            if (self.pos > 0) {
                try self.inner.writeAll(self.buf[0..self.pos]);
                self.pos = 0;
            }
        }
    };
}

pub const HnswParams = struct {
    /// Max neighbors per node at levels > 0.
    m: u32 = 16,
    /// Max neighbors at level 0 (paper: 2×m).
    m_max0: u32 = 32,
    /// Candidate-list size during insert (quality ↔ build speed).
    ef_construction: u32 = 100,
    /// Level-assignment factor. Paper recommends 1/ln(m).
    /// For m=16: 1/ln(16) ≈ 0.3607.
    ml: f32 = 0.3606737602222409,
    /// Deterministic RNG seed for level sampling. Change per instance in
    /// production if you want independent layer distributions.
    seed: u64 = 0xC0FFEE,
    /// Distance function driving graph construction and search. Defaults
    /// to cosine distance (1 − cos_sim). See `src/vector/metric.zig`.
    /// Built-in metrics (`cosine_dist`, `dot_dist`, `l2_dist`) are
    /// automatically dispatched to tag-specialized SIMD batch kernels.
    dist_fn: DistFn = metric_mod.cosine_dist,
};

/// Result from `search`. `id` is the internal node index; map back to the
/// caller's key via whatever side table you maintained at insert time.
pub const SearchResult = struct {
    id: u32,
    /// Distance (smaller = closer): cosine `1 − cos_sim` in `[0, 2]`,
    /// dot `−dot(a, b)`, L2 `‖a − b‖²`.
    dist: f32,
};

/// Internal metric classification derived from `HnswParams.dist_fn`.
const MetricKind = enum {
    cosine_unit,
    dot,
    l2,
    custom,

    fn fromDistFn(dist_fn: DistFn) MetricKind {
        if (dist_fn == metric_mod.cosine_dist) return .cosine_unit;
        if (dist_fn == metric_mod.dot_dist) return .dot;
        if (dist_fn == metric_mod.l2_dist) return .l2;
        return .custom;
    }
};

const NO_UPPER: u32 = std.math.maxInt(u32);
const FLAG_L0_PRUNED: u8 = 1 << 0;

/// Compact 8-byte per-node metadata header (8 headers per 64B cache line).
const NodeHeader = struct {
    l0_count: u16,
    level: u8,
    flags: u8,
    /// Starting slot in `upper_counts` / `upper_links` when `level >= 1`,
    /// or `NO_UPPER` when `level == 0` (~93.75% of nodes at M=16).
    upper_offset: u32,
};
comptime {
    std.debug.assert(@sizeOf(NodeHeader) == 8);
}

const PQItem = struct {
    id: u32,
    dist: f32,
};

fn pqDist(item: PQItem) f32 {
    return item.dist;
}

const BoundedResultHeap = topk_mod.BoundedMaxHeap(PQItem, pqDist);

/// Hole-sifting binary min-heap backed by a reusable `ArrayListUnmanaged`.
const MinHeap = struct {
    items: std.ArrayListUnmanaged(PQItem) = .empty,

    fn deinit(self: *MinHeap, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    inline fn clearRetainingCapacity(self: *MinHeap) void {
        self.items.clearRetainingCapacity();
    }

    inline fn peek(self: *const MinHeap) ?PQItem {
        return if (self.items.items.len > 0) self.items.items[0] else null;
    }

    fn push(self: *MinHeap, allocator: std.mem.Allocator, item: PQItem) !void {
        if (self.items.items.len < self.items.capacity) {
            self.items.appendAssumeCapacity(item);
        } else {
            try self.items.append(allocator, item);
        }
        const slice = self.items.items;
        var i = slice.len - 1;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (item.dist >= slice[parent].dist) break;
            slice[i] = slice[parent];
            i = parent;
        }
        slice[i] = item;
    }

    inline fn pop(self: *MinHeap) ?PQItem {
        const n = self.items.items.len;
        if (n == 0) return null;
        const slice = self.items.items;
        const top = slice[0];
        const last = slice[n - 1];
        self.items.items.len = n - 1;
        const new_n = n - 1;
        if (new_n > 0) {
            var i: usize = 0;
            while (true) {
                const l = 2 * i + 1;
                if (l >= new_n) break;
                const r = l + 1;
                var smallest = l;
                var smallest_dist = slice[l].dist;
                if (r < new_n and slice[r].dist < smallest_dist) {
                    smallest = r;
                    smallest_dist = slice[r].dist;
                }
                if (last.dist <= smallest_dist) break;
                slice[i] = slice[smallest];
                i = smallest;
            }
            slice[i] = last;
        }
        return top;
    }
};

/// Cache-dense bitset (`N/8` bytes) with O(visited_words) sparse dirty-word
/// reset. Invariant: `words` is always all-zero outside an active `searchLayer`.
const VisitedSet = struct {
    words: std.ArrayListUnmanaged(u64) = .empty,
    touched: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *VisitedSet, allocator: std.mem.Allocator) void {
        self.words.deinit(allocator);
        self.touched.deinit(allocator);
    }

    fn prepare(self: *VisitedSet, allocator: std.mem.Allocator, node_count: usize) !void {
        const needed_words = (node_count + 63) / 64;
        if (needed_words > self.words.items.len) {
            const old_len = self.words.items.len;
            try self.words.resize(allocator, needed_words);
            @memset(self.words.items[old_len..needed_words], 0);
        }
        const target_touched_cap = @min(needed_words, 512);
        if (self.touched.capacity < target_touched_cap) {
            try self.touched.ensureTotalCapacity(allocator, target_touched_cap);
        }
    }

    inline fn testAndSet(self: *VisitedSet, allocator: std.mem.Allocator, id: u32) !bool {
        const w_idx: usize = @as(usize, id) >> 6;
        const bit: u64 = @as(u64, 1) << @as(u6, @truncate(id));
        const slot = &self.words.items[w_idx];
        const prev = slot.*;
        if ((prev & bit) != 0) return true;
        if (prev == 0) {
            if (self.touched.items.len < self.touched.capacity) {
                self.touched.appendAssumeCapacity(@intCast(w_idx));
            } else {
                try self.touched.append(allocator, @intCast(w_idx));
            }
        }
        slot.* = prev | bit;
        return false;
    }

    inline fn reset(self: *VisitedSet) void {
        const w = self.words.items;
        for (self.touched.items) |idx| {
            w[idx] = 0;
        }
        self.touched.clearRetainingCapacity();
    }
};

/// 64B-aligned zero-length sentinels so `vectorSlab()` and empty slabs are
/// always validly aligned without allocating.
const EMPTY_F32_SLAB: [0]f32 align(64) = .{};
const EMPTY_U32_SLAB: [0]u32 align(64) = .{};

/// Stack buffer capacity for query preparation (covers dims up to 2048 = 8 KiB).
const STACK_QUERY_CAP: usize = 2048;

/// Reusable per-search scratch buffers. Pass one to `Hnsw.searchWithScratch`
/// for zero-allocation, zero-pool-lock repeated searches (e.g. `vcluster`,
/// `vproject_2d`), or let `Hnsw.search` check one out from its internal pool.
pub const SearchScratch = struct {
    visited: VisitedSet = .{},
    candidates: MinHeap = .{},
    results_buf: std.ArrayListUnmanaged(PQItem) = .empty,
    /// Fallback 64B-aligned query buffer for `vec_stride > STACK_QUERY_CAP`.
    query_buf: []align(64) f32 = @constCast(&EMPTY_F32_SLAB),

    pub fn init() SearchScratch {
        return .{};
    }

    pub fn deinit(self: *SearchScratch, allocator: std.mem.Allocator) void {
        self.visited.deinit(allocator);
        self.candidates.deinit(allocator);
        self.results_buf.deinit(allocator);
        if (self.query_buf.len > 0) allocator.free(self.query_buf);
        self.* = .{};
    }

    fn ensureQueryBuf(self: *SearchScratch, allocator: std.mem.Allocator, stride: usize) ![]align(64) f32 {
        if (self.query_buf.len < stride) {
            const fresh = try allocator.alignedAlloc(f32, .@"64", stride);
            if (self.query_buf.len > 0) allocator.free(self.query_buf);
            self.query_buf = fresh;
        }
        return self.query_buf[0..stride];
    }
};

/// Bounded thread-safe pool of `SearchScratch` instances owned by `Hnsw`.
/// Enables concurrent `search()` calls under a shared reader lock with zero
/// steady-state heap allocations and clean teardown on `Hnsw.deinit()`.
const MAX_POOLED_SCRATCHES: usize = 64;

const SearchScratchPool = struct {
    mutex: PoolMutex = .{},
    slots: [MAX_POOLED_SCRATCHES]*SearchScratch = undefined,
    count: usize = 0,

    fn acquire(self: *SearchScratchPool, allocator: std.mem.Allocator) !*SearchScratch {
        self.mutex.lock();
        if (self.count > 0) {
            self.count -= 1;
            const s = self.slots[self.count];
            self.mutex.unlock();
            return s;
        }
        self.mutex.unlock();

        const fresh = try allocator.create(SearchScratch);
        fresh.* = SearchScratch.init();
        return fresh;
    }

    fn release(self: *SearchScratchPool, allocator: std.mem.Allocator, scratch: *SearchScratch) void {
        self.mutex.lock();
        if (self.count < MAX_POOLED_SCRATCHES) {
            self.slots[self.count] = scratch;
            self.count += 1;
            self.mutex.unlock();
            return;
        }
        self.mutex.unlock();

        scratch.deinit(allocator);
        allocator.destroy(scratch);
    }

    fn deinit(self: *SearchScratchPool, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        const n = self.count;
        self.count = 0;
        self.mutex.unlock();

        for (0..n) |i| {
            self.slots[i].deinit(allocator);
            allocator.destroy(self.slots[i]);
        }
    }
};

/// Dedicated reusable scratch buffers for serialized `insert()` calls.
const InsertScratch = struct {
    search: SearchScratch = .{},
    eps: std.ArrayListUnmanaged(PQItem) = .empty,
    sel_items: std.ArrayListUnmanaged(PQItem) = .empty,
    prune_cands: std.ArrayListUnmanaged(PQItem) = .empty,
    prune_sel: std.ArrayListUnmanaged(PQItem) = .empty,

    fn deinit(self: *InsertScratch, allocator: std.mem.Allocator) void {
        self.search.deinit(allocator);
        self.eps.deinit(allocator);
        self.sel_items.deinit(allocator);
        self.prune_cands.deinit(allocator);
        self.prune_sel.deinit(allocator);
    }
};

inline fn clampCosineDist(dot_val: f32) f32 {
    return @max(@as(f32, 0.0), @min(@as(f32, 2.0), 1.0 - dot_val));
}

fn sortPQItemsAsc(items: []PQItem) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and items[j - 1].dist > key.dist) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
}

/// Growth schedule balancing low realloc count with tight memory overhead
/// (~5–6% slack at N=10k/50k vs ~64% with naive 2× doubling).
fn nextNodeCapacity(current: usize, needed: usize) usize {
    if (current == 0) return @max(needed, 64);
    var cap = current;
    while (cap < needed) {
        const step = if (cap < 1024)
            cap
        else if (cap < 4096)
            cap / 4
        else
            @max(@as(usize, 256), cap / 8);
        cap = std.mem.alignForward(usize, cap + step, 64);
    }
    return cap;
}

pub const Hnsw = struct {
    allocator: std.mem.Allocator,
    params: HnswParams,
    metric_kind: MetricKind,
    /// Vector dimension, captured on first insert. 0 means "no nodes yet".
    dim: usize,
    /// Padded vector stride in f32 elements: `alignForward(dim, 16)` when `dim > 0`.
    /// Every node's vector starts on a 64B boundary and ends with zero-filled padding.
    vec_stride: usize,
    /// Stride in u32 elements per node in `l0_links` (`params.m_max0`).
    l0_stride: usize,
    /// Stride in u32 elements per upper slot in `upper_links` (`params.m`).
    upper_stride: usize,
    /// Active node count.
    node_count: usize,
    /// Allocated capacity for `headers`, `l0_max_dist`, `l0_links`.
    node_cap: usize,
    /// Allocated capacity in nodes for `vectors`.
    vec_cap: usize,
    /// Flat 64B-aligned contiguous vector slab (`vec_cap * vec_stride` f32s).
    vectors: []align(64) f32,
    /// Flat 64B-aligned contiguous L0 adjacency slab (`node_cap * l0_stride` u32s).
    l0_links: []align(64) u32,
    /// Per-node 8-byte metadata headers (`node_cap` entries).
    headers: []NodeHeader,
    /// Max neighbor distance after L0 heuristic prune (valid when `FLAG_L0_PRUNED` set).
    l0_max_dist: []f32,
    /// Compact upper-layer storage (only allocated for nodes with `level >= 1`).
    upper_counts: std.ArrayListUnmanaged(u16),
    upper_links: std.ArrayListUnmanaged(u32),
    entry_point: ?u32,
    /// Highest level across all nodes.
    top_level: u8,
    rng: std.Random.Xoshiro256,
    /// Reusable scratch buffers for write-locked `insert`.
    insert_scratch: InsertScratch,
    /// Thread-safe scratch pool for concurrent `search`.
    scratch_pool: SearchScratchPool,

    pub fn init(allocator: std.mem.Allocator, params: HnswParams) Hnsw {
        return .{
            .allocator = allocator,
            .params = params,
            .metric_kind = MetricKind.fromDistFn(params.dist_fn),
            .dim = 0,
            .vec_stride = 0,
            .l0_stride = params.m_max0,
            .upper_stride = params.m,
            .node_count = 0,
            .node_cap = 0,
            .vec_cap = 0,
            .vectors = @constCast(&EMPTY_F32_SLAB),
            .l0_links = @constCast(&EMPTY_U32_SLAB),
            .headers = &.{},
            .l0_max_dist = &.{},
            .upper_counts = .empty,
            .upper_links = .empty,
            .entry_point = null,
            .top_level = 0,
            .rng = std.Random.Xoshiro256.init(params.seed),
            .insert_scratch = .{},
            .scratch_pool = .{},
        };
    }

    pub fn deinit(self: *Hnsw) void {
        self.scratch_pool.deinit(self.allocator);
        self.insert_scratch.deinit(self.allocator);
        if (self.vectors.len > 0) self.allocator.free(self.vectors);
        if (self.l0_links.len > 0) self.allocator.free(self.l0_links);
        if (self.headers.len > 0) self.allocator.free(self.headers);
        if (self.l0_max_dist.len > 0) self.allocator.free(self.l0_max_dist);
        self.upper_counts.deinit(self.allocator);
        self.upper_links.deinit(self.allocator);
        self.vectors = @constCast(&EMPTY_F32_SLAB);
        self.l0_links = @constCast(&EMPTY_U32_SLAB);
        self.headers = &.{};
        self.l0_max_dist = &.{};
        self.node_count = 0;
        self.node_cap = 0;
        self.vec_cap = 0;
    }

    pub inline fn len(self: *const Hnsw) usize {
        return self.node_count;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Slab & Graph Accessors (Phase 2B/2C API)          ║
    // ╚═══════════════════════════════════════════════════╝

    /// Raw 64B-aligned base pointer to the contiguous vector slab. Empty-safe.
    pub inline fn vectorSlab(self: *const Hnsw) [*]align(64) const f32 {
        return self.vectors.ptr;
    }

    /// Padded vector stride in f32 elements (multiple of 16 when `dim > 0`).
    pub inline fn vecStride(self: *const Hnsw) usize {
        return self.vec_stride;
    }

    /// True when stored vectors are L2-normalized unit vectors (cosine metric).
    pub inline fn storesUnitVectors(self: *const Hnsw) bool {
        return self.metric_kind == .cosine_unit;
    }

    /// 64B-aligned pointer to node `id`'s padded vector in the flat slab.
    pub inline fn vecPtr(self: *const Hnsw, id: u32) [*]align(64) const f32 {
        const offset = @as(usize, id) * self.vec_stride;
        // `vec_stride` is a multiple of 16 f32s (64B), preserving 64B alignment.
        return @alignCast(self.vectors.ptr + offset);
    }

    /// Slice of node `id`'s stored vector (`len == self.dim`, 64B-aligned;
    /// coerces cleanly to `align(32)`, `align(16)`, and `align(1)`).
    /// Note: unit-normalized when `storesUnitVectors()` is true.
    pub inline fn getVector(self: *const Hnsw, id: u32) []align(64) const f32 {
        return self.vecPtr(id)[0..self.dim];
    }

    /// Highest layer node `id` participates in.
    pub inline fn nodeLevel(self: *const Hnsw, id: u32) u8 {
        return self.headers[id].level;
    }

    /// Active neighbor IDs of node `id` at level `lc`.
    pub inline fn nodeNeighbors(self: *const Hnsw, id: u32, lc: usize) []const u32 {
        const hdr = self.headers[id];
        if (lc == 0) {
            if (self.l0_stride == 0) return &.{};
            return self.l0_links[@as(usize, id) * self.l0_stride ..][0..hdr.l0_count];
        }
        if (lc > hdr.level or hdr.upper_offset == NO_UPPER or self.upper_stride == 0) return &.{};
        const slot = @as(usize, hdr.upper_offset) + (lc - 1);
        const cnt = self.upper_counts.items[slot];
        return self.upper_links.items[slot * self.upper_stride ..][0..cnt];
    }

    inline fn nodeNeighborsMut(self: *Hnsw, id: u32, lc: usize) []u32 {
        if (lc == 0) {
            if (self.l0_stride == 0) return &.{};
            return self.l0_links[@as(usize, id) * self.l0_stride ..][0..self.l0_stride];
        }
        const hdr = self.headers[id];
        const slot = @as(usize, hdr.upper_offset) + (lc - 1);
        return self.upper_links.items[slot * self.upper_stride ..][0..self.upper_stride];
    }

    inline fn nodeNeighborCount(self: *const Hnsw, id: u32, lc: usize) usize {
        const hdr = self.headers[id];
        if (lc == 0) return hdr.l0_count;
        const slot = @as(usize, hdr.upper_offset) + (lc - 1);
        return self.upper_counts.items[slot];
    }

    inline fn setNodeNeighborCount(self: *Hnsw, id: u32, lc: usize, new_count: u16) void {
        if (lc == 0) {
            self.headers[id].l0_count = new_count;
        } else {
            const slot = @as(usize, self.headers[id].upper_offset) + (lc - 1);
            self.upper_counts.items[slot] = new_count;
        }
    }

    /// Pre-allocate slab capacity for `additional` upcoming inserts.
    /// Safe to call before the first insert (vector slab sizes on first insert).
    pub fn reserve(self: *Hnsw, additional: usize) !void {
        if (additional == 0) return;
        const needed = try std.math.add(usize, self.node_count, additional);
        try self.ensureNodeCapacity(needed, true);
    }

    /// Grow flat slabs atomically so OOM midway never leaves torn state or leaks.
    fn ensureNodeCapacity(self: *Hnsw, needed: usize, exact: bool) !void {
        const need_meta = needed > self.node_cap;
        const need_vecs = self.vec_stride > 0 and needed > self.vec_cap;
        if (!need_meta and !need_vecs) return;

        const target_meta = if (need_meta)
            (if (exact) needed else nextNodeCapacity(self.node_cap, needed))
        else
            self.node_cap;

        const target_vecs = if (self.vec_stride > 0)
            @max(target_meta, self.vec_cap)
        else
            self.vec_cap;

        var new_headers: ?[]NodeHeader = null;
        errdefer if (new_headers) |b| self.allocator.free(b);

        var new_max_dist: ?[]f32 = null;
        errdefer if (new_max_dist) |b| self.allocator.free(b);

        var new_l0: ?[]align(64) u32 = null;
        errdefer if (new_l0) |b| self.allocator.free(b);

        var new_vecs: ?[]align(64) f32 = null;
        errdefer if (new_vecs) |b| self.allocator.free(b);

        if (need_meta) {
            new_headers = try self.allocator.alloc(NodeHeader, target_meta);
            new_max_dist = try self.allocator.alloc(f32, target_meta);
            if (self.l0_stride > 0) {
                const l0_elems = try std.math.mul(usize, target_meta, self.l0_stride);
                new_l0 = try self.allocator.alignedAlloc(u32, .@"64", l0_elems);
            }
        }

        if (self.vec_stride > 0 and target_vecs > self.vec_cap) {
            const vec_elems = try std.math.mul(usize, target_vecs, self.vec_stride);
            new_vecs = try self.allocator.alignedAlloc(f32, .@"64", vec_elems);
        }

        // All allocations succeeded — commit atomically.
        if (new_headers) |nh| {
            if (self.node_count > 0) {
                @memcpy(nh[0..self.node_count], self.headers[0..self.node_count]);
            }
            if (self.headers.len > 0) self.allocator.free(self.headers);
            self.headers = nh;
        }
        if (new_max_dist) |nm| {
            if (self.node_count > 0) {
                @memcpy(nm[0..self.node_count], self.l0_max_dist[0..self.node_count]);
            }
            if (self.l0_max_dist.len > 0) self.allocator.free(self.l0_max_dist);
            self.l0_max_dist = nm;
        }
        if (new_l0) |nl0| {
            if (self.node_count > 0) {
                const used = self.node_count * self.l0_stride;
                @memcpy(nl0[0..used], self.l0_links[0..used]);
            }
            if (self.l0_links.len > 0) self.allocator.free(self.l0_links);
            self.l0_links = nl0;
        }
        if (need_meta) {
            self.node_cap = target_meta;
        }

        if (new_vecs) |nv| {
            if (self.node_count > 0 and self.vec_cap > 0) {
                const used = self.node_count * self.vec_stride;
                @memcpy(nv[0..used], self.vectors[0..used]);
            }
            if (self.vectors.len > 0) self.allocator.free(self.vectors);
            self.vectors = nv;
            self.vec_cap = target_vecs;
        }
    }

    inline fn writeVectorToSlab(self: *Hnsw, node_id: u32, raw_vector: []align(1) const f32) void {
        if (self.vec_stride == 0) return;
        const dst = self.vectors[@as(usize, node_id) * self.vec_stride ..][0..self.vec_stride];
        if (self.metric_kind == .cosine_unit) {
            _ = distance.normalizeInto(raw_vector, dst[0..self.dim]);
        } else {
            @memcpy(dst[0..self.dim], raw_vector);
        }
        if (self.vec_stride > self.dim) {
            @memset(dst[self.dim..self.vec_stride], 0.0);
        }
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Serialization (WDBHNSW2 byte-exact format)        ║
    // ╚═══════════════════════════════════════════════════╝

    /// Binary graph-structure format (byte-identical to WDBHNSW2):
    ///   [params: 28 bytes] m, m_max0, ef_construction (u32×3),
    ///                      ml (f32), seed (u64), dim (u32)
    ///   [node_count: u32]
    ///   [has_entry: u8][entry_point: u32]    # entry_point undefined if has_entry=0
    ///   [top_level: u8]
    ///   [reserved: u8]                       # 0
    ///   For each node:
    ///     [level: u8]
    ///     For lc in 0..=level:
    ///       [neighbor_count: u16]
    ///       [neighbor_ids: u32 × count]
    ///
    /// Vectors are NOT written here — they live in the KV store and the
    /// enclosing snapshot format resolves them via `resolve_vector` on load.
    pub fn writeTo(self: *const Hnsw, writer: anytype) !void {
        var bw = BufferedWriter(@TypeOf(writer)){ .inner = writer };

        var buf: [28]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], self.params.m, .little);
        std.mem.writeInt(u32, buf[4..8], self.params.m_max0, .little);
        std.mem.writeInt(u32, buf[8..12], self.params.ef_construction, .little);
        std.mem.writeInt(u32, buf[12..16], @bitCast(self.params.ml), .little);
        std.mem.writeInt(u64, buf[16..24], self.params.seed, .little);
        std.mem.writeInt(u32, buf[24..28], @intCast(self.dim), .little);
        try bw.writeAll(&buf);

        var counters: [11]u8 = undefined;
        const nc: u32 = @intCast(self.node_count);
        std.mem.writeInt(u32, counters[0..4], nc, .little);
        counters[4] = if (self.entry_point != null) 1 else 0;
        std.mem.writeInt(u32, counters[5..9], self.entry_point orelse 0, .little);
        counters[9] = self.top_level;
        counters[10] = 0; // reserved
        try bw.writeAll(&counters);

        var node_id: u32 = 0;
        while (node_id < nc) : (node_id += 1) {
            const level = self.headers[node_id].level;
            try bw.writeAll(&[_]u8{level});

            var lc: usize = 0;
            while (lc <= level) : (lc += 1) {
                const nbrs = self.nodeNeighbors(node_id, lc);
                var nc_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, nc_buf[0..2], @intCast(nbrs.len), .little);
                try bw.writeAll(&nc_buf);

                if (nbrs.len > 0) {
                    if (comptime builtin.cpu.arch.endian() == .little) {
                        try bw.writeAll(std.mem.sliceAsBytes(nbrs));
                    } else {
                        for (nbrs) |nb_id| {
                            var id_buf: [4]u8 = undefined;
                            std.mem.writeInt(u32, id_buf[0..4], nb_id, .little);
                            try bw.writeAll(&id_buf);
                        }
                    }
                }
            }
        }

        try bw.flush();
    }

    /// Callback type for resolving a node id back to its vector bytes during
    /// load. The reader supplies a context + index; the callback returns the
    /// raw vector bytes (caller-borrowed — Hnsw copies/normalizes them into
    /// its aligned slab before returning).
    pub const ResolveVectorFn = *const fn (ctx: *anyopaque, node_id: u32) ?[]const u8;

    /// Load a graph produced by `writeTo` with the default cosine distance fn.
    /// Callers loading non-cosine (`.l2`/`.dot`) graphs MUST use
    /// `readFromWithDistFn` so raw vectors are not unit-normalized on load.
    pub fn readFrom(
        allocator: std.mem.Allocator,
        reader: anytype,
        resolve_vector: ResolveVectorFn,
        resolve_ctx: *anyopaque,
    ) !Hnsw {
        return readFromWithDistFn(allocator, reader, metric_mod.cosine_dist, resolve_vector, resolve_ctx);
    }

    /// Load a graph produced by `writeTo` using an explicit `dist_fn`.
    /// Rebuilds the flat 64B-aligned slabs (normalizing into unit vectors iff
    /// `dist_fn == metric_mod.cosine_dist`) without reading a single byte past
    /// the HNSW block (preserving any trailing WDBHNSW2 RaBitQ section).
    pub fn readFromWithDistFn(
        allocator: std.mem.Allocator,
        reader: anytype,
        dist_fn: DistFn,
        resolve_vector: ResolveVectorFn,
        resolve_ctx: *anyopaque,
    ) !Hnsw {
        var params_buf: [28]u8 = undefined;
        try readAllExact(reader, &params_buf);

        const params = HnswParams{
            .m = std.mem.readInt(u32, params_buf[0..4], .little),
            .m_max0 = std.mem.readInt(u32, params_buf[4..8], .little),
            .ef_construction = std.mem.readInt(u32, params_buf[8..12], .little),
            .ml = @bitCast(std.mem.readInt(u32, params_buf[12..16], .little)),
            .seed = std.mem.readInt(u64, params_buf[16..24], .little),
            .dist_fn = dist_fn,
        };
        const dim_u32 = std.mem.readInt(u32, params_buf[24..28], .little);
        // Guard against corrupt huge dimensions causing overflow in alignForward/mul.
        if (dim_u32 > (1 << 24)) return error.CorruptGraph;
        const dim: usize = @intCast(dim_u32);

        var counters: [11]u8 = undefined;
        try readAllExact(reader, &counters);
        const node_count_u32 = std.mem.readInt(u32, counters[0..4], .little);
        const has_ep = counters[4] != 0;
        const ep = std.mem.readInt(u32, counters[5..9], .little);
        const top_level = counters[9];

        if (top_level > 31) return error.CorruptGraph;
        if (has_ep and (node_count_u32 == 0 or ep >= node_count_u32)) return error.CorruptGraph;

        var hnsw = Hnsw.init(allocator, params);
        errdefer hnsw.deinit();
        hnsw.dim = dim;
        hnsw.vec_stride = if (dim > 0) std.mem.alignForward(usize, dim, 16) else 0;
        hnsw.top_level = top_level;
        hnsw.entry_point = if (has_ep) ep else null;

        const node_count: usize = @intCast(node_count_u32);
        const expected_vec_bytes = std.math.mul(usize, dim, @sizeOf(f32)) catch return error.CorruptGraph;

        // Pre-allocate up to 65,536 nodes upfront (caps OOM blast radius on
        // corrupt headers claiming millions of nodes before EOF).
        if (node_count > 0) {
            try hnsw.ensureNodeCapacity(@min(node_count, 65536), true);
        }

        var node_id: u32 = 0;
        while (node_id < node_count_u32) : (node_id += 1) {
            if (@as(usize, node_id) >= hnsw.node_cap) {
                try hnsw.ensureNodeCapacity(@min(node_count, @as(usize, node_id) + 65536), true);
            }

            var lvl_buf: [1]u8 = undefined;
            try readAllExact(reader, &lvl_buf);
            const level = lvl_buf[0];
            if (level > 31) return error.CorruptGraph;

            const vec_bytes = resolve_vector(resolve_ctx, node_id) orelse
                return error.MissingVector;
            if (vec_bytes.len != expected_vec_bytes) return error.CorruptGraph;

            if (dim > 0) {
                const src_ptr: [*]align(1) const f32 = @ptrCast(vec_bytes.ptr);
                hnsw.writeVectorToSlab(node_id, src_ptr[0..dim]);
            }

            var upper_offset: u32 = NO_UPPER;
            if (level > 0) {
                const levels_above = @as(usize, level);
                upper_offset = @intCast(hnsw.upper_counts.items.len);
                const old_slots = hnsw.upper_counts.items.len;
                const new_slots = try std.math.add(usize, old_slots, levels_above);
                try hnsw.upper_counts.resize(allocator, new_slots);
                @memset(hnsw.upper_counts.items[old_slots..new_slots], 0);
                if (hnsw.upper_stride > 0) {
                    const link_elems = try std.math.mul(usize, new_slots, hnsw.upper_stride);
                    try hnsw.upper_links.resize(allocator, link_elems);
                }
            }

            // Initialize header conservatively: FLAG_L0_PRUNED = 0 so future
            // post-reload inserts always verify exact pruning before fast-skip.
            hnsw.headers[node_id] = .{
                .l0_count = 0,
                .level = level,
                .flags = 0,
                .upper_offset = upper_offset,
            };
            hnsw.l0_max_dist[node_id] = std.math.inf(f32);
            hnsw.node_count = @as(usize, node_id) + 1;

            var lc: usize = 0;
            while (lc <= level) : (lc += 1) {
                var nc_buf: [2]u8 = undefined;
                try readAllExact(reader, &nc_buf);
                const stored_count = std.mem.readInt(u16, nc_buf[0..2], .little);

                const cap = hnsw.maxNeighborsAtLevel(@intCast(lc));
                if (stored_count > cap) return error.CorruptGraph;

                hnsw.setNodeNeighborCount(node_id, lc, stored_count);
                if (stored_count > 0) {
                    const dst_nbrs = hnsw.nodeNeighborsMut(node_id, lc)[0..stored_count];
                    if (comptime builtin.cpu.arch.endian() == .little) {
                        try readAllExact(reader, std.mem.sliceAsBytes(dst_nbrs));
                    } else {
                        for (dst_nbrs) |*slot| {
                            var id_buf: [4]u8 = undefined;
                            try readAllExact(reader, &id_buf);
                            slot.* = std.mem.readInt(u32, id_buf[0..4], .little);
                        }
                    }
                    for (dst_nbrs) |nb_id| {
                        if (nb_id >= node_count_u32) return error.CorruptGraph;
                    }
                }
            }
        }

        return hnsw;
    }

    /// Allow the enclosing layer to re-apply the metric's dist_fn after init.
    /// Note: callers restoring non-cosine snapshots must pass the metric's
    /// `dist_fn` directly to `readFromWithDistFn`.
    pub fn setDistFn(self: *Hnsw, dist_fn: DistFn) void {
        const new_kind = MetricKind.fromDistFn(dist_fn);
        std.debug.assert(self.node_count == 0 or (self.metric_kind == .cosine_unit) == (new_kind == .cosine_unit));
        self.params.dist_fn = dist_fn;
        self.metric_kind = new_kind;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Distance & Prefetch Helpers                       ║
    // ╚═══════════════════════════════════════════════════╝

    inline fn prefetchVector(self: *const Hnsw, id: u32) void {
        const ptr: [*]const u8 = @ptrCast(self.vecPtr(id));
        const vec_bytes = self.vec_stride * @sizeOf(f32);
        @prefetch(ptr, .{ .locality = 3 });
        if (vec_bytes > 64) @prefetch(ptr + 64, .{ .locality = 3 });
        if (vec_bytes > 128) @prefetch(ptr + 128, .{ .locality = 2 });
        if (vec_bytes > 192) @prefetch(ptr + 192, .{ .locality = 2 });
    }

    inline fn distPreparedSingle(self: *const Hnsw, q_ptr: [*]align(32) const f32, node_id: u32) f32 {
        const v_ptr = self.vecPtr(node_id);
        return switch (self.metric_kind) {
            .cosine_unit => clampCosineDist(distance.dotAligned(q_ptr, v_ptr, self.vec_stride)),
            .dot => -distance.dotAligned(q_ptr, v_ptr, self.vec_stride),
            .l2 => distance.l2SquaredAligned(q_ptr, v_ptr, self.vec_stride),
            .custom => self.params.dist_fn(q_ptr[0..self.dim], v_ptr[0..self.dim]),
        };
    }

    inline fn distPreparedBatch4(self: *const Hnsw, q_ptr: [*]align(32) const f32, ids: [4]u32) [4]f32 {
        const ptrs: [4][*]align(32) const f32 = .{
            self.vecPtr(ids[0]),
            self.vecPtr(ids[1]),
            self.vecPtr(ids[2]),
            self.vecPtr(ids[3]),
        };
        return switch (self.metric_kind) {
            .cosine_unit => blk: {
                const dots = distance.dotBatch4Aligned(q_ptr, ptrs, self.vec_stride);
                break :blk .{
                    clampCosineDist(dots[0]),
                    clampCosineDist(dots[1]),
                    clampCosineDist(dots[2]),
                    clampCosineDist(dots[3]),
                };
            },
            .dot => blk: {
                const dots = distance.dotBatch4Aligned(q_ptr, ptrs, self.vec_stride);
                break :blk .{ -dots[0], -dots[1], -dots[2], -dots[3] };
            },
            .l2 => distance.l2SquaredBatch4Aligned(q_ptr, ptrs, self.vec_stride),
            .custom => .{
                self.params.dist_fn(q_ptr[0..self.dim], ptrs[0][0..self.dim]),
                self.params.dist_fn(q_ptr[0..self.dim], ptrs[1][0..self.dim]),
                self.params.dist_fn(q_ptr[0..self.dim], ptrs[2][0..self.dim]),
                self.params.dist_fn(q_ptr[0..self.dim], ptrs[3][0..self.dim]),
            },
        };
    }

    inline fn prepareQueryInto(self: *const Hnsw, query: []align(1) const f32, dst: []align(64) f32) void {
        if (self.dim == 0) return;
        if (self.metric_kind == .cosine_unit) {
            _ = distance.normalizeInto(query, dst[0..self.dim]);
        } else {
            @memcpy(dst[0..self.dim], query);
        }
        if (self.vec_stride > self.dim) {
            @memset(dst[self.dim..self.vec_stride], 0.0);
        }
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

    inline fn maxNeighborsAtLevel(self: *const Hnsw, lc: u8) u32 {
        return if (lc == 0) self.params.m_max0 else self.params.m;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Upper-layer greedy hill-climb (ef = 1)            ║
    // ╚═══════════════════════════════════════════════════╝

    /// Standard Malkov & Yashunin Alg. 1/5 greedy descent on layers
    /// `from_level` down to `to_level_exclusive + 1`. Zero heap allocations,
    /// zero visited clears, 4-way SIMD batched neighbor evaluation.
    fn greedyDescend(
        self: *const Hnsw,
        q_ptr: [*]align(32) const f32,
        start_id: u32,
        start_dist: f32,
        from_level: u8,
        to_level_exclusive: u8,
    ) PQItem {
        var curr_id = start_id;
        var curr_dist = start_dist;
        var lc: i32 = from_level;
        while (lc > to_level_exclusive) : (lc -= 1) {
            const level: usize = @intCast(lc);
            while (true) {
                const nbrs = self.nodeNeighbors(curr_id, level);
                if (nbrs.len == 0) break;

                var improved = false;
                var j: usize = 0;
                const init_pf = @min(@as(usize, 4), nbrs.len);
                for (0..init_pf) |pf| {
                    if (nbrs[pf] < self.node_count) self.prefetchVector(nbrs[pf]);
                }

                while (j + 4 <= nbrs.len) : (j += 4) {
                    const pf_end = @min(j + 8, nbrs.len);
                    var pf = j + 4;
                    while (pf < pf_end) : (pf += 1) {
                        if (nbrs[pf] < self.node_count) self.prefetchVector(nbrs[pf]);
                    }
                    const batch_ids: [4]u32 = .{ nbrs[j], nbrs[j + 1], nbrs[j + 2], nbrs[j + 3] };
                    const ds = self.distPreparedBatch4(q_ptr, batch_ids);
                    inline for (0..4) |lane| {
                        if (ds[lane] < curr_dist) {
                            curr_dist = ds[lane];
                            curr_id = batch_ids[lane];
                            improved = true;
                        }
                    }
                }
                while (j < nbrs.len) : (j += 1) {
                    const nb_id = nbrs[j];
                    const d = self.distPreparedSingle(q_ptr, nb_id);
                    if (d < curr_dist) {
                        curr_dist = d;
                        curr_id = nb_id;
                        improved = true;
                    }
                }
                if (!improved) break;
            }
        }
        return .{ .id = curr_id, .dist = curr_dist };
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Algorithm 2 — search_layer                        ║
    // ╚═══════════════════════════════════════════════════╝

    /// Beam-search over one level using caller/pooled `SearchScratch`.
    /// Explores up to `ef` closest non-excluded candidates to `q_ptr` at level
    /// `lc`. Returns a `BoundedResultHeap` viewing `scratch.results_buf[0..ef]`.
    fn searchLayer(
        self: *const Hnsw,
        allocator: std.mem.Allocator,
        q_ptr: [*]align(32) const f32,
        entry_points: []const PQItem,
        ef: usize,
        lc: u8,
        skip: ?*const std.bit_set.Dynamic,
        exclude_id: ?u32,
        scratch: *SearchScratch,
    ) !BoundedResultHeap {
        try scratch.visited.prepare(allocator, self.node_count);
        defer scratch.visited.reset();

        scratch.candidates.clearRetainingCapacity();
        if (scratch.results_buf.items.len < ef) {
            try scratch.results_buf.resize(allocator, ef);
        }
        var w = BoundedResultHeap.init(scratch.results_buf.items[0..ef]);
        const has_filter = (skip != null or exclude_id != null);

        // Seed both heaps with pre-scored entry points. Excluded entry points
        // still enter `candidates` (we traverse through them) but not `w`.
        for (entry_points) |ep| {
            if (ep.id >= self.node_count) continue;
            if (try scratch.visited.testAndSet(allocator, ep.id)) continue;
            try scratch.candidates.push(allocator, ep);
            if (!has_filter or !isExcluded(skip, exclude_id, ep.id)) {
                w.pushOrReplace(ep);
            }
        }

        // Register-cached cutoff: +inf while w.len() < ef, else w.peek().dist.
        var worst_dist: f32 = w.worstDist();

        while (scratch.candidates.pop()) |c| {
            if (c.dist > worst_dist) break;

            // Hide L0 adjacency miss for the next candidate while expanding `c`.
            if (lc == 0) {
                if (scratch.candidates.peek()) |next_c| {
                    if (next_c.id < self.node_count) {
                        @prefetch(&self.headers[next_c.id], .{ .locality = 3 });
                        if (self.l0_stride > 0) {
                            @prefetch(&self.l0_links[@as(usize, next_c.id) * self.l0_stride], .{ .locality = 3 });
                        }
                    }
                }
            }

            const nbrs = self.nodeNeighbors(c.id, lc);
            if (nbrs.len == 0) continue;

            // Two-phase neighbor expansion:
            //   1. Gather unvisited neighbors into stack chunk + prefetch first 4.
            //   2. Evaluate 4 at a time via SIMD batch kernel while prefetching
            //      the next 4 unvisited vectors.
            var pos: usize = 0;
            while (pos < nbrs.len) {
                var unvisited: [64]u32 = undefined;
                var u_count: usize = 0;
                while (pos < nbrs.len and u_count < unvisited.len) : (pos += 1) {
                    const nb_id = nbrs[pos];
                    if (nb_id >= self.node_count) continue;
                    if (!try scratch.visited.testAndSet(allocator, nb_id)) {
                        unvisited[u_count] = nb_id;
                        if (u_count < 4) self.prefetchVector(nb_id);
                        u_count += 1;
                    }
                }

                var j: usize = 0;
                while (j + 4 <= u_count) : (j += 4) {
                    const pf_end = @min(j + 8, u_count);
                    var pf = j + 4;
                    while (pf < pf_end) : (pf += 1) {
                        self.prefetchVector(unvisited[pf]);
                    }

                    const batch_ids: [4]u32 = .{
                        unvisited[j],
                        unvisited[j + 1],
                        unvisited[j + 2],
                        unvisited[j + 3],
                    };
                    const ds = self.distPreparedBatch4(q_ptr, batch_ids);
                    inline for (0..4) |lane| {
                        const d = ds[lane];
                        if (d < worst_dist) {
                            const nb_id = batch_ids[lane];
                            try scratch.candidates.push(allocator, .{ .id = nb_id, .dist = d });
                            if (!has_filter or !isExcluded(skip, exclude_id, nb_id)) {
                                w.pushOrReplace(.{ .id = nb_id, .dist = d });
                                worst_dist = w.worstDist();
                            }
                        }
                    }
                }

                while (j < u_count) : (j += 1) {
                    const nb_id = unvisited[j];
                    const d = self.distPreparedSingle(q_ptr, nb_id);
                    if (d < worst_dist) {
                        try scratch.candidates.push(allocator, .{ .id = nb_id, .dist = d });
                        if (!has_filter or !isExcluded(skip, exclude_id, nb_id)) {
                            w.pushOrReplace(.{ .id = nb_id, .dist = d });
                            worst_dist = w.worstDist();
                        }
                    }
                }
            }
        }

        return w;
    }

    inline fn isSkipped(skip: ?*const std.bit_set.Dynamic, id: u32) bool {
        const s = skip orelse return false;
        if (id >= s.bit_length) return false;
        return s.isSet(id);
    }

    inline fn isExcluded(skip: ?*const std.bit_set.Dynamic, exclude_id: ?u32, id: u32) bool {
        if (exclude_id) |ex| {
            if (id == ex) return true;
        }
        return isSkipped(skip, id);
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Algorithm 4 — select_neighbors (heuristic)        ║
    // ╚═══════════════════════════════════════════════════╝

    /// Unified diversity-preserving heuristic selector over candidates already
    /// sorted ascending by distance to the query/center. Keeps a candidate iff
    /// it is closer to the center than to every already-selected neighbor.
    /// Zero allocations; uses 4-way batched SIMD once `selected >= 4`.
    fn selectNeighborsHeuristicSorted(
        self: *const Hnsw,
        sorted: []const PQItem,
        m_target: u32,
        out_items: []PQItem,
    ) usize {
        var selected: usize = 0;
        outer: for (sorted) |cand| {
            if (selected >= m_target) break;
            const cand_ptr = self.vecPtr(cand.id);
            var j: usize = 0;
            while (j + 4 <= selected) : (j += 4) {
                const s_ids: [4]u32 = .{
                    out_items[j].id,
                    out_items[j + 1].id,
                    out_items[j + 2].id,
                    out_items[j + 3].id,
                };
                const ds = self.distPreparedBatch4(cand_ptr, s_ids);
                if (ds[0] < cand.dist or ds[1] < cand.dist or ds[2] < cand.dist or ds[3] < cand.dist) {
                    continue :outer;
                }
            }
            while (j < selected) : (j += 1) {
                if (self.distPreparedSingle(cand_ptr, out_items[j].id) < cand.dist) {
                    continue :outer;
                }
            }
            out_items[selected] = cand;
            selected += 1;
        }
        return selected;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Algorithm 1 — insert                              ║
    // ╚═══════════════════════════════════════════════════╝

    /// Insert a vector. Returns the assigned node ID.
    ///
    /// Accepts align(1) input — caller may pass vectors reinterpreted from
    /// a byte buffer (e.g. via `distance.bytesToF32`). The index copies (and
    /// L2-normalizes for cosine) into its 64B-aligned flat slab internally.
    ///
    /// Thread safety: caller must serialize inserts. Searches on the same
    /// graph from other threads are unsafe during insert.
    pub fn insert(self: *Hnsw, vector: []align(1) const f32) !u32 {
        if (self.dim == 0 and self.node_count == 0) {
            self.dim = vector.len;
            self.vec_stride = if (vector.len > 0) std.mem.alignForward(usize, vector.len, 16) else 0;
        } else if (vector.len != self.dim) {
            return error.DimensionMismatch;
        }

        const new_level = self.sampleLevel();
        const new_id: u32 = @intCast(self.node_count);

        try self.ensureNodeCapacity(self.node_count + 1, false);

        // Allocate upper-layer slots only for the ~6.25% of nodes with level >= 1.
        var upper_offset: u32 = NO_UPPER;
        if (new_level > 0) {
            const levels_above = @as(usize, new_level);
            const old_slots = self.upper_counts.items.len;
            const new_slots = old_slots + levels_above;
            try self.upper_counts.resize(self.allocator, new_slots);
            errdefer self.upper_counts.items.len = old_slots;
            @memset(self.upper_counts.items[old_slots..new_slots], 0);
            if (self.upper_stride > 0) {
                try self.upper_links.resize(self.allocator, new_slots * self.upper_stride);
            }
            upper_offset = @intCast(old_slots);
        }

        self.writeVectorToSlab(new_id, vector);
        self.headers[new_id] = .{
            .l0_count = 0,
            .level = new_level,
            .flags = 0,
            .upper_offset = upper_offset,
        };
        self.l0_max_dist[new_id] = std.math.inf(f32);
        self.node_count += 1;

        // First node: becomes the entry point. No neighbors to connect.
        if (self.entry_point == null) {
            self.entry_point = new_id;
            self.top_level = new_level;
            return new_id;
        }

        const q_ptr: [*]align(32) const f32 = self.vecPtr(new_id);

        // ── Phase 1: greedy hill-climb from top_level down to new_level + 1 ──
        const ep0 = self.entry_point.?;
        var curr_ep = PQItem{ .id = ep0, .dist = self.distPreparedSingle(q_ptr, ep0) };
        if (self.top_level > new_level) {
            curr_ep = self.greedyDescend(q_ptr, curr_ep.id, curr_ep.dist, self.top_level, new_level);
        }

        // ── Phase 2: for each level ≤ new_level, search and connect ──
        self.insert_scratch.eps.clearRetainingCapacity();
        try self.insert_scratch.eps.append(self.allocator, curr_ep);

        var stack_sel: [64]PQItem = undefined;
        const max_m = @max(self.params.m, self.params.m_max0);
        const sel_out: []PQItem = if (max_m <= stack_sel.len)
            stack_sel[0..max_m]
        else blk: {
            try self.insert_scratch.sel_items.resize(self.allocator, max_m);
            break :blk self.insert_scratch.sel_items.items[0..max_m];
        };

        var lc: i32 = @min(@as(i32, self.top_level), @as(i32, new_level));
        while (lc >= 0) : (lc -= 1) {
            const level: u8 = @intCast(lc);
            var w = try self.searchLayer(
                self.allocator,
                q_ptr,
                self.insert_scratch.eps.items,
                self.params.ef_construction,
                level,
                null,
                null,
                &self.insert_scratch.search,
            );

            // Re-seed `eps` for the next lower level preserving precomputed distances!
            if (lc > 0) {
                const w_items = w.items();
                self.insert_scratch.eps.clearRetainingCapacity();
                try self.insert_scratch.eps.ensureTotalCapacity(self.allocator, w_items.len);
                self.insert_scratch.eps.appendSliceAssumeCapacity(w_items);
            }

            const sorted = w.sortedAsc();
            const m_target = self.maxNeighborsAtLevel(level);
            const n_selected = self.selectNeighborsHeuristicSorted(sorted, m_target, sel_out[0..m_target]);

            // Connect new_id → selected neighbors at this level.
            if (n_selected > 0) {
                const self_nbrs = self.nodeNeighborsMut(new_id, level);
                for (0..n_selected) |i| {
                    self_nbrs[i] = sel_out[i].id;
                }
                self.setNodeNeighborCount(new_id, level, @intCast(n_selected));
                if (level == 0 and n_selected == m_target) {
                    self.headers[new_id].flags |= FLAG_L0_PRUNED;
                    self.l0_max_dist[new_id] = sel_out[n_selected - 1].dist;
                }
            }

            // Add back-edges and prune if over capacity (passing already-known dist!).
            for (sel_out[0..n_selected]) |sel| {
                try self.addBackEdge(sel.id, new_id, sel.dist, level);
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
    /// neighborhood (existing + new) using 4-way batched distances and zero
    /// steady-state heap allocations.
    fn addBackEdge(
        self: *Hnsw,
        nb_id: u32,
        new_id: u32,
        d_new: f32,
        lc: u8,
    ) !void {
        const cap = self.maxNeighborsAtLevel(lc);
        if (cap == 0) return;

        const nb_nbrs_slice = self.nodeNeighborsMut(nb_id, lc);
        const cur_count = self.nodeNeighborCount(nb_id, lc);

        if (cur_count < cap) {
            nb_nbrs_slice[cur_count] = new_id;
            self.setNodeNeighborCount(nb_id, lc, @intCast(cur_count + 1));
            return;
        }

        // Mathematically-exact O(1) hub fast-skip at level 0:
        // If `nb_id` was previously heuristic-pruned and remains full at `cap`,
        // all `cap` existing neighbors are mutually non-pruning under symmetric
        // distance. Whenever `d_new > l0_max_dist[nb_id]`, `new_id` sorts
        // strictly last and is guaranteed to be discarded before index `cap`.
        if (lc == 0 and self.metric_kind != .custom and
            (self.headers[nb_id].flags & FLAG_L0_PRUNED) != 0 and
            d_new > self.l0_max_dist[nb_id])
        {
            return;
        }

        const total = cur_count + 1;
        var stack_cands: [65]PQItem = undefined;
        var stack_sel: [64]PQItem = undefined;
        const cands: []PQItem = if (total <= stack_cands.len)
            stack_cands[0..total]
        else blk: {
            try self.insert_scratch.prune_cands.resize(self.allocator, total);
            break :blk self.insert_scratch.prune_cands.items[0..total];
        };

        const nb_ptr: [*]align(32) const f32 = self.vecPtr(nb_id);
        var j: usize = 0;
        const init_pf = @min(@as(usize, 4), cur_count);
        for (0..init_pf) |pf| self.prefetchVector(nb_nbrs_slice[pf]);

        while (j + 4 <= cur_count) : (j += 4) {
            const pf_end = @min(j + 8, cur_count);
            var pf = j + 4;
            while (pf < pf_end) : (pf += 1) self.prefetchVector(nb_nbrs_slice[pf]);

            const batch_ids: [4]u32 = .{
                nb_nbrs_slice[j],
                nb_nbrs_slice[j + 1],
                nb_nbrs_slice[j + 2],
                nb_nbrs_slice[j + 3],
            };
            const ds = self.distPreparedBatch4(nb_ptr, batch_ids);
            inline for (0..4) |lane| {
                cands[j + lane] = .{ .id = batch_ids[lane], .dist = ds[lane] };
            }
        }
        while (j < cur_count) : (j += 1) {
            const id = nb_nbrs_slice[j];
            cands[j] = .{ .id = id, .dist = self.distPreparedSingle(nb_ptr, id) };
        }
        cands[cur_count] = .{ .id = new_id, .dist = d_new };

        sortPQItemsAsc(cands);

        const sel_out: []PQItem = if (cap <= stack_sel.len)
            stack_sel[0..cap]
        else blk: {
            try self.insert_scratch.prune_sel.resize(self.allocator, cap);
            break :blk self.insert_scratch.prune_sel.items[0..cap];
        };

        const n_selected = self.selectNeighborsHeuristicSorted(cands, cap, sel_out);

        for (0..n_selected) |i| {
            nb_nbrs_slice[i] = sel_out[i].id;
        }
        self.setNodeNeighborCount(nb_id, lc, @intCast(n_selected));

        if (lc == 0) {
            if (n_selected == cap) {
                self.headers[nb_id].flags |= FLAG_L0_PRUNED;
                self.l0_max_dist[nb_id] = sel_out[n_selected - 1].dist;
            } else {
                self.headers[nb_id].flags &= ~FLAG_L0_PRUNED;
            }
        }
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Algorithm 5 — search_knn                          ║
    // ╚═══════════════════════════════════════════════════╝

    /// k-NN search using the index's thread-safe pooled `SearchScratch`.
    /// Fills `out` with up to `k` results sorted by ascending distance.
    /// Returns the number of results written (≤ k; may be < k if the index has
    /// fewer live nodes).
    ///
    /// `skip`, if non-null, is a bit set indexed by node id. Nodes with their
    /// bit set are **still traversed** (their neighbors are explored) but are
    /// never returned in `out`.
    pub fn search(
        self: *Hnsw,
        query: []align(1) const f32,
        k: usize,
        ef: usize,
        out: []SearchResult,
        skip: ?*const std.bit_set.Dynamic,
    ) !usize {
        return self.searchWithSkipAndExclude(query, k, ef, out, skip, null);
    }

    /// k-NN search with both a tombstone `skip` bitset and an optional single
    /// `exclude_id` (e.g. excluding `query_key` itself without oversampling).
    pub fn searchWithSkipAndExclude(
        self: *Hnsw,
        query: []align(1) const f32,
        k: usize,
        ef: usize,
        out: []SearchResult,
        skip: ?*const std.bit_set.Dynamic,
        exclude_id: ?u32,
    ) !usize {
        if (self.entry_point == null) return 0;
        if (k == 0 or out.len == 0) return 0;
        if (self.dim != 0 and query.len != self.dim) return error.DimensionMismatch;

        const scratch = try self.scratch_pool.acquire(self.allocator);
        defer self.scratch_pool.release(self.allocator, scratch);

        return self.searchWithScratch(self.allocator, query, k, ef, out, skip, exclude_id, scratch);
    }

    /// Pure `*const Hnsw` k-NN search using a caller-owned `SearchScratch`.
    /// Zero pool mutex, zero steady-state allocations. Ideal for tight search
    /// loops (`vcluster`, `vproject_2d`) and concurrent serving paths.
    pub fn searchWithScratch(
        self: *const Hnsw,
        allocator: std.mem.Allocator,
        query: []align(1) const f32,
        k: usize,
        ef: usize,
        out: []SearchResult,
        skip: ?*const std.bit_set.Dynamic,
        exclude_id: ?u32,
        scratch: *SearchScratch,
    ) !usize {
        if (self.entry_point == null) return 0;
        if (k == 0 or out.len == 0) return 0;
        if (self.dim != 0 and query.len != self.dim) return error.DimensionMismatch;

        const limit = @min(k, out.len);
        const effective_ef = @max(ef, limit);

        var stack_q: [STACK_QUERY_CAP]f32 align(64) = undefined;
        const q_slice: []align(64) f32 = if (self.vec_stride <= STACK_QUERY_CAP)
            stack_q[0..self.vec_stride]
        else
            try scratch.ensureQueryBuf(allocator, self.vec_stride);
        self.prepareQueryInto(query, q_slice);
        const q_ptr: [*]align(32) const f32 = q_slice.ptr;

        // ── Greedy hill-climb from top_level down to 1 (ef = 1) ──
        // Upper layers don't filter — navigation is about geometry, not
        // eligibility. A tombstoned entry-point still guides descent.
        const ep0 = self.entry_point.?;
        var ep = PQItem{ .id = ep0, .dist = self.distPreparedSingle(q_ptr, ep0) };
        if (self.top_level > 0) {
            ep = self.greedyDescend(q_ptr, ep.id, ep.dist, self.top_level, 0);
        }

        // ── Final layer with full ef — apply skip + exclude_id filter here ──
        var w = try self.searchLayer(
            allocator,
            q_ptr,
            &.{ep},
            effective_ef,
            0,
            skip,
            exclude_id,
            scratch,
        );

        const sorted = w.sortedAsc();
        const n = @min(limit, sorted.len);
        for (0..n) |i| {
            out[i] = .{ .id = sorted[i].id, .dist = sorted[i].dist };
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

    // Empty-safe slab accessors
    _ = h.vectorSlab();
    try testing.expectEqual(@as(usize, 0), h.vecStride());
    try testing.expect(h.storesUnitVectors());

    var out: [5]SearchResult = undefined;
    const q = [_]f32{ 1, 0, 0, 0 };
    const n = try h.search(&q, 5, 50, &out, null);
    try testing.expectEqual(@as(usize, 0), n);
}

test "hnsw: single node returns itself" {
    var h = Hnsw.init(testing.allocator, .{});
    defer h.deinit();

    const v = [_]f32{ 1, 0, 0, 0 };
    const id = try h.insert(&v);
    try testing.expectEqual(@as(u32, 0), id);

    var out: [5]SearchResult = undefined;
    const n = try h.search(&v, 5, 50, &out, null);
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
    try testing.expectError(error.DimensionMismatch, h.search(&[_]f32{ 1, 0 }, 1, 50, &out, null));
}

test "hnsw: recall on synthetic clusters" {
    var h = Hnsw.init(testing.allocator, .{ .m = 16, .ef_construction = 200 });
    defer h.deinit();

    const dim: usize = 32;
    const n_per_cluster: usize = 50;
    const n_clusters: usize = 4;
    const total = n_per_cluster * n_clusters;

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const rand = prng.random();

    var centers: [n_clusters][dim]f32 = undefined;
    for (&centers, 0..) |*c, i| {
        @memset(c, 0);
        c[i * (dim / n_clusters)] = 1.0;
    }

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

    const q = centers[0];
    var out: [10]SearchResult = undefined;
    const n = try h.search(&q, 10, 100, &out, null);
    try testing.expectEqual(@as(usize, 10), n);

    var correct: usize = 0;
    for (out[0..n]) |r| {
        if (cluster_of[r.id] == 0) correct += 1;
    }
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
    const got = try h.search(&q, 10, 50, &out, null);
    try testing.expect(got > 0);
    for (1..got) |i| {
        try testing.expect(out[i - 1].dist <= out[i].dist);
    }
}

test "hnsw: distinct levels are sampled" {
    var h = Hnsw.init(testing.allocator, .{ .m = 16 });
    defer h.deinit();

    var seen_levels: [32]bool = @splat(false);
    for (0..500) |_| {
        const lv = h.sampleLevel();
        seen_levels[lv] = true;
    }
    try testing.expect(seen_levels[0]);
    var at_least_one_above_zero = false;
    for (1..32) |i| {
        if (seen_levels[i]) at_least_one_above_zero = true;
    }
    try testing.expect(at_least_one_above_zero);
}

test "hnsw: recall vs brute-force on random data" {
    const alloc = testing.allocator;
    var h = Hnsw.init(alloc, .{ .m = 16, .ef_construction = 200 });
    defer h.deinit();

    const dim: usize = 48;
    const n: usize = 400;
    const k: usize = 10;

    const all_vecs = try alloc.alloc(f32, n * dim);
    defer alloc.free(all_vecs);

    var prng = std.Random.DefaultPrng.init(0xABCDEF);
    const rand = prng.random();
    for (all_vecs) |*x| x.* = rand.floatNorm(f32);

    for (0..n) |i| {
        const slice = all_vecs[i * dim ..][0..dim];
        _ = try h.insert(slice);
    }

    const n_queries: usize = 20;
    var total_correct: usize = 0;

    for (0..n_queries) |_| {
        var q: [48]f32 = undefined;
        for (&q) |*x| x.* = rand.floatNorm(f32);

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
        for (0..k) |i| {
            var min_idx = i;
            for (i + 1..n) |j| {
                if (bf_dists[j] < bf_dists[min_idx]) min_idx = j;
            }
            std.mem.swap(f32, &bf_dists[i], &bf_dists[min_idx]);
            std.mem.swap(u32, &bf_ids[i], &bf_ids[min_idx]);
        }
        const ground_truth = bf_ids[0..k];

        var hnsw_out: [k]SearchResult = undefined;
        const got = try h.search(&q, k, 100, &hnsw_out, null);
        try testing.expectEqual(k, got);

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
    try testing.expect(recall >= 0.95);
}

test "hnsw: L2 metric yields correct ranking" {
    var h = Hnsw.init(testing.allocator, .{ .dist_fn = metric_mod.l2_dist });
    defer h.deinit();
    try testing.expect(!h.storesUnitVectors());

    _ = try h.insert(&[_]f32{ 10, 10, 0, 0 }); // id 0, far by magnitude
    _ = try h.insert(&[_]f32{ 1.1, 1.0, 0, 0 }); // id 1, closest
    _ = try h.insert(&[_]f32{ 5, 5, 0, 0 }); // id 2, medium

    var out: [3]SearchResult = undefined;
    const q = [_]f32{ 1, 1, 0, 0 };
    const n = try h.search(&q, 3, 50, &out, null);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u32, 1), out[0].id);
    try testing.expectApproxEqAbs(@as(f32, 0.01), out[0].dist, 1e-4);
}

test "hnsw: dot-product metric yields correct ranking" {
    var h = Hnsw.init(testing.allocator, .{ .dist_fn = metric_mod.dot_dist });
    defer h.deinit();
    try testing.expect(!h.storesUnitVectors());

    _ = try h.insert(&[_]f32{ 0.1, 0, 0, 0 }); // id 0, small overlap
    _ = try h.insert(&[_]f32{ 10, 0, 0, 0 }); // id 1, huge dot with query
    _ = try h.insert(&[_]f32{ 1, 1, 0, 0 }); // id 2, medium

    var out: [3]SearchResult = undefined;
    const q = [_]f32{ 1, 0, 0, 0 };
    const n = try h.search(&q, 3, 50, &out, null);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u32, 1), out[0].id);
    try testing.expectApproxEqAbs(@as(f32, -10), out[0].dist, 1e-4);
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
    const n = try h.search(&q, 50, 50, &out, null);
    try testing.expectEqual(@as(usize, 5), n);
}

test "hnsw: zero-norm cosine vectors produce finite dist 1.0 (no NaN)" {
    var h = Hnsw.init(testing.allocator, .{});
    defer h.deinit();

    const zero = [_]f32{ 0, 0, 0, 0 };
    const unit = [_]f32{ 1, 0, 0, 0 };
    const id_z = try h.insert(&zero);
    const id_u = try h.insert(&unit);

    var out: [2]SearchResult = undefined;
    const n1 = try h.search(&unit, 2, 16, &out, null);
    try testing.expectEqual(@as(usize, 2), n1);
    try testing.expectEqual(id_u, out[0].id);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out[0].dist, 1e-5);
    try testing.expectEqual(id_z, out[1].id);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[1].dist, 1e-5);
    try testing.expect(!std.math.isNan(out[1].dist));

    // Zero-norm query returns finite dist 1.0 for every node
    const n2 = try h.search(&zero, 2, 16, &out, null);
    try testing.expectEqual(@as(usize, 2), n2);
    for (out[0..n2]) |r| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), r.dist, 1e-5);
        try testing.expect(!std.math.isNan(r.dist));
    }
}

test "hnsw: k=0, ef < k, and exclude_id" {
    var h = Hnsw.init(testing.allocator, .{ .m = 8, .ef_construction = 50 });
    defer h.deinit();

    var prng = std.Random.DefaultPrng.init(0x12345);
    const rand = prng.random();
    const dim: usize = 16;
    const n: usize = 30;
    var first_vec: [dim]f32 = undefined;
    for (0..n) |i| {
        var v: [dim]f32 = undefined;
        for (&v) |*x| x.* = rand.floatNorm(f32);
        if (i == 0) first_vec = v;
        _ = try h.insert(&v);
    }

    var out: [10]SearchResult = undefined;
    // k = 0 returns 0
    try testing.expectEqual(@as(usize, 0), try h.search(&first_vec, 0, 50, &out, null));

    // ef < k automatically clamps effective_ef >= k and returns k results
    const got_small_ef = try h.search(&first_vec, 10, 2, &out, null);
    try testing.expectEqual(@as(usize, 10), got_small_ef);
    try testing.expectEqual(@as(u32, 0), out[0].id);

    // exclude_id = 0 omits node 0 without reducing returned count
    const got_excl = try h.searchWithSkipAndExclude(&first_vec, 10, 50, &out, null, 0);
    try testing.expectEqual(@as(usize, 10), got_excl);
    for (out[0..got_excl]) |r| {
        try testing.expect(r.id != 0);
    }
}

test "hnsw: skip bitset with tombstoned entry_point, 50% and 100% tombstoned" {
    const alloc = testing.allocator;
    var h = Hnsw.init(alloc, .{ .m = 8, .m_max0 = 16, .ef_construction = 80 });
    defer h.deinit();

    var prng = std.Random.DefaultPrng.init(0x70AB570E);
    const rand = prng.random();
    const dim: usize = 24;
    const n: usize = 80;
    for (0..n) |_| {
        var v: [dim]f32 = undefined;
        for (&v) |*x| x.* = rand.floatNorm(f32);
        _ = try h.insert(&v);
    }

    var q: [dim]f32 = undefined;
    for (&q) |*x| x.* = rand.floatNorm(f32);

    var skip = try std.bit_set.Dynamic.initEmpty(alloc, n);
    defer skip.deinit(alloc);

    // Tombstone entry_point + 50% of nodes
    const ep = h.entry_point.?;
    skip.set(ep);
    var live_expected: usize = n - 1;
    for (0..n) |i| {
        if (i % 2 == 0 and i != ep) {
            skip.set(i);
            live_expected -= 1;
        }
    }

    var out: [80]SearchResult = undefined;
    const got_half = try h.search(&q, 10, 64, &out, &skip);
    try testing.expectEqual(@as(usize, 10), got_half);
    for (out[0..got_half]) |r| {
        try testing.expect(!skip.isSet(r.id));
    }

    // Request all live nodes when 50% tombstoned -> returns exact live count
    const got_all_live = try h.search(&q, n, n, &out, &skip);
    try testing.expectEqual(live_expected, got_all_live);
    for (out[0..got_all_live]) |r| {
        try testing.expect(!skip.isSet(r.id));
    }

    // 100% tombstoned -> returns 0
    for (0..n) |i| skip.set(i);
    const got_none = try h.search(&q, 10, 64, &out, &skip);
    try testing.expectEqual(@as(usize, 0), got_none);
}

test "hnsw: L2 and dot recall@10 on N=500" {
    const alloc = testing.allocator;
    const dim: usize = 32;
    const n: usize = 500;
    const k: usize = 10;
    const n_queries: usize = 25;

    const corpus = try alloc.alloc(f32, n * dim);
    defer alloc.free(corpus);

    var prng = std.Random.DefaultPrng.init(0x500_12D0);
    const rand = prng.random();
    for (corpus) |*x| x.* = rand.floatNorm(f32);

    const queries = try alloc.alloc(f32, n_queries * dim);
    defer alloc.free(queries);
    for (queries) |*x| x.* = rand.floatNorm(f32);

    inline for ([_]metric_mod.Metric{ .l2, .dot }) |m| {
        var h = Hnsw.init(alloc, .{
            .m = 16,
            .m_max0 = 32,
            .ef_construction = 150,
            .dist_fn = m.distFn(),
        });
        defer h.deinit();
        try h.reserve(n);

        for (0..n) |i| {
            _ = try h.insert(corpus[i * dim ..][0..dim]);
        }

        var scratch = SearchScratch.init();
        defer scratch.deinit(alloc);

        var total_hits: usize = 0;
        for (0..n_queries) |qi| {
            const q = queries[qi * dim ..][0..dim];

            var bf_dists: [n]f32 = undefined;
            var bf_ids: [n]u32 = undefined;
            for (0..n) |i| {
                const v = corpus[i * dim ..][0..dim];
                bf_dists[i] = m.distSingle(q, v);
                bf_ids[i] = @intCast(i);
            }
            for (0..k) |i| {
                var min_idx = i;
                for (i + 1..n) |j| {
                    if (bf_dists[j] < bf_dists[min_idx]) min_idx = j;
                }
                std.mem.swap(f32, &bf_dists[i], &bf_dists[min_idx]);
                std.mem.swap(u32, &bf_ids[i], &bf_ids[min_idx]);
            }

            var out_pool: [k]SearchResult = undefined;
            var out_scratch: [k]SearchResult = undefined;
            const got_p = try h.search(q, k, 128, &out_pool, null);
            const got_s = try h.searchWithScratch(alloc, q, k, 128, &out_scratch, null, null, &scratch);
            try testing.expectEqual(k, got_p);
            try testing.expectEqual(got_p, got_s);

            for (0..got_p) |i| {
                try testing.expectEqual(out_pool[i].id, out_scratch[i].id);
                try testing.expectApproxEqAbs(out_pool[i].dist, out_scratch[i].dist, 1e-6);
            }

            for (out_pool[0..got_p]) |r| {
                for (bf_ids[0..k]) |gt| {
                    if (r.id == gt) {
                        total_hits += 1;
                        break;
                    }
                }
            }
        }

        const recall = @as(f32, @floatFromInt(total_hits)) / @as(f32, @floatFromInt(n_queries * k));
        try testing.expect(recall >= 0.95);
    }
}

test "hnsw: concurrent read-only search across 4 threads" {
    if (comptime builtin.single_threaded) return;

    const alloc = testing.allocator;
    var h = Hnsw.init(alloc, .{ .m = 16, .m_max0 = 32, .ef_construction = 100 });
    defer h.deinit();

    const dim: usize = 48;
    const n: usize = 300;
    const n_queries: usize = 40;

    var prng = std.Random.DefaultPrng.init(0xC0AC_0004);
    const rand = prng.random();
    const corpus = try alloc.alloc(f32, n * dim);
    defer alloc.free(corpus);
    for (corpus) |*x| x.* = rand.floatNorm(f32);
    for (0..n) |i| _ = try h.insert(corpus[i * dim ..][0..dim]);

    const queries = try alloc.alloc(f32, n_queries * dim);
    defer alloc.free(queries);
    for (queries) |*x| x.* = rand.floatNorm(f32);

    // Single-threaded baseline results to verify exact determinism under concurrency
    const ref_ids = try alloc.alloc([5]u32, n_queries);
    defer alloc.free(ref_ids);
    for (0..n_queries) |qi| {
        var out: [5]SearchResult = undefined;
        const got = try h.search(queries[qi * dim ..][0..dim], 5, 64, &out, null);
        try testing.expectEqual(@as(usize, 5), got);
        for (0..5) |j| ref_ids[qi][j] = out[j].id;
    }

    const WorkerCtx = struct {
        hnsw: *Hnsw,
        queries: []const f32,
        ref_ids: []const [5]u32,
        dim: usize,
        n_queries: usize,
        failed: std.atomic.Value(u32) = .init(0),

        fn run(ctx: *@This()) void {
            var out: [5]SearchResult = undefined;
            for (0..3) |_| {
                for (0..ctx.n_queries) |qi| {
                    const got = ctx.hnsw.search(ctx.queries[qi * ctx.dim ..][0..ctx.dim], 5, 64, &out, null) catch {
                        _ = ctx.failed.fetchAdd(1, .monotonic);
                        return;
                    };
                    if (got != 5) {
                        _ = ctx.failed.fetchAdd(1, .monotonic);
                        return;
                    }
                    for (0..5) |j| {
                        if (out[j].id != ctx.ref_ids[qi][j]) {
                            _ = ctx.failed.fetchAdd(1, .monotonic);
                            return;
                        }
                    }
                }
            }
        }
    };

    var wctx = WorkerCtx{
        .hnsw = &h,
        .queries = queries,
        .ref_ids = ref_ids,
        .dim = dim,
        .n_queries = n_queries,
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, WorkerCtx.run, .{&wctx});
    }
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 0), wctx.failed.load(.acquire));
}

test "hnsw: custom DistFn works end-to-end" {
    const L1 = struct {
        fn dist(a: []align(1) const f32, b: []align(1) const f32) f32 {
            var s: f32 = 0.0;
            for (a, b) |x, y| s += @abs(x - y);
            return s;
        }
    };

    var h = Hnsw.init(testing.allocator, .{ .dist_fn = L1.dist });
    defer h.deinit();
    try testing.expect(!h.storesUnitVectors());

    _ = try h.insert(&[_]f32{ 0, 0, 0 });
    _ = try h.insert(&[_]f32{ 1, 1, 1 });
    _ = try h.insert(&[_]f32{ 5, 0, 0 });

    var out: [3]SearchResult = undefined;
    const got = try h.search(&[_]f32{ 1.1, 1.0, 1.0 }, 3, 16, &out, null);
    try testing.expectEqual(@as(usize, 3), got);
    try testing.expectEqual(@as(u32, 1), out[0].id);
    try testing.expectApproxEqAbs(@as(f32, 0.1), out[0].dist, 1e-5);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Serialization tests                               ║
// ╚═══════════════════════════════════════════════════╝

const SerdeHarness = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    const Writer = struct {
        h: *SerdeHarness,
        alloc: std.mem.Allocator,
        pub fn writeAll(self: *@This(), data: []const u8) !void {
            try self.h.buf.appendSlice(self.alloc, data);
        }
    };

    const Reader = struct {
        h: *SerdeHarness,
        pos: usize = 0,
        pub fn readAll(self: *@This(), dest: []u8) !usize {
            const avail = self.h.buf.items.len - self.pos;
            const n = @min(dest.len, avail);
            @memcpy(dest[0..n], self.h.buf.items[self.pos..][0..n]);
            self.pos += n;
            return n;
        }
    };
};

const VecStore = struct {
    vectors: []const []const u8,
    fn resolve(raw_ctx: *anyopaque, node_id: u32) ?[]const u8 {
        const self: *VecStore = @ptrCast(@alignCast(raw_ctx));
        if (node_id >= self.vectors.len) return null;
        return self.vectors[node_id];
    }
};

test "hnsw: writeTo/readFrom roundtrip preserves graph shape and recall" {
    const alloc = testing.allocator;
    var h = Hnsw.init(alloc, .{ .m = 8, .ef_construction = 100 });
    defer h.deinit();

    var prng = std.Random.DefaultPrng.init(0xFEEDFACE);
    const rand = prng.random();
    const dim: usize = 16;
    const n_vecs: usize = 30;

    const raw_buf = try alloc.alloc(f32, n_vecs * dim);
    defer alloc.free(raw_buf);
    for (raw_buf) |*x| x.* = rand.floatNorm(f32);

    var byte_slices: [n_vecs][]const u8 = undefined;
    for (0..n_vecs) |i| {
        const f32_slice = raw_buf[i * dim ..][0..dim];
        const byte_ptr: [*]const u8 = @ptrCast(f32_slice.ptr);
        byte_slices[i] = byte_ptr[0 .. dim * @sizeOf(f32)];
        _ = try h.insert(f32_slice);
    }

    var q: [dim]f32 = undefined;
    for (&q) |*x| x.* = rand.floatNorm(f32);
    var baseline_out: [10]SearchResult = undefined;
    const baseline_n = try h.search(&q, 10, 100, &baseline_out, null);

    var harness = SerdeHarness{};
    defer harness.buf.deinit(alloc);
    var writer = SerdeHarness.Writer{ .h = &harness, .alloc = alloc };
    try h.writeTo(&writer);

    var vec_store = VecStore{ .vectors = &byte_slices };
    var reader = SerdeHarness.Reader{ .h = &harness };
    var restored = try Hnsw.readFrom(alloc, &reader, VecStore.resolve, @ptrCast(&vec_store));
    defer restored.deinit();

    try testing.expectEqual(h.len(), restored.len());
    try testing.expectEqual(h.dim, restored.dim);
    try testing.expectEqual(h.top_level, restored.top_level);
    try testing.expectEqual(h.entry_point, restored.entry_point);
    for (0..h.len()) |i| {
        const nid: u32 = @intCast(i);
        const lvl = h.nodeLevel(nid);
        try testing.expectEqual(lvl, restored.nodeLevel(nid));
        for (0..@as(usize, lvl) + 1) |lc| {
            const orig_nbrs = h.nodeNeighbors(nid, lc);
            const rest_nbrs = restored.nodeNeighbors(nid, lc);
            try testing.expectEqualSlices(u32, orig_nbrs, rest_nbrs);
        }
    }

    // Reader consumed exact graph bytes with zero over-read
    try testing.expectEqual(harness.buf.items.len, reader.pos);

    var restored_out: [10]SearchResult = undefined;
    const restored_n = try restored.search(&q, 10, 100, &restored_out, null);
    try testing.expectEqual(baseline_n, restored_n);
    for (0..baseline_n) |i| {
        try testing.expectEqual(baseline_out[i].id, restored_out[i].id);
        try testing.expectApproxEqAbs(baseline_out[i].dist, restored_out[i].dist, 1e-6);
    }
}

test "hnsw: readFromWithDistFn preserves unnormalized L2 and dot vectors" {
    const alloc = testing.allocator;
    const v0 = [_]f32{ 10, 0, 0, 0 };
    const v1 = [_]f32{ 1, 0, 0, 0 };
    const v2 = [_]f32{ 5, 0, 0, 0 };
    const b0 = std.mem.sliceAsBytes(&v0);
    const b1 = std.mem.sliceAsBytes(&v1);
    const b2 = std.mem.sliceAsBytes(&v2);
    const slices = [_][]const u8{ b0, b1, b2 };

    inline for ([_]DistFn{ metric_mod.l2_dist, metric_mod.dot_dist }) |dfn| {
        var h = Hnsw.init(alloc, .{ .m = 4, .m_max0 = 8, .dist_fn = dfn });
        defer h.deinit();
        _ = try h.insert(&v0);
        _ = try h.insert(&v1);
        _ = try h.insert(&v2);

        var harness = SerdeHarness{};
        defer harness.buf.deinit(alloc);
        var writer = SerdeHarness.Writer{ .h = &harness, .alloc = alloc };
        try h.writeTo(&writer);
        // Append sentinel trailing bytes to verify zero over-read
        try harness.buf.appendSlice(alloc, "TRAIL");

        var vs = VecStore{ .vectors = &slices };
        var reader = SerdeHarness.Reader{ .h = &harness };
        var restored = try Hnsw.readFromWithDistFn(alloc, &reader, dfn, VecStore.resolve, @ptrCast(&vs));
        defer restored.deinit();

        try testing.expect(!restored.storesUnitVectors());
        // Magnitude must NOT have been normalized to 1.0
        try testing.expectApproxEqAbs(@as(f32, 10.0), restored.getVector(0)[0], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 5.0), restored.getVector(2)[0], 1e-6);
        // Trailing bytes untouched
        try testing.expectEqualStrings("TRAIL", harness.buf.items[reader.pos..]);
    }
}

test "hnsw: corrupt and truncated readFrom are leak-free" {
    const alloc = testing.allocator;
    var h = Hnsw.init(alloc, .{ .m = 4, .m_max0 = 8, .ef_construction = 40 });
    defer h.deinit();

    const dim: usize = 8;
    const n_vecs: usize = 10;
    var raw: [n_vecs][dim]f32 = undefined;
    var slices: [n_vecs][]const u8 = undefined;
    for (0..n_vecs) |i| {
        for (0..dim) |d| raw[i][d] = @as(f32, @floatFromInt(i + d + 1));
        slices[i] = std.mem.sliceAsBytes(&raw[i]);
        _ = try h.insert(&raw[i]);
    }

    var full = SerdeHarness{};
    defer full.buf.deinit(alloc);
    var writer = SerdeHarness.Writer{ .h = &full, .alloc = alloc };
    try h.writeTo(&writer);

    var vs = VecStore{ .vectors = &slices };

    // 1. Truncated at header and mid-node -> EndOfStream, zero leaks
    for ([_]usize{ 0, 10, 38, 40, full.buf.items.len / 2, full.buf.items.len - 1 }) |cut| {
        var trunc = SerdeHarness{};
        defer trunc.buf.deinit(alloc);
        try trunc.buf.appendSlice(alloc, full.buf.items[0..cut]);
        var reader = SerdeHarness.Reader{ .h = &trunc };
        try testing.expectError(error.EndOfStream, Hnsw.readFrom(alloc, &reader, VecStore.resolve, @ptrCast(&vs)));
    }

    // 2. Missing vector mid-load -> MissingVector, zero leaks
    {
        var short_vs = VecStore{ .vectors = slices[0..5] };
        var reader = SerdeHarness.Reader{ .h = &full };
        try testing.expectError(error.MissingVector, Hnsw.readFrom(alloc, &reader, VecStore.resolve, @ptrCast(&short_vs)));
    }

    // 3. Corrupt neighbor count exceeding m_max0 -> CorruptGraph, zero leaks
    {
        var bad = SerdeHarness{};
        defer bad.buf.deinit(alloc);
        try bad.buf.appendSlice(alloc, full.buf.items);
        // Header = 28 + 11 = 39 bytes; byte 39 = node 0 level; bytes 40..42 = L0 count
        std.mem.writeInt(u16, bad.buf.items[40..42], 999, .little);
        var reader = SerdeHarness.Reader{ .h = &bad };
        try testing.expectError(error.CorruptGraph, Hnsw.readFrom(alloc, &reader, VecStore.resolve, @ptrCast(&vs)));
    }

    // 4. Corrupt out-of-bounds entry point -> CorruptGraph, zero leaks
    {
        var bad = SerdeHarness{};
        defer bad.buf.deinit(alloc);
        try bad.buf.appendSlice(alloc, full.buf.items);
        std.mem.writeInt(u32, bad.buf.items[33..37], 9999, .little);
        var reader = SerdeHarness.Reader{ .h = &bad };
        try testing.expectError(error.CorruptGraph, Hnsw.readFrom(alloc, &reader, VecStore.resolve, @ptrCast(&vs)));
    }

    // 5. Corrupt level > 31 -> CorruptGraph, zero leaks
    {
        var bad = SerdeHarness{};
        defer bad.buf.deinit(alloc);
        try bad.buf.appendSlice(alloc, full.buf.items);
        bad.buf.items[39] = 40;
        var reader = SerdeHarness.Reader{ .h = &bad };
        try testing.expectError(error.CorruptGraph, Hnsw.readFrom(alloc, &reader, VecStore.resolve, @ptrCast(&vs)));
    }
}
