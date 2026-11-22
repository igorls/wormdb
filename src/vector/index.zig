//! Per-namespace HNSW index registry.
//!
//! Wraps the pure-graph `Hnsw` from `hnsw.zig` with the side tables and
//! locking that make it usable from concurrent server code:
//!
//!   NamespaceIndex — one per namespace.
//!     .hnsw       — the graph (pure, lock-free)
//!     .keys       — arena-owned vec keys indexed by node_id
//!     .timestamps — vec insert timestamps indexed by node_id
//!     .lock       — RwLock: concurrent searches, serialized inserts
//!
//!   NamespaceRegistry — global, owned by the server.
//!     Maps namespace string → *NamespaceIndex. Itself protected by an
//!     RwLock so getOrCreate is race-safe.
//!
//! Lifecycle:
//!   - Registry is created at server init, destroyed at shutdown.
//!   - A NamespaceIndex is created lazily on first `getOrCreate`.
//!   - Indexes never shrink (HNSW has no delete support in MVP). Full
//!     rebuild via EXEC vreindex.
//!
//! Not handled in this module (by design):
//!   - Persistence. Indexes are in-memory; restart = empty.
//!   - Cluster replication of index state. Peers must run `vreindex`.
//!     The underlying vectors and BQ hashes DO replicate, so queries
//!     on peers fall back to the BQ prefilter until reindexed.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../core/compat.zig");
const narrow_atomics = compat.narrow_atomics;
/// The canonical signal: with it set, std.Thread.join/spawn are not analysed.
const single_threaded = @import("build_options").single_threaded;
const build_options = @import("build_options");
const distance = @import("distance.zig");
const hnsw_mod = @import("hnsw.zig");
const metric_mod = @import("metric.zig");
const rabitq_mod = @import("rabitq.zig");
const topk_mod = @import("topk.zig");

pub const Hnsw = hnsw_mod.Hnsw;
pub const HnswParams = hnsw_mod.HnswParams;
pub const Metric = metric_mod.Metric;
pub const RabitqParams = rabitq_mod.RabitqParams;

pub const RegistryError = error{
    /// Returned by `getOrCreate` when the caller supplies a metric that
    /// disagrees with the one the namespace was originally created with.
    /// A namespace's metric is immutable — callers who want to switch
    /// must drop the namespace (via `vreindex` with a new first insert,
    /// or a future `vnsdrop` op) and start fresh.
    MetricMismatch,
    /// Returned when an insert's vector length differs from the dimension
    /// frozen on the namespace's first insert. Each namespace's HNSW graph
    /// is built against one dimension; variable-dim vectors would become
    /// invisible to stage-2 refine (silent drop) and, under WORM, would be
    /// permanently stuck in the store. Dim is frozen eagerly to fail loudly.
    DimensionMismatch,
    /// Serialized block failed structural validation (unknown metric byte,
    /// torn counts, etc).
    CorruptIndex,
    /// Reader returned 0 bytes mid-record.
    EndOfStream,
};

/// Outcome of `markTombstoneLocked`.
pub const TombstoneResult = enum {
    /// The node was live; it is now tombstoned.
    deleted,
    /// The node was already tombstoned; this call was a no-op.
    noop,
    /// No node matched the given key in this index.
    missing,
};

/// Cache-line-padded sharded reader-writer lock (`compat.ShardedRwLock`).
/// Eliminates cross-core reader cache-line bouncing on multi-CCD CPUs while
/// compiling to an inert no-op on `wasm32-wasi` (`narrow_atomics`).
const RwLock = compat.ShardedRwLock;

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const EMPTY_U8_SLAB: [0]u8 align(64) = .{};
const EMPTY_F32_SLAB: [0]f32 align(64) = .{};

/// Result from `NamespaceIndex.search`. `key` is the stored vec key (borrowed
/// from the index's keys[] array — valid as long as the caller holds the
/// index's read-lock, or copies before releasing).
pub const IndexSearchResult = struct {
    key: []const u8,
    dist: f32,
    timestamp: u64,
};

/// Result from in-index BQ / RaBitQ / exact slab scans. `key` is borrowed from
/// `NamespaceIndex.keys` and valid while the caller holds `ns_idx.lockShared()`.
pub const IndexScoredResult = struct {
    key: []const u8,
    score: f32,
    timestamp: u64,
};

/// Outcome of an in-index BQ / RaBitQ slab scan.
/// When `needs_kv_rerank` is true, `out[0..count]` holds Stage-1 candidates whose
/// exact Stage-2 rescore must read raw unnormalized vectors from KV *after*
/// releasing `ns_idx.lockShared()` (e.g. `.l2`/`.dot` query on a `.cosine` NS
/// whose HNSW slab stores unit-normalized vectors).
pub const SlabSearchResult = struct {
    count: usize,
    needs_kv_rerank: bool,
};

/// Reference-counted owner for `RabitqParams` using a 32-bit atomic counter
/// (`wasm32-wasi` safe). Allows KV-fallback RaBitQ scans to retain params and
/// release `ns_idx.lockShared()` BEFORE calling `Store.scanPrefixCallback`,
/// eliminating AB-BA deadlocks against `Store.writeSnapshot`.
pub const RabitqParamsHandle = struct {
    allocator: std.mem.Allocator,
    params: *RabitqParams,
    refs: std.atomic.Value(u32),

    pub fn create(allocator: std.mem.Allocator, params: *RabitqParams) !*RabitqParamsHandle {
        const h = try allocator.create(RabitqParamsHandle);
        h.* = .{
            .allocator = allocator,
            .params = params,
            .refs = .init(1),
        };
        return h;
    }

    pub inline fn retain(self: *RabitqParamsHandle) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *RabitqParamsHandle) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.params.deinit();
            self.allocator.destroy(self.params);
            self.allocator.destroy(self);
        }
    }
};

fn nextSlabCap(current: usize, needed: usize) usize {
    if (current == 0) return @max(needed, 64);
    var cap = current;
    while (cap < needed) {
        const step = if (cap < 1024) cap else @max(@as(usize, 256), cap / 4);
        cap = std.mem.alignForward(usize, cap + step, 64);
    }
    return cap;
}

/// Dense 64B-aligned legacy 1-bit BQ code slab indexed by `node_id`.
/// Row stride is 8B-aligned and zero-padded so `distance.hammingBatch4` hits
/// wide u64/AVX-512 paths with zero tail divergence.
const BqSlab = struct {
    dim: usize = 0,
    code_bytes: usize = 0,
    code_stride: usize = 0,
    len: usize = 0,
    cap: usize = 0,
    codes: []align(64) u8 = @constCast(&EMPTY_U8_SLAB),
    synced: bool = true,

    fn deinit(self: *BqSlab, allocator: std.mem.Allocator) void {
        if (self.codes.len > 0) allocator.free(self.codes);
        self.* = .{};
    }

    fn resetKeepingAlloc(self: *BqSlab, synced: bool) void {
        self.dim = 0;
        self.code_bytes = 0;
        self.code_stride = 0;
        self.len = 0;
        self.synced = synced;
    }

    fn configure(self: *BqSlab, allocator: std.mem.Allocator, dim: usize) void {
        const cb = distance.binaryQuantizedSize(dim);
        const stride = std.mem.alignForward(usize, cb, 8);
        if (self.dim != dim or self.code_stride != stride) {
            if (self.codes.len > 0) {
                allocator.free(self.codes);
                self.codes = @constCast(&EMPTY_U8_SLAB);
                self.cap = 0;
            }
            self.dim = dim;
            self.code_bytes = cb;
            self.code_stride = stride;
            self.len = 0;
        }
    }

    fn ensureCapacity(self: *BqSlab, allocator: std.mem.Allocator, needed: usize, exact: bool) !void {
        if (self.code_stride == 0 or needed <= self.cap) return;
        const target = if (exact) needed else nextSlabCap(self.cap, needed);
        const fresh = try allocator.alignedAlloc(u8, .@"64", target * self.code_stride);
        if (self.len > 0) {
            @memcpy(fresh[0 .. self.len * self.code_stride], self.codes[0 .. self.len * self.code_stride]);
        }
        if (self.codes.len > 0) allocator.free(self.codes);
        self.codes = fresh;
        self.cap = target;
    }

    fn setSlot(self: *BqSlab, id: usize, code: []const u8) void {
        const dst = self.codes[id * self.code_stride ..][0..self.code_stride];
        @memcpy(dst[0..self.code_bytes], code[0..self.code_bytes]);
        if (self.code_stride > self.code_bytes) {
            @memset(dst[self.code_bytes..self.code_stride], 0);
        }
    }

    fn appendCode(self: *BqSlab, allocator: std.mem.Allocator, dim: usize, code: []const u8) !void {
        if (self.dim == 0) self.configure(allocator, dim);
        try self.ensureCapacity(allocator, self.len + 1, false);
        self.setSlot(self.len, code);
        self.len += 1;
    }

    fn appendFromVec(self: *BqSlab, allocator: std.mem.Allocator, vec: []align(1) const f32) !void {
        if (self.dim == 0) self.configure(allocator, vec.len);
        try self.ensureCapacity(allocator, self.len + 1, false);
        const dst = self.codes[self.len * self.code_stride ..][0..self.code_stride];
        distance.binaryQuantize(vec, dst[0..self.code_bytes]);
        if (self.code_stride > self.code_bytes) {
            @memset(dst[self.code_bytes..self.code_stride], 0);
        }
        self.len += 1;
    }

    inline fn codeAt(self: *const BqSlab, id: usize) []const u8 {
        return self.codes[id * self.code_stride ..][0..self.code_stride];
    }
};

/// Dense 64B-aligned RaBitQ SoA + FastScan32 transposed-nibble slab indexed by `node_id`.
/// Full 32-vector blocks are packed incrementally via `rabitq.packFastScanBlock32`
/// and scanned via `rabitq.estimateFastScanBlock32`; partial tail `< 32` uses
/// `rabitq.estimateL2Sq4BitSlabBatch4`.
const RabitqSlab = struct {
    dim: usize = 0,
    code_bytes: usize = 0,
    code_stride: usize = 0,
    block_bytes: usize = 0,
    len: usize = 0,
    cap: usize = 0,
    block_cap: usize = 0,
    packed_blocks: usize = 0,
    codes: []align(64) u8 = @constCast(&EMPTY_U8_SLAB),
    f_add: []align(64) f32 = @constCast(&EMPTY_F32_SLAB),
    f_rescale: []align(64) f32 = @constCast(&EMPTY_F32_SLAB),
    popc: []u16 = &.{},
    fastscan_blocks: []align(64) u8 = @constCast(&EMPTY_U8_SLAB),
    synced: bool = false,

    fn deinit(self: *RabitqSlab, allocator: std.mem.Allocator) void {
        if (self.codes.len > 0) allocator.free(self.codes);
        if (self.f_add.len > 0) allocator.free(self.f_add);
        if (self.f_rescale.len > 0) allocator.free(self.f_rescale);
        if (self.popc.len > 0) allocator.free(self.popc);
        if (self.fastscan_blocks.len > 0) allocator.free(self.fastscan_blocks);
        self.* = .{};
    }

    fn reset(self: *RabitqSlab, allocator: std.mem.Allocator, synced: bool) void {
        self.deinit(allocator);
        self.synced = synced;
    }

    fn configure(self: *RabitqSlab, allocator: std.mem.Allocator, dim: usize) void {
        const cb = rabitq_mod.codeBytes(dim);
        const stride = std.mem.alignForward(usize, cb, 8);
        const bb = rabitq_mod.fastScanBlockBytes(dim);
        if (self.dim != dim or self.code_stride != stride or self.block_bytes != bb) {
            const was_synced = self.synced;
            self.deinit(allocator);
            self.dim = dim;
            self.code_bytes = cb;
            self.code_stride = stride;
            self.block_bytes = bb;
            self.synced = was_synced;
        }
    }

    fn ensureCapacity(self: *RabitqSlab, allocator: std.mem.Allocator, needed: usize, exact: bool) !void {
        if (self.code_stride == 0) return;
        const need_nodes = needed > self.cap;
        const needed_blocks = needed / 32;
        const need_blocks = needed_blocks > self.block_cap;
        if (!need_nodes and !need_blocks) return;

        const target_nodes = if (need_nodes)
            (if (exact) needed else nextSlabCap(self.cap, needed))
        else
            self.cap;
        const target_blocks = if (need_blocks)
            (if (exact) needed_blocks else @max(needed_blocks, if (self.block_cap == 0) @as(usize, 4) else self.block_cap + @max(@as(usize, 4), self.block_cap / 2)))
        else
            self.block_cap;

        var new_codes: ?[]align(64) u8 = null;
        errdefer if (new_codes) |b| allocator.free(b);
        var new_f_add: ?[]align(64) f32 = null;
        errdefer if (new_f_add) |b| allocator.free(b);
        var new_f_rescale: ?[]align(64) f32 = null;
        errdefer if (new_f_rescale) |b| allocator.free(b);
        var new_popc: ?[]u16 = null;
        errdefer if (new_popc) |b| allocator.free(b);
        var new_blocks: ?[]align(64) u8 = null;
        errdefer if (new_blocks) |b| allocator.free(b);

        if (need_nodes) {
            new_codes = try allocator.alignedAlloc(u8, .@"64", target_nodes * self.code_stride);
            new_f_add = try allocator.alignedAlloc(f32, .@"64", target_nodes);
            new_f_rescale = try allocator.alignedAlloc(f32, .@"64", target_nodes);
            new_popc = try allocator.alloc(u16, target_nodes);
        }
        if (need_blocks and self.block_bytes > 0) {
            new_blocks = try allocator.alignedAlloc(u8, .@"64", target_blocks * self.block_bytes);
        }

        if (need_nodes) {
            if (self.len > 0) {
                @memcpy(new_codes.?[0 .. self.len * self.code_stride], self.codes[0 .. self.len * self.code_stride]);
                @memcpy(new_f_add.?[0..self.len], self.f_add[0..self.len]);
                @memcpy(new_f_rescale.?[0..self.len], self.f_rescale[0..self.len]);
                @memcpy(new_popc.?[0..self.len], self.popc[0..self.len]);
            }
            if (self.codes.len > 0) allocator.free(self.codes);
            if (self.f_add.len > 0) allocator.free(self.f_add);
            if (self.f_rescale.len > 0) allocator.free(self.f_rescale);
            if (self.popc.len > 0) allocator.free(self.popc);
            self.codes = new_codes.?;
            self.f_add = new_f_add.?;
            self.f_rescale = new_f_rescale.?;
            self.popc = new_popc.?;
            self.cap = target_nodes;
        }
        if (new_blocks) |nb| {
            if (self.packed_blocks > 0) {
                @memcpy(nb[0 .. self.packed_blocks * self.block_bytes], self.fastscan_blocks[0 .. self.packed_blocks * self.block_bytes]);
            }
            if (self.fastscan_blocks.len > 0) allocator.free(self.fastscan_blocks);
            self.fastscan_blocks = nb;
            self.block_cap = target_blocks;
        }
    }

    fn setSlot(self: *RabitqSlab, id: usize, code: []const u8, l2_norm: f32, corr: f32) void {
        const dst = self.codes[id * self.code_stride ..][0..self.code_stride];
        @memcpy(dst[0..self.code_bytes], code[0..self.code_bytes]);
        if (self.code_stride > self.code_bytes) {
            @memset(dst[self.code_bytes..self.code_stride], 0);
        }
        const factors = rabitq_mod.computeSlabFactors(self.dim, l2_norm, corr, dst[0..self.code_bytes]);
        self.f_add[id] = factors.f_add;
        self.f_rescale[id] = factors.f_rescale;
        self.popc[id] = factors.popc;
    }

    fn setTombstoneSlot(self: *RabitqSlab, id: usize) void {
        const dst = self.codes[id * self.code_stride ..][0..self.code_stride];
        @memset(dst, 0);
        self.f_add[id] = std.math.inf(f32);
        self.f_rescale[id] = 0.0;
        self.popc[id] = 0;
    }

    fn packBlock(self: *RabitqSlab, blk_idx: usize) void {
        const base = blk_idx * 32;
        var ptrs: [32][]const u8 = undefined;
        inline for (0..32) |j| {
            ptrs[j] = self.codes[(base + j) * self.code_stride ..][0..self.code_bytes];
        }
        const out_blk = self.fastscan_blocks[blk_idx * self.block_bytes ..][0..self.block_bytes];
        rabitq_mod.packFastScanBlock32(ptrs, self.dim, out_blk);
    }

    fn packAllFullBlocks(self: *RabitqSlab) void {
        const n_blocks = self.len / 32;
        for (0..n_blocks) |b| {
            self.packBlock(b);
        }
        self.packed_blocks = n_blocks;
    }

    fn appendEncoded(self: *RabitqSlab, allocator: std.mem.Allocator, dim: usize, code: []const u8, l2_norm: f32, corr: f32) !void {
        if (self.dim == 0) self.configure(allocator, dim);
        try self.ensureCapacity(allocator, self.len + 1, false);
        self.setSlot(self.len, code, l2_norm, corr);
        self.len += 1;
        if (self.len % 32 == 0) {
            const blk_idx = (self.len / 32) - 1;
            self.packBlock(blk_idx);
            self.packed_blocks = blk_idx + 1;
        }
    }

    inline fn codeAt(self: *const RabitqSlab, id: usize) []const u8 {
        return self.codes[id * self.code_stride ..][0..self.code_bytes];
    }
};

const STACK_DIM_CAP: usize = 1536;
const STACK_SLAB_QUERY_CAP: usize = 2048;
const STACK_LUT_GROUPS: usize = 512; // covers up to dim = 2048
const MAX_BQ_BUCKET_BITS: usize = 2048;
const RABITQ_SEL_STACK_CAP: usize = 1024;
const RABITQ_SEL_GUARD: usize = 32;

const is_x86_64 = builtin.cpu.arch == .x86_64;
const has_avx512f = is_x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f);
const has_avx2 = is_x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

const IdDist = struct { id: u32, dist: f32 };
fn idDistOf(x: IdDist) f32 {
    return x.dist;
}
fn idDistLess(_: void, a: IdDist, b: IdDist) bool {
    return a.dist < b.dist;
}
const IdDistHeap = topk_mod.BoundedMaxHeap(IdDist, idDistOf);

const IdHam = struct { id: u32, ham: u16 };

const IdScore = struct { id: u32, score: f32 };
fn idScoreOf(x: IdScore) f32 {
    return x.score;
}
const IdScoreTopK = topk_mod.TopK(IdScore, idScoreOf);

/// Compare 32 FastScan distances against `threshold` using SIMD vectors and pack
/// strictly-passing lanes (`d2 < threshold`) into a `u32` bitmask (lane `i` = bit `i`).
/// IEEE-754 ordered `<` naturally rejects `NaN` and `+inf` (including tombstones).
inline fn blockLessThanMask32(d2_buf: *align(64) const [32]f32, threshold: f32) u32 {
    if (comptime has_avx512f) {
        const tv: @Vector(16, f32) = @splat(threshold);
        const m0: u16 = @bitCast(@as(@Vector(16, f32), d2_buf[0..16].*) < tv);
        const m1: u16 = @bitCast(@as(@Vector(16, f32), d2_buf[16..32].*) < tv);
        return @as(u32, m0) | (@as(u32, m1) << 16);
    } else if (comptime has_avx2) {
        const tv: @Vector(8, f32) = @splat(threshold);
        const m0: u8 = @bitCast(@as(@Vector(8, f32), d2_buf[0..8].*) < tv);
        const m1: u8 = @bitCast(@as(@Vector(8, f32), d2_buf[8..16].*) < tv);
        const m2: u8 = @bitCast(@as(@Vector(8, f32), d2_buf[16..24].*) < tv);
        const m3: u8 = @bitCast(@as(@Vector(8, f32), d2_buf[24..32].*) < tv);
        return @as(u32, m0) | (@as(u32, m1) << 8) | (@as(u32, m2) << 16) | (@as(u32, m3) << 24);
    } else {
        const tv: @Vector(4, f32) = @splat(threshold);
        var mask: u32 = 0;
        inline for (0..8) |chunk| {
            const m: u4 = @bitCast(@as(@Vector(4, f32), d2_buf[chunk * 4 ..][0..4].*) < tv);
            mask |= @as(u32, m) << @intCast(chunk * 4);
        }
        return mask;
    }
}

/// AVX-512F branchless compress-store of strictly-passing (`v < tv`) 16-lane distance
/// and node-ID vectors directly into contiguous SoA scratch buffers.
/// Caller guarantees `dst_d` and `dst_i` have >= 16 writable slots remaining.
inline fn compressStore16Avx512(
    v: @Vector(16, f32),
    ids: @Vector(16, u32),
    tv: @Vector(16, f32),
    dst_d: [*]f32,
    dst_i: [*]u32,
) usize {
    const mask_vec = v < tv;
    const m: u16 = @bitCast(mask_vec);
    asm volatile (
        \\vcompressps %[v], (%[dd]) {%[k]}
        \\vpcompressd %[ids], (%[di]) {%[k]}
        :
        : [k] "{k1}" (mask_vec),
          [v] "v" (v),
          [ids] "v" (ids),
          [dd] "r" (dst_d),
          [di] "r" (dst_i),
        : .{ .memory = true });
    return @popCount(m);
}

/// In-place Sedgewick median-of-3 quickselect over SoA `(dists, ids)` ascending by `dist`.
/// Used only as an OOM fallback when `dists.len > RABITQ_SEL_STACK_CAP + RABITQ_SEL_GUARD`
/// and allocating temporary scratch fails.
fn nthElementSoaInPlace(dists: []f32, ids: []u32, k: usize) f32 {
    std.debug.assert(k < dists.len and dists.len == ids.len);
    var lo: usize = 0;
    var hi: usize = dists.len - 1;
    while (lo < hi) {
        if (hi - lo <= 16) {
            var idx: usize = lo + 1;
            while (idx <= hi) : (idx += 1) {
                const kd = dists[idx];
                const ki = ids[idx];
                var p = idx;
                while (p > lo and dists[p - 1] > kd) : (p -= 1) {
                    dists[p] = dists[p - 1];
                    ids[p] = ids[p - 1];
                }
                dists[p] = kd;
                ids[p] = ki;
            }
            return dists[k];
        }

        const mid = lo + ((hi - lo) >> 1);
        if (dists[mid] < dists[lo]) {
            std.mem.swap(f32, &dists[lo], &dists[mid]);
            std.mem.swap(u32, &ids[lo], &ids[mid]);
        }
        if (dists[hi] < dists[lo]) {
            std.mem.swap(f32, &dists[lo], &dists[hi]);
            std.mem.swap(u32, &ids[lo], &ids[hi]);
        }
        if (dists[hi] < dists[mid]) {
            std.mem.swap(f32, &dists[mid], &dists[hi]);
            std.mem.swap(u32, &ids[mid], &ids[hi]);
        }

        std.mem.swap(f32, &dists[mid], &dists[lo + 1]);
        std.mem.swap(u32, &ids[mid], &ids[lo + 1]);
        const pivot = dists[lo + 1];

        var i = lo + 1;
        var j = hi;
        while (true) {
            i += 1;
            while (dists[i] < pivot) : (i += 1) {}
            j -= 1;
            while (dists[j] > pivot) : (j -= 1) {}
            if (i >= j) break;
            std.mem.swap(f32, &dists[i], &dists[j]);
            std.mem.swap(u32, &ids[i], &ids[j]);
        }
        std.mem.swap(f32, &dists[lo + 1], &dists[j]);
        std.mem.swap(u32, &ids[lo + 1], &ids[j]);

        if (j == k) return dists[k];
        if (k < j) {
            hi = j - 1;
        } else {
            lo = j + 1;
        }
    }
    return dists[k];
}

/// Branchless two-buffer SoA quickselect: places the `k` smallest `(dist, id)` pairs
/// in `dists[0..k]` / `ids[0..k]` and returns the exact `k`-th smallest distance
/// (`max(dists[0..k])`). Marked `noinline` + `.cold` so the FastScan32 loop stays
/// compact and keeps ZMM registers live without spills.
/// Precondition: `1 <= k <= dists.len`, `dists.len == ids.len`, no NaNs in `dists`.
noinline fn branchlessSelectKSoa(
    dists: []f32,
    ids: []u32,
    k: usize,
    scratch_alloc: std.mem.Allocator,
) f32 {
    @branchHint(.cold);
    std.debug.assert(k >= 1 and k <= dists.len and dists.len == ids.len);

    var tmp_d_stack: [RABITQ_SEL_STACK_CAP + RABITQ_SEL_GUARD]f32 = undefined;
    var tmp_i_stack: [RABITQ_SEL_STACK_CAP + RABITQ_SEL_GUARD]u32 = undefined;
    var tmp_d_heap: ?[]f32 = null;
    var tmp_i_heap: ?[]u32 = null;
    defer if (tmp_d_heap) |b| scratch_alloc.free(b);
    defer if (tmp_i_heap) |b| scratch_alloc.free(b);

    const tmp_d: []f32 = if (dists.len <= tmp_d_stack.len)
        tmp_d_stack[0..dists.len]
    else blk: {
        const bd = scratch_alloc.alloc(f32, dists.len) catch return nthElementSoaInPlace(dists, ids, k - 1);
        tmp_d_heap = bd;
        break :blk bd;
    };
    const tmp_i: []u32 = if (ids.len <= tmp_i_stack.len)
        tmp_i_stack[0..ids.len]
    else blk: {
        const bi = scratch_alloc.alloc(u32, ids.len) catch return nthElementSoaInPlace(dists, ids, k - 1);
        tmp_i_heap = bi;
        break :blk bi;
    };

    var lo: usize = 0;
    var hi: usize = dists.len;
    var target = k;

    while (hi - lo > 16) {
        const mid = lo + ((hi - lo) >> 1);
        const a = dists[lo];
        const b = dists[mid];
        const c = dists[hi - 1];
        const pivot = @max(@min(a, b), @min(@max(a, b), c));

        var nl: usize = 0;
        var neq: usize = 0;
        var nr: usize = 0;
        for (lo..hi) |idx| {
            const d = dists[idx];
            const id = ids[idx];
            const lt = d < pivot;
            const dl_idx = lo + nl;
            const dr_idx = hi - 1 - nr;
            tmp_d[dl_idx] = d;
            tmp_i[dl_idx] = id;
            nl += @intFromBool(lt);
            tmp_d[dr_idx] = d;
            tmp_i[dr_idx] = id;
            nr += @intFromBool(!lt);
            neq += @intFromBool(d == pivot);
        }

        if (target <= nl) {
            @memcpy(dists[lo .. lo + nl], tmp_d[lo .. lo + nl]);
            @memcpy(ids[lo .. lo + nl], tmp_i[lo .. lo + nl]);
            hi = lo + nl;
        } else if (target <= nl + neq) {
            @memcpy(dists[lo .. lo + nl], tmp_d[lo .. lo + nl]);
            @memcpy(ids[lo .. lo + nl], tmp_i[lo .. lo + nl]);
            var w = lo + nl;
            for (hi - nr..hi) |idx| {
                if (tmp_d[idx] == pivot) {
                    dists[w] = tmp_d[idx];
                    ids[w] = tmp_i[idx];
                    w += 1;
                    if (w == lo + target) break;
                }
            }
            return pivot;
        } else {
            @memcpy(dists[lo .. lo + nl], tmp_d[lo .. lo + nl]);
            @memcpy(ids[lo .. lo + nl], tmp_i[lo .. lo + nl]);
            var w = lo + nl;
            var ngt: usize = 0;
            for (hi - nr..hi) |idx| {
                const d = tmp_d[idx];
                const id = tmp_i[idx];
                const eq = d == pivot;
                dists[w] = d;
                ids[w] = id;
                w += @intFromBool(eq);
                tmp_d[ngt] = d;
                tmp_i[ngt] = id;
                ngt += @intFromBool(!eq);
            }
            @memcpy(dists[w .. w + ngt], tmp_d[0..ngt]);
            @memcpy(ids[w .. w + ngt], tmp_i[0..ngt]);
            target -= (nl + neq);
            lo = w;
            hi = w + ngt;
        }
    }

    var idx = lo + 1;
    while (idx < hi) : (idx += 1) {
        const kd = dists[idx];
        const ki = ids[idx];
        var p = idx;
        while (p > lo and dists[p - 1] > kd) : (p -= 1) {
            dists[p] = dists[p - 1];
            ids[p] = ids[p - 1];
        }
        dists[p] = kd;
        ids[p] = ki;
    }
    return dists[k - 1];
}

