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
const hnsw_mod = @import("hnsw.zig");

pub const Hnsw = hnsw_mod.Hnsw;
pub const HnswParams = hnsw_mod.HnswParams;

/// Local RwLock wrapper over std.Io.RwLock. Mirrors src/core/compat.zig's
/// shape but lives inside the vector module so `zig test` can build this
/// file standalone (no cross-module import path). Zig 0.16's RwLock
/// requires an Io handle for every operation; we pin it to the global
/// blocking Io.
const RwLock = struct {
    inner: std.Io.RwLock = .init,

    fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(io());
    }
    fn unlock(self: *RwLock) void {
        self.inner.unlock(io());
    }
    fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(io());
    }
    fn unlockShared(self: *RwLock) void {
        self.inner.unlockShared(io());
    }
};

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Result from `NamespaceIndex.search`. `key` is the stored vec key (borrowed
/// from the index's keys[] array — valid as long as the caller holds the
/// index's read-lock, or copies before releasing).
pub const IndexSearchResult = struct {
    key: []const u8,
    dist: f32,
    timestamp: u64,
};

pub const NamespaceIndex = struct {
    allocator: std.mem.Allocator,
    hnsw: Hnsw,
    /// keys[node_id] — arena-owned copy of the vec key (e.g. "vec:articles:id").
    keys: std.ArrayListUnmanaged([]u8),
    /// timestamps[node_id] — from the vec Entry when inserted.
    timestamps: std.ArrayListUnmanaged(u64),
    /// Held exclusively for inserts; shared for searches.
    lock: RwLock,

    pub fn init(allocator: std.mem.Allocator, params: HnswParams) NamespaceIndex {
        return .{
            .allocator = allocator,
            .hnsw = Hnsw.init(allocator, params),
            .keys = .empty,
            .timestamps = .empty,
            .lock = .{},
        };
    }

    pub fn deinit(self: *NamespaceIndex) void {
        self.hnsw.deinit();
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.deinit(self.allocator);
        self.timestamps.deinit(self.allocator);
    }

    pub fn len(self: *const NamespaceIndex) usize {
        return self.hnsw.len();
    }

    /// Insert a vector under the caller's write-lock. Returns the new node ID.
    /// The `key` is duped into the index's allocator; caller retains ownership
    /// of the passed-in slice.
    pub fn insertLocked(
        self: *NamespaceIndex,
        key: []const u8,
        vector: []align(1) const f32,
        timestamp: u64,
    ) !u32 {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const node_id = try self.hnsw.insert(vector);

        // hnsw.insert already succeeded — ensure side-tables stay in lockstep.
        // If either append fails we're in an inconsistent state; treat as OOM.
        try self.keys.append(self.allocator, key_copy);
        errdefer {
            _ = self.keys.pop();
        }
        try self.timestamps.append(self.allocator, timestamp);

        return node_id;
    }

    /// kNN search under the caller's read-lock. Fills `out` with up to `k`
    /// results sorted by ascending distance. Returned `key` slices are
    /// borrowed from the index's keys[] and valid only while the caller
    /// holds the read-lock.
    pub fn searchLocked(
        self: *NamespaceIndex,
        query: []align(1) const f32,
        k: usize,
        ef: usize,
        out: []IndexSearchResult,
        hnsw_scratch: []hnsw_mod.SearchResult,
    ) !usize {
        if (hnsw_scratch.len < k) return error.ScratchTooSmall;
        const n = try self.hnsw.search(query, k, ef, hnsw_scratch[0..k]);
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

    /// Full reset — caller must hold write-lock. Used by vreindex before
    /// a bulk rebuild.
    pub fn clearLocked(self: *NamespaceIndex) void {
        // Rebuild hnsw + side tables from scratch. Freeing and re-initing
        // the Hnsw drops all vectors + graph; the new graph starts empty
        // with the same params.
        const params = self.hnsw.params;
        self.hnsw.deinit();
        self.hnsw = Hnsw.init(self.allocator, params);
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.clearRetainingCapacity();
        self.timestamps.clearRetainingCapacity();
    }
};

pub const NamespaceRegistry = struct {
    allocator: std.mem.Allocator,
    /// Key = owned copy of the namespace string. Value = owned *NamespaceIndex.
    map: std.StringHashMapUnmanaged(*NamespaceIndex),
    /// Protects `map` structure (get/put/remove). Per-index locks live on
    /// each NamespaceIndex and are independent of this one.
    lock: RwLock,
    /// Default params applied to newly-created namespaces.
    default_params: HnswParams,

    pub fn init(allocator: std.mem.Allocator, default_params: HnswParams) NamespaceRegistry {
        return .{
            .allocator = allocator,
            .map = .empty,
            .lock = .{},
            .default_params = default_params,
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
    pub fn getOrCreate(self: *NamespaceRegistry, namespace: []const u8) !*NamespaceIndex {
        // Fast path: shared lock, peek the map.
        self.lock.lockShared();
        if (self.map.get(namespace)) |idx| {
            self.lock.unlockShared();
            return idx;
        }
        self.lock.unlockShared();

        // Slow path: exclusive lock, double-checked insert.
        self.lock.lock();
        defer self.lock.unlock();

        if (self.map.get(namespace)) |idx| return idx;

        const ns_copy = try self.allocator.dupe(u8, namespace);
        errdefer self.allocator.free(ns_copy);

        const idx = try self.allocator.create(NamespaceIndex);
        errdefer self.allocator.destroy(idx);
        idx.* = NamespaceIndex.init(self.allocator, self.default_params);

        try self.map.put(self.allocator, ns_copy, idx);
        return idx;
    }

    /// Drop a namespace's index entirely. Caller is responsible for not
    /// holding the per-index lock when calling this.
    pub fn remove(self: *NamespaceRegistry, namespace: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.map.fetchRemove(namespace)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit();
            self.allocator.destroy(kv.value);
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

    const a = try reg.getOrCreate("vec:");
    const b = try reg.getOrCreate("vec:");
    try testing.expectEqual(a, b);
}

test "registry: distinct namespaces get distinct indexes" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    const a = try reg.getOrCreate("vec:articles:");
    const b = try reg.getOrCreate("vec:products:");
    try testing.expect(a != b);
}

test "registry: get returns null before create" {
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();

    try testing.expect(reg.get("vec:") == null);
    _ = try reg.getOrCreate("vec:");
    try testing.expect(reg.get("vec:") != null);
}

test "namespace index: insert + search maps ids back to keys" {
    var reg = NamespaceRegistry.init(testing.allocator, .{ .m = 8, .ef_construction = 50 });
    defer reg.deinit();

    const idx = try reg.getOrCreate("vec:");
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

    const idx = try reg.getOrCreate("vec:");
    idx.lock.lock();
    defer idx.lock.unlock();

    const v = [_]f32{ 1, 0, 0 };
    const v_align: []align(1) const f32 = @ptrCast(&v);
    _ = try idx.insertLocked("vec:a", v_align, 1);
    try testing.expectEqual(@as(usize, 1), idx.len());

    idx.clearLocked();
    try testing.expectEqual(@as(usize, 0), idx.len());
}
