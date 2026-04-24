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
const metric_mod = @import("metric.zig");
const rabitq_mod = @import("rabitq.zig");

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

/// Local RwLock wrapper over std.Io.RwLock. Mirrors src/core/compat.zig's
/// shape but lives inside the vector module so `zig test` can build this
/// file standalone (no cross-module import path). Zig 0.16's RwLock
/// requires an Io handle for every operation; we pin it to the global
/// blocking Io.
const RwLock = struct {
    inner: std.Io.RwLock = .init,

    pub fn lock(self: *RwLock) void {
        self.inner.lockUncancelable(io());
    }
    pub fn unlock(self: *RwLock) void {
        self.inner.unlock(io());
    }
    pub fn lockShared(self: *RwLock) void {
        self.inner.lockSharedUncancelable(io());
    }
    pub fn unlockShared(self: *RwLock) void {
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
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    shutdown: bool = false,
    pending: std.atomic.Value(usize) = .init(0), // for vstats (lock-free read)
};

pub const NamespaceIndex = struct {
    allocator: std.mem.Allocator,
    hnsw: Hnsw,
    /// keys[node_id] — arena-owned copy of the vec key (e.g. "vec:articles:id").
    keys: std.ArrayListUnmanaged([]u8),
    /// timestamps[node_id] — from the vec Entry when inserted.
    timestamps: std.ArrayListUnmanaged(u64),
    /// Reverse lookup: vec key → node_id. Populated on every insertLocked,
    /// so DELETE-style ops can find the graph node to tombstone in O(1).
    /// The map's keys are borrowed from `self.keys` (no extra dupe).
    key_to_node: std.StringHashMapUnmanaged(u32),
    /// Tombstone bitset: bit i set ⇔ node i is logically deleted.
    /// Length tracks hnsw.len() — grown on every insertLocked. Search
    /// traversal skips tombstoned neighbors entirely.
    tombstones: std.DynamicBitSetUnmanaged,
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
    /// instead of the raw Hamming prefilter. Owned by this struct.
    rabitq_params: ?*RabitqParams,

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
        };
    }

    pub fn deinit(self: *NamespaceIndex) void {
        // Shut down the async worker BEFORE tearing down the graph it writes to.
        if (self.async_queue) |q| {
            const zio = io();
            q.mutex.lockUncancelable(zio);
            q.shutdown = true;
            q.cond.signal(zio);
            q.mutex.unlock(zio);

            if (self.async_worker) |t| t.join();

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
        // key_to_node's keys are borrowed from self.keys — only free the map.
        self.key_to_node.deinit(self.allocator);
        self.tombstones.deinit(self.allocator);
        if (self.rabitq_params) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
    }

    /// Install a full set of RaBitQ parameters (centroid + rotation).
    /// Takes ownership of the passed-in struct — caller must not deinit
    /// or destroy. Replaces any previous params (old allocations freed).
    /// Caller holds the write-lock.
    pub fn setRabitqParams(self: *NamespaceIndex, new_params: *RabitqParams) void {
        if (self.rabitq_params) |old| {
            old.deinit();
            self.allocator.destroy(old);
        }
        self.rabitq_params = new_params;
    }

    /// Read-only access to the installed params under the caller's lock
    /// (shared is fine). Returns null if `vrabitq` has not run yet.
    pub fn getRabitqParams(self: *const NamespaceIndex) ?*const RabitqParams {
        return self.rabitq_params;
    }

    /// Idempotently enable async mode: allocate the queue + spawn worker
    /// if this is the first call. Caller need not hold any lock; this
    /// function serializes its own setup via the AsyncQueue's mutex.
    pub fn enableAsyncMode(self: *NamespaceIndex) !void {
        if (@atomicLoad(bool, &self.async_mode, .acquire)) return;

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

    /// Enqueue a pending insert for the background worker. Caller passes
    /// ownership of key + vector byte slices — the worker frees them after
    /// insertLocked.
    pub fn enqueueAsync(self: *NamespaceIndex, key: []u8, vector: []u8, timestamp: u64) !void {
        const q = self.async_queue orelse return error.AsyncNotEnabled;
        const zio = io();
        q.mutex.lockUncancelable(zio);
        defer q.mutex.unlock(zio);
        try q.items.append(self.allocator, .{ .key = key, .vector = vector, .timestamp = timestamp });
        _ = q.pending.fetchAdd(1, .monotonic);
        q.cond.signal(zio);
    }

    /// Batch-enqueue for bulk inserts: a single mutex acquisition for N
    /// items. Duplicates key and vector bytes (bulk frame buffer is arena
    /// memory that will be freed when the request completes).
    pub fn enqueueAsyncBatch(
        self: *NamespaceIndex,
        items: []const @import("../core/mod.zig").types.Command.VbulkinsertParams.BulkItem,
    ) !void {
        const q = self.async_queue orelse return error.AsyncNotEnabled;
        const zio = io();

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

        q.mutex.lockUncancelable(zio);
        defer q.mutex.unlock(zio);
        try q.items.appendSlice(self.allocator, owned.items);
        _ = q.pending.fetchAdd(items.len, .monotonic);
        q.cond.signal(zio);
        owned.clearRetainingCapacity();
    }

    /// Non-blocking snapshot of pending-insert count. `vstats` surfaces this.
    pub fn pendingAsyncCount(self: *const NamespaceIndex) usize {
        const q = self.async_queue orelse return 0;
        return q.pending.load(.monotonic);
    }

    fn asyncWorkerLoop(self: *NamespaceIndex) void {
        const q = self.async_queue orelse return;
        const distance = @import("distance.zig");
        const zio = io();

        while (true) {
            // Wait for work or shutdown.
            q.mutex.lockUncancelable(zio);
            while (q.items.items.len == 0 and !q.shutdown) {
                q.cond.waitUncancelable(zio, &q.mutex);
            }
            const is_shutdown = q.shutdown;
            // Swap: the worker takes everything queued so producers can
            // keep enqueuing into a fresh list while we drain.
            const tmp = q.items;
            q.items = q.scratch;
            q.scratch = tmp;
            q.mutex.unlock(zio);

            if (q.scratch.items.len > 0) {
                const drained = q.scratch.items.len;

                // One write-lock acquisition for the entire drain batch.
                self.lock.lock();
                for (q.scratch.items) |item| {
                    const vec_f32 = distance.bytesToF32(item.vector) orelse {
                        std.log.warn("async hnsw: invalid vector bytes for key '{s}'", .{item.key});
                        continue;
                    };
                    _ = self.insertLocked(item.key, vec_f32, item.timestamp) catch |e| {
                        std.log.warn("async hnsw: insert '{s}' failed: {s}", .{ item.key, @errorName(e) });
                    };
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
        if (self.dim) |d| {
            if (vector.len != d) return RegistryError.DimensionMismatch;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const node_id = try self.hnsw.insert(vector);
        // hnsw.insert succeeded — freeze dim on the first successful insert.
        if (self.dim == null) self.dim = vector.len;

        // hnsw.insert already succeeded — ensure side-tables stay in lockstep.
        try self.keys.append(self.allocator, key_copy);
        errdefer {
            _ = self.keys.pop();
        }
        try self.timestamps.append(self.allocator, timestamp);
        errdefer {
            _ = self.timestamps.pop();
        }

        // Grow tombstones bitset to cover the new node. resize with `false`
        // ensures the new slot is active (not-tombstoned) by default.
        try self.tombstones.resize(self.allocator, self.hnsw.len(), false);

        // Reverse map uses the just-duped key slice — borrow, don't re-dupe.
        try self.key_to_node.put(self.allocator, key_copy, node_id);

        return node_id;
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
        if (hnsw_scratch.len < k) return error.ScratchTooSmall;
        const filter: ?*const std.DynamicBitSetUnmanaged =
            if (self.tombstone_count > 0) &self.tombstones else null;
        const n = try self.hnsw.search(query, k, ef, hnsw_scratch[0..k], filter);
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
    /// a bulk rebuild. Metric is preserved (callers who want to switch
    /// metrics must drop the namespace entirely).
    pub fn clearLocked(self: *NamespaceIndex) void {
        const params = self.hnsw.params;
        self.hnsw.deinit();
        self.hnsw = Hnsw.init(self.allocator, params);
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.clearRetainingCapacity();
        self.timestamps.clearRetainingCapacity();
        self.key_to_node.clearRetainingCapacity();
        self.tombstones.deinit(self.allocator);
        self.tombstones = .{};
        self.tombstone_count = 0;
        // Dimension must re-freeze on the next insert — `vreindex` may be
        // used to switch a namespace's dim during a full rebuild.
        self.dim = null;
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
        const w = writer;

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
    }

    /// Resolver context used internally during readFromLocked — bridges
    /// from Hnsw's node_id-based callback to the outer key-based KV
    /// lookup. `keys` lives on the reading side's stack until the whole
    /// index is built.
    const LocalResolver = struct {
        keys: []const []const u8,
        outer_resolve: OuterResolveFn,
        outer_ctx: *anyopaque,

        pub const OuterResolveFn = *const fn (ctx: *anyopaque, key: []const u8) ?[]const u8;

        fn bridge(raw_ctx: *anyopaque, node_id: u32) ?[]const u8 {
            const self: *LocalResolver = @ptrCast(@alignCast(raw_ctx));
            if (node_id >= self.keys.len) return null;
            return self.outer_resolve(self.outer_ctx, self.keys[node_id]);
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
        const tombstone_count = std.mem.readInt(u64, tc_buf[0..8], .little);

        var tombstones: std.DynamicBitSetUnmanaged = if (node_count == 0)
            .{}
        else
            try std.DynamicBitSetUnmanaged.initEmpty(allocator, node_count);
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
        var bridge_ctx = LocalResolver{
            .keys = keys.items,
            .outer_resolve = outer_resolve,
            .outer_ctx = outer_ctx,
        };
        var hnsw = try Hnsw.readFrom(
            allocator,
            reader,
            LocalResolver.bridge,
            @ptrCast(&bridge_ctx),
        );
        errdefer hnsw.deinit();
        hnsw.setDistFn(metric.distFn());

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
            errdefer allocator.free(centroid);
            try readF32Slice(reader, centroid);

            const rotation = try allocator.alloc(f32, dim_usize * dim_usize);
            errdefer allocator.free(rotation);
            try readF32Slice(reader, rotation);

            const p = try allocator.create(RabitqParams);
            errdefer allocator.destroy(p);
            p.* = .{
                .allocator = allocator,
                .centroid = centroid,
                .rotation = rotation,
                .dim = dim_u32,
                .seed = seed,
            };
            rabitq_params_ptr = p;
            // If the graph never resolved a vector (empty namespace), fall
            // back to the params' dim so later inserts know what shape to
            // accept.
            if (derived_dim == null) derived_dim = dim_usize;
        } else if (has_rabitq_buf[0] != 0) {
            return error.CorruptIndex;
        }

        return .{
            .allocator = allocator,
            .hnsw = hnsw,
            .keys = keys,
            .timestamps = timestamps,
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
        };
    }
};

fn writeF32Slice(writer: anytype, slice: []const f32) !void {
    var buf: [4]u8 = undefined;
    for (slice) |x| {
        const bits: u32 = @bitCast(x);
        std.mem.writeInt(u32, &buf, bits, .little);
        try writer.writeAll(&buf);
    }
}

fn readF32Slice(reader: anytype, dest: []f32) !void {
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
        idx.setRabitqParams(p);
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