/// Compact a full BQ passing-candidate buffer in-place to the exact top `stage1_k`
/// items using the live `cutoff` histogram, preserving exact `counts[0..cutoff+1]`.
fn compactBqBuf(
    buf: []IdHam,
    buf_len: *usize,
    counts: []u32,
    cutoff: u32,
    stage1_k: usize,
    total_le: *usize,
) void {
    const strictly_less = total_le.* - counts[cutoff];
    const max_eq = stage1_k - strictly_less;
    var kept_eq: usize = 0;
    var write: usize = 0;
    for (buf[0..buf_len.*]) |item| {
        if (item.ham < cutoff) {
            buf[write] = item;
            write += 1;
        } else if (item.ham == cutoff and kept_eq < max_eq) {
            buf[write] = item;
            write += 1;
            kept_eq += 1;
        }
    }
    buf_len.* = write;
    counts[cutoff] = @intCast(kept_eq);
    total_le.* = write;
}

inline fn applyDecayIndex(raw_sim: f32, timestamp: u64, decay: f32, now_ms: u64, decay_tau_hours: f32) f32 {
    if (decay <= 0.0) return raw_sim;
    const age_ms = if (now_ms > timestamp) now_ms - timestamp else 0;
    const age_hours: f32 = @as(f32, @floatFromInt(age_ms)) / 3_600_000.0;
    const recency = @exp(-age_hours / decay_tau_hours);
    return (1.0 - decay) * raw_sim + decay * recency;
}

inline fn rabitqD2ToSim(d2_est: f32, cosine_score: bool) f32 {
    const d2_clamped: f32 = if (d2_est < 0.0) 0.0 else d2_est;
    if (cosine_score) {
        const cos_est = 1.0 - d2_clamped * 0.5;
        const cos_clamped: f32 = if (cos_est > 1.0) 1.0 else if (cos_est < -1.0) -1.0 else cos_est;
        return (cos_clamped + 1.0) * 0.5;
    }
    return 1.0 / (1.0 + d2_clamped);
}

/// Stack-buffered writer for `writeToLocked` — coalesces small field writes
/// without altering a single byte of the `WDBHNSW2` wire format.
fn BufferedIndexWriter(comptime InnerPtr: type) type {
    return struct {
        inner: InnerPtr,
        buf: [4096]u8 = undefined,
        pos: usize = 0,

        pub fn writeAll(self: *@This(), data: []const u8) !void {
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

        pub fn flush(self: *@This()) !void {
            if (self.pos > 0) {
                try self.inner.writeAll(self.buf[0..self.pos]);
                self.pos = 0;
            }
        }
    };
}

/// A pending insert job for the async HNSW worker. Owns its key and vector
/// bytes (worker frees after insertLocked). Timestamp comes from the
/// originating VINSERT so async-built indexes keep the same time order as
/// sync-built ones.
const PendingInsert = struct {
    key: []u8,
    vector: []u8, // raw f32 bytes; insertLocked will reinterpret
    timestamp: u64,
};

/// Async HNSW queue + drainer state. Lives behind `NamespaceIndex.async_queue`;
/// allocated lazily on transition to async mode.
const AsyncQueue = struct {
    items: std.ArrayListUnmanaged(PendingInsert) = .empty,
    scratch: std.ArrayListUnmanaged(PendingInsert) = .empty, // worker-owned swap buffer
    mutex: if (narrow_atomics) struct {} else std.Io.Mutex = if (narrow_atomics) .{} else .init,
    cond: if (narrow_atomics) struct {} else std.Io.Condition = if (narrow_atomics) .{} else .init,
    shutdown: bool = false,
    pending: std.atomic.Value(usize) = .init(0), // for vstats (lock-free read)

    /// Inert on a narrow-atomics target: no worker thread exists there to contend, and
    /// std.Io.Mutex lowers to an atomic wait instruction wasm does not have.
    fn lock(self: *AsyncQueue) void {
        if (comptime narrow_atomics) return else self.mutex.lockUncancelable(io());
    }
    fn unlock(self: *AsyncQueue) void {
        if (comptime narrow_atomics) return else self.mutex.unlock(io());
    }
    fn wait(self: *AsyncQueue) void {
        if (comptime narrow_atomics) return else self.cond.waitUncancelable(io(), &self.mutex);
    }
    fn signal(self: *AsyncQueue) void {
        if (comptime narrow_atomics) return else self.cond.signal(io());
    }
};

pub const NamespaceIndex = struct {
    allocator: std.mem.Allocator,
    hnsw: Hnsw,
    /// keys[node_id] — arena-owned copy of the vec key (e.g. "vec:articles:id").
    keys: std.ArrayListUnmanaged([]u8),
    /// timestamps[node_id] — from the vec Entry when inserted.
    timestamps: std.ArrayListUnmanaged(u64),
    /// Wyhash of each node's raw incoming vector bytes (indexed by node_id).
    /// Preserves identical-write idempotence even when HNSW stores
    /// unit-normalized vectors for `.cosine`.
    vec_hashes: std.ArrayListUnmanaged(u64),
    /// Reverse lookup: vec key → node_id. Populated on every insertLocked,
    /// so DELETE-style ops can find the graph node to tombstone in O(1).
    /// The map's keys are borrowed from `self.keys` (no extra dupe).
    key_to_node: std.StringHashMapUnmanaged(u32),
    /// Tombstone bitset: bit i set ⇔ node i is logically deleted.
    /// Length tracks hnsw.len() — grown on every insertLocked. Search
    /// traversal skips tombstoned neighbors entirely.
    tombstones: std.bit_set.Dynamic,
    /// Running count of set bits in `tombstones`, kept in sync as a cache
    /// so `vstats` can report deletion density without re-scanning.
    tombstone_count: usize,
    /// Metric chosen at namespace creation. Drives the HNSW dist_fn and
    /// determines which query metrics can reuse this index.
    metric: Metric,
    /// Embedding dimension frozen on the first `insertLocked` call (null
    /// until then). All subsequent inserts must match. Mutated only under
    /// the write lock; readers use `expectedDim()` which acquires the
    /// shared lock. Snapshot-restored indexes derive this from the first
    /// resolvable vector in `readFromLocked`.
    dim: ?usize,
    /// Held exclusively for inserts; shared for searches.
    lock: RwLock,
    /// True ⇔ VINSERTs hand the HNSW build to the background worker. Set
    /// on the first VINSERT that carries the async flag; once true, never
    /// flips back. The store + BQ writes still happen synchronously — only
    /// the graph update is deferred. Queries remain consistent with the
    /// graph's current state; items in `async_queue.items` are invisible
    /// to `vsearch` until the worker drains them.
    async_mode: bool,
    /// Allocated on transition to async_mode=true; nil otherwise. Holds
    /// the pending job queue + the worker thread handle.
    async_queue: ?*AsyncQueue,
    async_worker: ?std.Thread,
    /// Frozen RaBitQ parameters (centroid + random orthogonal rotation).
    /// Null until `setRabitqParams` is called (via the `vrabitq`
    /// procedure). Once installed, `applyVinsert` encodes new bq entries
    /// with `rabitq.encode` and `vsearch` scores via `rabitq.estimateL2Sq`
    /// instead of the raw Hamming prefilter. Owned via `rabitq_handle`.
    rabitq_params: ?*RabitqParams,
    /// Reference-counted lifetime owner for `rabitq_params`. Readers that
    /// fall back to KV scan retain this handle and unlock `self.lock`
    /// before touching Store shards.
    rabitq_handle: ?*RabitqParamsHandle,
    /// Dense 64B-aligned legacy 1-bit BQ code slab (maintained when
    /// `rabitq_params == null`).
    bq_slab: BqSlab,
    /// Dense 64B-aligned RaBitQ SoA + FastScan32 slab (populated on `vrabitq`,
    /// incremental inserts, and snapshot restore when `rabitq_params != null`).
    rq_slab: RabitqSlab,
    /// Lock-free flag recording whether `__meta:vecns:<namespace>` has already
    /// been written to the Store, eliminating a per-insert Store lookup.
    config_persisted: std.atomic.Value(bool),
    /// True iff every valid vector under `namespace` in the attached Store is
    /// guaranteed to be represented in this index (allowing `mode=exact` to
    /// scan the contiguous HNSW vector slab directly). Cleared on any skipped
    /// or failed insert or when creating an index over a non-empty KV prefix.
    complete_with_store: bool,

    pub fn init(allocator: std.mem.Allocator, params: HnswParams, m: Metric) NamespaceIndex {
        // Override params.dist_fn with the chosen metric so the two can't
        // drift apart. Callers pass HnswParams for tuning (m, ef, etc);
        // metric determines the distance fn authoritatively.
        var p = params;
        p.dist_fn = m.distFn();
        return .{
            .allocator = allocator,
            .hnsw = Hnsw.init(allocator, p),
            .keys = .empty,
            .timestamps = .empty,
            .vec_hashes = .empty,
            .key_to_node = .empty,
            .tombstones = .{},
            .tombstone_count = 0,
            .metric = m,
            .dim = null,
            .lock = .{},
            .async_mode = false,
            .async_queue = null,
            .async_worker = null,
            .rabitq_params = null,
            .rabitq_handle = null,
            .bq_slab = .{},
            .rq_slab = .{},
            .config_persisted = .init(false),
            .complete_with_store = true,
        };
    }

    pub fn deinit(self: *NamespaceIndex) void {
        // Shut down the async worker BEFORE tearing down the graph it writes to.
        if (self.async_queue) |q| {
            q.lock();
            q.shutdown = true;
            q.signal();
            q.unlock();

            if (!single_threaded) if (self.async_worker) |t| t.join();

            // Anything still on the queue at shutdown couldn't be drained
            // (crash-like conditions, or worker failed). Free the owned bytes.
            for (q.items.items) |item| {
                self.allocator.free(item.key);
                self.allocator.free(item.vector);
            }
            q.items.deinit(self.allocator);
            q.scratch.deinit(self.allocator);
            self.allocator.destroy(q);
        }

        self.hnsw.deinit();
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.deinit(self.allocator);
        self.timestamps.deinit(self.allocator);
        self.vec_hashes.deinit(self.allocator);
        // key_to_node's keys are borrowed from self.keys — only free the map.
        self.key_to_node.deinit(self.allocator);
        self.tombstones.deinit(self.allocator);
        self.bq_slab.deinit(self.allocator);
        self.rq_slab.deinit(self.allocator);
        if (self.rabitq_handle) |h| {
            h.release();
            self.rabitq_handle = null;
            self.rabitq_params = null;
        }
    }

    /// Install a full set of RaBitQ parameters (centroid + rotation).
    /// Takes ownership of `new_params` on success — caller must not deinit
    /// or destroy after success. On allocation failure, `new_params` is
    /// untouched so caller's `errdefer` cleans it up cleanly.
    /// Caller holds the write-lock.
    pub fn setRabitqParams(self: *NamespaceIndex, new_params: *RabitqParams) !void {
        const handle = try RabitqParamsHandle.create(self.allocator, new_params);
        if (self.rabitq_handle) |old| {
            old.release();
        }
        self.rabitq_handle = handle;
        self.rabitq_params = new_params;
        // Legacy BQ slab is no longer used once RaBitQ params are installed.
        self.bq_slab.deinit(self.allocator);
        self.bq_slab.synced = false;
        // If empty, the RaBitQ slab starts synced for upcoming inserts; otherwise
        // `vrabitq` will populate it via `installRabitqSlabFromEncodedLocked`.
        self.rq_slab.reset(self.allocator, self.hnsw.len() == 0);
        if (self.hnsw.len() == 0 and new_params.dim > 0) {
            self.rq_slab.configure(self.allocator, @intCast(new_params.dim));
        }
    }

    /// Read-only access to the installed params under the caller's lock
    /// (shared is fine). Returns null if `vrabitq` has not run yet.
    pub fn getRabitqParams(self: *const NamespaceIndex) ?*const RabitqParams {
        return self.rabitq_params;
    }

    /// Retain a reference-counted handle to the installed RaBitQ params under
    /// the caller's lock (shared or exclusive). Caller MUST call `.release()`
    /// once finished (safe after releasing `self.lock`).
    pub fn acquireRabitqHandleLocked(self: *const NamespaceIndex) ?*RabitqParamsHandle {
        const h = self.rabitq_handle orelse return null;
        h.retain();
        return h;
    }

    /// Mark that this index may not cover every key under `namespace` in Store.
    /// Also invalidates in-index BQ/RaBitQ slabs so `mode=bq` / `mode=bq_rerank`
    /// fall back to KV scan until `vreindex` rebuilds a complete index.
    /// Caller holds the write-lock.
    pub fn markIncompleteLocked(self: *NamespaceIndex) void {
        self.complete_with_store = false;
        self.bq_slab.synced = false;
        self.rq_slab.synced = false;
    }

    /// Pre-allocate graph, side-table, and quantized-slab capacity for `additional`
    /// upcoming inserts. Caller holds the write-lock.
    pub fn reserveAdditionalLocked(self: *NamespaceIndex, additional: usize) !void {
        if (additional == 0) return;
        const needed = try std.math.add(usize, self.hnsw.len(), additional);
        try self.hnsw.reserve(additional);
        try self.keys.ensureTotalCapacity(self.allocator, needed);
        try self.timestamps.ensureTotalCapacity(self.allocator, needed);
        try self.vec_hashes.ensureTotalCapacity(self.allocator, needed);
        if (needed <= std.math.maxInt(u32)) {
            try self.key_to_node.ensureTotalCapacity(self.allocator, @intCast(needed));
        }
        if (self.dim) |d| {
            if (self.rabitq_params) |p| {
                if (self.rq_slab.synced and p.dim == d) {
                    if (self.rq_slab.dim == 0) self.rq_slab.configure(self.allocator, d);
                    try self.rq_slab.ensureCapacity(self.allocator, needed, true);
                }
            } else if (self.bq_slab.synced) {
                if (self.bq_slab.dim == 0) self.bq_slab.configure(self.allocator, d);
                try self.bq_slab.ensureCapacity(self.allocator, needed, true);
            }
        }
    }

    /// Idempotently enable async mode: allocate the queue + spawn worker
    /// if this is the first call. Caller need not hold any lock; this
    /// function serializes its own setup via the AsyncQueue's mutex.
    pub fn enableAsyncMode(self: *NamespaceIndex) !void {
        if (@atomicLoad(bool, &self.async_mode, .acquire)) return;

        // A single-threaded build (wasm32) has no worker to drain the queue, so the
        // caller falls back to synchronous inserts instead of a queue that never runs.
        // The `else` is load-bearing: std.Thread.spawn below is a COMPILE error in
        // single-threaded mode merely by being analysed, so a runtime `return` would not
        // keep it out of the build. Only the else-branch is analysed.
        if (comptime build_options.single_threaded) {
            return error.AsyncUnsupported;
        } else {
            const queue = try self.allocator.create(AsyncQueue);
            errdefer self.allocator.destroy(queue);
            queue.* = .{};

            const worker = try std.Thread.spawn(.{}, asyncWorkerLoop, .{self});
            // Spawn succeeded — publish queue + flag + handle in one burst, then
            // flip async_mode last so enqueue paths can read queue without races.
            self.async_queue = queue;
            self.async_worker = worker;
            @atomicStore(bool, &self.async_mode, true, .release);
        }
    }

    /// Enqueue a pending insert for the background worker. Caller passes
    /// ownership of key + vector byte slices — the worker frees them after
    /// insertLocked.
    pub fn enqueueAsync(self: *NamespaceIndex, key: []u8, vector: []u8, timestamp: u64) !void {
        const q = self.async_queue orelse return error.AsyncNotEnabled;
        q.lock();
        defer q.unlock();
        try q.items.append(self.allocator, .{ .key = key, .vector = vector, .timestamp = timestamp });
        _ = q.pending.fetchAdd(1, .monotonic);
        q.signal();
    }

    /// Batch-enqueue for bulk inserts: a single mutex acquisition for N
    /// items. Duplicates key and vector bytes (bulk frame buffer is arena
    /// memory that will be freed when the request completes).
    pub fn enqueueAsyncBatch(
        self: *NamespaceIndex,
        items: []const @import("../core/mod.zig").types.Command.VbulkinsertParams.BulkItem,
    ) !void {
        const q = self.async_queue orelse return error.AsyncNotEnabled;

        // Pre-dupe so we don't hold the queue mutex while allocating.
        var owned: std.ArrayListUnmanaged(PendingInsert) = .empty;
        defer owned.deinit(self.allocator);
        try owned.ensureTotalCapacity(self.allocator, items.len);
        for (items) |item| {
            const key_copy = try self.allocator.dupe(u8, item.key);
            errdefer self.allocator.free(key_copy);
            const vec_copy = try self.allocator.dupe(u8, item.vector);
            errdefer self.allocator.free(vec_copy);
            owned.appendAssumeCapacity(.{ .key = key_copy, .vector = vec_copy, .timestamp = item.timestamp });
        }

        q.lock();
        defer q.unlock();
        try q.items.appendSlice(self.allocator, owned.items);
        _ = q.pending.fetchAdd(items.len, .monotonic);
        q.signal();
        owned.clearRetainingCapacity();
    }

    /// Non-blocking snapshot of pending-insert count. `vstats` surfaces this.
    pub fn pendingAsyncCount(self: *const NamespaceIndex) usize {
        const q = self.async_queue orelse return 0;
        return q.pending.load(.monotonic);
    }

    fn asyncWorkerLoop(self: *NamespaceIndex) void {
        const q = self.async_queue orelse return;

        while (true) {
            // Wait for work or shutdown.
            q.lock();
            while (q.items.items.len == 0 and !q.shutdown) {
                q.wait();
            }
            const is_shutdown = q.shutdown;
            // Swap: the worker takes everything queued so producers can
            // keep enqueuing into a fresh list while we drain.
            const tmp = q.items;
            q.items = q.scratch;
            q.scratch = tmp;
            q.unlock();

            if (q.scratch.items.len > 0) {
                const drained = q.scratch.items.len;

                // One write-lock acquisition for the entire drain batch.
                self.lock.lock();
                self.reserveAdditionalLocked(drained) catch {};
                var batch_stack: [512]BatchInsertItem = undefined;
                var batch_heap: ?[]BatchInsertItem = null;
                defer if (batch_heap) |bh| self.allocator.free(bh);
                const batch_buf: ?[]BatchInsertItem = if (drained >= 32) blk: {
                    if (drained <= batch_stack.len) break :blk batch_stack[0..drained];
                    const b = self.allocator.alloc(BatchInsertItem, drained) catch break :blk null;
                    batch_heap = b;
                    break :blk b;
                } else null;

                if (batch_buf) |buf| {
                    var valid: usize = 0;
                    for (q.scratch.items) |item| {
                        const vec_f32 = distance.bytesToF32(item.vector) orelse {
                            std.log.warn("async hnsw: invalid vector bytes for key '{s}'", .{item.key});
                            continue;
                        };
                        buf[valid] = .{ .key = item.key, .vector = vec_f32, .timestamp = item.timestamp };
                        valid += 1;
                    }
                    _ = self.insertBatchLocked(buf[0..valid]) catch |e| {
                        self.complete_with_store = false;
                        std.log.warn("async hnsw: batch insert failed: {s}", .{@errorName(e)});
                    };
                } else {
                    for (q.scratch.items) |item| {
                        const vec_f32 = distance.bytesToF32(item.vector) orelse {
                            std.log.warn("async hnsw: invalid vector bytes for key '{s}'", .{item.key});
                            continue;
                        };
                        _ = self.insertLocked(item.key, vec_f32, item.timestamp) catch |e| {
                            self.complete_with_store = false;
                            std.log.warn("async hnsw: insert '{s}' failed: {s}", .{ item.key, @errorName(e) });
                        };
                    }
                }
                self.lock.unlock();

                // Free the owned copies now that the graph has the data.
                for (q.scratch.items) |item| {
                    self.allocator.free(item.key);
                    self.allocator.free(item.vector);
                }
                q.scratch.clearRetainingCapacity();
                _ = q.pending.fetchSub(drained, .monotonic);
            }

            if (is_shutdown) break;
        }
    }

    pub fn len(self: *const NamespaceIndex) usize {
        return self.hnsw.len();
    }

    /// Active (non-tombstoned) node count. Use for user-facing stats.
    pub fn liveCount(self: *const NamespaceIndex) usize {
        return self.hnsw.len() - self.tombstone_count;
    }

    /// Insert a vector under the caller's write-lock. Returns the new node ID.
    /// The `key` is duped into the index's allocator; caller retains ownership
    /// of the passed-in slice.
    ///
    /// Freezes `self.dim` on the first call; subsequent inserts with a
    /// different `vector.len` return `error.DimensionMismatch` (the graph
    /// is single-dim, so accepting mismatches would silently drop them at
    /// query time — worse under WORM, where the store entry is permanent).
    pub fn insertLocked(
        self: *NamespaceIndex,
        key: []const u8,
        vector: []align(1) const f32,
        timestamp: u64,
    ) !u32 {
        return self.insertLockedWithBq(key, vector, timestamp, null);
    }

    /// Like `insertLocked`, optionally accepting the already-encoded BQ or
    /// RaBitQ payload so bulk/single insert paths never quantize twice.
    /// Maintains the contiguous BQ or RaBitQ FastScan32 slab in lockstep.
    pub fn insertLockedWithBq(
        self: *NamespaceIndex,
        key: []const u8,
        vector: []align(1) const f32,
        timestamp: u64,
        pre_encoded_bq: ?[]const u8,
    ) !u32 {
        if (self.dim) |d| {
            if (vector.len != d) return RegistryError.DimensionMismatch;
        }

        const incoming_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(vector));
        var old_live_id: ?u32 = null;
        if (self.key_to_node.get(key)) |old_id| {
            if (!self.tombstones.isSet(old_id)) {
                if (timestamp < self.timestamps.items[old_id]) {
                    return old_id;
                }
                const same_vec = if (self.hnsw.storesUnitVectors())
                    self.vec_hashes.items[old_id] == incoming_hash and self.hnsw.dim == vector.len
                else blk: {
                    const old_vec = self.hnsw.getVector(old_id);
                    break :blk old_vec.len == vector.len and
                        std.mem.eql(u8, std.mem.sliceAsBytes(old_vec), std.mem.sliceAsBytes(vector));
                };
                if (same_vec) {
                    self.timestamps.items[old_id] = timestamp;
                    return old_id;
                }
                old_live_id = old_id;
            }
        }

        // Reserve all side-table capacity BEFORE mutating HNSW or tombstones so
        // an OOM leaves the index completely consistent.
        const next_len = self.hnsw.len() + 1;
        const key_copy = try self.allocator.dupe(u8, key);
        var key_owned_by_index = false;
        errdefer if (!key_owned_by_index) self.allocator.free(key_copy);

        try self.keys.ensureUnusedCapacity(self.allocator, 1);
        try self.timestamps.ensureUnusedCapacity(self.allocator, 1);
        try self.vec_hashes.ensureUnusedCapacity(self.allocator, 1);
        try self.key_to_node.ensureUnusedCapacity(self.allocator, 1);
        try self.tombstones.resize(self.allocator, next_len, false);

        // Pre-prepare slab slot capacity so slab append cannot fail after HNSW insert.
        const want_rq = blk: {
            if (self.rabitq_params) |p| {
                if (self.rq_slab.synced and p.dim == vector.len and self.rq_slab.len == self.hnsw.len()) {
                    if (self.rq_slab.dim == 0) self.rq_slab.configure(self.allocator, vector.len);
                    try self.rq_slab.ensureCapacity(self.allocator, next_len, false);
                    break :blk true;
                }
            }
            break :blk false;
        };
        const want_bq = blk: {
            if (self.rabitq_params == null and self.bq_slab.synced and self.bq_slab.len == self.hnsw.len()) {
                if (self.bq_slab.dim == 0) self.bq_slab.configure(self.allocator, vector.len);
                try self.bq_slab.ensureCapacity(self.allocator, next_len, false);
                break :blk true;
            }
            break :blk false;
        };

        // Pre-encode RaBitQ into a stack/temp buffer if needed before mutating HNSW,
        // so any fallback heap alloc for dim > STACK_DIM_CAP fails cleanly before commit.
        var rq_code_stack: [256]u8 = undefined;
        var rq_code_heap: ?[]u8 = null;
        defer if (rq_code_heap) |b| self.allocator.free(b);
        var rq_parsed: ?rabitq_mod.Encoded = null;

        if (want_rq) {
            if (pre_encoded_bq) |pb| {
                if (rabitq_mod.parse(pb, vector.len)) |enc| {
                    rq_parsed = enc;
                }
            }
            if (rq_parsed == null) {
                const p = self.rabitq_params.?;
                const cb = rabitq_mod.codeBytes(vector.len);
                const code_dst: []u8 = if (cb <= rq_code_stack.len)
                    rq_code_stack[0..cb]
                else blk: {
                    const b = try self.allocator.alloc(u8, cb);
                    rq_code_heap = b;
                    break :blk b;
                };
                rq_parsed = try self.encodeRabitqCoreLocked(self.allocator, p, vector, code_dst);
            }
        }

        const node_id = self.hnsw.insert(vector) catch |err| {
            // `Hnsw.insert` is not atomic: a failure while linking leaves the node
            // appended. Give it side-table entries so node ids stay aligned with keys.
            if (self.hnsw.len() == next_len) {
                if (self.dim == null) self.dim = vector.len;
                self.absorbFailedNodeLocked(@intCast(next_len - 1), key_copy, timestamp, incoming_hash, old_live_id);
                key_owned_by_index = true;
                self.markIncompleteLocked();
            }
            return err;
        };
        // hnsw.insert succeeded — commit infallibly.
        if (old_live_id) |old_id| {
            self.tombstones.set(old_id);
            self.tombstone_count += 1;
        }
        if (self.dim == null) self.dim = vector.len;

        self.keys.appendAssumeCapacity(key_copy);
        self.timestamps.appendAssumeCapacity(timestamp);
        self.vec_hashes.appendAssumeCapacity(incoming_hash);
        self.key_to_node.putAssumeCapacity(key_copy, node_id);

        if (want_rq) {
            const enc = rq_parsed.?;
            self.rq_slab.setSlot(node_id, enc.code, enc.l2_norm, enc.corr);
            self.rq_slab.len = next_len;
            if (next_len % 32 == 0) {
                const blk_idx = (next_len / 32) - 1;
                self.rq_slab.packBlock(blk_idx);
                self.rq_slab.packed_blocks = blk_idx + 1;
            }
        } else if (self.rabitq_params != null) {
            self.rq_slab.synced = false;
        }

        if (want_bq) {
            const cb = self.bq_slab.code_bytes;
            if (pre_encoded_bq) |pb| {
                if (pb.len == cb) {
                    self.bq_slab.setSlot(node_id, pb);
                } else {
                    const dst = self.bq_slab.codes[node_id * self.bq_slab.code_stride ..][0..self.bq_slab.code_stride];
                    distance.binaryQuantize(vector, dst[0..cb]);
                    if (self.bq_slab.code_stride > cb) @memset(dst[cb..self.bq_slab.code_stride], 0);
                }
            } else {
                const dst = self.bq_slab.codes[node_id * self.bq_slab.code_stride ..][0..self.bq_slab.code_stride];
                distance.binaryQuantize(vector, dst[0..cb]);
                if (self.bq_slab.code_stride > cb) @memset(dst[cb..self.bq_slab.code_stride], 0);
            }
            self.bq_slab.len = next_len;
        } else if (self.rabitq_params == null) {
            self.bq_slab.synced = false;
        }

        return node_id;
    }

    /// Give an HNSW node that a failed insert left behind its side-table entries, in
    /// the same state as a key that was inserted and then deleted: the node keeps its
    /// key, timestamp and hash, any live node it would have superseded is tombstoned,
    /// and the node itself is tombstoned so searches traverse it but never return it.
    /// This keeps `hnsw.len() == keys.items.len` and survives a snapshot round-trip
    /// (the reverse map resolves the key to the tombstoned node, as after a delete).
    ///
    /// Caller holds the write-lock, has reserved one slot in `keys`, `timestamps`,
    /// `vec_hashes` and `key_to_node`, has sized `tombstones` past `node_id`, and
    /// passes `node_id == keys.items.len`. Takes ownership of `key_copy`. The caller
    /// should also `markIncompleteLocked()`: the store holds a vector the index lacks.
    fn absorbFailedNodeLocked(
        self: *NamespaceIndex,
        node_id: u32,
        key_copy: []u8,
        timestamp: u64,
        vec_hash: u64,
        old_live_id: ?u32,
    ) void {
        std.debug.assert(node_id == self.keys.items.len);
        if (old_live_id) |old_id| {
            self.tombstones.set(old_id);
            self.tombstone_count += 1;
        }
        self.keys.appendAssumeCapacity(key_copy);
        self.timestamps.appendAssumeCapacity(timestamp);
        self.vec_hashes.appendAssumeCapacity(vec_hash);
        self.key_to_node.putAssumeCapacity(key_copy, node_id);
        self.tombstones.set(node_id);
        self.tombstone_count += 1;
    }

    pub const BatchInsertItem = struct {
        key: []const u8,
        vector: []align(1) const f32,
        timestamp: u64,
        pre_encoded_bq: ?[]const u8 = null,
    };

    /// Insert a batch of vectors under the caller's write-lock using multi-threaded
    /// `Hnsw.insertBatchParallel` when `items.len >= 32` and all items share a single
    /// dimension with distinct keys. Falls back to sequential `insertLockedWithBq` for
    /// small batches, mixed dimensions, intra-batch duplicate keys, or single-threaded
    /// (`wasm32-wasi`) builds, preserving identical per-item semantics.
    pub fn insertBatchLocked(self: *NamespaceIndex, items: []const BatchInsertItem) !usize {
        if (items.len == 0) return 0;

        if (comptime build_options.single_threaded) {
            return self.insertBatchSequentialLocked(items);
        } else {
            if (items.len < 32) {
                return self.insertBatchSequentialLocked(items);
            }

            const target_dim = self.dim orelse items[0].vector.len;
            if (target_dim == 0) {
                return self.insertBatchSequentialLocked(items);
            }

            // Validate uniform dimension and absence of intra-batch duplicate keys.
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(self.allocator);
            try seen.ensureTotalCapacity(self.allocator, @intCast(items.len));
            for (items) |item| {
                if (item.vector.len != target_dim) {
                    return self.insertBatchSequentialLocked(items);
                }
                const gop = seen.getOrPutAssumeCapacity(item.key);
                if (gop.found_existing) {
                    return self.insertBatchSequentialLocked(items);
                }
            }

            const StagedEntry = struct {
                item_idx: usize,
                key_copy: []u8,
                incoming_hash: u64,
                old_live_id: ?u32,
                rq_l2_norm: f32 = 0,
                rq_corr: f32 = 0,
            };

            var staged: std.ArrayListUnmanaged(StagedEntry) = .empty;
            defer {
                for (staged.items) |st| self.allocator.free(st.key_copy);
                staged.deinit(self.allocator);
            }
            try staged.ensureTotalCapacity(self.allocator, items.len);

            var batch_vecs: std.ArrayListUnmanaged([]align(1) const f32) = .empty;
            defer batch_vecs.deinit(self.allocator);
            try batch_vecs.ensureTotalCapacity(self.allocator, items.len);

            // Pass 1: filter identical/stale overwrites and stage key copies + vectors.
            for (items, 0..) |item, idx| {
                const incoming_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(item.vector));
                var old_live_id: ?u32 = null;
                if (self.key_to_node.get(item.key)) |old_id| {
                    if (!self.tombstones.isSet(old_id)) {
                        if (item.timestamp < self.timestamps.items[old_id]) {
                            continue;
                        }
                        const same_vec = if (self.hnsw.storesUnitVectors())
                            self.vec_hashes.items[old_id] == incoming_hash and self.hnsw.dim == item.vector.len
                        else blk: {
                            const old_vec = self.hnsw.getVector(old_id);
                            break :blk old_vec.len == item.vector.len and
                                std.mem.eql(u8, std.mem.sliceAsBytes(old_vec), std.mem.sliceAsBytes(item.vector));
                        };
                        if (same_vec) {
                            self.timestamps.items[old_id] = item.timestamp;
                            continue;
                        }
                        old_live_id = old_id;
                    }
                }

                const key_copy = try self.allocator.dupe(u8, item.key);
                staged.appendAssumeCapacity(.{
                    .item_idx = idx,
                    .key_copy = key_copy,
                    .incoming_hash = incoming_hash,
                    .old_live_id = old_live_id,
                });
                batch_vecs.appendAssumeCapacity(item.vector);
            }

            const n_new = staged.items.len;
            if (n_new == 0) return 0;

            const base_len = self.hnsw.len();
            const final_len = try std.math.add(usize, base_len, n_new);

            // Reserve all side-tables + slabs upfront BEFORE mutating HNSW.
            try self.keys.ensureTotalCapacity(self.allocator, final_len);
            try self.timestamps.ensureTotalCapacity(self.allocator, final_len);
            try self.vec_hashes.ensureTotalCapacity(self.allocator, final_len);
            try self.key_to_node.ensureTotalCapacity(self.allocator, @intCast(final_len));
            try self.tombstones.resize(self.allocator, final_len, false);

            const want_rq = blk: {
                if (self.rabitq_params) |p| {
                    if (self.rq_slab.synced and p.dim == target_dim and self.rq_slab.len == base_len) {
                        if (self.rq_slab.dim == 0) self.rq_slab.configure(self.allocator, target_dim);
                        try self.rq_slab.ensureCapacity(self.allocator, final_len, false);
                        break :blk true;
                    }
                }
                break :blk false;
            };
            const want_bq = blk: {
                if (self.rabitq_params == null and self.bq_slab.synced and self.bq_slab.len == base_len) {
                    if (self.bq_slab.dim == 0) self.bq_slab.configure(self.allocator, target_dim);
                    try self.bq_slab.ensureCapacity(self.allocator, final_len, false);
                    break :blk true;
                }
                break :blk false;
            };

            // Pre-encode RaBitQ codes into a contiguous staging buffer before mutating HNSW.
            const rq_cb = if (want_rq) rabitq_mod.codeBytes(target_dim) else 0;
            var rq_codes_buf: []u8 = &.{};
            defer if (rq_codes_buf.len > 0) self.allocator.free(rq_codes_buf);
            if (want_rq) {
                rq_codes_buf = try self.allocator.alloc(u8, n_new * rq_cb);
                const p = self.rabitq_params.?;
                for (staged.items, 0..) |*st, i| {
                    const item = items[st.item_idx];
                    const dst = rq_codes_buf[i * rq_cb ..][0..rq_cb];
                    var parsed: ?rabitq_mod.Encoded = null;
                    if (item.pre_encoded_bq) |pb| {
                        if (rabitq_mod.parse(pb, target_dim)) |enc| {
                            @memcpy(dst, enc.code);
                            parsed = enc;
                        }
                    }
                    if (parsed == null) {
                        parsed = try self.encodeRabitqCoreLocked(self.allocator, p, item.vector, dst);
                    }
                    st.rq_l2_norm = parsed.?.l2_norm;
                    st.rq_corr = parsed.?.corr;
                }
            }

            // Pass 2: Parallel multi-threaded HNSW graph construction!
            const base_id = self.hnsw.insertBatchParallel(batch_vecs.items) catch |err| {
                // Not atomic: seed nodes, or the whole batch when a worker fails
                // mid-link, may already be appended as ids `base_len + i` for
                // `staged[i]`. Give each one side-table entries so node ids stay
                // aligned with keys; the rest of the batch was never appended.
                const appended = self.hnsw.len() - base_len;
                if (appended > 0) {
                    if (self.dim == null) self.dim = target_dim;
                    for (staged.items[0..appended], 0..) |st, i| {
                        self.absorbFailedNodeLocked(
                            @intCast(base_len + i),
                            st.key_copy,
                            items[st.item_idx].timestamp,
                            st.incoming_hash,
                            st.old_live_id,
                        );
                    }
                    // Those key copies now belong to `self.keys`.
                    staged.replaceRangeAssumeCapacity(0, appended, &.{});
                    self.markIncompleteLocked();
                }
                return err;
            };

            // Pass 3: Infallible commit of side-tables and quantized slabs.
            if (self.dim == null) self.dim = target_dim;

            for (staged.items, 0..) |st, i| {
                const node_id: u32 = base_id + @as(u32, @intCast(i));
                const item = items[st.item_idx];
                if (st.old_live_id) |old_id| {
                    self.tombstones.set(old_id);
                    self.tombstone_count += 1;
                }
                self.keys.appendAssumeCapacity(st.key_copy);
                self.timestamps.appendAssumeCapacity(item.timestamp);
                self.vec_hashes.appendAssumeCapacity(st.incoming_hash);
                self.key_to_node.putAssumeCapacity(st.key_copy, node_id);

                if (want_rq) {
                    const code = rq_codes_buf[i * rq_cb ..][0..rq_cb];
                    self.rq_slab.setSlot(node_id, code, st.rq_l2_norm, st.rq_corr);
                } else if (want_bq) {
                    const cb = self.bq_slab.code_bytes;
                    if (item.pre_encoded_bq) |pb| {
                        if (pb.len == cb) {
                            self.bq_slab.setSlot(node_id, pb);
                        } else {
                            const dst = self.bq_slab.codes[node_id * self.bq_slab.code_stride ..][0..self.bq_slab.code_stride];
                            distance.binaryQuantize(item.vector, dst[0..cb]);
                            if (self.bq_slab.code_stride > cb) @memset(dst[cb..self.bq_slab.code_stride], 0);
                        }
                    } else {
                        const dst = self.bq_slab.codes[node_id * self.bq_slab.code_stride ..][0..self.bq_slab.code_stride];
                        distance.binaryQuantize(item.vector, dst[0..cb]);
                        if (self.bq_slab.code_stride > cb) @memset(dst[cb..self.bq_slab.code_stride], 0);
                    }
                }
            }

            // Ownership of all `key_copy` slices transferred into `self.keys`.
            staged.clearRetainingCapacity();

            if (want_rq) {
                const old_blocks = self.rq_slab.packed_blocks;
                self.rq_slab.len = final_len;
                const new_blocks = final_len / 32;
                var b = old_blocks;
                while (b < new_blocks) : (b += 1) {
                    self.rq_slab.packBlock(b);
                }
                self.rq_slab.packed_blocks = new_blocks;
            } else if (self.rabitq_params != null) {
                self.rq_slab.synced = false;
            }

            if (want_bq) {
                self.bq_slab.len = final_len;
            } else if (self.rabitq_params == null) {
                self.bq_slab.synced = false;
            }

            return n_new;
        }
    }

    fn insertBatchSequentialLocked(self: *NamespaceIndex, items: []const BatchInsertItem) !usize {
        var inserted: usize = 0;
        for (items) |item| {
            _ = self.insertLockedWithBq(item.key, item.vector, item.timestamp, item.pre_encoded_bq) catch |e| {
                self.markIncompleteLocked();
                std.log.warn("insertBatchLocked: HNSW insert '{s}': {s}", .{ item.key, @errorName(e) });
                continue;
            };
            inserted += 1;
        }
        return inserted;
    }

    fn encodeRabitqCoreLocked(
        self: *const NamespaceIndex,
        allocator: std.mem.Allocator,
        p: *const RabitqParams,
        vec_f32: []align(1) const f32,
        code_slice: []u8,
    ) !rabitq_mod.Encoded {
        const dim = vec_f32.len;
        var res_stack: [STACK_DIM_CAP]f32 = undefined;
        var rot_stack: [STACK_DIM_CAP]f32 = undefined;
        var norm_stack: [STACK_DIM_CAP]f32 = undefined;

        var res_heap: ?[]f32 = null;
        defer if (res_heap) |b| allocator.free(b);
        var rot_heap: ?[]f32 = null;
        defer if (rot_heap) |b| allocator.free(b);
        var norm_heap: ?[]f32 = null;
        defer if (norm_heap) |b| allocator.free(b);

        const residual: []f32 = if (dim <= STACK_DIM_CAP)
            res_stack[0..dim]
        else blk: {
            const b = try allocator.alloc(f32, dim);
            res_heap = b;
            break :blk b;
        };
        const rotated: []f32 = if (dim <= STACK_DIM_CAP)
            rot_stack[0..dim]
        else blk: {
            const b = try allocator.alloc(f32, dim);
            rot_heap = b;
            break :blk b;
        };

        const encode_input: []align(1) const f32 = if (self.metric == .cosine) blk: {
            const norm_buf: []f32 = if (dim <= STACK_DIM_CAP)
                norm_stack[0..dim]
            else blk2: {
                const b = allocator.alloc(f32, dim) catch break :blk vec_f32;
                norm_heap = b;
                break :blk2 b;
            };
            if (!rabitq_mod.normalizeInto(vec_f32, norm_buf)) {
                break :blk vec_f32;
            }
            break :blk @ptrCast(norm_buf);
        } else vec_f32;

        return rabitq_mod.encode(encode_input, p, residual, rotated, code_slice);
    }

    /// Encode `vec_f32` into its BQ companion format into caller-supplied
    /// `stack_buf` when large enough, otherwise allocates with `allocator`.
    /// Sets `heap_out.*` when a heap allocation occurred (caller must free).
    /// Caller must hold `self.lock` (shared or exclusive).
    pub fn encodeBqIntoLocked(
        self: *const NamespaceIndex,
        allocator: std.mem.Allocator,
        vec_f32: []align(1) const f32,
        stack_buf: []u8,
        heap_out: *?[]u8,
    ) ![]u8 {
        heap_out.* = null;
        if (self.rabitq_params) |p| {
            if (p.dim == vec_f32.len) {
                const needed = rabitq_mod.encodedSize(vec_f32.len);
                const out: []u8 = if (needed <= stack_buf.len)
                    stack_buf[0..needed]
                else blk: {
                    const b = try allocator.alloc(u8, needed);
                    heap_out.* = b;
                    break :blk b;
                };
                errdefer if (heap_out.*) |b| {
                    allocator.free(b);
                    heap_out.* = null;
                };
                const code_slice = out[0..rabitq_mod.codeBytes(vec_f32.len)];
                const enc = try self.encodeRabitqCoreLocked(allocator, p, vec_f32, code_slice);
                rabitq_mod.serialize(enc, out);
                return out;
            }
        }
        const needed = distance.binaryQuantizedSize(vec_f32.len);
        const out: []u8 = if (needed <= stack_buf.len)
            stack_buf[0..needed]
        else blk: {
            const b = try allocator.alloc(u8, needed);
            heap_out.* = b;
            break :blk b;
        };
        distance.binaryQuantize(vec_f32, out);
        return out;
    }

    /// Encode `vec_f32` into its BQ companion format (RaBitQ 24B/128-dim when
    /// `self.rabitq_params` is installed and matches `vec_f32.len`, otherwise
    /// 1-bit sign quantization). Caller must hold `self.lock` (shared or exclusive).
    pub fn encodeBqLocked(
        self: *const NamespaceIndex,
        allocator: std.mem.Allocator,
        vec_f32: []align(1) const f32,
    ) ![]u8 {
        if (self.rabitq_params) |p| {
            if (p.dim == vec_f32.len) {
                const out = try allocator.alloc(u8, rabitq_mod.encodedSize(vec_f32.len));
                errdefer allocator.free(out);
                const code_slice = out[0..rabitq_mod.codeBytes(vec_f32.len)];
                const enc = try self.encodeRabitqCoreLocked(allocator, p, vec_f32, code_slice);
                rabitq_mod.serialize(enc, out);
                return out;
            }
        }
        const out = try allocator.alloc(u8, distance.binaryQuantizedSize(vec_f32.len));
        errdefer allocator.free(out);
        distance.binaryQuantize(vec_f32, out);
        return out;
    }

    /// Mark the node corresponding to `key` as tombstoned. Returns:
    ///   .deleted  — key existed and was not already tombstoned
    ///   .noop     — key existed but was already tombstoned
    ///   .missing  — key is not in the index
    /// Caller must hold the write-lock.
    pub fn markTombstoneLocked(self: *NamespaceIndex, key: []const u8) TombstoneResult {
        const node_id = self.key_to_node.get(key) orelse return .missing;
        if (self.tombstones.isSet(node_id)) return .noop;
        self.tombstones.set(node_id);
        self.tombstone_count += 1;
        return .deleted;
    }

    /// Look up the internal node id for a key under any lock mode.
    pub fn nodeIdFor(self: *const NamespaceIndex, key: []const u8) ?u32 {
        return self.key_to_node.get(key);
    }

    /// The frozen embedding dimension for this namespace, or null if no
    /// insert has happened yet. Takes the shared lock; safe to call
    /// concurrently with readers. Callers use this to pre-check inserts
    /// before touching the store, failing fast on dim mismatches.
    pub fn expectedDim(self: *NamespaceIndex) ?usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.dim;
    }

    /// Is this node id marked deleted? Callers typically pass the bitset
    /// directly to `hnsw.search` via the filter parameter; this accessor is
    /// for explicit single-id checks (debugging, tests).
    pub fn isTombstoned(self: *const NamespaceIndex, node_id: u32) bool {
        if (node_id >= self.tombstones.bit_length) return false;
        return self.tombstones.isSet(node_id);
    }

    /// kNN search under the caller's read-lock. Fills `out` with up to `k`
    /// results sorted by ascending distance. Returned `key` slices are
    /// borrowed from the index's keys[] and valid only while the caller
    /// holds the read-lock.
    ///
    /// Tombstoned nodes are excluded from results via the filter passed to
    /// `hnsw.search`. The graph traversal visits them (as path-through-only
    /// nodes) so graph shape is preserved, but they are never returned.
    pub fn searchLocked(
        self: *NamespaceIndex,
        query: []align(1) const f32,
        k: usize,
        ef: usize,
        out: []IndexSearchResult,
        hnsw_scratch: []hnsw_mod.SearchResult,
    ) !usize {
        return self.searchLockedWithExclude(query, k, ef, null, out, hnsw_scratch);
    }

    /// Like `searchLocked`, additionally excluding `exclude_id` (e.g. `query_key`'s
    /// own node ID) inside HNSW L0 traversal without oversampling `top_k`.
    pub fn searchLockedWithExclude(
        self: *NamespaceIndex,
        query: []align(1) const f32,
        k: usize,
        ef: usize,
        exclude_id: ?u32,
        out: []IndexSearchResult,
        hnsw_scratch: []hnsw_mod.SearchResult,
    ) !usize {
        if (hnsw_scratch.len < k) return error.ScratchTooSmall;
        const filter: ?*const std.bit_set.Dynamic =
            if (self.tombstone_count > 0) &self.tombstones else null;
        const n = try self.hnsw.searchWithSkipAndExclude(query, k, ef, hnsw_scratch[0..k], filter, exclude_id);
        for (0..n) |i| {
            const r = hnsw_scratch[i];
            out[i] = .{
                .key = self.keys.items[r.id],
                .dist = r.dist,
                .timestamp = self.timestamps.items[r.id],
            };
        }
        return n;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  In-Index Contiguous Slab Scans (BQ/RaBitQ/Exact)  ║
    // ╚═══════════════════════════════════════════════════╝

    /// True when the dense legacy BQ slab can serve `query_dim` under `lockShared`.
    pub fn canUseBqSlabLocked(self: *const NamespaceIndex, query_dim: usize) bool {
        return self.rabitq_params == null and
            self.pendingAsyncCount() == 0 and
            self.bq_slab.synced and
            self.bq_slab.len == self.hnsw.len() and
            self.bq_slab.len > 0 and
            self.liveCount() > 0 and
            self.dim != null and
            self.dim.? == query_dim;
    }

    /// True when the dense RaBitQ FastScan32/SoA slab can serve `query_dim` under `lockShared`.
    pub fn canUseRabitqSlabLocked(self: *const NamespaceIndex, query_dim: usize) bool {
        const p = self.rabitq_params orelse return false;
        return self.pendingAsyncCount() == 0 and
            self.rq_slab.synced and
            self.rq_slab.len == self.hnsw.len() and
            self.rq_slab.len > 0 and
            self.liveCount() > 0 and
            p.dim == query_dim and
            self.dim != null and
            self.dim.? == query_dim;
    }

    /// True when the HNSW contiguous f32 vector slab can serve exact brute-force
    /// scans for `(query_dim, query_metric)` with 100% mathematical fidelity.
    pub fn canUseExactSlabLocked(self: *const NamespaceIndex, query_dim: usize, query_metric: Metric) bool {
        if (!self.complete_with_store) return false;
        if (self.pendingAsyncCount() != 0) return false;
        if (self.liveCount() == 0 or self.hnsw.vecStride() == 0) return false;
        if (self.dim == null or self.dim.? != query_dim) return false;
        if (self.hnsw.storesUnitVectors() and query_metric != .cosine) return false;
        return true;
    }

    /// True when `self.hnsw`'s stored vectors match the exact vector space of `query_metric`
    /// (false only when `.cosine` unit-normalized storage is queried with `.l2`/`.dot`).
    pub inline fn canRerankFromHnswLocked(self: *const NamespaceIndex, query_metric: Metric) bool {
        return query_metric == self.metric or !self.hnsw.storesUnitVectors();
    }

    /// Prepare a 64B-aligned, zero-padded query buffer matching `self.hnsw.vecStride()`.
    fn prepareAlignedQuery(
        self: *const NamespaceIndex,
        query: []align(1) const f32,
        query_metric: Metric,
        dst: []align(64) f32,
    ) f32 {
        const dim = query.len;
        const stride = self.hnsw.vecStride();
        if (query_metric == .cosine and self.hnsw.storesUnitVectors()) {
            const norm = distance.normalizeInto(query, dst[0..dim]);
            if (stride > dim) @memset(dst[dim..stride], 0.0);
            return norm;
        }
        @memcpy(dst[0..dim], query);
        if (stride > dim) @memset(dst[dim..stride], 0.0);
        if (query_metric == .cosine) {
            const qn = distance.l2Norm(query);
            if (qn > 0.0) {
                const inv = 1.0 / qn;
                return if (std.math.isFinite(inv)) inv else 0.0;
            }
            return 0.0;
        }
        return 1.0;
    }

    /// Rescore a slice of candidate node IDs directly against `self.hnsw`'s flat
    /// 64B-aligned vector slab using 4-way batched SIMD. Zero shard locks, zero `getCopy`.
    fn rescoreIdsLocked(
        self: *const NamespaceIndex,
        query: []align(1) const f32,
        cand_ids: []const u32,
        top_k: usize,
        query_metric: Metric,
        decay: f32,
        now_ms: u64,
        decay_tau_hours: f32,
        out: []IndexScoredResult,
        scratch_alloc: std.mem.Allocator,
    ) !usize {
        const n_cands = cand_ids.len;
        const k = @min(top_k, out.len);
        if (n_cands == 0 or k == 0) return 0;

        const stride = self.hnsw.vecStride();
        var q_stack: [STACK_SLAB_QUERY_CAP]f32 align(64) = undefined;
        var q_heap: ?[]align(64) f32 = null;
        defer if (q_heap) |b| scratch_alloc.free(b);
        const q_buf: []align(64) f32 = if (stride <= STACK_SLAB_QUERY_CAP)
            q_stack[0..stride]
        else blk: {
            const b = try scratch_alloc.alignedAlloc(f32, .@"64", stride);
            q_heap = b;
            break :blk b;
        };
        const q_aux = self.prepareAlignedQuery(query, query_metric, q_buf);
        const q_ptr: [*]align(32) const f32 = q_buf.ptr;
        const unit_cos = (query_metric == .cosine and self.hnsw.storesUnitVectors());

        var heap_stack: [128]IdScore = undefined;
        var heap_alloc: ?[]IdScore = null;
        defer if (heap_alloc) |b| scratch_alloc.free(b);
        const heap_buf: []IdScore = if (k <= heap_stack.len)
            heap_stack[0..k]
        else blk: {
            const b = try scratch_alloc.alloc(IdScore, k);
            heap_alloc = b;
            break :blk b;
        };
        var topk = IdScoreTopK.init(heap_buf);
        var thresh = topk.thresholdScore();

        var i: usize = 0;
        while (i + 4 <= n_cands) : (i += 4) {
            if (i + 8 <= n_cands) {
                inline for (0..4) |pf| {
                    @prefetch(self.hnsw.vecPtr(cand_ids[i + 4 + pf]), .{ .locality = 3 });
                }
            }
            const id0 = cand_ids[i];
            const id1 = cand_ids[i + 1];
            const id2 = cand_ids[i + 2];
            const id3 = cand_ids[i + 3];
            const raw_sims: [4]f32 = switch (query_metric) {
                .cosine => if (unit_cos) blk: {
                    if (!(q_aux > 0.0)) break :blk .{ 0.0, 0.0, 0.0, 0.0 };
                    const ds = distance.dotBatch4Aligned(q_ptr, .{
                        self.hnsw.vecPtr(id0),
                        self.hnsw.vecPtr(id1),
                        self.hnsw.vecPtr(id2),
                        self.hnsw.vecPtr(id3),
                    }, stride);
                    break :blk .{
                        @max(@as(f32, -1.0), @min(@as(f32, 1.0), ds[0])),
                        @max(@as(f32, -1.0), @min(@as(f32, 1.0), ds[1])),
                        @max(@as(f32, -1.0), @min(@as(f32, 1.0), ds[2])),
                        @max(@as(f32, -1.0), @min(@as(f32, 1.0), ds[3])),
                    };
                } else distance.cosineWithQueryNormBatch4(query, q_aux, .{
                    self.hnsw.getVector(id0),
                    self.hnsw.getVector(id1),
                    self.hnsw.getVector(id2),
                    self.hnsw.getVector(id3),
                }),
                .dot => distance.dotBatch4Aligned(q_ptr, .{
                    self.hnsw.vecPtr(id0),
                    self.hnsw.vecPtr(id1),
                    self.hnsw.vecPtr(id2),
                    self.hnsw.vecPtr(id3),
                }, stride),
                .l2 => blk: {
                    const ds = distance.l2SquaredBatch4Aligned(q_ptr, .{
                        self.hnsw.vecPtr(id0),
                        self.hnsw.vecPtr(id1),
                        self.hnsw.vecPtr(id2),
                        self.hnsw.vecPtr(id3),
                    }, stride);
                    break :blk .{
                        1.0 / (1.0 + ds[0]),
                        1.0 / (1.0 + ds[1]),
                        1.0 / (1.0 + ds[2]),
                        1.0 / (1.0 + ds[3]),
                    };
                },
            };
            const ids4 = [4]u32{ id0, id1, id2, id3 };
            inline for (0..4) |lane| {
                const cid = ids4[lane];
                const score = if (decay > 0.0)
                    applyDecayIndex(raw_sims[lane], self.timestamps.items[cid], decay, now_ms, decay_tau_hours)
                else
                    raw_sims[lane];
                if (score > thresh) {
                    topk.push(.{ .id = cid, .score = score });
                    thresh = topk.thresholdScore();
                }
            }
        }
        while (i < n_cands) : (i += 1) {
            const cid = cand_ids[i];
            const raw_sim: f32 = switch (query_metric) {
                .cosine => if (unit_cos) blk: {
                    if (!(q_aux > 0.0)) break :blk 0.0;
                    const d = distance.dotAligned(q_ptr, self.hnsw.vecPtr(cid), stride);
                    break :blk @max(@as(f32, -1.0), @min(@as(f32, 1.0), d));
                } else distance.cosineWithQueryNorm(query, q_aux, self.hnsw.getVector(cid)),
                .dot => distance.dotAligned(q_ptr, self.hnsw.vecPtr(cid), stride),
                .l2 => 1.0 / (1.0 + distance.l2SquaredAligned(q_ptr, self.hnsw.vecPtr(cid), stride)),
            };
            const score = if (decay > 0.0)
                applyDecayIndex(raw_sim, self.timestamps.items[cid], decay, now_ms, decay_tau_hours)
            else
                raw_sim;
            if (score > thresh) {
                topk.push(.{ .id = cid, .score = score });
                thresh = topk.thresholdScore();
            }
        }

        const winners = topk.sortedDesc();
        for (winners, 0..) |w, idx| {
            out[idx] = .{
                .key = self.keys.items[w.id],
                .score = w.score,
                .timestamp = self.timestamps.items[w.id],
            };
        }
        return winners.len;
    }

    /// Scan the dense legacy 1-bit BQ slab with 4-way batched Hamming and optional
    /// zero-copy Stage-2 rerank directly against the HNSW vector slab.
    /// Caller holds `self.lockShared()`. Returns `null` if the slab is not usable.
    pub fn searchBqLocked(
        self: *const NamespaceIndex,
        query: []align(1) const f32,
        exclude_id: ?u32,
        top_k: usize,
        oversample: usize,
        query_metric: Metric,
        decay: f32,
        now_ms: u64,
        decay_tau_hours: f32,
        rerank: bool,
        out: []IndexScoredResult,
        scratch_alloc: std.mem.Allocator,
    ) !?SlabSearchResult {
        if (!self.canUseBqSlabLocked(query.len)) return null;
        if (top_k == 0 or out.len == 0) return .{ .count = 0, .needs_kv_rerank = false };

        const slab = &self.bq_slab;
        const n = slab.len;
        const cb = slab.code_bytes;
        const stride = slab.code_stride;
        const stage1_k = @min(self.liveCount(), if (rerank) top_k * oversample else top_k);
        if (stage1_k == 0) return .{ .count = 0, .needs_kv_rerank = false };

        var q_bq_stack: [256]u8 align(64) = undefined;
        var q_bq_heap: ?[]u8 = null;
        defer if (q_bq_heap) |b| scratch_alloc.free(b);
        const q_bq: []u8 = if (stride <= q_bq_stack.len)
            q_bq_stack[0..stride]
        else blk: {
            const b = try scratch_alloc.alloc(u8, stride);
            q_bq_heap = b;
            break :blk b;
        };
        distance.binaryQuantize(query, q_bq[0..cb]);
        if (stride > cb) @memset(q_bq[cb..stride], 0);

        const total_bits: f32 = @floatFromInt(cb * 8);
        const inv_total_bits: f32 = 1.0 / total_bits;
        const has_tomb = self.tombstone_count > 0;
        const has_filter = has_tomb or exclude_id != null;
        const ex_val: u32 = exclude_id orelse std.math.maxInt(u32);

        // Stage 1: gather top `stage1_k` node IDs (zero string dupes).
        var cand_ids_stack: [256]u32 = undefined;
        var cand_ids_heap: ?[]u32 = null;
        defer if (cand_ids_heap) |b| scratch_alloc.free(b);
        const cand_ids_buf: []u32 = if (stage1_k <= cand_ids_stack.len)
            cand_ids_stack[0..stage1_k]
        else blk: {
            const b = try scratch_alloc.alloc(u32, stage1_k);
            cand_ids_heap = b;
            break :blk b;
        };
        var n_stage1: usize = 0;

        if (decay <= 0.0) {
            const max_ham_usize = cb * 8;
            if (max_ham_usize <= MAX_BQ_BUCKET_BITS) {
                // Single-pass exact O(N) counting-bucket selection with dynamic integer cutoff:
                // zero heap sifts, zero float conversions, single pass over `bq_codes`.
                const max_ham: u32 = @intCast(max_ham_usize);
                var counts: [MAX_BQ_BUCKET_BITS + 1]u32 = undefined;
                @memset(counts[0 .. max_ham + 1], 0);

                const sel_cap = @max(stage1_k * 2, 512);
                var buf_stack: [512]IdHam = undefined;
                var buf_heap: ?[]IdHam = null;
                defer if (buf_heap) |b| scratch_alloc.free(b);
                const buf: []IdHam = if (sel_cap <= buf_stack.len)
                    buf_stack[0..sel_cap]
                else blk: {
                    const b = try scratch_alloc.alloc(IdHam, sel_cap);
                    buf_heap = b;
                    break :blk b;
                };

                var buf_len: usize = 0;
                var cutoff: u32 = max_ham;
                var accept_limit: u32 = max_ham + 1;
                var total_le: usize = 0;

                var i: usize = 0;
                while (i + 4 <= n) : (i += 4) {
                    if (i + 16 < n) {
                        @prefetch(slab.codes.ptr + (i + 16) * stride, .{ .locality = 3 });
                    }
                    const hs = distance.hammingBatch4(q_bq, .{
                        slab.codeAt(i),
                        slab.codeAt(i + 1),
                        slab.codeAt(i + 2),
                        slab.codeAt(i + 3),
                    });
                    const min_h = @min(@min(hs[0], hs[1]), @min(hs[2], hs[3]));
                    if (min_h < accept_limit) {
                        inline for (0..4) |lane| {
                            const h = hs[lane];
                            if (h < accept_limit) {
                                const nid: u32 = @intCast(i + lane);
                                if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                                    std.debug.assert(h <= max_ham);
                                    if (buf_len == sel_cap) {
                                        compactBqBuf(buf, &buf_len, counts[0 .. max_ham + 1], cutoff, stage1_k, &total_le);
                                    }
                                    counts[h] += 1;
                                    total_le += 1;
                                    buf[buf_len] = .{ .id = nid, .ham = @intCast(h) };
                                    buf_len += 1;
                                    if (total_le >= stage1_k) {
                                        while (cutoff > 0 and total_le - counts[cutoff] >= stage1_k) {
                                            total_le -= counts[cutoff];
                                            cutoff -= 1;
                                        }
                                        accept_limit = cutoff;
                                    }
                                }
                            }
                        }
                    }
                }
                while (i < n) : (i += 1) {
                    const h = distance.hamming(q_bq, slab.codeAt(i));
                    if (h < accept_limit) {
                        const nid: u32 = @intCast(i);
                        if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                            std.debug.assert(h <= max_ham);
                            if (buf_len == sel_cap) {
                                compactBqBuf(buf, &buf_len, counts[0 .. max_ham + 1], cutoff, stage1_k, &total_le);
                            }
                            counts[h] += 1;
                            total_le += 1;
                            buf[buf_len] = .{ .id = nid, .ham = @intCast(h) };
                            buf_len += 1;
                            if (total_le >= stage1_k) {
                                while (cutoff > 0 and total_le - counts[cutoff] >= stage1_k) {
                                    total_le -= counts[cutoff];
                                    cutoff -= 1;
                                }
                                accept_limit = cutoff;
                            }
                        }
                    }
                }

                if (!rerank) {
                    const emit_n = @min(total_le, @min(top_k, out.len));
                    if (emit_n == 0) return .{ .count = 0, .needs_kv_rerank = false };
                    var offsets: [MAX_BQ_BUCKET_BITS + 1]u32 = undefined;
                    var acc: u32 = 0;
                    for (0..cutoff + 1) |b| {
                        offsets[b] = acc;
                        acc += counts[b];
                    }
                    for (buf[0..buf_len]) |item| {
                        if (item.ham <= cutoff) {
                            const pos = offsets[item.ham];
                            if (pos < emit_n) {
                                out[pos] = .{
                                    .key = self.keys.items[item.id],
                                    .score = 1.0 - @as(f32, @floatFromInt(item.ham)) * inv_total_bits,
                                    .timestamp = self.timestamps.items[item.id],
                                };
                                offsets[item.ham] = pos + 1;
                            }
                        }
                    }
                    return .{ .count = emit_n, .needs_kv_rerank = false };
                }

                const strictly_less = total_le - counts[cutoff];
                const max_eq = if (total_le >= stage1_k) stage1_k - strictly_less else counts[cutoff];
                var kept_eq: usize = 0;
                for (buf[0..buf_len]) |item| {
                    if (item.ham < cutoff) {
                        cand_ids_buf[n_stage1] = item.id;
                        n_stage1 += 1;
                    } else if (item.ham == cutoff and kept_eq < max_eq) {
                        cand_ids_buf[n_stage1] = item.id;
                        n_stage1 += 1;
                        kept_eq += 1;
                    }
                }
            } else {
                var h_stack: [256]IdDist = undefined;
                var h_heap: ?[]IdDist = null;
                defer if (h_heap) |b| scratch_alloc.free(b);
                const h_buf: []IdDist = if (stage1_k <= h_stack.len)
                    h_stack[0..stage1_k]
                else blk: {
                    const b = try scratch_alloc.alloc(IdDist, stage1_k);
                    h_heap = b;
                    break :blk b;
                };
                var heap = IdDistHeap.init(h_buf);
                var worst_ham: u32 = std.math.maxInt(u32);

                var i: usize = 0;
                while (i + 4 <= n) : (i += 4) {
                    if (i + 16 < n) {
                        @prefetch(slab.codes.ptr + (i + 16) * stride, .{ .locality = 3 });
                    }
                    const hs = distance.hammingBatch4(q_bq, .{
                        slab.codeAt(i),
                        slab.codeAt(i + 1),
                        slab.codeAt(i + 2),
                        slab.codeAt(i + 3),
                    });
                    inline for (0..4) |lane| {
                        const h = hs[lane];
                        if (h < worst_ham) {
                            const nid: u32 = @intCast(i + lane);
                            if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                                heap.pushOrReplace(.{ .id = nid, .dist = @floatFromInt(h) });
                                if (heap.isFull()) {
                                    worst_ham = @intFromFloat(heap.worstDist());
                                }
                            }
                        }
                    }
                }
                while (i < n) : (i += 1) {
                    const h = distance.hamming(q_bq, slab.codeAt(i));
                    if (h < worst_ham) {
                        const nid: u32 = @intCast(i);
                        if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                            heap.pushOrReplace(.{ .id = nid, .dist = @floatFromInt(h) });
                            if (heap.isFull()) {
                                worst_ham = @intFromFloat(heap.worstDist());
                            }
                        }
                    }
                }

                if (!rerank) {
                    const sorted = heap.sortedAsc();
                    const emit_n = @min(sorted.len, @min(top_k, out.len));
                    for (0..emit_n) |idx| {
                        const r = sorted[idx];
                        out[idx] = .{
                            .key = self.keys.items[r.id],
                            .score = 1.0 - r.dist * inv_total_bits,
                            .timestamp = self.timestamps.items[r.id],
                        };
                    }
                    return .{ .count = emit_n, .needs_kv_rerank = false };
                }

                const items = heap.items();
                n_stage1 = items.len;
                for (items, 0..) |item, idx| cand_ids_buf[idx] = item.id;
            }
        } else {
            var h_stack: [256]IdScore = undefined;
            var h_heap: ?[]IdScore = null;
            defer if (h_heap) |b| scratch_alloc.free(b);
            const h_buf: []IdScore = if (stage1_k <= h_stack.len)
                h_stack[0..stage1_k]
            else blk: {
                const b = try scratch_alloc.alloc(IdScore, stage1_k);
                h_heap = b;
                break :blk b;
            };
            var heap = IdScoreTopK.init(h_buf);
            var thresh = heap.thresholdScore();

            var i: usize = 0;
            while (i + 4 <= n) : (i += 4) {
                if (i + 16 < n) {
                    @prefetch(slab.codes.ptr + (i + 16) * stride, .{ .locality = 3 });
                }
                const hs = distance.hammingBatch4(q_bq, .{
                    slab.codeAt(i),
                    slab.codeAt(i + 1),
                    slab.codeAt(i + 2),
                    slab.codeAt(i + 3),
                });
                inline for (0..4) |lane| {
                    const nid: u32 = @intCast(i + lane);
                    if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                        const sim = 1.0 - @as(f32, @floatFromInt(hs[lane])) * inv_total_bits;
                        const score = applyDecayIndex(sim, self.timestamps.items[nid], decay, now_ms, decay_tau_hours);
                        if (score > thresh) {
                            heap.push(.{ .id = nid, .score = score });
                            thresh = heap.thresholdScore();
                        }
                    }
                }
            }
            while (i < n) : (i += 1) {
                const nid: u32 = @intCast(i);
                if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                    const h = distance.hamming(q_bq, slab.codeAt(i));
                    const sim = 1.0 - @as(f32, @floatFromInt(h)) * inv_total_bits;
                    const score = applyDecayIndex(sim, self.timestamps.items[nid], decay, now_ms, decay_tau_hours);
                    if (score > thresh) {
                        heap.push(.{ .id = nid, .score = score });
                        thresh = heap.thresholdScore();
                    }
                }
            }

            if (!rerank) {
                const sorted = heap.sortedDesc();
                const emit_n = @min(sorted.len, @min(top_k, out.len));
                for (0..emit_n) |idx| {
                    const r = sorted[idx];
                    out[idx] = .{
                        .key = self.keys.items[r.id],
                        .score = r.score,
                        .timestamp = self.timestamps.items[r.id],
                    };
                }
                return .{ .count = emit_n, .needs_kv_rerank = false };
            }

            n_stage1 = heap.len();
            for (heap.buf[0..n_stage1], 0..) |item, idx| cand_ids_buf[idx] = item.id;
        }

        // Stage 2: rerank directly from HNSW slab when metric-compatible; otherwise
        // return Stage-1 candidates so caller reranks from KV after releasing `self.lock`.
        if (self.canRerankFromHnswLocked(query_metric)) {
            const count = try self.rescoreIdsLocked(
                query,
                cand_ids_buf[0..n_stage1],
                top_k,
                query_metric,
                decay,
                now_ms,
                decay_tau_hours,
                out,
                scratch_alloc,
            );
            return .{ .count = count, .needs_kv_rerank = false };
        }

        const emit_n = @min(n_stage1, out.len);
        for (0..emit_n) |idx| {
            const cid = cand_ids_buf[idx];
            out[idx] = .{
                .key = self.keys.items[cid],
                .score = 0.0,
                .timestamp = self.timestamps.items[cid],
            };
        }
        return .{ .count = emit_n, .needs_kv_rerank = true };
    }

    /// Scan the dense RaBitQ FastScan32 + SoA slab with optional zero-copy Stage-2
    /// rerank directly against the HNSW vector slab.
    /// Caller holds `self.lockShared()`. Returns `null` if the slab is not usable.
    pub fn searchRabitqLocked(
        self: *const NamespaceIndex,
        query: []align(1) const f32,
        exclude_id: ?u32,
        top_k: usize,
        oversample: usize,
        query_metric: Metric,
        decay: f32,
        now_ms: u64,
        decay_tau_hours: f32,
        rerank: bool,
        out: []IndexScoredResult,
        scratch_alloc: std.mem.Allocator,
    ) !?SlabSearchResult {
        if (!self.canUseRabitqSlabLocked(query.len)) return null;
        if (top_k == 0 or out.len == 0) return .{ .count = 0, .needs_kv_rerank = false };

        const p = self.rabitq_params.?;
        const slab = &self.rq_slab;
        const dim = query.len;
        const n = slab.len;
        const stage1_k = @min(self.liveCount(), if (rerank) top_k * oversample else top_k);
        if (stage1_k == 0) return .{ .count = 0, .needs_kv_rerank = false };

        // Stack-first query preparation (zero heap alloc for dim <= 2048).
        var q_res_stack: [STACK_SLAB_QUERY_CAP]f32 = undefined;
        var q_rot_stack: [STACK_SLAB_QUERY_CAP]f32 = undefined;
        var q_norm_stack: [STACK_SLAB_QUERY_CAP]f32 = undefined;
        var q_res_heap: ?[]f32 = null;
        defer if (q_res_heap) |b| scratch_alloc.free(b);
        var q_rot_heap: ?[]f32 = null;
        defer if (q_rot_heap) |b| scratch_alloc.free(b);
        var q_norm_heap: ?[]f32 = null;
        defer if (q_norm_heap) |b| scratch_alloc.free(b);

        const q_residual: []f32 = if (dim <= STACK_SLAB_QUERY_CAP) q_res_stack[0..dim] else blk: {
            const b = try scratch_alloc.alloc(f32, dim);
            q_res_heap = b;
            break :blk b;
        };
        const q_rot_unit: []f32 = if (dim <= STACK_SLAB_QUERY_CAP) q_rot_stack[0..dim] else blk: {
            const b = try scratch_alloc.alloc(f32, dim);
            q_rot_heap = b;
            break :blk b;
        };
        const cosine_score = (query_metric == .cosine);
        const prepare_input: []align(1) const f32 = if (cosine_score) blk: {
            const nb: []f32 = if (dim <= STACK_SLAB_QUERY_CAP) q_norm_stack[0..dim] else blk2: {
                const b = try scratch_alloc.alloc(f32, dim);
                q_norm_heap = b;
                break :blk2 b;
            };
            _ = rabitq_mod.normalizeInto(query, nb);
            break :blk @ptrCast(nb);
        } else query;

        const q_l2 = rabitq_mod.prepareQuery(prepare_input, p, q_residual, q_rot_unit);
        const q_l2_sq = q_l2 * q_l2;

        // Build FastScan32 LUT only if we have >= 1 full 32-vector block.
        const n_blocks = slab.packed_blocks;
        const n_groups = rabitq_mod.fastScanGroups(dim);
        var lut_stack: [STACK_LUT_GROUPS][16]u8 = undefined;
        var lut_heap: ?[][16]u8 = null;
        defer if (lut_heap) |b| scratch_alloc.free(b);
        var lut_slice: [][16]u8 = &.{};
        var lut_scale: rabitq_mod.FastScanLutScale = .{ .vl = 0.0, .delta = 0.0 };
        if (n_blocks > 0) {
            lut_slice = if (n_groups <= STACK_LUT_GROUPS) lut_stack[0..n_groups] else blk: {
                const b = try scratch_alloc.alloc([16]u8, n_groups);
                lut_heap = b;
                break :blk b;
            };
            lut_scale = rabitq_mod.buildFastScanLut(q_rot_unit, lut_slice);
        }

        // Build 4-bit bit-planes only if a partial tail (< 32 vectors) exists.
        const tail_start = n_blocks * 32;
        const has_tail = tail_start < n;
        var plane_stack: [4 * 256]u8 = undefined;
        var plane_heap: ?[]u8 = null;
        defer if (plane_heap) |b| scratch_alloc.free(b);
        var pq: rabitq_mod.PreparedQuery = undefined;
        if (has_tail) {
            const plane_bytes = 4 * slab.code_bytes;
            const pbuf: []u8 = if (plane_bytes <= plane_stack.len) plane_stack[0..plane_bytes] else blk: {
                const b = try scratch_alloc.alloc(u8, plane_bytes);
                plane_heap = b;
                break :blk b;
            };
            pq = rabitq_mod.prepareQueryFromRotated(q_rot_unit, q_l2, pbuf);
        }

        const has_tomb = self.tombstone_count > 0;
        const has_filter = has_tomb or exclude_id != null;
        const ex_val: u32 = exclude_id orelse std.math.maxInt(u32);

        var cand_ids_stack: [256]u32 = undefined;
        var cand_ids_heap: ?[]u32 = null;
        defer if (cand_ids_heap) |b| scratch_alloc.free(b);
        const cand_ids_buf: []u32 = if (stage1_k <= cand_ids_stack.len)
            cand_ids_stack[0..stage1_k]
        else blk: {
            const b = try scratch_alloc.alloc(u32, stage1_k);
            cand_ids_heap = b;
            break :blk b;
        };
        var n_stage1: usize = 0;

        if (decay <= 0.0) {
            var d2_buf: [32]f32 align(64) = undefined;

            if (stage1_k >= 32) {
                // Batched SoA threshold-partition selection with 32-slot guard space so the
                // hot FastScan32 block loop has zero per-element flush checks, zero mid-block
                // threshold mutations, and zero branch mispredictions on AVX-512F via
                // vcompressps/vpcompressd + cold branchless two-buffer quickselect.
                const sel_cap = @max(stage1_k * 2, RABITQ_SEL_STACK_CAP);
                const sel_total = sel_cap + RABITQ_SEL_GUARD;
                var sel_d_stack: [RABITQ_SEL_STACK_CAP + RABITQ_SEL_GUARD]f32 align(64) = undefined;
                var sel_i_stack: [RABITQ_SEL_STACK_CAP + RABITQ_SEL_GUARD]u32 align(64) = undefined;
                var sel_d_heap: ?[]f32 = null;
                var sel_i_heap: ?[]u32 = null;
                defer if (sel_d_heap) |b| scratch_alloc.free(b);
                defer if (sel_i_heap) |b| scratch_alloc.free(b);

                const sel_d: []f32 = if (sel_total <= sel_d_stack.len)
                    sel_d_stack[0..sel_total]
                else blk: {
                    const b = try scratch_alloc.alloc(f32, sel_total);
                    sel_d_heap = b;
                    break :blk b;
                };
                const sel_i: []u32 = if (sel_total <= sel_i_stack.len)
                    sel_i_stack[0..sel_total]
                else blk: {
                    const b = try scratch_alloc.alloc(u32, sel_total);
                    sel_i_heap = b;
                    break :blk b;
                };

                var sel_len: usize = 0;
                var threshold: f32 = std.math.inf(f32);

                // 1. Full 32-vector FastScan blocks.
                if (comptime has_avx512f) {
                    if (!has_filter) {
                        const iota0: @Vector(16, u32) = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
                        const iota1: @Vector(16, u32) = .{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
                        for (0..n_blocks) |blk_idx| {
                            if (blk_idx + 2 < n_blocks) {
                                @prefetch(slab.fastscan_blocks.ptr + (blk_idx + 2) * slab.block_bytes, .{ .locality = 3 });
                                @prefetch(slab.f_add.ptr + (blk_idx + 2) * 32, .{ .locality = 3 });
                                @prefetch(slab.f_rescale.ptr + (blk_idx + 2) * 32, .{ .locality = 3 });
                            }
                            const base = blk_idx * 32;
                            const packed_slice = slab.fastscan_blocks[blk_idx * slab.block_bytes ..][0..slab.block_bytes];
                            rabitq_mod.estimateFastScanBlock32(
                                lut_slice,
                                lut_scale.vl,
                                lut_scale.delta,
                                q_l2,
                                q_l2_sq,
                                packed_slice,
                                slab.f_add[base..][0..32],
                                slab.f_rescale[base..][0..32],
                                &d2_buf,
                            );
                            const tv: @Vector(16, f32) = @splat(threshold);
                            const bv: @Vector(16, u32) = @splat(@as(u32, @intCast(base)));
                            sel_len += compressStore16Avx512(d2_buf[0..16].*, bv + iota0, tv, sel_d.ptr + sel_len, sel_i.ptr + sel_len);
                            sel_len += compressStore16Avx512(d2_buf[16..32].*, bv + iota1, tv, sel_d.ptr + sel_len, sel_i.ptr + sel_len);
                            if (sel_len >= sel_cap) {
                                @branchHint(.cold);
                                threshold = branchlessSelectKSoa(sel_d[0..sel_len], sel_i[0..sel_len], stage1_k, scratch_alloc);
                                sel_len = stage1_k;
                            }
                        }
                    } else {
                        for (0..n_blocks) |blk_idx| {
                            if (blk_idx + 2 < n_blocks) {
                                @prefetch(slab.fastscan_blocks.ptr + (blk_idx + 2) * slab.block_bytes, .{ .locality = 3 });
                                @prefetch(slab.f_add.ptr + (blk_idx + 2) * 32, .{ .locality = 3 });
                                @prefetch(slab.f_rescale.ptr + (blk_idx + 2) * 32, .{ .locality = 3 });
                            }
                            const base = blk_idx * 32;
                            const packed_slice = slab.fastscan_blocks[blk_idx * slab.block_bytes ..][0..slab.block_bytes];
                            rabitq_mod.estimateFastScanBlock32(
                                lut_slice,
                                lut_scale.vl,
                                lut_scale.delta,
                                q_l2,
                                q_l2_sq,
                                packed_slice,
                                slab.f_add[base..][0..32],
                                slab.f_rescale[base..][0..32],
                                &d2_buf,
                            );
                            var mask = blockLessThanMask32(&d2_buf, threshold);
                            if (mask != 0) {
                                while (mask != 0) {
                                    const lane: u5 = @intCast(@ctz(mask));
                                    mask &= mask - 1;
                                    const nid: u32 = @intCast(base + lane);
                                    if (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid))) {
                                        sel_d[sel_len] = d2_buf[lane];
                                        sel_i[sel_len] = nid;
                                        sel_len += 1;
                                    }
                                }
                                if (sel_len >= sel_cap) {
                                    @branchHint(.cold);
                                    threshold = branchlessSelectKSoa(sel_d[0..sel_len], sel_i[0..sel_len], stage1_k, scratch_alloc);
                                    sel_len = stage1_k;
                                }
                            }
                        }
                    }
                } else {
                    for (0..n_blocks) |blk_idx| {
                        if (blk_idx + 2 < n_blocks) {
                            @prefetch(slab.fastscan_blocks.ptr + (blk_idx + 2) * slab.block_bytes, .{ .locality = 3 });
                            @prefetch(slab.f_add.ptr + (blk_idx + 2) * 32, .{ .locality = 3 });
                            @prefetch(slab.f_rescale.ptr + (blk_idx + 2) * 32, .{ .locality = 3 });
                        }
                        const base = blk_idx * 32;
                        const packed_slice = slab.fastscan_blocks[blk_idx * slab.block_bytes ..][0..slab.block_bytes];
                        rabitq_mod.estimateFastScanBlock32(
                            lut_slice,
                            lut_scale.vl,
                            lut_scale.delta,
                            q_l2,
                            q_l2_sq,
                            packed_slice,
                            slab.f_add[base..][0..32],
                            slab.f_rescale[base..][0..32],
                            &d2_buf,
                        );
                        var mask = blockLessThanMask32(&d2_buf, threshold);
                        if (mask != 0) {
                            while (mask != 0) {
                                const lane: u5 = @intCast(@ctz(mask));
                                mask &= mask - 1;
                                const nid: u32 = @intCast(base + lane);
                                if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                                    sel_d[sel_len] = d2_buf[lane];
                                    sel_i[sel_len] = nid;
                                    sel_len += 1;
                                }
                            }
                            if (sel_len >= sel_cap) {
                                @branchHint(.cold);
                                threshold = branchlessSelectKSoa(sel_d[0..sel_len], sel_i[0..sel_len], stage1_k, scratch_alloc);
                                sel_len = stage1_k;
                            }
                        }
                    }
                }

                // 2. Partial tail (< 32 vectors) via 4-bit AND-Popcount SoA batch4.
                var i = tail_start;
                while (i < n) : (i += 4) {
                    const rem = @min(@as(usize, 4), n - i);
                    const k0 = i;
                    const k1 = if (rem > 1) i + 1 else i;
                    const k2 = if (rem > 2) i + 2 else i;
                    const k3 = if (rem > 3) i + 3 else i;
                    const ds = rabitq_mod.estimateL2Sq4BitSlabBatch4(
                        &pq,
                        .{ slab.codeAt(k0), slab.codeAt(k1), slab.codeAt(k2), slab.codeAt(k3) },
                        .{ slab.f_add[k0], slab.f_add[k1], slab.f_add[k2], slab.f_add[k3] },
                        .{ slab.f_rescale[k0], slab.f_rescale[k1], slab.f_rescale[k2], slab.f_rescale[k3] },
                        .{ slab.popc[k0], slab.popc[k1], slab.popc[k2], slab.popc[k3] },
                    );
                    for (0..rem) |lane| {
                        const d2 = ds[lane];
                        if (d2 < threshold) {
                            const nid: u32 = @intCast(i + lane);
                            if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                                sel_d[sel_len] = d2;
                                sel_i[sel_len] = nid;
                                sel_len += 1;
                            }
                        }
                    }
                    if (sel_len >= sel_cap) {
                        @branchHint(.cold);
                        threshold = branchlessSelectKSoa(sel_d[0..sel_len], sel_i[0..sel_len], stage1_k, scratch_alloc);
                        sel_len = stage1_k;
                    }
                }

                if (sel_len > stage1_k) {
                    _ = branchlessSelectKSoa(sel_d[0..sel_len], sel_i[0..sel_len], stage1_k, scratch_alloc);
                    sel_len = stage1_k;
                }

                if (!rerank) {
                    var sort_stack: [256]IdDist = undefined;
                    var sort_heap: ?[]IdDist = null;
                    defer if (sort_heap) |b| scratch_alloc.free(b);
                    const sort_buf: []IdDist = if (sel_len <= sort_stack.len)
                        sort_stack[0..sel_len]
                    else blk: {
                        const b = try scratch_alloc.alloc(IdDist, sel_len);
                        sort_heap = b;
                        break :blk b;
                    };
                    for (0..sel_len) |idx| sort_buf[idx] = .{ .id = sel_i[idx], .dist = sel_d[idx] };
                    std.sort.pdq(IdDist, sort_buf, {}, idDistLess);
                    const emit_n = @min(sort_buf.len, @min(top_k, out.len));
                    for (0..emit_n) |idx| {
                        const r = sort_buf[idx];
                        out[idx] = .{
                            .key = self.keys.items[r.id],
                            .score = rabitqD2ToSim(r.dist, cosine_score),
                            .timestamp = self.timestamps.items[r.id],
                        };
                    }
                    return .{ .count = emit_n, .needs_kv_rerank = false };
                }

                n_stage1 = sel_len;
                @memcpy(cand_ids_buf[0..sel_len], sel_i[0..sel_len]);
            } else {
                // Small-K path (stage1_k < 32): tiny bounded max-heap + SIMD 32-lane threshold mask.
                var h_stack: [32]IdDist = undefined;
                var heap = IdDistHeap.init(h_stack[0..stage1_k]);
                var worst_d2 = heap.worstDist();

                // 1. Full 32-vector FastScan blocks.
                for (0..n_blocks) |blk_idx| {
                    if (blk_idx + 2 < n_blocks) {
                        @prefetch(slab.fastscan_blocks.ptr + (blk_idx + 2) * slab.block_bytes, .{ .locality = 3 });
                        @prefetch(slab.f_add.ptr + (blk_idx + 2) * 32, .{ .locality = 3 });
                        @prefetch(slab.f_rescale.ptr + (blk_idx + 2) * 32, .{ .locality = 3 });
                    }
                    const base = blk_idx * 32;
                    const packed_slice = slab.fastscan_blocks[blk_idx * slab.block_bytes ..][0..slab.block_bytes];
                    rabitq_mod.estimateFastScanBlock32(
                        lut_slice,
                        lut_scale.vl,
                        lut_scale.delta,
                        q_l2,
                        q_l2_sq,
                        packed_slice,
                        slab.f_add[base..][0..32],
                        slab.f_rescale[base..][0..32],
                        &d2_buf,
                    );
                    var mask = blockLessThanMask32(&d2_buf, worst_d2);
                    while (mask != 0) {
                        const lane: u5 = @intCast(@ctz(mask));
                        mask &= mask - 1;
                        const d2 = d2_buf[lane];
                        if (d2 < worst_d2) {
                            const nid: u32 = @intCast(base + lane);
                            if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                                heap.pushOrReplace(.{ .id = nid, .dist = d2 });
                                worst_d2 = heap.worstDist();
                            }
                        }
                    }
                }

                // 2. Partial tail (< 32 vectors) via 4-bit AND-Popcount SoA batch4.
                var i = tail_start;
                while (i < n) : (i += 4) {
                    const rem = @min(@as(usize, 4), n - i);
                    const k0 = i;
                    const k1 = if (rem > 1) i + 1 else i;
                    const k2 = if (rem > 2) i + 2 else i;
                    const k3 = if (rem > 3) i + 3 else i;
                    const ds = rabitq_mod.estimateL2Sq4BitSlabBatch4(
                        &pq,
                        .{ slab.codeAt(k0), slab.codeAt(k1), slab.codeAt(k2), slab.codeAt(k3) },
                        .{ slab.f_add[k0], slab.f_add[k1], slab.f_add[k2], slab.f_add[k3] },
                        .{ slab.f_rescale[k0], slab.f_rescale[k1], slab.f_rescale[k2], slab.f_rescale[k3] },
                        .{ slab.popc[k0], slab.popc[k1], slab.popc[k2], slab.popc[k3] },
                    );
                    for (0..rem) |lane| {
                        const d2 = ds[lane];
                        if (d2 < worst_d2) {
                            const nid: u32 = @intCast(i + lane);
                            if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                                heap.pushOrReplace(.{ .id = nid, .dist = d2 });
                                worst_d2 = heap.worstDist();
                            }
                        }
                    }
                }

                if (!rerank) {
                    const sorted = heap.sortedAsc();
                    const emit_n = @min(sorted.len, @min(top_k, out.len));
                    for (0..emit_n) |idx| {
                        const r = sorted[idx];
                        out[idx] = .{
                            .key = self.keys.items[r.id],
                            .score = rabitqD2ToSim(r.dist, cosine_score),
                            .timestamp = self.timestamps.items[r.id],
                        };
                    }
                    return .{ .count = emit_n, .needs_kv_rerank = false };
                }

                const items = heap.items();
                n_stage1 = items.len;
                for (items, 0..) |item, idx| cand_ids_buf[idx] = item.id;
            }
        } else {
            var h_stack: [256]IdScore = undefined;
            var h_heap: ?[]IdScore = null;
            defer if (h_heap) |b| scratch_alloc.free(b);
            const h_buf: []IdScore = if (stage1_k <= h_stack.len)
                h_stack[0..stage1_k]
            else blk: {
                const b = try scratch_alloc.alloc(IdScore, stage1_k);
                h_heap = b;
                break :blk b;
            };
            var heap = IdScoreTopK.init(h_buf);
            var thresh = heap.thresholdScore();

            var d2_buf: [32]f32 = undefined;
            for (0..n_blocks) |blk_idx| {
                if (blk_idx + 2 < n_blocks) {
                    @prefetch(slab.fastscan_blocks.ptr + (blk_idx + 2) * slab.block_bytes, .{ .locality = 3 });
                }
                const base = blk_idx * 32;
                const packed_slice = slab.fastscan_blocks[blk_idx * slab.block_bytes ..][0..slab.block_bytes];
                rabitq_mod.estimateFastScanBlock32(
                    lut_slice,
                    lut_scale.vl,
                    lut_scale.delta,
                    q_l2,
                    q_l2_sq,
                    packed_slice,
                    slab.f_add[base..][0..32],
                    slab.f_rescale[base..][0..32],
                    &d2_buf,
                );
                inline for (0..32) |lane| {
                    const nid: u32 = @intCast(base + lane);
                    if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                        const raw_sim = rabitqD2ToSim(d2_buf[lane], cosine_score);
                        const score = applyDecayIndex(raw_sim, self.timestamps.items[nid], decay, now_ms, decay_tau_hours);
                        if (score > thresh) {
                            heap.push(.{ .id = nid, .score = score });
                            thresh = heap.thresholdScore();
                        }
                    }
                }
            }

            var i = tail_start;
            while (i < n) : (i += 4) {
                const rem = @min(@as(usize, 4), n - i);
                const k0 = i;
                const k1 = if (rem > 1) i + 1 else i;
                const k2 = if (rem > 2) i + 2 else i;
                const k3 = if (rem > 3) i + 3 else i;
                const ds = rabitq_mod.estimateL2Sq4BitSlabBatch4(
                    &pq,
                    .{ slab.codeAt(k0), slab.codeAt(k1), slab.codeAt(k2), slab.codeAt(k3) },
                    .{ slab.f_add[k0], slab.f_add[k1], slab.f_add[k2], slab.f_add[k3] },
                    .{ slab.f_rescale[k0], slab.f_rescale[k1], slab.f_rescale[k2], slab.f_rescale[k3] },
                    .{ slab.popc[k0], slab.popc[k1], slab.popc[k2], slab.popc[k3] },
                );
                for (0..rem) |lane| {
                    const nid: u32 = @intCast(i + lane);
                    if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                        const raw_sim = rabitqD2ToSim(ds[lane], cosine_score);
                        const score = applyDecayIndex(raw_sim, self.timestamps.items[nid], decay, now_ms, decay_tau_hours);
                        if (score > thresh) {
                            heap.push(.{ .id = nid, .score = score });
                            thresh = heap.thresholdScore();
                        }
                    }
                }
            }

            if (!rerank) {
                const sorted = heap.sortedDesc();
                const emit_n = @min(sorted.len, @min(top_k, out.len));
                for (0..emit_n) |idx| {
                    const r = sorted[idx];
                    out[idx] = .{
                        .key = self.keys.items[r.id],
                        .score = r.score,
                        .timestamp = self.timestamps.items[r.id],
                    };
                }
                return .{ .count = emit_n, .needs_kv_rerank = false };
            }

            n_stage1 = heap.len();
            for (heap.buf[0..n_stage1], 0..) |item, idx| cand_ids_buf[idx] = item.id;
        }

        if (self.canRerankFromHnswLocked(query_metric)) {
            const count = try self.rescoreIdsLocked(
                query,
                cand_ids_buf[0..n_stage1],
                top_k,
                query_metric,
                decay,
                now_ms,
                decay_tau_hours,
                out,
                scratch_alloc,
            );
            return .{ .count = count, .needs_kv_rerank = false };
        }

        const emit_n = @min(n_stage1, out.len);
        for (0..emit_n) |idx| {
            const cid = cand_ids_buf[idx];
            out[idx] = .{
                .key = self.keys.items[cid],
                .score = 0.0,
                .timestamp = self.timestamps.items[cid],
            };
        }
        return .{ .count = emit_n, .needs_kv_rerank = true };
    }

    /// Exact brute-force scan over `self.hnsw`'s contiguous 64B-aligned vector slab
    /// using 4-way batched SIMD. Caller holds `self.lockShared()` and must have
    /// verified `canUseExactSlabLocked(query.len, query_metric)`.
    pub fn searchExactLocked(
        self: *const NamespaceIndex,
        query: []align(1) const f32,
        exclude_id: ?u32,
        top_k: usize,
        query_metric: Metric,
        decay: f32,
        now_ms: u64,
        decay_tau_hours: f32,
        out: []IndexScoredResult,
        scratch_alloc: std.mem.Allocator,
    ) !usize {
        const n = self.hnsw.len();
        const k = @min(top_k, out.len);
        if (n == 0 or k == 0) return 0;

        const stride = self.hnsw.vecStride();
        var q_stack: [STACK_SLAB_QUERY_CAP]f32 align(64) = undefined;
        var q_heap: ?[]align(64) f32 = null;
        defer if (q_heap) |b| scratch_alloc.free(b);
        const q_buf: []align(64) f32 = if (stride <= STACK_SLAB_QUERY_CAP)
            q_stack[0..stride]
        else blk: {
            const b = try scratch_alloc.alignedAlloc(f32, .@"64", stride);
            q_heap = b;
            break :blk b;
        };
        const q_aux = self.prepareAlignedQuery(query, query_metric, q_buf);
        const q_ptr: [*]align(32) const f32 = q_buf.ptr;
        const unit_cos = (query_metric == .cosine and self.hnsw.storesUnitVectors());
        const slab_base = self.hnsw.vectorSlab();

        const has_tomb = self.tombstone_count > 0;
        const has_filter = has_tomb or exclude_id != null;
        const ex_val: u32 = exclude_id orelse std.math.maxInt(u32);

        // Fast monotonic L2 path when decay == 0 (avoids division in inner loop).
        if (query_metric == .l2 and decay <= 0.0) {
            var h_stack: [128]IdDist = undefined;
            var h_heap: ?[]IdDist = null;
            defer if (h_heap) |b| scratch_alloc.free(b);
            const h_buf: []IdDist = if (k <= h_stack.len)
                h_stack[0..k]
            else blk: {
                const b = try scratch_alloc.alloc(IdDist, k);
                h_heap = b;
                break :blk b;
            };
            var heap = IdDistHeap.init(h_buf);
            var worst_d2 = heap.worstDist();

            var i: usize = 0;
            while (i + 4 <= n) : (i += 4) {
                if (i + 8 < n) {
                    @prefetch(slab_base + (i + 8) * stride, .{ .locality = 3 });
                }
                const ds = distance.l2SquaredBatch4Aligned(q_ptr, .{
                    self.hnsw.vecPtr(@intCast(i)),
                    self.hnsw.vecPtr(@intCast(i + 1)),
                    self.hnsw.vecPtr(@intCast(i + 2)),
                    self.hnsw.vecPtr(@intCast(i + 3)),
                }, stride);
                inline for (0..4) |lane| {
                    const d2 = ds[lane];
                    if (d2 < worst_d2) {
                        const nid: u32 = @intCast(i + lane);
                        if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                            heap.pushOrReplace(.{ .id = nid, .dist = d2 });
                            worst_d2 = heap.worstDist();
                        }
                    }
                }
            }
            while (i < n) : (i += 1) {
                const d2 = distance.l2SquaredAligned(q_ptr, self.hnsw.vecPtr(@intCast(i)), stride);
                if (d2 < worst_d2) {
                    const nid: u32 = @intCast(i);
                    if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                        heap.pushOrReplace(.{ .id = nid, .dist = d2 });
                        worst_d2 = heap.worstDist();
                    }
                }
            }

            const sorted = heap.sortedAsc();
            for (sorted, 0..) |r, idx| {
                out[idx] = .{
                    .key = self.keys.items[r.id],
                    .score = 1.0 / (1.0 + r.dist),
                    .timestamp = self.timestamps.items[r.id],
                };
            }
            return sorted.len;
        }

        // General path: cosine (unit dot or precomputed norm), dot, or L2 with decay.
        var h_stack: [128]IdScore = undefined;
        var h_heap: ?[]IdScore = null;
        defer if (h_heap) |b| scratch_alloc.free(b);
        const h_buf: []IdScore = if (k <= h_stack.len)
            h_stack[0..k]
        else blk: {
            const b = try scratch_alloc.alloc(IdScore, k);
            h_heap = b;
            break :blk b;
        };
        var topk = IdScoreTopK.init(h_buf);
        var thresh = topk.thresholdScore();

        var i: usize = 0;
        while (i + 4 <= n) : (i += 4) {
            if (i + 8 < n) {
                @prefetch(slab_base + (i + 8) * stride, .{ .locality = 3 });
            }
            const id0: u32 = @intCast(i);
            const id1: u32 = @intCast(i + 1);
            const id2: u32 = @intCast(i + 2);
            const id3: u32 = @intCast(i + 3);
            const raw_sims: [4]f32 = switch (query_metric) {
                .cosine => if (unit_cos) blk: {
                    if (!(q_aux > 0.0)) break :blk .{ 0.0, 0.0, 0.0, 0.0 };
                    const ds = distance.dotBatch4Aligned(q_ptr, .{
                        self.hnsw.vecPtr(id0),
                        self.hnsw.vecPtr(id1),
                        self.hnsw.vecPtr(id2),
                        self.hnsw.vecPtr(id3),
                    }, stride);
                    break :blk .{
                        @max(@as(f32, -1.0), @min(@as(f32, 1.0), ds[0])),
                        @max(@as(f32, -1.0), @min(@as(f32, 1.0), ds[1])),
                        @max(@as(f32, -1.0), @min(@as(f32, 1.0), ds[2])),
                        @max(@as(f32, -1.0), @min(@as(f32, 1.0), ds[3])),
                    };
                } else distance.cosineWithQueryNormBatch4(query, q_aux, .{
                    self.hnsw.getVector(id0),
                    self.hnsw.getVector(id1),
                    self.hnsw.getVector(id2),
                    self.hnsw.getVector(id3),
                }),
                .dot => distance.dotBatch4Aligned(q_ptr, .{
                    self.hnsw.vecPtr(id0),
                    self.hnsw.vecPtr(id1),
                    self.hnsw.vecPtr(id2),
                    self.hnsw.vecPtr(id3),
                }, stride),
                .l2 => blk: {
                    const ds = distance.l2SquaredBatch4Aligned(q_ptr, .{
                        self.hnsw.vecPtr(id0),
                        self.hnsw.vecPtr(id1),
                        self.hnsw.vecPtr(id2),
                        self.hnsw.vecPtr(id3),
                    }, stride);
                    break :blk .{
                        1.0 / (1.0 + ds[0]),
                        1.0 / (1.0 + ds[1]),
                        1.0 / (1.0 + ds[2]),
                        1.0 / (1.0 + ds[3]),
                    };
                },
            };
            inline for (0..4) |lane| {
                const nid: u32 = @intCast(i + lane);
                if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                    const score = if (decay > 0.0)
                        applyDecayIndex(raw_sims[lane], self.timestamps.items[nid], decay, now_ms, decay_tau_hours)
                    else
                        raw_sims[lane];
                    if (score > thresh) {
                        topk.push(.{ .id = nid, .score = score });
                        thresh = topk.thresholdScore();
                    }
                }
            }
        }
        while (i < n) : (i += 1) {
            const nid: u32 = @intCast(i);
            if (!has_filter or (nid != ex_val and (!has_tomb or !self.tombstones.isSet(nid)))) {
                const raw_sim: f32 = switch (query_metric) {
                    .cosine => if (unit_cos) blk: {
                        if (!(q_aux > 0.0)) break :blk 0.0;
                        const d = distance.dotAligned(q_ptr, self.hnsw.vecPtr(nid), stride);
                        break :blk @max(@as(f32, -1.0), @min(@as(f32, 1.0), d));
                    } else distance.cosineWithQueryNorm(query, q_aux, self.hnsw.getVector(nid)),
                    .dot => distance.dotAligned(q_ptr, self.hnsw.vecPtr(nid), stride),
                    .l2 => 1.0 / (1.0 + distance.l2SquaredAligned(q_ptr, self.hnsw.vecPtr(nid), stride)),
                };
                const score = if (decay > 0.0)
                    applyDecayIndex(raw_sim, self.timestamps.items[nid], decay, now_ms, decay_tau_hours)
                else
                    raw_sim;
                if (score > thresh) {
                    topk.push(.{ .id = nid, .score = score });
                    thresh = topk.thresholdScore();
                }
            }
        }

        const winners = topk.sortedDesc();
        for (winners, 0..) |w, idx| {
            out[idx] = .{
                .key = self.keys.items[w.id],
                .score = w.score,
                .timestamp = self.timestamps.items[w.id],
            };
        }
        return winners.len;
    }

    /// Key + encoded RaBitQ slice pair passed by `vrabitq` to bulk-populate
    /// `self.rq_slab` + FastScan32 blocks under a single write-lock acquisition.
    pub const EncodedSlabEntry = struct {
        key: []const u8,
        encoded: []const u8,
    };

    /// Populate `self.rq_slab` + FastScan32 blocks from pre-encoded `(key, encoded)`
    /// records built off-lock by `vrabitq`. Any live node present in `self` that
    /// was inserted concurrently during `vrabitq` is encoded from `self.hnsw`.
    /// Caller holds `self.lock` exclusively and `self.rabitq_params == expected_params`.
    pub fn installRabitqSlabFromEncodedLocked(
        self: *NamespaceIndex,
        expected_params: *const RabitqParams,
        entries: []const EncodedSlabEntry,
    ) !void {
        const cur = self.rabitq_params orelse return;
        if (cur != expected_params) return;

        const dim: usize = @intCast(expected_params.dim);
        const total = self.hnsw.len();
        self.rq_slab.reset(self.allocator, false);
        if (total == 0 or dim == 0) {
            if (dim > 0) self.rq_slab.configure(self.allocator, dim);
            self.rq_slab.synced = (entries.len == 0);
            return;
        }
        if (self.dim != null and self.dim.? != dim) return;

        self.rq_slab.configure(self.allocator, dim);
        try self.rq_slab.ensureCapacity(self.allocator, total, true);
        self.rq_slab.len = total;

        var populated = try std.bit_set.Dynamic.initEmpty(self.allocator, total);
        defer populated.deinit(self.allocator);

        // Initialize all slots as tombstoned sentinels first so tombstoned nodes
        // have safe finite/inf factors even without KV bq entries.
        for (0..total) |id| {
            self.rq_slab.setTombstoneSlot(id);
        }

        for (entries) |entry| {
            const nid = self.key_to_node.get(entry.key) orelse {
                // Store holds a key absent from this index (incomplete index):
                // leave `rq_slab.synced = false` so KV fallback serves full corpus.
                self.rq_slab.reset(self.allocator, false);
                return;
            };
            if (nid >= total or self.tombstones.isSet(nid)) {
                self.rq_slab.reset(self.allocator, false);
                return;
            }
            const parsed = rabitq_mod.parse(entry.encoded, dim) orelse {
                self.rq_slab.reset(self.allocator, false);
                return;
            };
            self.rq_slab.setSlot(nid, parsed.code, parsed.l2_norm, parsed.corr);
            populated.set(nid);
        }

        // Fill any live nodes inserted concurrently between vrabitq scan & swap.
        var code_stack: [256]u8 = undefined;
        var code_heap: ?[]u8 = null;
        defer if (code_heap) |b| self.allocator.free(b);
        const cb = rabitq_mod.codeBytes(dim);
        const code_buf: []u8 = if (cb <= code_stack.len) code_stack[0..cb] else blk: {
            const b = try self.allocator.alloc(u8, cb);
            code_heap = b;
            break :blk b;
        };
        for (0..total) |id| {
            if (self.tombstones.isSet(id) or populated.isSet(id)) continue;
            const vec = self.hnsw.getVector(@intCast(id));
            if (vec.len != dim) continue;
            const enc = try self.encodeRabitqCoreLocked(self.allocator, expected_params, vec, code_buf);
            self.rq_slab.setSlot(id, enc.code, enc.l2_norm, enc.corr);
        }

        self.rq_slab.packAllFullBlocks();
        self.rq_slab.synced = true;
    }

    /// Atomically swap graph, side-tables, and slabs from an off-lock rebuilt
    /// `NamespaceIndex` into `self` under `self.lock` (exclusive). Preserves
    /// `self.async_*`, `self.rabitq_params`/`rabitq_handle`, and `self.config_persisted`.
    /// After releasing `self.lock`, caller calls `fresh.deinit()` off-lock to free
    /// the displaced old graph & tables.
    pub fn swapRebuiltLocked(
        self: *NamespaceIndex,
        fresh: *NamespaceIndex,
        built_for_rabitq: ?*const RabitqParams,
    ) void {
        std.mem.swap(Hnsw, &self.hnsw, &fresh.hnsw);
        std.mem.swap(std.ArrayListUnmanaged([]u8), &self.keys, &fresh.keys);
        std.mem.swap(std.ArrayListUnmanaged(u64), &self.timestamps, &fresh.timestamps);
        std.mem.swap(std.ArrayListUnmanaged(u64), &self.vec_hashes, &fresh.vec_hashes);
        std.mem.swap(std.StringHashMapUnmanaged(u32), &self.key_to_node, &fresh.key_to_node);
        std.mem.swap(std.bit_set.Dynamic, &self.tombstones, &fresh.tombstones);
        std.mem.swap(usize, &self.tombstone_count, &fresh.tombstone_count);
        std.mem.swap(?usize, &self.dim, &fresh.dim);
        std.mem.swap(BqSlab, &self.bq_slab, &fresh.bq_slab);
        std.mem.swap(RabitqSlab, &self.rq_slab, &fresh.rq_slab);
        self.complete_with_store = fresh.complete_with_store;

        // If `vrabitq` changed `self.rabitq_params` while `fresh` was building off-lock,
        // invalidate the rebuilt slab so `vsearch` stays 100% consistent.
        const cur_ptr: ?*const RabitqParams = self.rabitq_params;
        if (cur_ptr != built_for_rabitq) {
            self.bq_slab.synced = false;
            self.rq_slab.synced = false;
        }
    }

    /// Full reset — caller must hold write-lock. Used by vreindex before
    /// a bulk rebuild. Metric is preserved (callers who want to switch
    /// metrics must drop the namespace entirely).
    pub fn clearLocked(self: *NamespaceIndex) void {
        const params = self.hnsw.params;
        self.hnsw.deinit();
        self.hnsw = Hnsw.init(self.allocator, params);
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.clearRetainingCapacity();
        self.timestamps.clearRetainingCapacity();
        self.vec_hashes.clearRetainingCapacity();
        self.key_to_node.clearRetainingCapacity();
        self.tombstones.deinit(self.allocator);
        self.tombstones = .{};
        self.tombstone_count = 0;
        // Dimension must re-freeze on the next insert — `vreindex` may be
        // used to switch a namespace's dim during a full rebuild.
        self.dim = null;
        if (self.rabitq_params) |p| {
            self.bq_slab.deinit(self.allocator);
            self.bq_slab.synced = false;
            self.rq_slab.reset(self.allocator, true);
            if (p.dim > 0) self.rq_slab.configure(self.allocator, @intCast(p.dim));
        } else {
            self.rq_slab.reset(self.allocator, false);
            self.bq_slab.resetKeepingAlloc(true);
        }
        self.complete_with_store = true;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Serialization                                     ║
    // ╚═══════════════════════════════════════════════════╝

    /// Per-namespace block format (WDBHNSW2):
    ///   [1B metric]                                 (0=cosine, 1=dot, 2=l2)
    ///   [4B node_count]                             (canonical; used by reader
    ///                                               to preallocate key table
    ///                                               BEFORE the graph block)
    ///   For each node:
    ///     [2B key_len][key bytes]
    ///     [8B timestamp]
    ///   [8B tombstone_count]
    ///   [ceil(node_count/8) bytes: tombstone bits]  (LSB-first per byte)
    ///   [hnsw graph block]                          (Hnsw.writeTo — repeats
    ///                                               node_count internally for
    ///                                               self-containment)
    ///   [1B has_rabitq]                             (0=absent, 1=present)
    ///   If has_rabitq == 1:
    ///     [4B dim][8B seed]
    ///     [dim × 4B centroid f32s, little-endian]
    ///     [dim × dim × 4B rotation f32s, row-major, little-endian]
    ///
    /// Why keys first: Hnsw.readFrom resolves each node's vector by node_id
    /// via a callback. If keys came after the graph, the callback couldn't
    /// know which key belongs to which id at resolve time. Keys first lets
    /// the outer reader stage a node_id → key array before the graph loads.
    ///
    /// Caller must hold the write-lock for the duration — writeToLocked
    /// does not lock itself so the enclosing snapshot can batch several
    /// namespaces under a consistent point-in-time view.
    pub fn writeToLocked(self: *const NamespaceIndex, writer: anytype) !void {
        var bw = BufferedIndexWriter(@TypeOf(writer)){ .inner = writer };
        const w = &bw;

        const metric_byte: u8 = switch (self.metric) {
            .cosine => 0,
            .dot => 1,
            .l2 => 2,
        };
        try w.writeAll(&[_]u8{metric_byte});

        const node_count = self.hnsw.len();
        var nc_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, nc_buf[0..4], @intCast(node_count), .little);
        try w.writeAll(&nc_buf);

        for (self.keys.items, 0..) |key, i| {
            var kl_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, kl_buf[0..2], @intCast(key.len), .little);
            try w.writeAll(&kl_buf);
            try w.writeAll(key);

            var ts_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, ts_buf[0..8], self.timestamps.items[i], .little);
            try w.writeAll(&ts_buf);
        }

        var tc_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, tc_buf[0..8], self.tombstone_count, .little);
        try w.writeAll(&tc_buf);

        const tomb_bytes = (node_count + 7) / 8;
        if (tomb_bytes > 0) {
            const buf = try self.allocator.alloc(u8, tomb_bytes);
            defer self.allocator.free(buf);
            @memset(buf, 0);
            var id: usize = 0;
            while (id < node_count) : (id += 1) {
                if (self.tombstones.isSet(id)) {
                    buf[id / 8] |= @as(u8, 1) << @intCast(id % 8);
                }
            }
            try w.writeAll(buf);
        }

        try self.hnsw.writeTo(w);

        // ── RaBitQ params trailer ────────────────────────────────────
        if (self.rabitq_params) |p| {
            try w.writeAll(&[_]u8{1});
            var dim_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, dim_buf[0..4], p.dim, .little);
            try w.writeAll(&dim_buf);
            var seed_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, seed_buf[0..8], p.seed, .little);
            try w.writeAll(&seed_buf);
            // Bit-cast each f32 to u32 so the stream is little-endian on
            // any host. Centroid first, then rotation.
            try writeF32Slice(w, p.centroid);
            try writeF32Slice(w, p.rotation);
        } else {
            try w.writeAll(&[_]u8{0});
        }

        try bw.flush();
    }

    /// Resolver context used internally during readFromLocked — bridges
    /// from Hnsw's node_id-based callback to the outer key-based KV
    /// lookup. `keys` lives on the reading side's stack until the whole
    /// index is built.
    const LocalResolver = struct {
        keys: []const []const u8,
        vec_hashes: []u64,
        outer_resolve: OuterResolveFn,
        outer_ctx: *anyopaque,

        pub const OuterResolveFn = *const fn (ctx: *anyopaque, key: []const u8) ?[]const u8;

        fn bridge(raw_ctx: *anyopaque, node_id: u32) ?[]const u8 {
            const self: *LocalResolver = @ptrCast(@alignCast(raw_ctx));
            if (node_id >= self.keys.len) return null;
            const bytes = self.outer_resolve(self.outer_ctx, self.keys[node_id]) orelse return null;
            self.vec_hashes[node_id] = std.hash.Wyhash.hash(0, bytes);
            return bytes;
        }
    };

    /// Reconstruct a NamespaceIndex from a serialized block. The caller
    /// supplies a KEY-based resolver (`outer_resolve`) that maps a vector
    /// key to its raw bytes; NamespaceIndex.readFromLocked builds the
    /// node_id → key array internally from the file's keys block and
    /// bridges the two layers.
    ///
    /// Caller holds no locks; the returned index owns all its storage.
    pub fn readFromLocked(
        allocator: std.mem.Allocator,
        reader: anytype,
        outer_resolve: LocalResolver.OuterResolveFn,
        outer_ctx: *anyopaque,
    ) !NamespaceIndex {
        var metric_buf: [1]u8 = undefined;
        try readAllExact(reader, &metric_buf);
        const metric: Metric = switch (metric_buf[0]) {
            0 => .cosine,
            1 => .dot,
            2 => .l2,
            else => return error.CorruptIndex,
        };

        var nc_buf: [4]u8 = undefined;
        try readAllExact(reader, &nc_buf);
        const node_count = std.mem.readInt(u32, nc_buf[0..4], .little);

        // ── Stage 1: read keys + timestamps ──
        var keys: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (keys.items) |k| allocator.free(k);
            keys.deinit(allocator);
        }
        try keys.ensureTotalCapacity(allocator, node_count);

        var timestamps: std.ArrayListUnmanaged(u64) = .empty;
        errdefer timestamps.deinit(allocator);
        try timestamps.ensureTotalCapacity(allocator, node_count);

        var i: usize = 0;
        while (i < node_count) : (i += 1) {
            var kl_buf: [2]u8 = undefined;
            try readAllExact(reader, &kl_buf);
            const key_len = std.mem.readInt(u16, kl_buf[0..2], .little);
            const key_copy = try allocator.alloc(u8, key_len);
            errdefer allocator.free(key_copy);
            try readAllExact(reader, key_copy);

            var ts_buf: [8]u8 = undefined;
            try readAllExact(reader, &ts_buf);
            const ts = std.mem.readInt(u64, ts_buf[0..8], .little);

            try keys.append(allocator, key_copy);
            try timestamps.append(allocator, ts);
        }

        // ── Stage 2: read tombstone header + bits ──
        var tc_buf: [8]u8 = undefined;
        try readAllExact(reader, &tc_buf);
        // The format stores the count as u64. On a 32-bit target (wasm32) `usize` is u32, so the
        // narrowing has to be explicit; the value is bounded by the vector count, far under 2^32.
        const tombstone_count: usize = @intCast(std.mem.readInt(u64, tc_buf[0..8], .little));

        var tombstones: std.bit_set.Dynamic = if (node_count == 0)
            .{}
        else
            try std.bit_set.Dynamic.initEmpty(allocator, node_count);
        errdefer tombstones.deinit(allocator);

        const tomb_bytes = (node_count + 7) / 8;
        if (tomb_bytes > 0) {
            const buf = try allocator.alloc(u8, tomb_bytes);
            defer allocator.free(buf);
            try readAllExact(reader, buf);
            var id: usize = 0;
            while (id < node_count) : (id += 1) {
                if ((buf[id / 8] & (@as(u8, 1) << @intCast(id % 8))) != 0) {
                    tombstones.set(id);
                }
            }
        }

        // ── Stage 3: read graph, bridging node_id → key lookups ──
        var vec_hashes: std.ArrayListUnmanaged(u64) = .empty;
        errdefer vec_hashes.deinit(allocator);
        try vec_hashes.resize(allocator, node_count);
        @memset(vec_hashes.items, 0);

        var bridge_ctx = LocalResolver{
            .keys = keys.items,
            .vec_hashes = vec_hashes.items,
            .outer_resolve = outer_resolve,
            .outer_ctx = outer_ctx,
        };
        var hnsw = try Hnsw.readFromWithDistFn(
            allocator,
            reader,
            metric.distFn(),
            LocalResolver.bridge,
            @ptrCast(&bridge_ctx),
        );
        errdefer hnsw.deinit();

        // ── Build the reverse map (keys must already be populated) ──
        var key_to_node: std.StringHashMapUnmanaged(u32) = .empty;
        errdefer key_to_node.deinit(allocator);
        for (keys.items, 0..) |k, idx| {
            try key_to_node.put(allocator, k, @intCast(idx));
        }

        // ── Derive dim from the first resolvable vector. The snapshot
        //    format doesn't carry dim explicitly; scanning keys in order
        //    and taking the first non-null resolve is cheap (~one KV lookup)
        //    and robust against tombstoned or missing entries.
        var derived_dim: ?usize = null;
        for (keys.items) |k| {
            if (outer_resolve(outer_ctx, k)) |bytes| {
                if (bytes.len > 0 and bytes.len % 4 == 0) {
                    derived_dim = bytes.len / 4;
                    break;
                }
            }
        }

        // ── RaBitQ params trailer ────────────────────────────────────
        var rabitq_handle: ?*RabitqParamsHandle = null;
        errdefer if (rabitq_handle) |h| h.release();
        var rabitq_params_ptr: ?*RabitqParams = null;

        var has_rabitq_buf: [1]u8 = undefined;
        try readAllExact(reader, &has_rabitq_buf);
        if (has_rabitq_buf[0] == 1) {
            var dim_buf: [4]u8 = undefined;
            try readAllExact(reader, &dim_buf);
            const dim_u32 = std.mem.readInt(u32, dim_buf[0..4], .little);
            var seed_buf: [8]u8 = undefined;
            try readAllExact(reader, &seed_buf);
            const seed = std.mem.readInt(u64, seed_buf[0..8], .little);

            const dim_usize: usize = @intCast(dim_u32);
            const centroid = try allocator.alloc(f32, dim_usize);
            var ownership_transferred = false;
            errdefer if (!ownership_transferred) allocator.free(centroid);
            try readF32Slice(reader, centroid);

            const rotation = try allocator.alloc(f32, dim_usize * dim_usize);
            errdefer if (!ownership_transferred) allocator.free(rotation);
            try readF32Slice(reader, rotation);

            const p = try allocator.create(RabitqParams);
            errdefer if (!ownership_transferred) allocator.destroy(p);
            p.* = .{
                .allocator = allocator,
                .centroid = centroid,
                .rotation = rotation,
                .dim = dim_u32,
                .seed = seed,
            };
            const handle = try RabitqParamsHandle.create(allocator, p);
            ownership_transferred = true;
            rabitq_handle = handle;
            rabitq_params_ptr = p;
            // If the graph never resolved a vector (empty namespace), fall
            // back to the params' dim so later inserts know what shape to
            // accept.
            if (derived_dim == null) derived_dim = dim_usize;
        } else if (has_rabitq_buf[0] != 0) {
            return error.CorruptIndex;
        }

        // ── Rebuild in-index contiguous BQ / RaBitQ slabs ────────────
        var bq_slab: BqSlab = .{};
        errdefer bq_slab.deinit(allocator);
        var rq_slab: RabitqSlab = .{};
        errdefer rq_slab.deinit(allocator);

        if (rabitq_params_ptr) |p| {
            bq_slab.synced = false;
            const pdim: usize = @intCast(p.dim);
            if (node_count == 0) {
                if (pdim > 0) rq_slab.configure(allocator, pdim);
                rq_slab.synced = true;
            } else if (pdim > 0 and (derived_dim == null or derived_dim.? == pdim)) {
                rq_slab.configure(allocator, pdim);
                try rq_slab.ensureCapacity(allocator, node_count, true);
                rq_slab.len = node_count;
                var all_matched = true;
                var bq_key_stack: [512]u8 = undefined;
                for (0..node_count) |id| {
                    if (tombstones.isSet(id)) {
                        rq_slab.setTombstoneSlot(id);
                        continue;
                    }
                    const k = keys.items[id];
                    const need = 3 + k.len;
                    var bq_key_heap: ?[]u8 = null;
                    defer if (bq_key_heap) |b| allocator.free(b);
                    const bq_key: []const u8 = if (need <= bq_key_stack.len) blk: {
                        @memcpy(bq_key_stack[0..3], "bq:");
                        @memcpy(bq_key_stack[3..need], k);
                        break :blk bq_key_stack[0..need];
                    } else blk: {
                        const b = try allocator.alloc(u8, need);
                        bq_key_heap = b;
                        @memcpy(b[0..3], "bq:");
                        @memcpy(b[3..need], k);
                        break :blk b;
                    };
                    const bq_bytes = outer_resolve(outer_ctx, bq_key) orelse {
                        all_matched = false;
                        break;
                    };
                    const parsed = rabitq_mod.parse(bq_bytes, pdim) orelse {
                        all_matched = false;
                        break;
                    };
                    rq_slab.setSlot(id, parsed.code, parsed.l2_norm, parsed.corr);
                }
                if (all_matched) {
                    rq_slab.packAllFullBlocks();
                    rq_slab.synced = true;
                } else {
                    rq_slab.reset(allocator, false);
                }
            }
        } else if (node_count > 0) {
            if (derived_dim) |d| {
                bq_slab.configure(allocator, d);
                try bq_slab.ensureCapacity(allocator, node_count, true);
                bq_slab.len = node_count;
                var all_ok = true;
                for (0..node_count) |id| {
                    const dst = bq_slab.codes[id * bq_slab.code_stride ..][0..bq_slab.code_stride];
                    @memset(dst, 0);
                    if (tombstones.isSet(id)) continue;
                    const vec = hnsw.getVector(@intCast(id));
                    if (vec.len != d) {
                        all_ok = false;
                        break;
                    }
                    distance.binaryQuantize(vec, dst[0..bq_slab.code_bytes]);
                }
                if (!all_ok) {
                    bq_slab.deinit(allocator);
                    bq_slab.synced = false;
                }
            } else {
                bq_slab.synced = false;
            }
        }

        return .{
            .allocator = allocator,
            .hnsw = hnsw,
            .keys = keys,
            .timestamps = timestamps,
            .vec_hashes = vec_hashes,
            .key_to_node = key_to_node,
            .tombstones = tombstones,
            .tombstone_count = tombstone_count,
            .metric = metric,
            .dim = derived_dim,
            .lock = .{},
            .async_mode = false,
            .async_queue = null,
            .async_worker = null,
            .rabitq_params = rabitq_params_ptr,
            .rabitq_handle = rabitq_handle,
            .bq_slab = bq_slab,
            .rq_slab = rq_slab,
            .config_persisted = .init(false),
            .complete_with_store = false,
        };
    }
};

fn writeF32Slice(writer: anytype, slice: []const f32) !void {
    if (comptime builtin.cpu.arch.endian() == .little) {
        try writer.writeAll(std.mem.sliceAsBytes(slice));
        return;
    }
    var buf: [4]u8 = undefined;
    for (slice) |x| {
        const bits: u32 = @bitCast(x);
        std.mem.writeInt(u32, &buf, bits, .little);
        try writer.writeAll(&buf);
    }
}

fn readF32Slice(reader: anytype, dest: []f32) !void {
    if (comptime builtin.cpu.arch.endian() == .little) {
        try readAllExact(reader, std.mem.sliceAsBytes(dest));
        return;
    }
    var buf: [4]u8 = undefined;
    for (dest) |*slot| {
        try readAllExact(reader, &buf);
        const bits = std.mem.readInt(u32, &buf, .little);
        slot.* = @bitCast(bits);
    }
}

fn readAllExact(reader: anytype, dest: []u8) !void {
    var pos: usize = 0;
    while (pos < dest.len) {
        const n = try reader.readAll(dest[pos..]);
        if (n == 0) return error.EndOfStream;
        pos += n;
    }
}

pub const NamespaceRegistry = struct {
    allocator: std.mem.Allocator,
    /// Key = owned copy of the namespace string. Value = owned *NamespaceIndex.
    map: std.StringHashMapUnmanaged(*NamespaceIndex),
    /// Protects `map` structure (get/put/remove). Per-index locks live on
    /// each NamespaceIndex and are independent of this one.
    lock: RwLock,
    /// Default params applied to newly-created namespaces.
    default_params: HnswParams,
    /// Lock-free count of active namespaces so non-vector KV workloads skip
    /// `syncRawSet` / `syncRawDelete` without acquiring `lock`.
    active_namespaces: std.atomic.Value(usize) = .init(0),
    /// 256-bit lock-free first-byte bitmap (32 bytes = half a cache line, 32-bit atomics
    /// for wasm32 compatibility). Checked inline on every KV write before calling into
    /// `syncVectorSetWithRegistry` so non-matching keys stay in 1 hot L1 cache line.
    first_byte_mask: [8]std.atomic.Value(u32) align(64) = initFirstByteMask(),
    /// Lock-free first-byte refcount table of registered namespaces, indexed by
    /// `namespace[0]`. Keeps bit-clear on `remove` exact when multiple namespaces share byte 0.
    first_byte_counts: [256]std.atomic.Value(u32) align(64) = initFirstByteCounts(),

    fn initFirstByteMask() [8]std.atomic.Value(u32) {
        var table: [8]std.atomic.Value(u32) = undefined;
        for (&table) |*slot| slot.* = .init(0);
        return table;
    }

    fn initFirstByteCounts() [256]std.atomic.Value(u32) {
        var table: [256]std.atomic.Value(u32) = undefined;
        for (&table) |*slot| slot.* = .init(0);
        return table;
    }

    fn addFirstByteLocked(self: *NamespaceRegistry, b: u8) void {
        const prev = self.first_byte_counts[b].fetchAdd(1, .release);
        if (prev == 0) {
            const word_idx: usize = b >> 5;
            const bit: u32 = @as(u32, 1) << @as(u5, @truncate(b));
            _ = self.first_byte_mask[word_idx].fetchOr(bit, .release);
        }
    }

    fn removeFirstByteLocked(self: *NamespaceRegistry, b: u8) void {
        const prev = self.first_byte_counts[b].fetchSub(1, .release);
        if (prev == 1) {
            const word_idx: usize = b >> 5;
            const bit: u32 = @as(u32, 1) << @as(u5, @truncate(b));
            _ = self.first_byte_mask[word_idx].fetchAnd(~bit, .release);
        }
    }

    pub fn init(allocator: std.mem.Allocator, default_params: HnswParams) NamespaceRegistry {
        return .{
            .allocator = allocator,
            .map = .empty,
            .lock = .{},
            .default_params = default_params,
            .active_namespaces = .init(0),
            .first_byte_mask = initFirstByteMask(),
            .first_byte_counts = initFirstByteCounts(),
        };
    }

    pub fn deinit(self: *NamespaceRegistry) void {
        self.lock.lock();
        defer self.lock.unlock();
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
        for (&self.first_byte_mask) |*slot| slot.store(0, .monotonic);
        for (&self.first_byte_counts) |*slot| slot.store(0, .monotonic);
        self.active_namespaces.store(0, .monotonic);
    }

    /// Look up an existing index. Returns null if the namespace has no
    /// index yet. Takes a shared lock; caller can use the returned pointer
    /// without further registry coordination — per-index locking is
    /// separate.
    pub fn get(self: *NamespaceRegistry, namespace: []const u8) ?*NamespaceIndex {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.map.get(namespace);
    }

    /// Look up or create. Takes a write-lock briefly to insert into the
    /// registry; the returned pointer is stable across concurrent
    /// getOrCreate calls for the same namespace.
    ///
    /// If the namespace already exists and its metric differs from `m`,
    /// returns `error.MetricMismatch`. Namespaces are single-metric by
    /// design — the HNSW graph is built against one distance function
    /// and can't serve queries under another without full rebuild.
    pub fn getOrCreate(self: *NamespaceRegistry, namespace: []const u8, m: Metric) !*NamespaceIndex {
        // Fast path: shared lock, peek the map.
        self.lock.lockShared();
        if (self.map.get(namespace)) |idx| {
            self.lock.unlockShared();
            if (idx.metric != m) return RegistryError.MetricMismatch;
            return idx;
        }
        self.lock.unlockShared();

        // Slow path: exclusive lock, double-checked insert.
        self.lock.lock();
        defer self.lock.unlock();

        if (self.map.get(namespace)) |idx| {
            if (idx.metric != m) return RegistryError.MetricMismatch;
            return idx;
        }

        const ns_copy = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_copy);

        const idx = try self.allocator.create(NamespaceIndex);
        errdefer self.allocator.destroy(idx);
        idx.* = NamespaceIndex.init(self.allocator, self.default_params, m);

        try self.map.put(self.allocator, ns_copy, idx);
        if (ns_copy.len > 0) {
            self.addFirstByteLocked(ns_copy[0]);
        }
        _ = self.active_namespaces.fetchAdd(1, .release);
        return idx;
    }

    /// Drop a namespace's index entirely. Caller is responsible for not
    /// holding the per-index lock when calling this.
    pub fn remove(self: *NamespaceRegistry, namespace: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.map.fetchRemove(namespace)) |kv| {
            if (kv.key.len > 0) {
                self.removeFirstByteLocked(kv.key[0]);
            }
            _ = self.active_namespaces.fetchSub(1, .release);
            self.allocator.free(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Single-atomic-load fast check suitable for inlining at the Store write/delete hot path.
    /// Returns false whenever no registered namespace starts with `key[0]`.
    pub inline fn mayMatchFast(self: *const NamespaceRegistry, key: []const u8) bool {
        if (key.len == 0) return false;
        const b = key[0];
        const word = self.first_byte_mask[b >> 5].load(.acquire);
        return (word & (@as(u32, 1) << @as(u5, @truncate(b)))) != 0;
    }

    inline fn mayMatchRegisteredNamespace(self: *const NamespaceRegistry, key: []const u8) bool {
        if (!self.mayMatchFast(key)) return false;
        if (self.active_namespaces.load(.acquire) == 0) return false;
        if (std.mem.startsWith(u8, key, "bq:") or std.mem.startsWith(u8, key, "__meta:")) return false;
        return true;
    }

    pub const RawSetBqAction = union(enum) {
        none,
        upsert: []u8,
        delete,
    };

    /// Synchronize a plain `DEL` against any registered vector namespace whose
    /// prefix matches `key`. Returns true if `key` matched any registered
    /// namespace prefix (so the caller can also remove any `"bq:" ++ key`
    /// companion). Must be called with NO shard locks held.
    pub fn syncRawDelete(self: *NamespaceRegistry, key: []const u8) bool {
        if (!self.mayMatchRegisteredNamespace(key)) return false;

        self.lock.lockShared();
        defer self.lock.unlockShared();

        var matched_ns = false;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (std.mem.startsWith(u8, key, entry.key_ptr.*)) {
                matched_ns = true;
                const idx = entry.value_ptr.*;
                idx.lock.lock();
                defer idx.lock.unlock();
                _ = idx.markTombstoneLocked(key);
            }
        }
        return matched_ns;
    }

    /// Synchronize a raw `SET` against registered vector namespaces without
    /// returning a BQ companion buffer.
    pub fn syncRawSet(self: *NamespaceRegistry, key: []const u8, value: []const u8, timestamp: u64) void {
        _ = self.syncRawSetInternal(key, value, timestamp, false);
    }

    /// Synchronize a raw `SET` against registered vector namespaces and return
    /// the companion `bq:<key>` mutation to apply in `Store` after releasing
    /// registry/index locks. Must be called with NO shard locks held.
    pub fn syncRawSetWithBq(self: *NamespaceRegistry, key: []const u8, value: []const u8, timestamp: u64) RawSetBqAction {
        return self.syncRawSetInternal(key, value, timestamp, true);
    }

    fn syncRawSetInternal(
        self: *NamespaceRegistry,
        key: []const u8,
        value: []const u8,
        timestamp: u64,
        want_bq: bool,
    ) RawSetBqAction {
        if (!self.mayMatchRegisteredNamespace(key)) return .none;

        self.lock.lockShared();
        defer self.lock.unlockShared();

        var best_ns_len: usize = 0;
        var best_idx: ?*NamespaceIndex = null;
        var refreshed_existing = false;
        var encoded_ns_len: usize = 0;
        var action: RawSetBqAction = .none;

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const ns = entry.key_ptr.*;
            if (!std.mem.startsWith(u8, key, ns)) continue;
            const idx = entry.value_ptr.*;
            idx.lock.lock();
            defer idx.lock.unlock();
            if (idx.nodeIdFor(key)) |old_id| {
                refreshed_existing = true;
                if (!idx.tombstones.isSet(old_id) and timestamp < idx.timestamps.items[old_id]) {
                    continue;
                }
                if (distance.bytesToF32(value)) |vec| {
                    if (idx.dim == null or vec.len == idx.dim.?) {
                        const pre_bq: ?[]u8 = if (want_bq and ns.len >= encoded_ns_len)
                            (idx.encodeBqLocked(self.allocator, vec) catch null)
                        else
                            null;
                        if (idx.insertLockedWithBq(key, vec, timestamp, pre_bq)) |_| {
                            if (pre_bq) |bq| {
                                if (action == .upsert) self.allocator.free(action.upsert);
                                action = .{ .upsert = bq };
                                encoded_ns_len = ns.len;
                            }
                        } else |_| {
                            if (pre_bq) |bq| self.allocator.free(bq);
                            idx.markIncompleteLocked();
                            _ = idx.markTombstoneLocked(key);
                            if (action == .none) action = .delete;
                        }
                    } else {
                        _ = idx.markTombstoneLocked(key);
                        if (action == .none) action = .delete;
                    }
                } else {
                    _ = idx.markTombstoneLocked(key);
                    if (action == .none) action = .delete;
                }
            } else if (ns.len > best_ns_len) {
                best_ns_len = ns.len;
                best_idx = idx;
            }
        }

        if (!refreshed_existing) {
            if (best_idx) |idx| {
                idx.lock.lock();
                defer idx.lock.unlock();
                if (idx.dim) |d| {
                    if (distance.bytesToF32(value)) |vec| {
                        if (vec.len == d) {
                            const pre_bq: ?[]u8 = if (want_bq)
                                (idx.encodeBqLocked(self.allocator, vec) catch null)
                            else
                                null;
                            if (idx.insertLockedWithBq(key, vec, timestamp, pre_bq)) |_| {
                                if (pre_bq) |bq| {
                                    action = .{ .upsert = bq };
                                }
                            } else |_| {
                                if (pre_bq) |bq| self.allocator.free(bq);
                                idx.markIncompleteLocked();
                            }
                        } else if (want_bq) {
                            action = .delete;
                        }
                    } else if (want_bq) {
                        action = .delete;
                    }
                } else if (distance.bytesToF32(value) != null) {
                    idx.markIncompleteLocked();
                }
            }
        }

        return action;
    }

    // ╔═══════════════════════════════════════════════════╗
    // ║  Serialization                                     ║
    // ╚═══════════════════════════════════════════════════╝

    /// Magic + subversion marker that begins the HNSW section when
    /// embedded in a snapshot. Distinct from the outer WDBSNAP1/2 magic
    /// so a bare "is there HNSW data here?" check is cheap.
    /// WDBHNSW2 extends WDBHNSW1 with a per-namespace RaBitQ params
    /// trailer (1-byte presence flag, optional centroid + rotation).
    pub const HNSW_MARKER = "WDBHNSW2";

    /// Serialize every namespace index into `writer`:
    ///   [8B HNSW_MARKER]
    ///   [4B ns_count]
    ///   For each namespace (in iteration order):
    ///     [2B ns_len][namespace]
    ///     [NamespaceIndex block via writeToLocked]
    ///
    /// Takes the registry's write lock AND each NamespaceIndex's write
    /// lock for the duration of its block. The enclosing snapshot
    /// machinery holds all shard locks outside of this call, so the
    /// combined window is a consistent point-in-time capture.
    pub fn writeTo(self: *NamespaceRegistry, writer: anytype) !void {
        const w = writer;

        self.lock.lock();
        defer self.lock.unlock();

        try w.writeAll(HNSW_MARKER);

        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, count_buf[0..4], @intCast(self.map.count()), .little);
        try w.writeAll(&count_buf);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const ns = entry.key_ptr.*;
            const idx = entry.value_ptr.*;

            var ns_len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, ns_len_buf[0..2], @intCast(ns.len), .little);
            try w.writeAll(&ns_len_buf);
            try w.writeAll(ns);

            idx.lock.lock();
            defer idx.lock.unlock();
            try idx.writeToLocked(w);
        }
    }

    /// Restore namespaces from a serialized block produced by `writeTo`.
    /// The registry must be empty on entry; populates `self.map` with
    /// newly-constructed NamespaceIndex values owning their own storage.
    ///
    /// `outer_resolve(key)` returns the raw vector bytes for a stored key
    /// (typically a closure over the already-loaded KV store). It is
    /// called during graph reconstruction; the file's key section is
    /// read before the graph so the reader always has the right key in
    /// hand for a given node_id when the resolver runs.
    pub fn readFrom(
        self: *NamespaceRegistry,
        reader: anytype,
        outer_resolve: NamespaceIndex.LocalResolver.OuterResolveFn,
        outer_ctx: *anyopaque,
    ) !void {
        self.lock.lock();
        defer self.lock.unlock();

        var marker_buf: [HNSW_MARKER.len]u8 = undefined;
        try readAllExact(reader, &marker_buf);
        if (!std.mem.eql(u8, &marker_buf, HNSW_MARKER)) return error.CorruptIndex;

        var count_buf: [4]u8 = undefined;
        try readAllExact(reader, &count_buf);
        const ns_count = std.mem.readInt(u32, count_buf[0..4], .little);

        var i: u32 = 0;
        while (i < ns_count) : (i += 1) {
            var ns_len_buf: [2]u8 = undefined;
            try readAllExact(reader, &ns_len_buf);
            const ns_len = std.mem.readInt(u16, ns_len_buf[0..2], .little);
            const ns_copy = try self.allocator.alloc(u8, ns_len);
            errdefer self.allocator.free(ns_copy);
            try readAllExact(reader, ns_copy);

            const idx_ptr = try self.allocator.create(NamespaceIndex);
            errdefer self.allocator.destroy(idx_ptr);
            idx_ptr.* = try NamespaceIndex.readFromLocked(
                self.allocator,
                reader,
                outer_resolve,
                outer_ctx,
            );
            errdefer idx_ptr.deinit();

            try self.map.put(self.allocator, ns_copy, idx_ptr);
            if (ns_copy.len > 0) {
                self.addFirstByteLocked(ns_copy[0]);
            }
            _ = self.active_namespaces.fetchAdd(1, .release);
        }
    }
};

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

const testing = std.testing;

test "registry: getOrCreate is idempotent" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    const a = try reg.getOrCreate("vec:", .cosine);
    const b = try reg.getOrCreate("vec:", .cosine);
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(u32, 1), reg.first_byte_counts['v'].load(.acquire));
    try testing.expect(!reg.mayMatchRegisteredNamespace("kv:1"));
    try testing.expect(reg.mayMatchRegisteredNamespace("vec:1"));

    reg.remove("vec:");
    try testing.expectEqual(@as(u32, 0), reg.first_byte_counts['v'].load(.acquire));
    try testing.expect(!reg.mayMatchRegisteredNamespace("vec:1"));
    try testing.expect(!reg.mayMatchFast("vec:1"));

    // Multiple namespaces sharing byte 0 keep the bitmap bit set until the last is removed.
    _ = try reg.getOrCreate("vec:a:", .cosine);
    _ = try reg.getOrCreate("vec:b:", .cosine);
    try testing.expect(reg.mayMatchFast("vec:anything"));
    reg.remove("vec:a:");
    try testing.expect(reg.mayMatchFast("vec:anything"));
    reg.remove("vec:b:");
    try testing.expect(!reg.mayMatchFast("vec:anything"));
}

test "registry: distinct namespaces get distinct indexes" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    const a = try reg.getOrCreate("vec:articles:", .cosine);
    const b = try reg.getOrCreate("vec:products:", .cosine);
    try testing.expect(a != b);
}

test "registry: get returns null before create" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    try testing.expect(reg.get("vec:") == null);
    _ = try reg.getOrCreate("vec:", .cosine);
    try testing.expect(reg.get("vec:") != null);
}

test "registry: distinct metrics on same namespace error" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    _ = try reg.getOrCreate("vec:", .cosine);
    // Re-request with a different metric — should reject.
    try testing.expectError(
        RegistryError.MetricMismatch,
        reg.getOrCreate("vec:", .l2),
    );
    // Original index still accessible with the original metric.
    const idx = try reg.getOrCreate("vec:", .cosine);
    try testing.expectEqual(Metric.cosine, idx.metric);
}

test "registry: each metric builds independent indexes under different namespaces" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    const a = try reg.getOrCreate("vec:cos:", .cosine);
    const b = try reg.getOrCreate("vec:l2:", .l2);
    const c = try reg.getOrCreate("vec:dot:", .dot);
    try testing.expectEqual(Metric.cosine, a.metric);
    try testing.expectEqual(Metric.l2, b.metric);
    try testing.expectEqual(Metric.dot, c.metric);
}

test "namespace index: insert + search maps ids back to keys" {
    var reg = NamespaceRegistry.init(testing.allocator, .{ .m = 8, .ef_construction = 50 });
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    idx.lock.lock();
    defer idx.lock.unlock();

    const v1 = [_]f32{ 1, 0, 0, 0 };
    const v2 = [_]f32{ 0, 1, 0, 0 };
    const v3 = [_]f32{ 0, 0, 1, 0 };

    const v1_align: []align(1) const f32 = @ptrCast(&v1);
    const v2_align: []align(1) const f32 = @ptrCast(&v2);
    const v3_align: []align(1) const f32 = @ptrCast(&v3);

    _ = try idx.insertLocked("vec:a", v1_align, 100);
    _ = try idx.insertLocked("vec:b", v2_align, 200);
    _ = try idx.insertLocked("vec:c", v3_align, 300);

    var out: [2]IndexSearchResult = undefined;
    var scratch: [2]hnsw_mod.SearchResult = undefined;
    const n = try idx.searchLocked(v1_align, 2, 20, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("vec:a", out[0].key);
    try testing.expectEqual(@as(u64, 100), out[0].timestamp);
    // v1 is its own nearest; dist ≈ 0
    try testing.expect(out[0].dist < 0.001);
}

test "namespace index: clearLocked resets" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    idx.lock.lock();
    defer idx.lock.unlock();

    const v = [_]f32{ 1, 0, 0 };
    const v_align: []align(1) const f32 = @ptrCast(&v);
    _ = try idx.insertLocked("vec:a", v_align, 1);
    try testing.expectEqual(@as(usize, 1), idx.len());

    idx.clearLocked();
    try testing.expectEqual(@as(usize, 0), idx.len());
    try testing.expectEqual(@as(usize, 0), idx.tombstone_count);
    try testing.expect(idx.nodeIdFor("vec:a") == null);
}

test "namespace index: key_to_node map is populated on insert" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    idx.lock.lock();
    defer idx.lock.unlock();

    const a = [_]f32{ 1, 0, 0 };
    const b = [_]f32{ 0, 1, 0 };
    const a_align: []align(1) const f32 = @ptrCast(&a);
    const b_align: []align(1) const f32 = @ptrCast(&b);
    const id_a = try idx.insertLocked("vec:a", a_align, 1);
    const id_b = try idx.insertLocked("vec:b", b_align, 2);

    try testing.expectEqual(id_a, idx.nodeIdFor("vec:a").?);
    try testing.expectEqual(id_b, idx.nodeIdFor("vec:b").?);
    try testing.expect(idx.nodeIdFor("vec:missing") == null);
}

test "namespace index: markTombstoneLocked semantics" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    idx.lock.lock();
    defer idx.lock.unlock();

    const v = [_]f32{ 1, 0, 0 };
    const v_align: []align(1) const f32 = @ptrCast(&v);
    _ = try idx.insertLocked("vec:a", v_align, 1);

    try testing.expectEqual(TombstoneResult.deleted, idx.markTombstoneLocked("vec:a"));
    try testing.expectEqual(@as(usize, 1), idx.tombstone_count);

    // Second call is a no-op.
    try testing.expectEqual(TombstoneResult.noop, idx.markTombstoneLocked("vec:a"));
    try testing.expectEqual(@as(usize, 1), idx.tombstone_count);

    // Unknown key → missing.
    try testing.expectEqual(TombstoneResult.missing, idx.markTombstoneLocked("vec:ghost"));
}

test "namespace index: search excludes tombstoned nodes" {
    // Insert 3 orthogonal-ish vectors, tombstone the closest, then query:
    // the next-closest vector should surface at position 0.
    var reg = NamespaceRegistry.init(testing.allocator, .{ .m = 8, .ef_construction = 50 });
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    idx.lock.lock();
    defer idx.lock.unlock();

    const v_near = [_]f32{ 1, 0.01, 0, 0 };
    const v_mid = [_]f32{ 1, 0.5, 0, 0 };
    const v_far = [_]f32{ 0, 1, 0, 0 };
    const near_a: []align(1) const f32 = @ptrCast(&v_near);
    const mid_a: []align(1) const f32 = @ptrCast(&v_mid);
    const far_a: []align(1) const f32 = @ptrCast(&v_far);

    _ = try idx.insertLocked("vec:near", near_a, 100);
    _ = try idx.insertLocked("vec:mid", mid_a, 200);
    _ = try idx.insertLocked("vec:far", far_a, 300);

    const q = [_]f32{ 1, 0, 0, 0 };
    const q_align: []align(1) const f32 = @ptrCast(&q);

    // Sanity: without tombstones, "vec:near" wins.
    var out: [3]IndexSearchResult = undefined;
    var scratch: [3]hnsw_mod.SearchResult = undefined;
    const n_before = try idx.searchLocked(q_align, 3, 50, &out, &scratch);
    try testing.expectEqual(@as(usize, 3), n_before);
    try testing.expectEqualStrings("vec:near", out[0].key);

    // Tombstone it; next-closest should now lead.
    _ = idx.markTombstoneLocked("vec:near");
    const n_after = try idx.searchLocked(q_align, 3, 50, &out, &scratch);
    // Only 2 live nodes left but we asked for 3 — should return what's available.
    try testing.expectEqual(@as(usize, 2), n_after);
    try testing.expectEqualStrings("vec:mid", out[0].key);
    try testing.expectEqualStrings("vec:far", out[1].key);

    // liveCount reflects the deletion.
    try testing.expectEqual(@as(usize, 2), idx.liveCount());
    try testing.expectEqual(@as(usize, 3), idx.len());
}

test "namespace index: expectedDim is null before any insert" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    try testing.expect(idx.expectedDim() == null);
}

test "namespace index: dim freezes on first insert" {
    var reg = NamespaceRegistry.init(testing.allocator, .{ .m = 4, .ef_construction = 30 });
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    idx.lock.lock();
    defer idx.lock.unlock();

    const v = [_]f32{ 1, 0, 0, 0 };
    const v_align: []align(1) const f32 = @ptrCast(&v);
    _ = try idx.insertLocked("vec:a", v_align, 1);

    try testing.expectEqual(@as(?usize, 4), idx.dim);
}

test "namespace index: insertLocked rejects mismatched dim" {
    var reg = NamespaceRegistry.init(testing.allocator, .{ .m = 4, .ef_construction = 30 });
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    idx.lock.lock();
    defer idx.lock.unlock();

    const v4 = [_]f32{ 1, 0, 0, 0 };
    const v3 = [_]f32{ 1, 0, 0 };
    const v4_align: []align(1) const f32 = @ptrCast(&v4);
    const v3_align: []align(1) const f32 = @ptrCast(&v3);

    _ = try idx.insertLocked("vec:a", v4_align, 1);
    try testing.expectError(
        RegistryError.DimensionMismatch,
        idx.insertLocked("vec:b", v3_align, 2),
    );
    // Failed insert must not have corrupted the graph: count unchanged.
    try testing.expectEqual(@as(usize, 1), idx.len());
}

test "namespace index: clearLocked resets dim for rebuild under new dim" {
    var reg = NamespaceRegistry.init(testing.allocator, .{ .m = 4, .ef_construction = 30 });
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:", .cosine);
    idx.lock.lock();
    defer idx.lock.unlock();

    const v4 = [_]f32{ 1, 0, 0, 0 };
    const v3 = [_]f32{ 1, 0, 0 };
    const v4_align: []align(1) const f32 = @ptrCast(&v4);
    const v3_align: []align(1) const f32 = @ptrCast(&v3);

    _ = try idx.insertLocked("vec:a", v4_align, 1);
    try testing.expectEqual(@as(?usize, 4), idx.dim);

    idx.clearLocked();
    try testing.expect(idx.dim == null);

    // A different dim is now acceptable after clear.
    _ = try idx.insertLocked("vec:b", v3_align, 2);
    try testing.expectEqual(@as(?usize, 3), idx.dim);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Registry serialization tests                      ║
// ╚═══════════════════════════════════════════════════╝

const RegSerdeHarness = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    const Writer = struct {
        h: *RegSerdeHarness,
        alloc: std.mem.Allocator,
        pub fn writeAll(self: *@This(), data: []const u8) !void {
            try self.h.buf.appendSlice(self.alloc, data);
        }
    };

    const Reader = struct {
        h: *RegSerdeHarness,
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

/// Key-based resolver for the serde test: maps a stored vec key to its
/// original bytes. Simulates the KV-lookup path the real snapshot layer
/// will provide.
const KeyResolver = struct {
    map: *std.StringHashMapUnmanaged([]const u8),
    fn resolve(raw_ctx: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *KeyResolver = @ptrCast(@alignCast(raw_ctx));
        return self.map.get(key);
    }
};

test "registry: writeTo/readFrom roundtrip preserves indexes" {
    const alloc = testing.allocator;

    // Build a registry with two namespaces, different metrics.
    var src_reg = NamespaceRegistry.init(alloc, .{ .m = 4, .ef_construction = 50 });
    defer src_reg.deinit();

    // Store the vector bytes so the reader can look them up by key.
    var key_to_bytes: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer key_to_bytes.deinit(alloc);

    const v1 = [_]f32{ 1, 0, 0, 0 };
    const v2 = [_]f32{ 0, 1, 0, 0 };
    const v3 = [_]f32{ 0, 0, 1, 0 };

    const v1_bytes_ptr: [*]const u8 = @ptrCast(&v1);
    const v2_bytes_ptr: [*]const u8 = @ptrCast(&v2);
    const v3_bytes_ptr: [*]const u8 = @ptrCast(&v3);
    const v1_bytes = v1_bytes_ptr[0 .. 4 * @sizeOf(f32)];
    const v2_bytes = v2_bytes_ptr[0 .. 4 * @sizeOf(f32)];
    const v3_bytes = v3_bytes_ptr[0 .. 4 * @sizeOf(f32)];

    try key_to_bytes.put(alloc, "vec:a", v1_bytes);
    try key_to_bytes.put(alloc, "vec:b", v2_bytes);
    try key_to_bytes.put(alloc, "vec:articles:x", v3_bytes);

    const v1_align: []align(1) const f32 = @ptrCast(&v1);
    const v2_align: []align(1) const f32 = @ptrCast(&v2);
    const v3_align: []align(1) const f32 = @ptrCast(&v3);

    {
        const idx = try src_reg.getOrCreate("vec:", .cosine);
        idx.lock.lock();
        defer idx.lock.unlock();
        _ = try idx.insertLocked("vec:a", v1_align, 1000);
        _ = try idx.insertLocked("vec:b", v2_align, 2000);
        _ = idx.markTombstoneLocked("vec:b");
    }
    {
        const idx = try src_reg.getOrCreate("vec:articles:", .l2);
        idx.lock.lock();
        defer idx.lock.unlock();
        _ = try idx.insertLocked("vec:articles:x", v3_align, 3000);
    }

    // Serialize.
    var harness = RegSerdeHarness{};
    defer harness.buf.deinit(alloc);
    var writer = RegSerdeHarness.Writer{ .h = &harness, .alloc = alloc };
    try src_reg.writeTo(&writer);

    // Deserialize into a fresh registry.
    var dst_reg = NamespaceRegistry.init(alloc, .{ .m = 4, .ef_construction = 50 });
    defer dst_reg.deinit();

    var resolver = KeyResolver{ .map = &key_to_bytes };
    var reader = RegSerdeHarness.Reader{ .h = &harness };
    try dst_reg.readFrom(&reader, KeyResolver.resolve, @ptrCast(&resolver));

    // Validate structure.
    const vec_idx = dst_reg.get("vec:").?;
    const articles_idx = dst_reg.get("vec:articles:").?;
    try testing.expectEqual(Metric.cosine, vec_idx.metric);
    try testing.expectEqual(Metric.l2, articles_idx.metric);
    try testing.expectEqual(@as(usize, 2), vec_idx.len());
    try testing.expectEqual(@as(usize, 1), vec_idx.tombstone_count);
    try testing.expect(vec_idx.isTombstoned(vec_idx.nodeIdFor("vec:b").?));
    try testing.expect(!vec_idx.isTombstoned(vec_idx.nodeIdFor("vec:a").?));
    try testing.expectEqual(@as(u64, 1000), vec_idx.timestamps.items[vec_idx.nodeIdFor("vec:a").?]);
    try testing.expectEqual(@as(usize, 1), articles_idx.len());

    // Dim should have been derived from the first resolvable vector
    // during readFromLocked — both namespaces used 4-dim vectors.
    try testing.expectEqual(@as(?usize, 4), vec_idx.dim);
    try testing.expectEqual(@as(?usize, 4), articles_idx.dim);
}

test "registry: writeTo/readFrom preserves installed RabitqParams" {
    const alloc = testing.allocator;

    var src_reg = NamespaceRegistry.init(alloc, .{ .m = 4, .ef_construction = 50 });
    defer src_reg.deinit();

    var key_to_bytes: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer key_to_bytes.deinit(alloc);

    const v = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    const v_bytes_ptr: [*]const u8 = @ptrCast(&v);
    const v_bytes = v_bytes_ptr[0 .. 4 * @sizeOf(f32)];
    try key_to_bytes.put(alloc, "vec:x", v_bytes);

    const v_align: []align(1) const f32 = @ptrCast(&v);

    {
        const idx = try src_reg.getOrCreate("vec:", .l2);
        idx.lock.lock();
        defer idx.lock.unlock();
        _ = try idx.insertLocked("vec:x", v_align, 42);

        // Install a handcrafted RabitqParams so the serde is exercised
        // end-to-end without requiring the vrabitq procedure.
        const centroid = try idx.allocator.alloc(f32, 4);
        centroid[0] = 0.5;
        centroid[1] = 0.5;
        centroid[2] = 0.5;
        centroid[3] = 0.5;
        const rotation = try rabitq_mod.generateRotation(idx.allocator, 4, 0x9999);
        const p = try idx.allocator.create(RabitqParams);
        p.* = .{
            .allocator = idx.allocator,
            .centroid = centroid,
            .rotation = rotation,
            .dim = 4,
            .seed = 0x9999,
        };
        try idx.setRabitqParams(p);
    }

    // Serialize.
    var harness = RegSerdeHarness{};
    defer harness.buf.deinit(alloc);
    var writer = RegSerdeHarness.Writer{ .h = &harness, .alloc = alloc };
    try src_reg.writeTo(&writer);

    // Deserialize into a fresh registry.
    var dst_reg = NamespaceRegistry.init(alloc, .{ .m = 4, .ef_construction = 50 });
    defer dst_reg.deinit();

    var resolver = KeyResolver{ .map = &key_to_bytes };
    var reader = RegSerdeHarness.Reader{ .h = &harness };
    try dst_reg.readFrom(&reader, KeyResolver.resolve, @ptrCast(&resolver));

    const restored = dst_reg.get("vec:").?;
    try testing.expect(restored.rabitq_params != null);
    const rp = restored.rabitq_params.?;
    try testing.expectEqual(@as(u32, 4), rp.dim);
    try testing.expectEqual(@as(u64, 0x9999), rp.seed);
    try testing.expectEqual(@as(usize, 4), rp.centroid.len);
    try testing.expectEqual(@as(usize, 16), rp.rotation.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rp.centroid[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), rp.centroid[3], 1e-6);

    // Rotation should be identical bit-for-bit given deterministic seed.
    const expected_rotation = try rabitq_mod.generateRotation(alloc, 4, 0x9999);
    defer alloc.free(expected_rotation);
    for (rp.rotation, expected_rotation) |got, want| {
        try testing.expectApproxEqAbs(want, got, 1e-7);
    }
}

test "insertLocked ignores writes older than the stored timestamp" {
    var idx = NamespaceIndex.init(testing.allocator, .{ .m = 4, .ef_construction = 20 }, .cosine);
    defer idx.deinit();

    const v_newer = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const v_older = [_]f32{ 0.0, 1.0, 0.0, 0.0 };

    const id_newer = try idx.insertLocked("vec:k1", &v_newer, 200);
    const id_older = try idx.insertLocked("vec:k1", &v_older, 100);

    try testing.expectEqual(id_newer, id_older);
    try testing.expectEqual(@as(usize, 1), idx.liveCount());
    try testing.expectEqual(@as(usize, 0), idx.tombstone_count);
    try testing.expectEqual(@as(u64, 200), idx.timestamps.items[id_newer]);
    try testing.expectApproxEqAbs(@as(f32, 1.0), idx.hnsw.getVector(id_newer)[0], 1e-6);
}

test "insertLocked identical-write idempotence under cosine unit-normalization" {
    var idx = NamespaceIndex.init(testing.allocator, .{ .m = 4, .ef_construction = 20 }, .cosine);
    defer idx.deinit();

    // Non-unit vector: HNSW stores [0.6, 0.8, 0, 0] internally under `.cosine`
    const v_raw = [_]f32{ 3.0, 4.0, 0.0, 0.0 };
    const v_scaled = [_]f32{ 6.0, 8.0, 0.0, 0.0 };
    const v_diff = [_]f32{ 0.0, 5.0, 0.0, 0.0 };

    const id1 = try idx.insertLocked("vec:k1", &v_raw, 100);
    // Re-inserting identical raw bytes must NOT tombstone (idempotent timestamp refresh)
    const id2 = try idx.insertLocked("vec:k1", &v_raw, 200);
    try testing.expectEqual(id1, id2);
    try testing.expectEqual(@as(usize, 1), idx.len());
    try testing.expectEqual(@as(usize, 1), idx.liveCount());
    try testing.expectEqual(@as(usize, 0), idx.tombstone_count);
    try testing.expectEqual(@as(u64, 200), idx.timestamps.items[id1]);
    try testing.expectApproxEqAbs(@as(f32, 0.6), idx.hnsw.getVector(id1)[0], 1e-6);

    // Different raw bytes (even same direction) still tombstone old node and append new node
    const id3 = try idx.insertLocked("vec:k1", &v_scaled, 300);
    try testing.expect(id3 != id1);
    try testing.expectEqual(@as(usize, 1), idx.tombstone_count);
    try testing.expectEqual(@as(usize, 1), idx.liveCount());

    const id4 = try idx.insertLocked("vec:k1", &v_diff, 400);
    try testing.expect(id4 != id3);
    try testing.expectEqual(@as(usize, 2), idx.tombstone_count);
    try testing.expectEqual(@as(usize, 1), idx.liveCount());
}

test "namespace index: overwrite + post-tombstone reinsert keeps BQ, RaBitQ FastScan32, and exact slabs consistent" {
    const alloc = testing.allocator;
    const dim: usize = 32;

    var idx = NamespaceIndex.init(alloc, .{ .m = 8, .ef_construction = 40 }, .l2);
    defer idx.deinit();

    // Insert 40 vectors (>32 so FastScan32 packs a full 32-vector block + 8-vector tail).
    var vecs: [40][dim]f32 = undefined;
    var key_buf: [32]u8 = undefined;
    for (0..40) |i| {
        for (0..dim) |d| {
            vecs[i][d] = if (d == i % dim) 2.0 + @as(f32, @floatFromInt(i)) * 0.01 else 0.05 * @as(f32, @floatFromInt((i + d) % 5));
        }
        const k = std.fmt.bufPrint(&key_buf, "vec:n{d}", .{i}) catch unreachable;
        _ = try idx.insertLocked(k, &vecs[i], 100 + i);
    }
    try testing.expectEqual(@as(usize, 40), idx.liveCount());
    try testing.expect(idx.canUseBqSlabLocked(dim));

    // Overwrite live key vec:n0 with a completely different vector (aligned with dim 15).
    var v_over: [dim]f32 = @splat(0.0);
    v_over[15] = 10.0;
    _ = try idx.insertLocked("vec:n0", &v_over, 500);
    try testing.expectEqual(@as(usize, 40), idx.liveCount());
    try testing.expectEqual(@as(usize, 1), idx.tombstone_count);

    // Tombstone vec:n1, then reinsert vec:n1 with a vector aligned with dim 31.
    try testing.expectEqual(TombstoneResult.deleted, idx.markTombstoneLocked("vec:n1"));
    try testing.expectEqual(@as(usize, 39), idx.liveCount());
    var v_reinsert: [dim]f32 = @splat(0.0);
    v_reinsert[31] = 10.0;
    _ = try idx.insertLocked("vec:n1", &v_reinsert, 600);
    try testing.expectEqual(@as(usize, 40), idx.liveCount());
    try testing.expectEqual(@as(usize, 2), idx.tombstone_count);

    // Verify legacy BQ slab + rerank finds vec:n0 first for v_over and never emits duplicate keys.
    var out: [10]IndexScoredResult = undefined;
    const bq_res = (try idx.searchBqLocked(&v_over, null, 10, 4, .l2, 0.0, 0, 24.0, true, &out, alloc)).?;
    try testing.expect(!bq_res.needs_kv_rerank);
    try testing.expectEqual(@as(usize, 10), bq_res.count);
    try testing.expectEqualStrings("vec:n0", out[0].key);
    for (0..bq_res.count) |a| {
        for (a + 1..bq_res.count) |b| {
            try testing.expect(!std.mem.eql(u8, out[a].key, out[b].key));
        }
    }

    // Verify exact slab finds vec:n1 first for v_reinsert and no duplicates.
    const exact_n = try idx.searchExactLocked(&v_reinsert, null, 10, .l2, 0.0, 0, 24.0, &out, alloc);
    try testing.expectEqual(@as(usize, 10), exact_n);
    try testing.expectEqualStrings("vec:n1", out[0].key);
    for (0..exact_n) |a| {
        for (a + 1..exact_n) |b| {
            try testing.expect(!std.mem.eql(u8, out[a].key, out[b].key));
        }
    }

    // Install RaBitQ params + populate slab, then overwrite vec:n2 and verify FastScan32 + tail consistency.
    const centroid = try alloc.alloc(f32, dim);
    @memset(centroid, 0.25);
    const rotation = try rabitq_mod.generateRotation(alloc, dim, 0x123456);
    const params = try alloc.create(RabitqParams);
    params.* = .{
        .allocator = alloc,
        .centroid = centroid,
        .rotation = rotation,
        .dim = dim,
        .seed = 0x123456,
    };
    try idx.setRabitqParams(params);
    try idx.installRabitqSlabFromEncodedLocked(params, &.{});
    try testing.expect(idx.canUseRabitqSlabLocked(dim));

    var v_rq_over: [dim]f32 = @splat(0.0);
    v_rq_over[7] = 12.0;
    _ = try idx.insertLocked("vec:n2", &v_rq_over, 700);
    try testing.expectEqual(@as(usize, 40), idx.liveCount());

    const rq_res = (try idx.searchRabitqLocked(&v_rq_over, null, 10, 4, .l2, 0.0, 0, 24.0, true, &out, alloc)).?;
    try testing.expect(!rq_res.needs_kv_rerank);
    try testing.expectEqual(@as(usize, 10), rq_res.count);
    try testing.expectEqualStrings("vec:n2", out[0].key);
    for (0..rq_res.count) |a| {
        for (a + 1..rq_res.count) |b| {
            try testing.expect(!std.mem.eql(u8, out[a].key, out[b].key));
        }
    }
}

test "namespace index: ShardedRwLock concurrent readers + writer stress" {
    if (single_threaded) return;

    const alloc = testing.allocator;
    const dim: usize = 16;
    var idx = NamespaceIndex.init(alloc, .{ .m = 8, .ef_construction = 32 }, .cosine);
    defer idx.deinit();

    // Seed initial vectors.
    var seed_key: [32]u8 = undefined;
    for (0..64) |i| {
        var v: [dim]f32 = undefined;
        for (0..dim) |d| v[d] = @as(f32, @floatFromInt(((i * 7 + d * 3) % 19) + 1)) * 0.1;
        const k = std.fmt.bufPrint(&seed_key, "vec:s{d}", .{i}) catch unreachable;
        _ = try idx.insertLocked(k, &v, 10 + i);
    }

    var stop = std.atomic.Value(bool).init(false);
    var reader_err = std.atomic.Value(bool).init(false);

    const ReaderCtx = struct {
        idx: *NamespaceIndex,
        stop: *std.atomic.Value(bool),
        err: *std.atomic.Value(bool),
        tid: usize,
    };

    const readerFn = struct {
        fn run(rc: ReaderCtx) void {
            var q: [dim]f32 = undefined;
            for (0..dim) |d| q[d] = @as(f32, @floatFromInt(((rc.tid + d) % 7) + 1)) * 0.2;
            var hnsw_out: [8]IndexSearchResult = undefined;
            var hnsw_scratch: [8]hnsw_mod.SearchResult = undefined;
            var slab_out: [8]IndexScoredResult = undefined;
            var iter: usize = 0;
            while (!rc.stop.load(.acquire) or iter < 32) : (iter += 1) {
                rc.idx.lock.lockShared();
                defer rc.idx.lock.unlockShared();
                const n = rc.idx.searchLocked(&q, 5, 24, &hnsw_out, &hnsw_scratch) catch {
                    rc.err.store(true, .release);
                    return;
                };
                if (n == 0) {
                    rc.err.store(true, .release);
                    return;
                }
                if ((iter & 1) == 0 and rc.idx.canUseBqSlabLocked(dim)) {
                    _ = rc.idx.searchBqLocked(&q, null, 5, 4, .cosine, 0.0, 0, 24.0, true, &slab_out, std.heap.page_allocator) catch {
                        rc.err.store(true, .release);
                        return;
                    };
                } else if (rc.idx.canUseExactSlabLocked(dim, .cosine)) {
                    _ = rc.idx.searchExactLocked(&q, null, 5, .cosine, 0.0, 0, 24.0, &slab_out, std.heap.page_allocator) catch {
                        rc.err.store(true, .release);
                        return;
                    };
                }
            }
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    for (0..threads.len) |t| {
        threads[t] = try std.Thread.spawn(.{}, readerFn, .{ReaderCtx{
            .idx = &idx,
            .stop = &stop,
            .err = &reader_err,
            .tid = t,
        }});
    }

    // Concurrent writer performing inserts, overwrites, and tombstones.
    var wkey: [32]u8 = undefined;
    for (0..48) |w| {
        var v: [dim]f32 = undefined;
        for (0..dim) |d| v[d] = @as(f32, @floatFromInt(((w * 5 + d) % 13) + 1)) * 0.15;
        const k = std.fmt.bufPrint(&wkey, "vec:w{d}", .{w % 24}) catch unreachable;
        idx.lock.lock();
        _ = idx.insertLocked(k, &v, 200 + w) catch {
            idx.lock.unlock();
            stop.store(true, .release);
            for (threads) |th| th.join();
            return error.TestUnexpectedResult;
        };
        if (w % 6 == 0) {
            const dk = std.fmt.bufPrint(&wkey, "vec:s{d}", .{w % 16}) catch unreachable;
            _ = idx.markTombstoneLocked(dk);
        }
        idx.lock.unlock();
    }

    stop.store(true, .release);
    for (threads) |th| th.join();
    try testing.expect(!reader_err.load(.acquire));
    try testing.expect(idx.liveCount() >= 64);
}

test "vector slab helpers: blockLessThanMask32 lane order and NaN/inf rejection" {
    var d2: [32]f32 align(64) = @splat(10.0);
    d2[0] = 1.0;
    d2[7] = 2.0;
    d2[15] = 4.99;
    d2[16] = 5.0; // equal -> MUST be rejected (strict `<`)
    d2[17] = -3.0;
    d2[24] = std.math.nan(f32);
    d2[25] = std.math.inf(f32);
    d2[26] = -std.math.inf(f32);
    d2[31] = 0.0;

    const mask = blockLessThanMask32(&d2, 5.0);
    const expected: u32 = (@as(u32, 1) << 0) | (@as(u32, 1) << 7) | (@as(u32, 1) << 15) |
        (@as(u32, 1) << 17) | (@as(u32, 1) << 26) | (@as(u32, 1) << 31);
    try testing.expectEqual(expected, mask);

    // Threshold +inf accepts all finite and -inf values, rejects NaN and +inf.
    const inf_mask = blockLessThanMask32(&d2, std.math.inf(f32));
    try testing.expect((inf_mask & (@as(u32, 1) << 24)) == 0); // NaN rejected
    try testing.expect((inf_mask & (@as(u32, 1) << 25)) == 0); // +inf rejected
    try testing.expect((inf_mask & (@as(u32, 1) << 16)) != 0); // finite 5.0 accepted
    try testing.expect((inf_mask & (@as(u32, 1) << 26)) != 0); // -inf accepted
}

test "vector slab helpers: branchlessSelectKSoa and nthElementSoaInPlace across ties and edge sizes" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5E1E_C701);
    const rand = prng.random();

    const Pattern = enum { random, sorted, reversed, all_equal, heavy_ties };
    const sizes = [_]usize{ 1, 2, 16, 17, 64, 512, 1200 };

    for (sizes) |n| {
        const ks = [_]usize{ 1, @max(@as(usize, 1), n / 2), n };
        for ([_]Pattern{ .random, .sorted, .reversed, .all_equal, .heavy_ties }) |pat| {
            const orig_d = try alloc.alloc(f32, n);
            defer alloc.free(orig_d);
            const orig_i = try alloc.alloc(u32, n);
            defer alloc.free(orig_i);
            const sorted_ref = try alloc.alloc(f32, n);
            defer alloc.free(sorted_ref);

            for (0..n) |i| {
                orig_i[i] = @intCast(i);
                orig_d[i] = switch (pat) {
                    .random => rand.float(f32) * 100.0 - 20.0,
                    .sorted => @floatFromInt(i),
                    .reversed => @floatFromInt(n - 1 - i),
                    .all_equal => 3.5,
                    .heavy_ties => @floatFromInt(i % 4),
                };
            }
            @memcpy(sorted_ref, orig_d);
            std.mem.sort(f32, sorted_ref, {}, std.sort.asc(f32));

            const work_d = try alloc.alloc(f32, n);
            defer alloc.free(work_d);
            const work_i = try alloc.alloc(u32, n);
            defer alloc.free(work_i);

            for (ks) |k| {
                @memcpy(work_d, orig_d);
                @memcpy(work_i, orig_i);
                const thr = branchlessSelectKSoa(work_d, work_i, k, alloc);
                try testing.expectEqual(sorted_ref[k - 1], thr);

                // Every selected item must match its original distance and be <= thr, with no duplicate IDs.
                var seen = try std.bit_set.Dynamic.initEmpty(alloc, n);
                defer seen.deinit(alloc);
                for (0..k) |j| {
                    try testing.expect(work_d[j] <= thr);
                    try testing.expectEqual(orig_d[work_i[j]], work_d[j]);
                    try testing.expect(!seen.isSet(work_i[j]));
                    seen.set(work_i[j]);
                }

                // Also verify in-place OOM fallback.
                @memcpy(work_d, orig_d);
                @memcpy(work_i, orig_i);
                const thr_ip = nthElementSoaInPlace(work_d, work_i, k - 1);
                try testing.expectEqual(sorted_ref[k - 1], thr_ip);
                for (0..k) |j| {
                    try testing.expect(work_d[j] <= thr_ip);
                    try testing.expectEqual(orig_d[work_i[j]], work_d[j]);
                }
            }
        }
    }
}

test "namespace index: large-M RaBitQ batched select and BQ counting-bucket parity with tombstones and exclude_id" {
    const alloc = testing.allocator;
    const dim: usize = 32;
    const N: usize = 1300; // > RABITQ_SEL_STACK_CAP (1024) so batched compaction fires!

    var idx = NamespaceIndex.init(alloc, .{ .m = 8, .ef_construction = 32 }, .cosine);
    defer idx.deinit();

    var prng = std.Random.DefaultPrng.init(0xB0C4_E701);
    const rand = prng.random();
    const corpus = try alloc.alloc(f32, N * dim);
    defer alloc.free(corpus);
    for (corpus) |*x| x.* = rand.floatNorm(f32);

    // Make vector 1250 nearly identical to query and vector 1251 identical to vector 1250.
    var query: [dim]f32 = undefined;
    for (&query) |*x| x.* = rand.floatNorm(f32);
    @memcpy(corpus[1250 * dim ..][0..dim], &query);
    @memcpy(corpus[1251 * dim ..][0..dim], &query);

    var key_buf: [32]u8 = undefined;
    for (0..N) |i| {
        const k = std.fmt.bufPrint(&key_buf, "vec:t:{d}", .{i}) catch unreachable;
        _ = try idx.insertLocked(k, corpus[i * dim ..][0..dim], 1000 + i);
    }

    // 1. Legacy BQ slab without filters (fast path): rerank=true (M=200) and rerank=false (top_k=10).
    var out10: [10]IndexScoredResult = undefined;
    const bq_rr = (try idx.searchBqLocked(&query, null, 10, 20, .cosine, 0.0, 0, 24.0, true, &out10, alloc)).?;
    try testing.expect(!bq_rr.needs_kv_rerank);
    try testing.expectEqual(@as(usize, 10), bq_rr.count);
    try testing.expect(std.mem.eql(u8, out10[0].key, "vec:t:1250") or std.mem.eql(u8, out10[0].key, "vec:t:1251"));
    try testing.expectApproxEqAbs(@as(f32, 1.0), out10[0].score, 1e-4);

    // Pure BQ (rerank=false) must be sorted descending by score (ascending Hamming) and match exact Hamming cutoff.
    const bq_pure = (try idx.searchBqLocked(&query, null, 10, 1, .cosine, 0.0, 0, 24.0, false, &out10, alloc)).?;
    try testing.expectEqual(@as(usize, 10), bq_pure.count);
    for (1..bq_pure.count) |j| {
        try testing.expect(out10[j - 1].score >= out10[j].score);
    }
    try testing.expectApproxEqAbs(@as(f32, 1.0), out10[0].score, 1e-6);

    // 2. Legacy BQ with exclude_id=1250 and tombstone=1251: neither may appear.
    const ex_id = idx.nodeIdFor("vec:t:1250").?;
    try testing.expectEqual(TombstoneResult.deleted, idx.markTombstoneLocked("vec:t:1251"));
    const bq_filt = (try idx.searchBqLocked(&query, ex_id, 10, 20, .cosine, 0.0, 0, 24.0, true, &out10, alloc)).?;
    try testing.expectEqual(@as(usize, 10), bq_filt.count);
    for (out10[0..bq_filt.count]) |r| {
        try testing.expect(!std.mem.eql(u8, r.key, "vec:t:1250"));
        try testing.expect(!std.mem.eql(u8, r.key, "vec:t:1251"));
    }

    // 3. Install RaBitQ slab and test BOTH unfiltered (AVX-512 compress path) and filtered large-M selection!
    // Reset tombstone on a fresh index for clean unfiltered test, then tombstone for filtered test.
    var rq_idx = NamespaceIndex.init(alloc, .{ .m = 8, .ef_construction = 32 }, .cosine);
    defer rq_idx.deinit();
    for (0..N) |i| {
        const k = std.fmt.bufPrint(&key_buf, "vec:r:{d}", .{i}) catch unreachable;
        _ = try rq_idx.insertLocked(k, corpus[i * dim ..][0..dim], 1000 + i);
    }

    const centroid = try alloc.alloc(f32, dim);
    @memset(centroid, 0.0);
    for (0..N) |i| {
        const v = rq_idx.hnsw.getVector(@intCast(i));
        for (0..dim) |d| centroid[d] += v[d];
    }
    for (centroid) |*c| c.* /= @as(f32, @floatFromInt(N));
    const rot = try rabitq_mod.generateRotation(alloc, dim, 0xCAFE);
    const params = try alloc.create(RabitqParams);
    params.* = .{ .allocator = alloc, .centroid = centroid, .rotation = rot, .dim = dim, .seed = 0xCAFE };
    try rq_idx.setRabitqParams(params);
    try rq_idx.installRabitqSlabFromEncodedLocked(params, &.{});

    // Unfiltered large-M rerank=true (stage1_k=200 -> triggers AVX-512 compress + compaction over N=1300).
    const rq_rr = (try rq_idx.searchRabitqLocked(&query, null, 10, 20, .cosine, 0.0, 0, 24.0, true, &out10, alloc)).?;
    try testing.expect(!rq_rr.needs_kv_rerank);
    try testing.expectEqual(@as(usize, 10), rq_rr.count);
    try testing.expect(std.mem.eql(u8, out10[0].key, "vec:r:1250") or std.mem.eql(u8, out10[0].key, "vec:r:1251"));
    try testing.expectApproxEqAbs(@as(f32, 1.0), out10[0].score, 1e-4);

    // Unfiltered large-M rerank=false (stage1_k=64 -> exercises sorted non-rerank path).
    var out64: [64]IndexScoredResult = undefined;
    const rq_pure64 = (try rq_idx.searchRabitqLocked(&query, null, 64, 1, .cosine, 0.0, 0, 24.0, false, &out64, alloc)).?;
    try testing.expectEqual(@as(usize, 64), rq_pure64.count);
    for (1..rq_pure64.count) |j| {
        try testing.expect(out64[j - 1].score >= out64[j].score);
    }

    // Filtered large-M rerank=true (tombstone 1251 + exclude_id 1250 -> neither may appear).
    const rq_ex = rq_idx.nodeIdFor("vec:r:1250").?;
    try testing.expectEqual(TombstoneResult.deleted, rq_idx.markTombstoneLocked("vec:r:1251"));
    const rq_filt = (try rq_idx.searchRabitqLocked(&query, rq_ex, 10, 20, .cosine, 0.0, 0, 24.0, true, &out10, alloc)).?;
    try testing.expectEqual(@as(usize, 10), rq_filt.count);
    for (out10[0..rq_filt.count]) |r| {
        try testing.expect(!std.mem.eql(u8, r.key, "vec:r:1250"));
        try testing.expect(!std.mem.eql(u8, r.key, "vec:r:1251"));
    }
}

test "namespace index: failed batch insert keeps node ids aligned with keys" {
    const alloc = testing.allocator;
    const dim: usize = 16;
    const n_a: usize = 64;
    const n_b: usize = 300;
    const n_c: usize = 100;
    const n_total = n_a + n_b + n_c;

    var prng = std.Random.DefaultPrng.init(0xFA11_BA7C);
    const rand = prng.random();
    const data = try alloc.alloc(f32, n_total * dim);
    defer alloc.free(data);
    for (data) |*x| x.* = rand.floatNorm(f32);

    const key_store = try alloc.alloc([16]u8, n_total);
    defer alloc.free(key_store);
    const items = try alloc.alloc(NamespaceIndex.BatchInsertItem, n_total);
    defer alloc.free(items);
    for (0..n_total) |i| {
        const tag: u8 = if (i < n_a) 'a' else if (i < n_a + n_b) 'b' else 'c';
        const rel: usize = if (i < n_a) i else if (i < n_a + n_b) i - n_a else i - n_a - n_b;
        const k = std.fmt.bufPrint(&key_store[i], "vec:{c}{d}", .{ tag, rel }) catch unreachable;
        items[i] = .{ .key = k, .vector = data[i * dim ..][0..dim], .timestamp = 100 + i };
    }
    const batch_a = items[0..n_a];
    const batch_b = items[n_a .. n_a + n_b];
    const batch_c = items[n_a + n_b ..];
    // First item of batch B overwrites a live key from batch A with a new vector.
    batch_b[0].key = batch_a[0].key;

    var idx = NamespaceIndex.init(alloc, .{ .m = 8, .ef_construction = 64 }, .l2);
    defer idx.deinit();

    try testing.expectEqual(n_a, try idx.insertBatchLocked(batch_a));
    try testing.expectEqual(n_a, idx.hnsw.len());

    // Fail while linking the 101st node of batch B. On the parallel path every node
    // of the batch is already appended; on the sequential fallback only the first 101.
    idx.hnsw.fail_link_node_for_test = @intCast(n_a + 100);
    try testing.expectError(error.OutOfMemory, idx.insertBatchLocked(batch_b));
    idx.hnsw.fail_link_node_for_test = null;

    const appended = idx.hnsw.len() - n_a;
    try testing.expect(appended >= 101 and appended <= n_b);
    try testing.expectEqual(idx.hnsw.len(), idx.keys.items.len);
    try testing.expectEqual(idx.hnsw.len(), idx.timestamps.items.len);
    try testing.expectEqual(idx.hnsw.len(), idx.vec_hashes.items.len);
    // Every appended node is tombstoned, as is the live node `vec:a0` it superseded.
    try testing.expectEqual(appended + 1, idx.tombstone_count);
    try testing.expectEqual(n_a - 1, idx.liveCount());
    try testing.expect(!idx.complete_with_store);
    for (n_a..idx.hnsw.len()) |id| try testing.expect(idx.tombstones.isSet(id));

    var out: [10]IndexSearchResult = undefined;
    var scratch: [10]hnsw_mod.SearchResult = undefined;

    // Surviving keys are still found; nothing from the failed batch is returned.
    var n = try idx.searchLocked(batch_a[5].vector, 10, 256, &out, &scratch);
    try testing.expect(n > 0);
    try testing.expectEqualStrings("vec:a5", out[0].key);
    for ([_]usize{ 0, 7, 150, 299 }) |bi| {
        n = try idx.searchLocked(batch_b[bi].vector, 10, 256, &out, &scratch);
        for (out[0..n]) |r| {
            try testing.expect(!std.mem.startsWith(u8, r.key, "vec:b"));
            try testing.expect(!std.mem.eql(u8, r.key, "vec:a0"));
        }
    }

    // A later batch gets ids that map back to its own keys.
    try testing.expectEqual(n_c, try idx.insertBatchLocked(batch_c));
    try testing.expectEqual(idx.hnsw.len(), idx.keys.items.len);
    for ([_]usize{ 0, 7, 99 }) |ci| {
        n = try idx.searchLocked(batch_c[ci].vector, 10, 256, &out, &scratch);
        try testing.expect(n > 0);
        try testing.expectEqualStrings(batch_c[ci].key, out[0].key);
        const nid = idx.nodeIdFor(batch_c[ci].key).?;
        try testing.expectEqualStrings(batch_c[ci].key, idx.keys.items[nid]);
        try testing.expect(!idx.tombstones.isSet(nid));
    }

    // Retrying the failed batch succeeds and its keys become searchable.
    try testing.expectEqual(n_b, try idx.insertBatchLocked(batch_b));
    try testing.expectEqual(idx.hnsw.len(), idx.keys.items.len);
    try testing.expectEqual(n_a - 1 + n_c + n_b, idx.liveCount());
    for ([_]usize{ 0, 7, 150, 299 }) |bi| {
        n = try idx.searchLocked(batch_b[bi].vector, 10, 256, &out, &scratch);
        try testing.expect(n > 0);
        try testing.expectEqualStrings(batch_b[bi].key, out[0].key);
    }
}

test "namespace index: failed single insert keeps node ids aligned with keys" {
    const alloc = testing.allocator;
    const dim: usize = 8;

    var idx = NamespaceIndex.init(alloc, .{ .m = 8, .ef_construction = 40 }, .l2);
    defer idx.deinit();

    var vecs: [6][dim]f32 = undefined;
    var key_buf: [16]u8 = undefined;
    for (0..6) |i| {
        for (0..dim) |d| vecs[i][d] = if (d == i) 1.0 else 0.01 * @as(f32, @floatFromInt(i + d));
    }
    for (0..4) |i| {
        const k = std.fmt.bufPrint(&key_buf, "vec:s{d}", .{i}) catch unreachable;
        _ = try idx.insertLocked(k, &vecs[i], 100 + i);
    }

    // The node is appended before linking fails; it must not be left without a key.
    idx.hnsw.fail_link_node_for_test = 4;
    try testing.expectError(error.OutOfMemory, idx.insertLocked("vec:s4", &vecs[4], 200));
    idx.hnsw.fail_link_node_for_test = null;

    try testing.expectEqual(@as(usize, 5), idx.hnsw.len());
    try testing.expectEqual(idx.hnsw.len(), idx.keys.items.len);
    try testing.expectEqual(@as(usize, 4), idx.liveCount());
    try testing.expect(idx.tombstones.isSet(4));
    try testing.expect(!idx.complete_with_store);

    var out: [5]IndexSearchResult = undefined;
    var scratch: [5]hnsw_mod.SearchResult = undefined;
    var n = try idx.searchLocked(&vecs[4], 5, 32, &out, &scratch);
    try testing.expectEqual(@as(usize, 4), n);
    for (out[0..n]) |r| try testing.expect(!std.mem.eql(u8, r.key, "vec:s4"));

    // Retry and a fresh key both land on ids that map to their own keys.
    _ = try idx.insertLocked("vec:s4", &vecs[4], 201);
    _ = try idx.insertLocked("vec:s5", &vecs[5], 202);
    try testing.expectEqual(idx.hnsw.len(), idx.keys.items.len);
    try testing.expectEqual(@as(usize, 6), idx.liveCount());
    n = try idx.searchLocked(&vecs[4], 1, 32, &out, &scratch);
    try testing.expectEqualStrings("vec:s4", out[0].key);
    n = try idx.searchLocked(&vecs[5], 1, 32, &out, &scratch);
    try testing.expectEqualStrings("vec:s5", out[0].key);
}
