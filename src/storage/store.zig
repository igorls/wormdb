//! In-memory key-value store with WAL persistence

const std = @import("std");
const core = @import("../core/mod.zig");
const wal_mod = @import("wal.zig");
const btree_mod = @import("btree.zig");
const CollectedKeys = btree_mod.CollectedKeys;

const Entry = core.types.Entry;
const OrderedIndex = btree_mod.OrderedIndex(*Entry, true);
const EntryFlags = core.types.EntryFlags;
const StoreError = core.types.StoreError;
const Config = core.config.Config;
const PersistenceMode = core.config.PersistenceMode;
const Wal = wal_mod.Wal;
const compat = core.compat;
const WalRecord = wal_mod.WalRecord;
const Segment = @import("segment.zig").Segment;
const Sst = @import("sst.zig").Sst;

// Snapshot format:
//   v1 → WDBSNAP1: KV entries only (legacy, still loadable).
//   v2 → WDBSNAP1 with version field set to 2: same KV block, followed
//        by an optional HNSW trailer produced by NamespaceRegistry.writeTo.
//        New writes always emit v2. Older readers on v1-only binaries
//        simply won't see the trailer.
//
// The magic bytes stay "WDBSNAP1" for backward compatibility — only
// the u32 version field after the magic distinguishes v1 from v2.
const SNAPSHOT_MAGIC = "WDBSNAP1";
const SNAPSHOT_VERSION: u32 = 2;

/// Optional back-reference to the per-namespace HNSW registry. When set,
/// writeSnapshot appends the HNSW trailer after the KV section; loadSnapshot
/// restores it when it finds the WDBHNSW2 marker. Populated via
/// `Store.attachVectorRegistry` after both are constructed (main.zig).
const hnsw_index_mod = @import("../vector/index.zig");
pub const NamespaceRegistry = hnsw_index_mod.NamespaceRegistry;
const distance = @import("../vector/distance.zig");
const Metric = @import("../vector/metric.zig").Metric;

const SHARD_COUNT: usize = 256;

pub fn shardIndex(key: []const u8) usize {
    var hash = std.hash.Fnv1a_64.init();
    hash.update(key);
    return @intCast(hash.final() & (SHARD_COUNT - 1));
}

const Shard = struct {
    /// Align each shard to a single 64-byte cache line (mutex 8B + unmanaged map 16B
    /// = 24B padded to 64B). Zero cross-core false sharing AND the entire `[256]Shard`
    /// table fits in 16 KiB (half of L1D).
    mutex: core.compat.Mutex align(64),
    data: std.StringHashMapUnmanaged(*Entry),
};
comptime {
    std.debug.assert(@sizeOf(Shard) <= 64);
}

const PrehashedStringCtx = struct {
    h: u64,

    pub fn hash(self: @This(), _: []const u8) u64 {
        return self.h;
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// Remove `key` from a shard's hashmap + global ordered index. Caller must hold the
/// shard lock and owns destroying the returned entry.
fn shardRemoveLocked(store: *Store, shard: *Shard, key: []const u8) ?*Entry {
    const removed = shard.data.fetchRemove(key) orelse return null;
    store.ordered.remove(key);
    _ = store.live_keys.fetchSub(1, .monotonic);
    return removed.value;
}

pub const LockPair = struct {
    low: usize,
    high: ?usize,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    shards: [SHARD_COUNT]Shard,
    /// Heap-allocated radix-partitioned (first-byte) ordered B+Tree replacing
    /// per-shard sorted slices (keeps `Store` compact on stack and gives
    /// `ShardedRwLock` buckets a stable address).
    ordered: *OrderedIndex,
    /// Live (non-sst) key count — maintained by shardPut/Remove for O(1) STATUS.
    /// Avoids locking all 256 shards on every STATUS call (#91).
    live_keys: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    wal: ?Wal,
    wal_enqueue_mutex: core.compat.Mutex,
    /// Lock order: wal_enqueue (if held) -> snapshot -> shards. Covers the
    /// entire copy/write/rename so every caller shares one snapshot writer.
    snapshot_mutex: core.compat.Mutex = .{},
    config: Config,
    /// Bump arena owning every snapshot-loaded entry (key, value, and Entry
    /// struct — flagged `arena_owned`). Snapshot data is overwhelmingly the
    /// static bulk of the store; three individual allocations per entry cost
    /// more in allocator round-trips and header overhead than the arena's
    /// one-shot reclaim loses on deleted/superseded entries (which just go
    /// unused until restart).
    snapshot_arena: std.heap.ArenaAllocator,
    /// Optional HNSW registry back-reference. Attached by main.zig after
    /// both objects exist; snapshot write/load use it when present.
    vector_registry: ?*NamespaceRegistry = null,
    /// Registry of frozen read-only segments (mmap'd `.wseg`), addressed by an
    /// opaque caller-chosen name. The engine is domain-agnostic: a serving layer
    /// attaches and looks up "its" segment by a string it owns, so no
    /// domain identity lives in the store.
    /// Attached by the composition root (`main.zig`) after construction; each
    /// segment (and its name) must outlive the store. Small fixed capacity —
    /// there are only a handful of serving domains.
    segments_buf: [MAX_SEGMENTS]NamedSegment = undefined,
    segment_count: usize = 0,
    fail_put_reserve_for_test: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},
    fail_ordered_insert_for_test: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},
    /// Frozen sorted-string segments (`.wsst`, see sst.zig) mounted as a
    /// TRANSPARENT overlay: GET/scan/EXEC consult live shards first, then each
    /// sst in attach order — so live writes shadow frozen keys and procedures
    /// need no segment awareness. Mounted by the composition root; each sst
    /// must outlive the store. v1 limitations (documented, enforced nowhere):
    /// DEL cannot mask a frozen key (it resurfaces), and STATUS/key counts
    /// cover live entries only.
    ssts_buf: [MAX_SSTS]*const Sst = undefined,
    sst_count: usize = 0,
    /// Per-Store sequence hint cache for `proof/append_log.zig` tail lookups.
    /// Scoped to the `Store` instance (rather than a process-global table keyed
    /// by `@intFromPtr(store)`) so address reuse across open/close or FFI
    /// lifetimes never inherits stale sequence hints.
    seq_hints: [SEQ_HINT_SLOTS]SeqHintSlot = @splat(.{}),

    pub const SEQ_HINT_SLOTS: usize = 64;
    pub const SeqHintSlot = struct {
        mutex: core.compat.Mutex = .{},
        log_hash: [32]u8 = @splat(0),
        seq: u64 = 0,
    };

    pub fn getAppendLogSeqHint(self: *Store, log_hash: [32]u8) u64 {
        const slot = &self.seq_hints[log_hash[0] & (SEQ_HINT_SLOTS - 1)];
        slot.mutex.lock();
        defer slot.mutex.unlock();
        if (std.mem.eql(u8, slot.log_hash[0..], log_hash[0..])) {
            return slot.seq;
        }
        return 0;
    }

    pub fn setAppendLogSeqHint(self: *Store, log_hash: [32]u8, seq: u64) void {
        const slot = &self.seq_hints[log_hash[0] & (SEQ_HINT_SLOTS - 1)];
        slot.mutex.lock();
        defer slot.mutex.unlock();
        slot.log_hash = log_hash;
        slot.seq = seq;
    }

    /// Attach the per-namespace HNSW registry to this store so snapshots
    /// persist and restore graph state alongside KV data. Call after both
    /// the store and the registry have been constructed (see main.zig).
    pub fn attachVectorRegistry(self: *Store, registry: *NamespaceRegistry) void {
        self.vector_registry = registry;
    }

    const MAX_SEGMENTS: usize = 8;
    const NamedSegment = struct { name: []const u8, seg: *const Segment };
    const MAX_SSTS: usize = 4;

    /// Mount a frozen sorted-string segment into the read overlay (earlier
    /// mounts win on duplicate keys). Call after construction; `s` must
    /// outlive the store.
    pub fn attachSst(self: *Store, s: *const Sst) void {
        if (self.sst_count >= MAX_SSTS) {
            std.log.warn("sst overlay full ({d}); dropping mount", .{MAX_SSTS});
            return;
        }
        self.ssts_buf[self.sst_count] = s;
        self.sst_count += 1;
    }

    /// True when one or more frozen SST segments are mounted as a read overlay.
    pub fn hasFrozenSegments(self: *const Store) bool {
        return self.sst_count > 0;
    }

    /// Overlay lookup behind the live shards: first attached sst that has the
    /// key wins. Lock-free — frozen mappings are immutable and immortal.
    pub fn sstHit(self: *const Store, key: []const u8) ?Sst.Hit {
        for (self.ssts_buf[0..self.sst_count]) |s| {
            if (s.get(key)) |hit| return hit;
        }
        return null;
    }

    /// True if the live shards contain `key` (regardless of any sst).
    fn containsLive(self: *Store, key: []const u8) bool {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        defer self.shards[si].mutex.unlock();
        return self.shards[si].data.contains(key);
    }

    /// True if ANY live key starts with `prefix` — O(log n) in a single ordered bucket.
    fn livePrefixNonEmpty(self: *Store, prefix: []const u8) bool {
        return self.ordered.hasPrefix(prefix);
    }

    /// Attach a frozen read-only segment under `name`. Re-attaching the same name
    /// replaces it. Call after the store is constructed and the segment is mapped;
    /// the segment (and `name`) must outlive the store.
    pub fn attachSegment(self: *Store, name: []const u8, seg: *const Segment) void {
        for (self.segments_buf[0..self.segment_count]) |*ns| {
            if (std.mem.eql(u8, ns.name, name)) {
                ns.seg = seg;
                return;
            }
        }
        if (self.segment_count >= MAX_SEGMENTS) {
            std.log.warn("segment registry full ({d}); dropping '{s}'", .{ MAX_SEGMENTS, name });
            return;
        }
        self.segments_buf[self.segment_count] = .{ .name = name, .seg = seg };
        self.segment_count += 1;
    }

    /// Look up a frozen segment by the name it was attached under. Null if none.
    pub fn segment(self: *const Store, name: []const u8) ?*const Segment {
        for (self.segments_buf[0..self.segment_count]) |ns| {
            if (std.mem.eql(u8, ns.name, name)) return ns.seg;
        }
        return null;
    }

    pub fn init(allocator: std.mem.Allocator, config: Config) !Store {
        return initWithRegistry(allocator, config, null);
    }

    /// Like `init`, but attaches a vector registry before snapshot loading
    /// so a v2 snapshot's HNSW trailer can be restored in the same pass.
    /// Callers that don't use vector search should use `init`.
    pub fn initWithRegistry(
        allocator: std.mem.Allocator,
        config: Config,
        registry: ?*NamespaceRegistry,
    ) !Store {
        // Only create/open WAL file when persistence == .full
        var wal: ?Wal = null;
        if (config.persistence == .full) {
            const file = compat.Dir.openFile(core.compat.cwd(), config.wal_path, .{ .mode = .read_write }) catch blk: {
                break :blk try compat.Dir.createFile(core.compat.cwd(), config.wal_path, .{ .read = true, .truncate = false });
            };
            compat.File.close(file);
            wal = try Wal.init(allocator, config.wal_path, config.sync_writes);
        }
        errdefer if (wal) |*w| w.deinit();

        var shards: [SHARD_COUNT]Shard = undefined;
        for (&shards) |*shard| {
            shard.* = .{
                .mutex = .{},
                .data = .empty,
            };
        }

        const ordered = try allocator.create(OrderedIndex);
        errdefer allocator.destroy(ordered);
        ordered.* = OrderedIndex.init(allocator);
        errdefer ordered.deinit();

        var store = Store{
            .allocator = allocator,
            .shards = shards,
            .ordered = ordered,
            .wal = wal,
            .wal_enqueue_mutex = .{},
            .config = config,
            .vector_registry = registry,
            .snapshot_arena = std.heap.ArenaAllocator.init(allocator),
        };

        // Load snapshot for full and snapshot modes, skip for none
        if (config.persistence != .none) {
            try store.loadSnapshot();
        }

        // Snapshot v2 (WDBHNSW2) already restored HNSW graphs + RaBitQ params for
        // namespaces present in `vector_registry`. Track any WAL mutations to those
        // namespaces so we can preserve restored graphs (0-cost on clean restart,
        // incremental delta on small WAL recovery) instead of unconditionally wiping
        // and rebuilding every namespace from scratch.
        var wal_vec_tracker = try WalVectorTracker.initFromRegistry(allocator, store.vector_registry);
        defer wal_vec_tracker.deinit();

        // Only replay WAL in full mode
        if (config.persistence == .full) {
            try store.replayWal(&wal_vec_tracker);
        }
        if (config.persistence != .none) {
            try store.reconcileVectorIndexes(&wal_vec_tracker);
        }

        return store;
    }

    /// Start WAL background writer/sync loop.
    /// Must be called after the Store is at its final, non-moving address.
    pub fn startBackgroundTasks(self: *Store) !void {
        if (self.wal) |*w| {
            try w.startBackground();
        }
    }

    pub fn deinit(self: *Store) void {
        // Auto-save snapshot on shutdown for snapshot mode
        if (self.config.persistence == .snapshot) {
            self.writeSnapshot() catch |err| {
                std.log.err("Failed to save snapshot on shutdown: {}", .{err});
            };
        }
        if (self.wal) |*w| w.deinit();
        self.ordered.deinit();
        self.allocator.destroy(self.ordered);
        for (&self.shards) |*shard| {
            var iter = shard.data.iterator();
            while (iter.next()) |entry| {
                self.destroyEntry(entry.value_ptr.*);
            }
            shard.data.deinit(self.allocator);
        }
        self.snapshot_arena.deinit();
        self.seq_hints = @splat(.{});
    }

    pub fn destroyEntry(self: *Store, entry: *Entry) void {
        // Arena-owned entries are reclaimed wholesale when the arena dies; a
        // deleted/superseded one just sits unused in it until then.
        if (entry.flags.arena_owned) return;
        entry.deinit(self.allocator);
        self.allocator.destroy(entry);
    }

    /// Insert or replace `entry` in a shard's hashmap + ordered index, keeping
    /// the two views consistent. Caller must hold the shard lock and have done
    /// any WORM checks. All allocations are reserved up front: on error the
    /// shard is untouched and the caller still owns `entry`; on success a
    /// superseded entry is destroyed only after both structures point at the
    /// new one (no dangling pointer is ever observable).
    fn shardPutLocked(self: *Store, shard: *Shard, entry: *Entry) StoreError!void {
        try self.shardReservePutLocked(shard, entry.key);
        if (!shard.data.contains(entry.key)) try self.orderedInsertLocked(shard, entry);
        self.shardPutReservedLocked(shard, entry);
    }

    fn shardReservePutLocked(self: *Store, shard: *Shard, _: []const u8) StoreError!void {
        if (@import("builtin").is_test and self.fail_put_reserve_for_test) return error.OutOfMemory;
        shard.data.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
    }

    /// Add a NEW key's entry to the ordered index. This is the only fallible step
    /// of publishing a new key besides the reservations, so it runs before the WAL
    /// record is written: a failure is returned to the caller with nothing durable,
    /// instead of leaving a key that `get` serves but scans and snapshots never see.
    ///
    /// Caller must hold the shard lock and keep it until the entry is either in the
    /// shard hashmap (`shardPutReservedLocked`) or taken back out of the index
    /// (`orderedUnindexLocked`). Readers that reach the entry through the index take
    /// that same shard lock before touching it (`tryLock` on the fast scan paths, a
    /// hashmap lookup under the lock on the others), so the half-published entry is
    /// never read. `countPrefix` can include it for the duration of the write.
    fn orderedInsertLocked(self: *Store, shard: *Shard, entry: *Entry) StoreError!void {
        if (@import("builtin").is_test and self.fail_ordered_insert_for_test) return error.OutOfMemory;
        const si = (@intFromPtr(shard) - @intFromPtr(&self.shards[0])) / @sizeOf(Shard);
        self.ordered.insert(entry.key, entry, si) catch return error.OutOfMemory;
    }

    /// Undo `orderedInsertLocked` for an entry that never reached the hashmap.
    /// Must run before the entry is destroyed: the index borrows its key bytes.
    fn orderedUnindexLocked(self: *Store, entry: *Entry) void {
        self.ordered.remove(entry.key);
    }

    /// Publish `entry` in the shard hashmap. Infallible: the caller has reserved
    /// hashmap capacity and, when the key is new to the shard, already added the
    /// entry to the ordered index with `orderedInsertLocked`.
    fn shardPutReservedLocked(self: *Store, shard: *Shard, entry: *Entry) void {
        if (shard.data.fetchRemove(entry.key)) |removed| {
            // Existing key replaced (e.g. arena-owned snapshot entry superseded or WAL replay):
            // update `ordered` value/key pointer under exclusive bucket lock BEFORE destroying `removed.value`.
            shard.data.putAssumeCapacity(entry.key, entry);
            self.ordered.replaceValue(entry.key, entry);
            self.destroyEntry(removed.value);
            return;
        }
        shard.data.putAssumeCapacity(entry.key, entry);
        _ = self.live_keys.fetchAdd(1, .monotonic);
    }

    /// Delete without WAL or WORM checks — the procedure-context (`Ctx.del`)
    /// escape hatch. Caller must hold the key's shard lock. Unlike a raw
    /// `data.fetchRemove`, this keeps the ordered index in sync.
    pub fn deleteUnsafe(self: *Store, key: []const u8) void {
        const shard = &self.shards[shardIndex(key)];
        if (shardRemoveLocked(self, shard, key)) |removed| {
            self.destroyEntry(removed);
        }
    }

    /// Fast read — lock only the key shard.
    pub fn get(self: *Store, key: []const u8) ?*const Entry {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        defer self.shards[si].mutex.unlock();
        return self.shards[si].data.get(key);
    }

    /// Safe read — copies value inside the shard lock using the caller's allocator.
    /// Prevents use-after-free when another thread deletes the key concurrently.
    /// Falls through to the frozen sst overlay on a live miss.
    pub fn getValueDupe(self: *Store, key: []const u8, alloc: std.mem.Allocator) !?[]const u8 {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        if (self.shards[si].data.get(key)) |entry| {
            defer self.shards[si].mutex.unlock();
            return try alloc.dupe(u8, entry.value);
        }
        self.shards[si].mutex.unlock();
        if (self.sstHit(key)) |hit| {
            return try alloc.dupe(u8, hit.value);
        }
        return null;
    }

    /// Outcome of `getValueInto`: distinguishes a missing key from a value that
    /// does not fit in the caller-supplied buffer (carrying the exact byte length
    /// so the caller can fall back to heap allocation without guessing).
    pub const GetIntoResult = union(enum) {
        hit: []const u8,
        too_small: usize,
        miss,
    };

    /// Zero-allocation read into a caller-owned buffer (e.g. a 16B-aligned stack
    /// buffer for vector queries). Locks only the key's shard, copies the value
    /// into `buf`, and unlocks. Falls through to the frozen SST overlay on a live
    /// miss, matching `getValueDupe` semantics identically.
    pub fn getValueInto(self: *Store, key: []const u8, buf: []u8) GetIntoResult {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        if (self.shards[si].data.get(key)) |entry| {
            defer self.shards[si].mutex.unlock();
            if (entry.value.len > buf.len) return .{ .too_small = entry.value.len };
            @memcpy(buf[0..entry.value.len], entry.value);
            return .{ .hit = buf[0..entry.value.len] };
        }
        self.shards[si].mutex.unlock();
        if (self.sstHit(key)) |hit| {
            if (hit.value.len > buf.len) return .{ .too_small = hit.value.len };
            @memcpy(buf[0..hit.value.len], hit.value);
            return .{ .hit = buf[0..hit.value.len] };
        }
        return .miss;
    }

    /// Zero-copy read with callback: locks the key's shard, invokes `cb(user_ctx, value)`
    /// with borrowed value bytes, and unlocks. Falls through to the frozen SST overlay
    /// on a live miss (where no shard lock is held during `cb`). Returns `true` iff the
    /// key existed and `cb` ran.
    ///
    /// Contract: `cb` MUST NOT retain the borrowed `value` slice after returning, and
    /// MUST NOT call back into `Store`, `NamespaceRegistry`, or `NamespaceIndex`
    /// (deadlock risk against the held shard mutex and global lock order).
    pub fn readWithCallback(
        self: *Store,
        key: []const u8,
        user_ctx: anytype,
        comptime cb: fn (@TypeOf(user_ctx), []const u8) void,
    ) bool {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        if (self.shards[si].data.get(key)) |entry| {
            defer self.shards[si].mutex.unlock();
            cb(user_ctx, entry.value);
            return true;
        }
        self.shards[si].mutex.unlock();
        if (self.sstHit(key)) |hit| {
            cb(user_ctx, hit.value);
            return true;
        }
        return false;
    }

    /// Stable receipt metadata for an entry, copied while the shard is locked.
    pub const EntryMetadata = struct {
        timestamp: u64,
        is_worm: bool,
        value_len: usize,
        value_sha256: [32]u8,
    };

    pub fn getEntryMetadata(self: *Store, key: []const u8) ?EntryMetadata {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        defer self.shards[si].mutex.unlock();

        const entry = self.shards[si].data.get(key) orelse return null;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.value, &digest, .{});
        return .{
            .timestamp = entry.timestamp,
            .is_worm = entry.flags.is_worm,
            .value_len = entry.value.len,
            .value_sha256 = digest,
        };
    }

    /// Read without acquiring a lock. Caller must hold the key shard lock.
    pub fn getUnsafe(self: *Store, key: []const u8) ?*const Entry {
        return self.shards[shardIndex(key)].data.get(key);
    }

    /// Write without acquiring a lock and **without WAL**. Caller must hold
    /// the key shard lock. Used by procedure hot-path (`Ctx.set` / `setInt`).
    ///
    /// On `.full` persistence the durable path is `set` / `setWithTimestamp`
    /// (or procedure `setDurable*`). Unsafe writes stay in the live map only
    /// until the next snapshot — they must not enqueue WAL records or they
    /// would pay WAL IO and be replayed on restart (#88).
    pub fn setUnsafe(self: *Store, key: []const u8, value: []const u8, is_worm: bool) StoreError!void {
        return self.setInternalLockedNoWal(shardIndex(key), key, value, is_worm);
    }

    /// Write — acquires only the key shard mutex.
    /// WAL enqueue happens OUTSIDE the shard lock to avoid serializing all shards.
    pub fn set(self: *Store, key: []const u8, value: []const u8, is_worm: bool) StoreError!void {
        return self.setWithTimestamp(key, value, is_worm, @intCast(compat.nowMs()));
    }

    /// Write with caller-supplied timestamp metadata.
    ///
    /// Used by provenance primitives that include a local DB receipt timestamp
    /// inside their hashed envelope and need the stored entry metadata to match.
    pub fn setWithTimestamp(self: *Store, key: []const u8, value: []const u8, is_worm: bool, timestamp: u64) StoreError!void {
        try self.setWithTimestampNoVectorSync(key, value, is_worm, timestamp);
        if (self.vector_registry) |reg| {
            if (reg.mayMatchFast(key)) {
                self.syncVectorSetWithRegistry(reg, key, value, is_worm, timestamp);
            }
        }
    }

    pub fn syncVectorSetWithRegistry(
        self: *Store,
        reg: *NamespaceRegistry,
        key: []const u8,
        value: []const u8,
        is_worm: bool,
        timestamp: u64,
    ) void {
        switch (reg.syncRawSetWithBq(key, value, timestamp)) {
            .none => {},
            .upsert => |bq_buf| {
                defer reg.allocator.free(bq_buf);
                var stack_buf: [256]u8 = undefined;
                const bq_key = std.fmt.bufPrint(&stack_buf, "bq:{s}", .{key}) catch
                    (std.fmt.allocPrint(self.allocator, "bq:{s}", .{key}) catch return);
                defer if (bq_key.ptr != &stack_buf) self.allocator.free(bq_key);
                self.setWithTimestampNoVectorSync(bq_key, bq_buf, is_worm, timestamp) catch {};
            },
            .delete => {
                var stack_buf: [256]u8 = undefined;
                const bq_key = std.fmt.bufPrint(&stack_buf, "bq:{s}", .{key}) catch
                    (std.fmt.allocPrint(self.allocator, "bq:{s}", .{key}) catch return);
                defer if (bq_key.ptr != &stack_buf) self.allocator.free(bq_key);
                self.delete(bq_key) catch {};
            },
        }
    }

    pub fn syncVectorDeleteWithRegistry(self: *Store, reg: *NamespaceRegistry, key: []const u8) void {
        if (reg.syncRawDelete(key)) {
            var stack_buf: [256]u8 = undefined;
            const bq_key = std.fmt.bufPrint(&stack_buf, "bq:{s}", .{key}) catch
                (std.fmt.allocPrint(self.allocator, "bq:{s}", .{key}) catch return);
            defer if (bq_key.ptr != &stack_buf) self.allocator.free(bq_key);
            self.delete(bq_key) catch {};
        }
    }

    /// Write with caller-supplied timestamp without triggering raw-SET HNSW sync
    /// (used by `applyVinsert` / `applyVbulkinsert`, which manage HNSW updates directly).
    pub fn setWithTimestampNoVectorSync(self: *Store, key: []const u8, value: []const u8, is_worm: bool, timestamp: u64) StoreError!void {
        const si = shardIndex(key);
        const shard = &self.shards[si];

        // Lock hierarchy:
        //   wal_enqueue_mutex (compaction / direct-WAL exclusion)
        //     -> snapshot_mutex
        //       -> shards[si].mutex
        //         -> wal.lanes[si & WAL_LANE_MASK].mutex (leaf mutex for background byte-ring)
        if (self.config.persistence == .full) {
            const flags = EntryFlags{ .is_worm = is_worm, .is_deleted = false };
            // Pre-serialize and CRC32C-hash into a stack buffer (heap fallback > 4 KiB)
            // outside all locks so concurrent producers parallelize hashing with zero malloc churn.
            const total_len = Wal.setRecordSize(key.len, value.len);
            var stack_buf: [4096]u8 = undefined;
            const heap_buf: ?[]u8 = if (total_len > stack_buf.len)
                (self.allocator.alloc(u8, total_len) catch return error.OutOfMemory)
            else
                null;
            defer if (heap_buf) |hb| self.allocator.free(hb);
            const record = Wal.encodeSetRecord(
                if (heap_buf) |hb| hb else stack_buf[0..total_len],
                key,
                value,
                flags,
                timestamp,
            );

            if (self.wal.?.writer_started) {
                // Background WAL writer mode (sync_writes=true, truncation disabled):
                // Lock only shard.mutex -> leaf wal.lanes[si & WAL_LANE_MASK].mutex.
                // Never acquire wal_enqueue_mutex after shard.mutex.
                shard.mutex.lock();
                defer shard.mutex.unlock();

                const existing = shard.data.get(key);
                if (existing) |ex| {
                    if (ex.flags.is_worm) return error.WormViolation;
                } else if (self.sstHit(key)) |frozen| {
                    if (frozen.is_worm) return error.WormViolation;
                }

                const prepared = try self.prepareUpsertLocked(shard, existing, key, value, is_worm, timestamp);
                self.wal.?.commitRecordBytesForLane(si, record) catch {
                    self.abortPreparedUpsert(prepared);
                    return error.IoError;
                };
                self.commitPreparedUpsertLocked(shard, prepared, value, is_worm, timestamp);
                return;
            }

            // Direct WAL file mode (!writer_started): hold wal_enqueue_mutex -> shard.mutex
            // across reserve + direct WAL write + live map commit so maybeSnapshotAndTruncate
            // cannot interleave (#92).
            self.wal_enqueue_mutex.lock();
            {
                shard.mutex.lock();
                defer shard.mutex.unlock();

                const existing = shard.data.get(key);
                if (existing) |ex| {
                    if (ex.flags.is_worm) {
                        self.wal_enqueue_mutex.unlock();
                        return error.WormViolation;
                    }
                } else if (self.sstHit(key)) |frozen| {
                    if (frozen.is_worm) {
                        self.wal_enqueue_mutex.unlock();
                        return error.WormViolation;
                    }
                }

                const prepared = self.prepareUpsertLocked(shard, existing, key, value, is_worm, timestamp) catch |err| {
                    self.wal_enqueue_mutex.unlock();
                    return err;
                };
                self.wal.?.commitRecordBytesForLane(si, record) catch {
                    self.abortPreparedUpsert(prepared);
                    self.wal_enqueue_mutex.unlock();
                    return error.IoError;
                };
                self.commitPreparedUpsertLocked(shard, prepared, value, is_worm, timestamp);
            }
            self.wal_enqueue_mutex.unlock();
        } else {
            shard.mutex.lock();
            defer shard.mutex.unlock();
            const existing = shard.data.get(key);
            if (existing) |ex| {
                if (ex.flags.is_worm) return error.WormViolation;
            } else if (self.sstHit(key)) |frozen| {
                if (frozen.is_worm) return error.WormViolation;
            }
            try self.upsertShardLocked(shard, existing, key, value, is_worm, timestamp);
        }

        if (self.config.persistence == .full) {
            self.maybeSnapshotAndTruncate() catch {};
        }
    }

    const PreparedUpsert = union(enum) {
        in_place_same_len: *Entry,
        in_place_new_val: struct { entry: *Entry, new_val: []u8 },
        /// `indexed` is set when the key is new and the entry is already in the
        /// ordered index; an abort must take it back out before destroying it.
        put_entry: struct { entry: *Entry, indexed: bool },
    };

    /// Reserve all memory and shard capacity needed for an upsert before publishing
    /// a WAL record. If this succeeds, `commitPreparedUpsertLocked` is infallible.
    fn prepareUpsertLocked(
        self: *Store,
        shard: *Shard,
        existing_opt: ?*Entry,
        key: []const u8,
        value: []const u8,
        is_worm: bool,
        timestamp: u64,
    ) StoreError!PreparedUpsert {
        if (@import("builtin").is_test and self.fail_put_reserve_for_test) return error.OutOfMemory;
        if (existing_opt) |existing| {
            if (!existing.flags.arena_owned) {
                if (existing.value.len == value.len) {
                    return .{ .in_place_same_len = existing };
                }
                const new_val = self.allocator.dupe(u8, value) catch return error.OutOfMemory;
                return .{ .in_place_new_val = .{ .entry = existing, .new_val = new_val } };
            }
        }
        try self.shardReservePutLocked(shard, key);
        const entry = try self.createMemoryEntry(key, value, is_worm, timestamp);
        // A key that is new to the shard is indexed now, while failing is still
        // free; an arena-owned entry being superseded is already in the index and
        // only has its pointer swapped at commit.
        const is_new = existing_opt == null;
        if (is_new) {
            self.orderedInsertLocked(shard, entry) catch |err| {
                self.destroyEntry(entry);
                return err;
            };
        }
        return .{ .put_entry = .{ .entry = entry, .indexed = is_new } };
    }

    fn abortPreparedUpsert(self: *Store, prepared: PreparedUpsert) void {
        switch (prepared) {
            .in_place_same_len => {},
            .in_place_new_val => |p| self.allocator.free(p.new_val),
            .put_entry => |p| {
                if (p.indexed) self.orderedUnindexLocked(p.entry);
                self.destroyEntry(p.entry);
            },
        }
    }

    fn commitPreparedUpsertLocked(
        self: *Store,
        shard: *Shard,
        prepared: PreparedUpsert,
        value: []const u8,
        is_worm: bool,
        timestamp: u64,
    ) void {
        switch (prepared) {
            .in_place_same_len => |existing| {
                @memcpy(@constCast(existing.value), value);
                existing.timestamp = timestamp;
                existing.flags = .{ .is_worm = is_worm, .is_deleted = false };
            },
            .in_place_new_val => |p| {
                self.allocator.free(p.entry.value);
                p.entry.value = p.new_val;
                p.entry.timestamp = timestamp;
                p.entry.flags = .{ .is_worm = is_worm, .is_deleted = false };
            },
            .put_entry => |p| {
                self.shardPutReservedLocked(shard, p.entry);
            },
        }
    }

    /// Update an existing non-arena Entry in-place when overwriting, or allocate
    /// and insert a new Entry when the key is new or snapshot-arena-owned.
    /// Caller must hold `shard.mutex` and have already checked WORM constraints.
    fn upsertShardLocked(
        self: *Store,
        shard: *Shard,
        existing_opt: ?*Entry,
        key: []const u8,
        value: []const u8,
        is_worm: bool,
        timestamp: u64,
    ) StoreError!void {
        const prepared = try self.prepareUpsertLocked(shard, existing_opt, key, value, is_worm, timestamp);
        self.commitPreparedUpsertLocked(shard, prepared, value, is_worm, timestamp);
    }

    /// Append a vector-insert metadata record to the WAL. The vector bytes
    /// themselves are already durable through the normal SET record for `key`;
    /// this record carries replay metadata needed to update HNSW directly.
    pub fn appendVectorInsertWal(
        self: *Store,
        key: []const u8,
        namespace: []const u8,
        metric: []const u8,
        is_worm: bool,
        is_async: bool,
        timestamp: u64,
    ) StoreError!void {
        if (self.config.persistence != .full) return;
        if (self.wal == null) return;
        var flags: u8 = 0;
        if (is_worm) flags |= 0x01;
        if (is_async) flags |= 0x02;

        const total_len = Wal.vinsertRecordSize(key.len, namespace.len, metric.len);
        var stack_buf: [1024]u8 = undefined;
        const heap_buf: ?[]u8 = if (total_len > stack_buf.len)
            (self.allocator.alloc(u8, total_len) catch return error.OutOfMemory)
        else
            null;
        defer if (heap_buf) |hb| self.allocator.free(hb);
        const record = Wal.encodeVinsertRecord(
            if (heap_buf) |hb| hb else stack_buf[0..total_len],
            key,
            namespace,
            metric,
            flags,
            timestamp,
        );

        if (!self.wal.?.writer_started) self.wal_enqueue_mutex.lock();
        defer if (!self.wal.?.writer_started) self.wal_enqueue_mutex.unlock();
        self.wal.?.commitRecordBytesForLane(shardIndex(key), record) catch return error.IoError;
    }

    /// Append a vector-delete metadata record to the WAL. The KV deletion is
    /// already durable through the normal DELETE record.
    pub fn appendVectorDeleteWal(self: *Store, key: []const u8, namespace: []const u8) StoreError!void {
        if (self.config.persistence != .full) return;
        if (self.wal == null) return;

        const total_len = Wal.vdeleteRecordSize(key.len, namespace.len);
        var stack_buf: [1024]u8 = undefined;
        const heap_buf: ?[]u8 = if (total_len > stack_buf.len)
            (self.allocator.alloc(u8, total_len) catch return error.OutOfMemory)
        else
            null;
        defer if (heap_buf) |hb| self.allocator.free(hb);
        const record = Wal.encodeVdeleteRecord(
            if (heap_buf) |hb| hb else stack_buf[0..total_len],
            key,
            namespace,
        );

        if (!self.wal.?.writer_started) self.wal_enqueue_mutex.lock();
        defer if (!self.wal.?.writer_started) self.wal_enqueue_mutex.unlock();
        self.wal.?.commitRecordBytesForLane(shardIndex(key), record) catch return error.IoError;
    }

    /// Lock two keys atomically in stable shard order to avoid deadlocks.
    pub fn lockKeyPair(self: *Store, key_a: []const u8, key_b: []const u8) LockPair {
        const a = shardIndex(key_a);
        const b = shardIndex(key_b);
        if (a == b) {
            self.shards[a].mutex.lock();
            return .{ .low = a, .high = null };
        }

        const low = @min(a, b);
        const high = @max(a, b);
        self.shards[low].mutex.lock();
        self.shards[high].mutex.lock();
        return .{ .low = low, .high = high };
    }

    pub fn unlockKeyPair(self: *Store, pair: LockPair) void {
        if (pair.high) |high| self.shards[high].mutex.unlock();
        self.shards[pair.low].mutex.unlock();
    }

    /// In-memory put under an already-held shard lock. Never touches the WAL
    /// or snapshot truncation (callers that need durability use `set` /
    /// `setWithTimestamp`). Enforces live and frozen WORM immutability.
    fn setInternalLockedNoWal(self: *Store, si: usize, key: []const u8, value: []const u8, is_worm: bool) StoreError!void {
        const shard = &self.shards[si];
        const timestamp: u64 = @intCast(compat.nowMs());

        const existing = shard.data.get(key);
        if (existing) |ex| {
            if (ex.flags.is_worm) return error.WormViolation;
        } else if (self.sstHit(key)) |frozen| {
            // A frozen WORM key may not be shadowed by a live write — that
            // would silently serve the new value over the immutable one.
            if (frozen.is_worm) return error.WormViolation;
        }

        try self.upsertShardLocked(shard, existing, key, value, is_worm, timestamp);
    }

    /// Allocate an Entry that is not backed by a WAL record (snapshot/none
    /// durable path, or setUnsafe procedure path).
    fn createMemoryEntry(self: *Store, key: []const u8, value: []const u8, is_worm: bool, timestamp: u64) StoreError!*Entry {
        const e = self.allocator.create(Entry) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(e);
        // Use errdefer only for cleanup — do not free manually in catch arms
        // or errdefer will double-free on the same error path (#90 review).
        const ek = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(ek);
        const ev = try self.allocator.dupe(u8, value);
        e.* = .{ .key = ek, .value = ev, .timestamp = timestamp, .flags = .{ .is_worm = is_worm, .is_deleted = false } };
        return e;
    }

    /// Delete a key.
    pub fn delete(self: *Store, key: []const u8) StoreError!void {
        const si = shardIndex(key);
        var did_exist = false;
        {
            // Lock order: wal_enqueue_mutex (when compaction is possible) -> shard.mutex -> wal.lanes[si & WAL_LANE_MASK].mutex.
            const need_compaction_lock = self.config.persistence == .full and !self.wal.?.writer_started;
            if (need_compaction_lock) self.wal_enqueue_mutex.lock();
            defer if (need_compaction_lock) self.wal_enqueue_mutex.unlock();
            const shard = &self.shards[si];
            shard.mutex.lock();
            defer shard.mutex.unlock();
            const existing = shard.data.get(key) orelse return;
            if (existing.flags.is_worm) return error.WormViolation;
            if (self.config.persistence == .full) {
                self.wal.?.appendDeleteForLane(si, key) catch return error.IoError;
            }

            if (shardRemoveLocked(self, shard, key)) |removed| {
                self.destroyEntry(removed);
                did_exist = true;
            }
        }
        if (did_exist) {
            if (self.vector_registry) |reg| {
                if (reg.mayMatchFast(key)) {
                    self.syncVectorDeleteWithRegistry(reg, key);
                }
            }
        }
        // Snapshot takes every shard; never enter it with one already held.
        if (self.config.persistence == .full) {
            self.maybeSnapshotAndTruncate() catch {};
        }
    }

    pub fn exists(self: *Store, key: []const u8) bool {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        defer self.shards[si].mutex.unlock();
        return self.shards[si].data.contains(key);
    }

    pub fn count(self: *Store) usize {
        // O(1): STATUS and operators must not wait on 256 shard locks while
        // writers hold any of them for WAL/snapshot work (#91).
        return self.live_keys.load(.monotonic);
    }

    /// Get WAL size in bytes.
    pub fn walSize(self: *Store) !usize {
        if (self.wal) |*w| return w.size();
        return 0;
    }

    /// Iterate all key-value pairs, calling `callback` for each entry.
    /// Locks each shard individually to minimize contention.
    /// Used for anti-entropy sync (full-state dump on peer rejoin).
    pub fn iterateAll(self: *Store, ctx: *anyopaque, callback: *const fn (ctx: *anyopaque, key: []const u8, value: []const u8, is_worm: bool) void) void {
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            var iter = shard.data.iterator();
            while (iter.next()) |entry| {
                callback(ctx, entry.value_ptr.*.key, entry.value_ptr.*.value, entry.value_ptr.*.flags.is_worm);
            }
        }
    }

    /// Result of a prefix scan — all fields are arena-allocated copies.
    pub const ScanResult = struct {
        key: []const u8,
        value: []const u8,
        timestamp: u64,
        is_worm: bool,
    };

    /// Which end of the (ascending) match set a scan `limit` keeps.
    pub const ScanCut = enum {
        /// Keep the FIRST N matches — the natural cut for autocomplete,
        /// pagination, and range reads.
        first,
        /// Keep the LAST N matches — "newest last" for timestamp-keyed data
        /// (chat history, audit tails).
        last,
    };

    /// Scan for keys matching a prefix. Returns arena-allocated copies sorted by key (ascending);
    /// `limit` keeps the LAST N (see `scanPrefixFirst` for the first-N cut).
    /// Locks each shard individually — does NOT require the caller to hold any locks.
    /// Each shard contributes its match range via an O(log n) seek in the ordered
    /// index (not a full walk); total cost is O(SHARDS·log n + matches), with
    /// `limit` also bounding the per-shard copies.
    pub fn scanPrefix(
        self: *Store,
        prefix: []const u8,
        limit: usize,
        alloc: std.mem.Allocator,
    ) ![]ScanResult {
        return self.scanPrefixCut(prefix, limit, alloc, .last);
    }

    /// `scanPrefix` with the limit keeping the FIRST N matches in ascending
    /// order — what autocomplete and forward pagination want.
    pub fn scanPrefixFirst(
        self: *Store,
        prefix: []const u8,
        limit: usize,
        alloc: std.mem.Allocator,
    ) ![]ScanResult {
        return self.scanPrefixCutWithCursor(prefix, limit, alloc, .first, null);
    }

    /// Cursor-paginated prefix scan: returns entries matching `prefix` with
    /// key strictly greater than `after` (when non-null).
    pub fn scanPrefixAfter(
        self: *Store,
        prefix: []const u8,
        after: ?[]const u8,
        limit: usize,
        alloc: std.mem.Allocator,
        cut: ScanCut,
    ) ![]ScanResult {
        return self.scanPrefixCutWithCursor(prefix, limit, alloc, cut, after);
    }

    inline fn keySuffix(key: []const u8, prefix_len: usize) []const u8 {
        return if (prefix_len <= key.len) key[prefix_len..] else key;
    }

    inline fn loadPrefix8(key: []const u8, offset: usize) u64 {
        const tail = if (offset < key.len) key[offset..] else "";
        if (tail.len >= 8) {
            return std.mem.readInt(u64, tail[0..8], .big);
        }
        var buf: [8]u8 = @splat(0);
        @memcpy(buf[0..tail.len], tail);
        return std.mem.readInt(u64, &buf, .big);
    }

    fn scanHeapWorse(cut: ScanCut, prefix_len: usize, a: ScanResult, b: ScanResult) bool {
        // Returns true if `a` is closer to eviction than `b` (so `a` sits higher in the heap):
        // - For `.first` (keep smallest): max-heap root is the LARGEST key (`a.key > b.key`).
        // - For `.last` (keep largest): min-heap root is the SMALLEST key (`a.key < b.key`).
        // All keys share `prefix`, so comparing suffixes skips redundant prefix bytes.
        const a_tail = keySuffix(a.key, prefix_len);
        const b_tail = keySuffix(b.key, prefix_len);
        return switch (cut) {
            .first => std.mem.order(u8, a_tail, b_tail) == .gt,
            .last => std.mem.order(u8, a_tail, b_tail) == .lt,
        };
    }

    fn scanHeapSiftUp(items: []ScanResult, cut: ScanCut, prefix_len: usize, start_idx: usize) void {
        var idx = start_idx;
        while (idx > 0) {
            const parent = (idx - 1) / 2;
            if (scanHeapWorse(cut, prefix_len, items[idx], items[parent])) {
                std.mem.swap(ScanResult, &items[idx], &items[parent]);
                idx = parent;
            } else break;
        }
    }

    fn scanHeapSiftDown(items: []ScanResult, cut: ScanCut, prefix_len: usize, start_idx: usize) void {
        var idx = start_idx;
        const len = items.len;
        while (true) {
            const left = 2 * idx + 1;
            if (left >= len) break;
            var best = left;
            const right = left + 1;
            if (right < len and scanHeapWorse(cut, prefix_len, items[right], items[left])) {
                best = right;
            }
            if (scanHeapWorse(cut, prefix_len, items[best], items[idx])) {
                std.mem.swap(ScanResult, &items[idx], &items[best]);
                idx = best;
            } else break;
        }
    }

    fn scanHeapOffer(
        results: *std.ArrayListUnmanaged(ScanResult),
        alloc: std.mem.Allocator,
        limit: usize,
        cut: ScanCut,
        prefix_len: usize,
        key: []const u8,
        value: []const u8,
        timestamp: u64,
        is_worm: bool,
    ) !bool {
        if (limit > 0 and results.items.len == limit) {
            // Check against the eviction root before duping any memory:
            const k_tail = keySuffix(key, prefix_len);
            const r_tail = keySuffix(results.items[0].key, prefix_len);
            const better = switch (cut) {
                .first => std.mem.order(u8, k_tail, r_tail) == .lt,
                .last => std.mem.order(u8, k_tail, r_tail) == .gt,
            };
            if (!better) return false;

            const key_copy = try alloc.dupe(u8, key);
            errdefer alloc.free(key_copy);
            const val_copy = try alloc.dupe(u8, value);

            alloc.free(results.items[0].key);
            alloc.free(results.items[0].value);
            results.items[0] = .{
                .key = key_copy,
                .value = val_copy,
                .timestamp = timestamp,
                .is_worm = is_worm,
            };
            scanHeapSiftDown(results.items, cut, prefix_len, 0);
            return true;
        }

        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);
        const val_copy = try alloc.dupe(u8, value);
        errdefer alloc.free(val_copy);

        try results.append(alloc, .{
            .key = key_copy,
            .value = val_copy,
            .timestamp = timestamp,
            .is_worm = is_worm,
        });
        if (limit > 0) {
            scanHeapSiftUp(results.items, cut, prefix_len, results.items.len - 1);
        }
        return true;
    }

    fn scanPrefixCut(
        self: *Store,
        prefix: []const u8,
        limit: usize,
        alloc: std.mem.Allocator,
        cut: ScanCut,
    ) ![]ScanResult {
        return self.scanPrefixCutWithCursor(prefix, limit, alloc, cut, null);
    }

    fn scanPrefixCutWithCursor(
        self: *Store,
        prefix: []const u8,
        limit: usize,
        alloc: std.mem.Allocator,
        cut: ScanCut,
        after: ?[]const u8,
    ) ![]ScanResult {
        // Fast path (no frozen SST overlay and non-empty prefix): acquire ONE bucket's
        // shared lock and read `slot.value` (`*Entry`) directly under non-blocking
        // `shard.mutex.tryLock()`. Eliminates key staging copies AND all hash-table
        // probes while remaining 100% deadlock-free (any `tryLock()` miss immediately
        // drops `bucket.lock` and falls through to the lock-decoupled path below).
        if (self.sst_count == 0 and prefix.len > 0) fast_path: {
            var out: std.ArrayListUnmanaged(ScanResult) = .empty;
            var keep_out = false;
            defer if (!keep_out) {
                for (out.items) |r| {
                    alloc.free(r.key);
                    alloc.free(r.value);
                }
                out.deinit(alloc);
            };

            const b = &self.ordered.buckets[prefix[0]];
            b.lock.lockShared();
            var b_locked = true;
            defer if (b_locked) b.lock.unlockShared();

            const pre_cap = if (limit > 0) @min(limit, 1024) else 0;
            if (pre_cap > 0) {
                try out.ensureTotalCapacity(alloc, pre_cap);
            }
            const use_p8_fast = prefix.len <= 8;
            const p8_mask: u64 = if (prefix.len >= 8)
                std.math.maxInt(u64)
            else
                (~@as(u64, 0)) << @intCast((8 - prefix.len) * 8);
            const p8_target: u64 = btree_mod.loadPrefix8(prefix) & p8_mask;

            if (limit > 0 and cut == .last) {
                if (b.seekLast(prefix, after)) |start| {
                    var leaf: ?*OrderedIndex.LeafNode = start.leaf;
                    var idx = start.idx;
                    while (leaf) |lf| {
                        while (true) {
                            const slot = &lf.slots[idx];
                            const k = slot.key.slice();
                            if (use_p8_fast) {
                                if ((lf.prefix8[idx] & p8_mask) != p8_target or k.len < prefix.len) {
                                    leaf = null;
                                    break;
                                }
                            } else if (!std.mem.startsWith(u8, k, prefix)) {
                                leaf = null;
                                break;
                            }
                            if (after) |cursor| {
                                if (std.mem.order(u8, k, cursor) != .gt) {
                                    leaf = null;
                                    break;
                                }
                            }
                            if (idx >= 2) {
                                const pf = &lf.slots[idx - 2];
                                @prefetch(pf.value, .{ .rw = .read, .locality = 1, .cache = .data });
                                @prefetch(&self.shards[pf.shard_idx], .{ .rw = .write, .locality = 1, .cache = .data });
                            }
                            const shard = &self.shards[slot.shard_idx];
                            if (!shard.mutex.tryLock()) {
                                b.lock.unlockShared();
                                b_locked = false;
                                break :fast_path;
                            }
                            const e = slot.value;
                            const val_copy = alloc.dupe(u8, e.value) catch |err| {
                                shard.mutex.unlock();
                                return err;
                            };
                            const ts = e.timestamp;
                            const worm = e.flags.is_worm;
                            shard.mutex.unlock();
                            const key_copy = alloc.dupe(u8, k) catch |err| {
                                alloc.free(val_copy);
                                return err;
                            };
                            const row = ScanResult{
                                .key = key_copy,
                                .value = val_copy,
                                .timestamp = ts,
                                .is_worm = worm,
                            };
                            if (out.items.len < out.capacity) {
                                out.appendAssumeCapacity(row);
                            } else {
                                out.append(alloc, row) catch |err| {
                                    alloc.free(key_copy);
                                    alloc.free(val_copy);
                                    return err;
                                };
                            }
                            if (out.items.len >= limit) {
                                leaf = null;
                                break;
                            }
                            if (idx == 0) break;
                            idx -= 1;
                        }
                        if (leaf) |cur_lf| {
                            leaf = cur_lf.prev;
                            if (leaf) |prev_lf| {
                                if (prev_lf.hdr.count == 0) break;
                                idx = prev_lf.hdr.count - 1;
                            }
                        }
                    }
                    std.mem.reverse(ScanResult, out.items);
                }
            } else {
                if (b.seekFirst(prefix, after)) |start| {
                    var leaf: ?*OrderedIndex.LeafNode = start.leaf;
                    var idx = start.idx;
                    while (leaf) |lf| {
                        const cnt: usize = lf.hdr.count;
                        while (idx < cnt) : (idx += 1) {
                            const slot = &lf.slots[idx];
                            const k = slot.key.slice();
                            if (use_p8_fast) {
                                if ((lf.prefix8[idx] & p8_mask) != p8_target or k.len < prefix.len) {
                                    leaf = null;
                                    break;
                                }
                            } else if (!std.mem.startsWith(u8, k, prefix)) {
                                leaf = null;
                                break;
                            }
                            if (idx + 2 < cnt) {
                                const pf = &lf.slots[idx + 2];
                                @prefetch(pf.value, .{ .rw = .read, .locality = 1, .cache = .data });
                                @prefetch(&self.shards[pf.shard_idx], .{ .rw = .write, .locality = 1, .cache = .data });
                            }
                            const shard = &self.shards[slot.shard_idx];
                            if (!shard.mutex.tryLock()) {
                                b.lock.unlockShared();
                                b_locked = false;
                                break :fast_path;
                            }
                            const e = slot.value;
                            const val_copy = alloc.dupe(u8, e.value) catch |err| {
                                shard.mutex.unlock();
                                return err;
                            };
                            const ts = e.timestamp;
                            const worm = e.flags.is_worm;
                            shard.mutex.unlock();
                            const key_copy = alloc.dupe(u8, k) catch |err| {
                                alloc.free(val_copy);
                                return err;
                            };
                            const row = ScanResult{
                                .key = key_copy,
                                .value = val_copy,
                                .timestamp = ts,
                                .is_worm = worm,
                            };
                            if (out.items.len < out.capacity) {
                                out.appendAssumeCapacity(row);
                            } else {
                                out.append(alloc, row) catch |err| {
                                    alloc.free(key_copy);
                                    alloc.free(val_copy);
                                    return err;
                                };
                            }
                            if (limit > 0 and out.items.len >= limit) {
                                leaf = null;
                                break;
                            }
                        }
                        if (leaf) |cur_lf| {
                            leaf = cur_lf.next;
                            idx = 0;
                        }
                    }
                }
            }

            b.lock.unlockShared();
            b_locked = false;
            const slice = try out.toOwnedSlice(alloc);
            keep_out = true;
            return slice;
        }

        var collected = CollectedKeys{};
        defer collected.deinit(alloc);

        const bcut: btree_mod.Cut = switch (cut) {
            .first => .first,
            .last => .last,
        };
        try self.ordered.collectRange(alloc, prefix, after, limit, bcut, &collected);
        const key_refs = collected.refs();

        // Fast path (no frozen SST overlay mounted): `collected` already contains
        // the exact `<= limit` keys in strict global ascending order — zero heap
        // sifting, zero eviction churn, zero post-sort!
        if (self.sst_count == 0) {
            var out: std.ArrayListUnmanaged(ScanResult) = .empty;
            errdefer {
                for (out.items) |r| {
                    alloc.free(r.key);
                    alloc.free(r.value);
                }
                out.deinit(alloc);
            }
            if (key_refs.len == 0) return try out.toOwnedSlice(alloc);
            try out.ensureTotalCapacity(alloc, key_refs.len);

            for (key_refs) |ref| {
                const k = collected.keySlice(ref);
                const shard = &self.shards[ref.shard_idx];
                shard.mutex.lock();
                const entry_opt = shard.data.getAdapted(k, PrehashedStringCtx{ .h = ref.key_hash });
                if (entry_opt) |e| {
                    const key_copy = alloc.dupe(u8, e.key) catch |err| {
                        shard.mutex.unlock();
                        return err;
                    };
                    const val_copy = alloc.dupe(u8, e.value) catch |err| {
                        shard.mutex.unlock();
                        alloc.free(key_copy);
                        return err;
                    };
                    const ts = e.timestamp;
                    const worm = e.flags.is_worm;
                    shard.mutex.unlock();
                    out.appendAssumeCapacity(.{
                        .key = key_copy,
                        .value = val_copy,
                        .timestamp = ts,
                        .is_worm = worm,
                    });
                } else {
                    shard.mutex.unlock();
                }
            }
            return try out.toOwnedSlice(alloc);
        }

        // SST overlay path: merge live results + frozen SST ranges with bounded heap.
        var results: std.ArrayListUnmanaged(ScanResult) = .empty;
        errdefer {
            for (results.items) |r| {
                alloc.free(r.key);
                alloc.free(r.value);
            }
            results.deinit(alloc);
        }
        if (limit > 0) {
            try results.ensureTotalCapacity(alloc, @min(limit, 1024));
        } else if (key_refs.len > 0) {
            try results.ensureTotalCapacity(alloc, key_refs.len);
        }

        const prefix_len = prefix.len;
        for (key_refs) |ref| {
            const k = collected.keySlice(ref);
            const shard = &self.shards[ref.shard_idx];
            shard.mutex.lock();
            const entry_opt = shard.data.getAdapted(k, PrehashedStringCtx{ .h = ref.key_hash });
            if (entry_opt) |e| {
                const offered = scanHeapOffer(&results, alloc, limit, cut, prefix_len, e.key, e.value, e.timestamp, e.flags.is_worm) catch |err| {
                    shard.mutex.unlock();
                    return err;
                };
                shard.mutex.unlock();
                _ = offered;
            } else {
                shard.mutex.unlock();
            }
        }

        // Frozen sst overlay: collect the same per-source window from each
        // mounted segment (two binary searches + an index slice). Keys present
        // in the live shards are skipped — live writes shadow frozen data.
        // No shard lock is held here, so the containsLive probe cannot deadlock.
        const live_may_shadow = self.livePrefixNonEmpty(prefix);
        for (self.ssts_buf[0..self.sst_count]) |sst| {
            var range = sst.prefixRange(prefix);
            if (after) |cursor| {
                while (range.lo < range.hi) {
                    const hit = sst.hitAt(range.lo);
                    if (std.mem.order(u8, hit.key, cursor) == .gt) break;
                    range.lo += 1;
                }
            }
            if (range.lo == range.hi) continue;

            if (limit > 0 and cut == .last) {
                const start = if (range.hi - range.lo > limit) range.hi - limit else range.lo;
                var idx = range.hi;
                while (idx > start) {
                    idx -= 1;
                    const hit = sst.hitAt(idx);
                    if (live_may_shadow and self.containsLive(hit.key)) continue;
                    if (!try scanHeapOffer(&results, alloc, limit, cut, prefix_len, hit.key, hit.value, hit.timestamp, hit.is_worm)) {
                        break;
                    }
                }
            } else {
                const end = if (limit > 0 and range.hi - range.lo > limit) range.lo + limit else range.hi;
                var i = range.lo;
                while (i < end) : (i += 1) {
                    const hit = sst.hitAt(i);
                    if (live_may_shadow and self.containsLive(hit.key)) continue;
                    if (!try scanHeapOffer(&results, alloc, limit, cut, prefix_len, hit.key, hit.value, hit.timestamp, hit.is_worm)) {
                        break;
                    }
                }
            }
        }

        // Sort surviving items by key ascending (lexicographic = chronological for timestamp-keyed data).
        const n = results.items.len;
        if (n <= 1) {
            return try results.toOwnedSlice(alloc);
        }

        if (n <= 32) {
            std.sort.pdq(ScanResult, results.items, prefix_len, struct {
                fn lessThan(p_len: usize, a: ScanResult, b: ScanResult) bool {
                    return std.mem.lessThan(u8, keySuffix(a.key, p_len), keySuffix(b.key, p_len));
                }
            }.lessThan);
            return try results.toOwnedSlice(alloc);
        }

        // For larger result sets, pack the first 8 suffix bytes inline into a 16-byte
        // SortSlot so pdqsort compares registers with minimal pointer chasing and
        // avoids swapping 48-byte ScanResult structs during partitioning.
        const SortSlot = struct {
            prefix8: u64,
            idx: u32,
        };
        const SortCtx = struct {
            items: []const ScanResult,
            p_len: usize,
            fn lessThan(ctx: @This(), a: SortSlot, b: SortSlot) bool {
                if (a.prefix8 != b.prefix8) return a.prefix8 < b.prefix8;
                return std.mem.lessThan(
                    u8,
                    keySuffix(ctx.items[a.idx].key, ctx.p_len),
                    keySuffix(ctx.items[b.idx].key, ctx.p_len),
                );
            }
        };

        var stack_slots: [256]SortSlot = undefined;
        var heap_slots: ?[]SortSlot = null;
        defer if (heap_slots) |hs| alloc.free(hs);
        const slots: []SortSlot = if (n <= stack_slots.len)
            stack_slots[0..n]
        else blk: {
            const buf = try alloc.alloc(SortSlot, n);
            heap_slots = buf;
            break :blk buf;
        };

        for (results.items, 0..) |r, i| {
            slots[i] = .{
                .prefix8 = loadPrefix8(r.key, prefix_len),
                .idx = @intCast(i),
            };
        }

        std.sort.pdq(SortSlot, slots, SortCtx{ .items = results.items, .p_len = prefix_len }, SortCtx.lessThan);

        const out = try alloc.alloc(ScanResult, n);
        for (slots, 0..) |s, i| {
            out[i] = results.items[s.idx];
        }
        results.deinit(alloc);
        return out;
    }

    /// Control flow return from a scan callback.
    pub const ScanAction = enum { cont, stop };

    /// Callback-based prefix scan — yields borrowed key/value slices to the
    /// callback while the matching shard is still locked. Zero allocations,
    /// zero copies. Suitable for hot paths (vector search, index rebuild)
    /// where arena-duping every matching value would be prohibitive.
    ///
    /// Matches are found via the ordered index (O(log n) seek per shard) and
    /// yielded in ascending key order WITHIN each shard; no global order is
    /// promised across shards.
    ///
    /// The callback MUST NOT:
    ///   - Retain the slices after returning (memory is only valid during the call)
    ///   - Call any Store method that acquires shard locks (deadlock risk)
    ///   - Block on long-running work (the shard is locked, blocking writers)
    ///
    /// Returns `.stop` from the callback to halt iteration early.
    ///
    /// Fails with `error.OutOfMemory` when a shard is contended and the scan cannot
    /// allocate the cursor or key chunk it needs to resume without the bucket lock.
    /// The callback may already have seen a prefix of the matches by then; callers
    /// must treat an error as "result incomplete", never as an empty or short scan.
    pub fn scanPrefixCallback(
        self: *Store,
        prefix: []const u8,
        context: *anyopaque,
        callback: *const fn (
            context: *anyopaque,
            key: []const u8,
            value: []const u8,
            timestamp: u64,
            is_worm: bool,
        ) ScanAction,
    ) error{OutOfMemory}!void {
        var cursor_stack: [512]u8 = undefined;
        var cursor_heap: std.ArrayListUnmanaged(u8) = .empty;
        defer cursor_heap.deinit(self.allocator);
        var cursor: ?[]const u8 = null;
        var fast_done = false;

        // Fast path for non-empty prefixes: walk leaf chain directly under one
        // shared bucket lock using non-blocking `shard.mutex.tryLock()` — zero
        // staging copies, zero hash lookups, zero allocations. If any shard is
        // contended, record the last yielded key as a cursor, release `bucket.lock`
        // immediately (zero deadlock), and resume via the lock-decoupled chunk loop.
        if (prefix.len > 0) fast_cb: {
            const b = &self.ordered.buckets[prefix[0]];
            b.lock.lockShared();
            var b_locked = true;
            defer if (b_locked) b.lock.unlockShared();

            var prev_yielded: ?[]const u8 = null;
            if (b.seekFirst(prefix, null)) |start| {
                var leaf: ?*OrderedIndex.LeafNode = start.leaf;
                var idx = start.idx;
                while (leaf) |lf| {
                    while (idx < lf.hdr.count) : (idx += 1) {
                        const slot = &lf.slots[idx];
                        const k = slot.key.slice();
                        if (!std.mem.startsWith(u8, k, prefix)) {
                            fast_done = true;
                            break :fast_cb;
                        }
                        const shard = &self.shards[slot.shard_idx];
                        if (!shard.mutex.tryLock()) {
                            if (prev_yielded) |pk| {
                                if (pk.len <= cursor_stack.len) {
                                    @memcpy(cursor_stack[0..pk.len], pk);
                                    cursor = cursor_stack[0..pk.len];
                                } else {
                                    cursor_heap.clearRetainingCapacity();
                                    try cursor_heap.appendSlice(self.allocator, pk);
                                    cursor = cursor_heap.items;
                                }
                            }
                            b.lock.unlockShared();
                            b_locked = false;
                            break :fast_cb;
                        }
                        const e = slot.value;
                        const action = callback(context, e.key, e.value, e.timestamp, e.flags.is_worm);
                        shard.mutex.unlock();
                        if (action == .stop) return;
                        prev_yielded = k;
                    }
                    leaf = lf.next;
                    idx = 0;
                }
            }
            fast_done = true;
        }

        if (!fast_done) {
            const CHUNK: usize = 64;
            var chunk = CollectedKeys{};
            defer chunk.deinit(self.allocator);

            while (true) {
                chunk.clear();
                self.ordered.collectRange(self.allocator, prefix, cursor, CHUNK, .first, &chunk) catch return error.OutOfMemory;
                const key_refs = chunk.refs();
                if (key_refs.len == 0) break;

                for (key_refs) |ref| {
                    const k = chunk.keySlice(ref);
                    const shard = &self.shards[ref.shard_idx];
                    shard.mutex.lock();
                    if (shard.data.getAdapted(k, PrehashedStringCtx{ .h = ref.key_hash })) |e| {
                        const action = callback(context, e.key, e.value, e.timestamp, e.flags.is_worm);
                        shard.mutex.unlock();
                        if (action == .stop) return;
                    } else {
                        shard.mutex.unlock();
                    }
                }

                if (key_refs.len < CHUNK) break;
                const last_k = chunk.keySlice(key_refs[key_refs.len - 1]);
                if (last_k.len <= cursor_stack.len) {
                    @memcpy(cursor_stack[0..last_k.len], last_k);
                    cursor = cursor_stack[0..last_k.len];
                } else {
                    cursor_heap.clearRetainingCapacity();
                    try cursor_heap.appendSlice(self.allocator, last_k);
                    cursor = cursor_heap.items;
                }
            }
        }

        // Frozen sst overlay — yielded after the live entries, skipping live-shadowed keys.
        const live_may_shadow = self.sst_count > 0 and self.livePrefixNonEmpty(prefix);
        for (self.ssts_buf[0..self.sst_count]) |sst| {
            const range = sst.prefixRange(prefix);
            var i = range.lo;
            while (i < range.hi) : (i += 1) {
                const hit = sst.hitAt(i);
                if (live_may_shadow and self.containsLive(hit.key)) continue;
                switch (callback(context, hit.key, hit.value, hit.timestamp, hit.is_worm)) {
                    .cont => {},
                    .stop => return,
                }
            }
        }
    }

    /// Count keys matching a prefix. O(log n) in a single ordered B+Tree bucket
    /// via maintained subtree counts — no allocation, no walking of matches.
    pub fn countPrefix(self: *Store, prefix: []const u8) usize {
        var total: usize = self.ordered.countPrefix(prefix);
        for (self.ssts_buf[0..self.sst_count]) |sst| {
            const range = sst.prefixRange(prefix);
            total += range.hi - range.lo;
        }
        return total;
    }

    /// Manually save current state as snapshot. Available in full and snapshot modes.
    /// In direct WAL mode (`!writer_started`), also truncates the WAL atomically under
    /// `wal_enqueue_mutex` so `wormdb.wal` does not grow unboundedly across `SAVE` calls.
    pub fn save(self: *Store) !void {
        if (self.config.persistence == .none) return;
        if (self.wal) |*w| {
            if (!w.writer_started) {
                self.wal_enqueue_mutex.lock();
                defer self.wal_enqueue_mutex.unlock();
                try self.writeSnapshot();
                try w.truncate();
                return;
            }
        }
        try self.writeSnapshot();
    }

    const MAX_INCREMENTAL_WAL_KEYS: usize = 4096;

    const WalVectorTracker = struct {
        allocator: std.mem.Allocator,
        entries: std.ArrayListUnmanaged(NsDelta) = .empty,

        const NsDelta = struct {
            namespace: []u8,
            dirty_keys: std.StringHashMapUnmanaged(void) = .empty,
            needs_full_rebuild: bool = false,
            reconciled: bool = false,
        };

        fn initFromRegistry(allocator: std.mem.Allocator, maybe_reg: ?*NamespaceRegistry) !WalVectorTracker {
            var self = WalVectorTracker{ .allocator = allocator };
            errdefer self.deinit();
            const reg = maybe_reg orelse return self;
            reg.lock.lockShared();
            defer reg.lock.unlockShared();

            var it = reg.map.iterator();
            while (it.next()) |kv| {
                const ns_copy = try allocator.dupe(u8, kv.key_ptr.*);
                errdefer allocator.free(ns_copy);
                try self.entries.append(allocator, .{ .namespace = ns_copy });
            }
            return self;
        }

        fn deinit(self: *WalVectorTracker) void {
            for (self.entries.items) |*e| {
                var kit = e.dirty_keys.keyIterator();
                while (kit.next()) |k| self.allocator.free(k.*);
                e.dirty_keys.deinit(self.allocator);
                self.allocator.free(e.namespace);
            }
            self.entries.deinit(self.allocator);
        }

        fn noteKey(self: *WalVectorTracker, key: []const u8) !void {
            if (self.entries.items.len == 0) return;
            if (std.mem.startsWith(u8, key, "bq:") or std.mem.startsWith(u8, key, "__meta:")) return;
            for (self.entries.items) |*e| {
                if (!std.mem.startsWith(u8, key, e.namespace)) continue;
                if (e.needs_full_rebuild) continue;
                if (e.dirty_keys.contains(key)) continue;
                if (e.dirty_keys.count() >= MAX_INCREMENTAL_WAL_KEYS) {
                    e.needs_full_rebuild = true;
                    continue;
                }
                const k_copy = try self.allocator.dupe(u8, key);
                errdefer self.allocator.free(k_copy);
                try e.dirty_keys.put(self.allocator, k_copy, {});
            }
        }

        fn isRestored(self: *const WalVectorTracker, namespace: []const u8) bool {
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.namespace, namespace)) return true;
            }
            return false;
        }

        fn isReconciled(self: *const WalVectorTracker, namespace: []const u8) bool {
            for (self.entries.items) |e| {
                if (std.mem.eql(u8, e.namespace, namespace)) return e.reconciled;
            }
            return false;
        }
    };

    fn replayWal(self: *Store, tracker: *WalVectorTracker) !void {
        var iter = self.wal.?.iterator();

        const wal_size = self.wal.?.size() catch 0;
        if (wal_size > 0) {
            std.log.info("Replaying WAL ({d} bytes)...", .{wal_size});
        }

        var record_count: usize = 0;
        while (try iter.next()) |record| {
            if (record_count > 0 and record_count % 500_000 == 0) {
                std.log.info("WAL replay progress: {d} records processed...", .{record_count});
            }
            switch (record) {
                .set => |set_rec| {
                    const shard = &self.shards[shardIndex(set_rec.key)];

                    // WORM-replay guard (proof spine): a replayed set must
                    // never overwrite an existing WORM entry.
                    if (shard.data.get(set_rec.key)) |existing| {
                        if (existing.flags.is_worm) {
                            self.allocator.free(set_rec.key);
                            self.allocator.free(set_rec.value);
                            continue;
                        }
                    }

                    try tracker.noteKey(set_rec.key);

                    const entry = self.allocator.create(Entry) catch |err| {
                        self.allocator.free(set_rec.key);
                        self.allocator.free(set_rec.value);
                        return err;
                    };
                    entry.* = .{
                        .key = set_rec.key,
                        .value = set_rec.value,
                        .timestamp = set_rec.timestamp,
                        .flags = set_rec.flags,
                    };
                    errdefer self.destroyEntry(entry);
                    // shardPutLocked replaces any prior version of the key
                    // atomically (and leaves the shard untouched on error).
                    try self.shardPutLocked(shard, entry);
                },
                .delete => |key| {
                    const shard = &self.shards[shardIndex(key)];
                    // WORM-replay guard (proof spine): never delete a WORM
                    // entry during replay; shardRemoveLocked keeps the
                    // ordered index in sync for the non-WORM path.
                    if (shard.data.get(key)) |existing| {
                        if (!existing.flags.is_worm) {
                            try tracker.noteKey(key);
                            if (shardRemoveLocked(self, shard, key)) |removed| {
                                self.destroyEntry(removed);
                            }
                        }
                    }
                    self.allocator.free(key);
                },
                .vinsert => |vinsert| {
                    try tracker.noteKey(vinsert.key);
                    // Restored v2 snapshot namespaces are reconciled after WAL replay
                    // from final live KV state. Configured indexes are also handled
                    // after replay; only unconfigured non-restored namespaces need
                    // per-record replay for their metric metadata.
                    if (!tracker.isRestored(vinsert.namespace) and !self.vectorNamespaceHasConfig(vinsert.namespace)) {
                        self.replayVectorInsert(vinsert) catch |err| {
                            std.log.warn("WAL vector insert replay skipped '{s}': {s}", .{ vinsert.key, @errorName(err) });
                        };
                    }
                    self.allocator.free(vinsert.key);
                    self.allocator.free(vinsert.namespace);
                    self.allocator.free(vinsert.metric);
                },
                .vdelete => |vdelete| {
                    try tracker.noteKey(vdelete.key);
                    if (!tracker.isRestored(vdelete.namespace) and !self.vectorNamespaceHasConfig(vdelete.namespace)) {
                        self.replayVectorDelete(vdelete) catch |err| {
                            std.log.warn("WAL vector delete replay skipped '{s}': {s}", .{ vdelete.key, @errorName(err) });
                        };
                    }
                    self.allocator.free(vdelete.key);
                    self.allocator.free(vdelete.namespace);
                },
            }
            record_count += 1;
        }

        // Cut off a torn tail before the first append can land behind it.
        try self.wal.?.finishReplay(&iter);

        if (record_count > 0) {
            std.log.info("WAL replay complete. Processed {d} records.", .{record_count});
        }
    }

    fn vectorNamespaceHasConfig(self: *Store, namespace: []const u8) bool {
        var key_buf: [512]u8 = undefined;
        const config_key = std.fmt.bufPrint(
            &key_buf,
            "__meta:vecns:{s}",
            .{namespace},
        ) catch return false;
        return self.get(config_key) != null;
    }

    fn replayVectorInsert(self: *Store, record: WalRecord.VinsertRecord) !void {
        const reg = self.vector_registry orelse return;
        if (record.namespace.len == 0 or !std.mem.startsWith(u8, record.key, record.namespace)) return;

        const metric = Metric.fromStr(record.metric) orelse return;
        const value = try self.getValueDupe(record.key, self.allocator) orelse return;
        defer self.allocator.free(value);
        const vec = distance.bytesToF32(value) orelse return;

        const ns_idx = try reg.getOrCreate(record.namespace, metric);
        if (record.isAsync() and !ns_idx.async_mode) {
            ns_idx.enableAsyncMode() catch |err| {
                std.log.warn("WAL vector insert replay: async mode '{s}': {s}", .{ record.namespace, @errorName(err) });
            };
        }

        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        _ = try ns_idx.insertLocked(record.key, vec, record.timestamp);
    }

    fn replayVectorDelete(self: *Store, record: WalRecord.VdeleteRecord) !void {
        const reg = self.vector_registry orelse return;
        if (record.namespace.len == 0 or !std.mem.startsWith(u8, record.key, record.namespace)) return;

        const ns_idx = reg.get(record.namespace) orelse return;
        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        _ = ns_idx.markTombstoneLocked(record.key);
    }

    const VectorRebuildCtx = struct {
        ns_idx: *hnsw_index_mod.NamespaceIndex,
        expected_dim: usize = 0,
        inserted: usize = 0,
        skipped: usize = 0,
        oom: bool = false,
    };

    fn rebuildVectorMatch(
        raw_ctx: *anyopaque,
        key: []const u8,
        value: []const u8,
        timestamp: u64,
        is_worm: bool,
    ) ScanAction {
        _ = is_worm;
        const ctx: *VectorRebuildCtx = @ptrCast(@alignCast(raw_ctx));
        const vec = distance.bytesToF32(value) orelse {
            ctx.skipped += 1;
            return .cont;
        };
        if (ctx.expected_dim == 0) {
            ctx.expected_dim = vec.len;
        } else if (vec.len != ctx.expected_dim) {
            ctx.skipped += 1;
            return .cont;
        }
        _ = ctx.ns_idx.insertLocked(key, vec, timestamp) catch |err| {
            if (err == error.OutOfMemory) {
                ctx.oom = true;
                return .stop;
            }
            ctx.skipped += 1;
            return .cont;
        };
        ctx.inserted += 1;
        return .cont;
    }

    fn rebuildVectorNamespaceFromKv(self: *Store, namespace: []const u8, metric: Metric) !void {
        const reg = self.vector_registry orelse return;
        const ns_idx = reg.getOrCreate(namespace, metric) catch |err| {
            std.log.warn("startup vector rebuild: skip '{s}': {s}", .{ namespace, @errorName(err) });
            return;
        };
        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        ns_idx.clearLocked();

        var rb = VectorRebuildCtx{ .ns_idx = ns_idx };
        try self.scanPrefixCallback(namespace, @ptrCast(&rb), rebuildVectorMatch);
        if (rb.oom) return error.OutOfMemory;
        if (rb.inserted > 0 or rb.skipped > 0) {
            std.log.info("startup vector rebuild: {s} inserted={d} skipped={d}", .{
                namespace,
                rb.inserted,
                rb.skipped,
            });
        }
    }

    fn reconcileVectorIndexes(self: *Store, tracker: *WalVectorTracker) !void {
        if (self.vector_registry) |reg| {
            for (tracker.entries.items) |*delta| {
                const ns_idx = reg.get(delta.namespace) orelse continue;
                if (!delta.needs_full_rebuild) {
                    if (delta.dirty_keys.count() == 0) {
                        delta.reconciled = true;
                        std.log.info("startup vector restore: {s} preserved={d} from snapshot", .{
                            delta.namespace,
                            ns_idx.liveCount(),
                        });
                        continue;
                    }
                    var applied: usize = 0;
                    var tombstoned: usize = 0;
                    var kit = delta.dirty_keys.keyIterator();
                    while (kit.next()) |k_ptr| {
                        const key = k_ptr.*;
                        if (self.getUnsafe(key)) |entry| {
                            if (distance.bytesToF32(entry.value)) |vec| {
                                ns_idx.lock.lock();
                                defer ns_idx.lock.unlock();
                                if (ns_idx.dim == null or vec.len == ns_idx.dim.?) {
                                    _ = try ns_idx.insertLocked(key, vec, entry.timestamp);
                                    applied += 1;
                                } else {
                                    _ = ns_idx.markTombstoneLocked(key);
                                    tombstoned += 1;
                                }
                            } else {
                                ns_idx.lock.lock();
                                defer ns_idx.lock.unlock();
                                _ = ns_idx.markTombstoneLocked(key);
                                tombstoned += 1;
                            }
                        } else {
                            ns_idx.lock.lock();
                            defer ns_idx.lock.unlock();
                            _ = ns_idx.markTombstoneLocked(key);
                            tombstoned += 1;
                        }
                    }
                    delta.reconciled = true;
                    std.log.info("startup vector restore: {s} preserved={d} wal_applied={d} wal_tombstoned={d}", .{
                        delta.namespace,
                        ns_idx.liveCount(),
                        applied,
                        tombstoned,
                    });
                } else {
                    try self.rebuildVectorNamespaceFromKv(delta.namespace, ns_idx.metric);
                    delta.reconciled = true;
                }
            }
        }

        try self.rebuildConfiguredVectorIndexesFromKv(tracker);
        try self.rebuildMemoryVectorIndexesFromKv(tracker);
    }

    fn rebuildConfiguredVectorIndexesFromKv(self: *Store, tracker: *const WalVectorTracker) !void {
        const configs = try self.scanPrefix("__meta:vecns:", 0, self.allocator);
        defer {
            for (configs) |cfg| {
                self.allocator.free(cfg.key);
                self.allocator.free(cfg.value);
            }
            self.allocator.free(configs);
        }

        for (configs) |cfg| {
            const namespace = vectorNamespaceFromConfigKey(cfg.key) orelse continue;
            if (tracker.isReconciled(namespace)) continue;
            const metric_name = extractJsonField(cfg.value, "metric") orelse "cosine";
            const metric = Metric.fromStr(metric_name) orelse .cosine;
            try self.rebuildVectorNamespaceFromKv(namespace, metric);
        }
    }

    fn rebuildMemoryVectorIndexesFromKv(self: *Store, tracker: *const WalVectorTracker) !void {
        const configs = try self.scanPrefix("__meta:mem:", 0, self.allocator);
        defer {
            for (configs) |cfg| {
                self.allocator.free(cfg.key);
                self.allocator.free(cfg.value);
            }
            self.allocator.free(configs);
        }

        for (configs) |cfg| {
            const ns = memoryNamespaceFromConfigKey(cfg.key) orelse continue;
            const metric_name = extractJsonField(cfg.value, "metric") orelse "cosine";
            const metric = Metric.fromStr(metric_name) orelse .cosine;
            const vec_namespace = try std.fmt.allocPrint(self.allocator, "vec:mem:{s}:", .{ns});
            defer self.allocator.free(vec_namespace);
            if (tracker.isReconciled(vec_namespace)) continue;

            // Normal memory ingest also creates a generic vector-namespace
            // config. `rebuildConfiguredVectorIndexesFromKv` has already
            // rebuilt that exact namespace, so do not clear and build the
            // same HNSW graph a second time.
            const vec_config_key = try std.fmt.allocPrint(
                self.allocator,
                "__meta:vecns:{s}",
                .{vec_namespace},
            );
            defer self.allocator.free(vec_config_key);
            if (self.get(vec_config_key) != null) continue;

            try self.rebuildVectorNamespaceFromKv(vec_namespace, metric);
        }
    }

    fn vectorNamespaceFromConfigKey(key: []const u8) ?[]const u8 {
        const prefix = "__meta:vecns:";
        if (!std.mem.startsWith(u8, key, prefix)) return null;
        if (key.len <= prefix.len) return null;
        return key[prefix.len..];
    }

    fn memoryNamespaceFromConfigKey(key: []const u8) ?[]const u8 {
        const prefix = "__meta:mem:";
        const suffix = ":config";
        if (!std.mem.startsWith(u8, key, prefix)) return null;
        if (!std.mem.endsWith(u8, key, suffix)) return null;
        if (key.len <= prefix.len + suffix.len) return null;
        return key[prefix.len .. key.len - suffix.len];
    }

    fn extractJsonField(json: []const u8, field: []const u8) ?[]const u8 {
        var needle_buf: [96]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{field}) catch return null;
        const start_rel = std.mem.indexOf(u8, json, needle) orelse return null;
        const start = start_rel + needle.len;
        const end_rel = std.mem.indexOfScalar(u8, json[start..], '"') orelse return null;
        return json[start .. start + end_rel];
    }

    fn maybeSnapshotAndTruncate(self: *Store) !void {
        // Background WAL writer and truncation are not coordinated yet.
        // Keep truncation disabled in sync_writes mode to avoid races.
        if (self.config.sync_writes) return;
        if (self.config.max_wal_size == 0) return;
        if (self.wal) |*w| {
            // Hold wal_enqueue for the entire snap+truncate window so no
            // concurrent durable SET can append a WAL record that is missing
            // from the snapshot copy and then get wiped by truncate (#92 P1).
            self.wal_enqueue_mutex.lock();
            defer self.wal_enqueue_mutex.unlock();

            const wal_size = try w.size();
            if (wal_size < self.config.max_wal_size) return;
            try self.writeSnapshot();
            try w.truncate();
        }
    }

    fn writeSnapshot(self: *Store) !void {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();

        // Phase 1: under all shard locks, deep-copy each shard's already-sorted
        // entries (+ optional HNSW trailer bytes) into a single bump arena.
        // Phase 2 (256-way merge + disk I/O) does NOT hold shard locks (#91).
        const SnapRec = struct {
            key: []u8,
            value: []u8,
            flags: EntryFlags,
            timestamp: u64,
        };

        var snap_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer snap_arena.deinit();
        const snap_alloc = snap_arena.allocator();

        var records: std.ArrayListUnmanaged(SnapRec) = .empty;

        var hnsw_trailer: std.ArrayListUnmanaged(u8) = .empty;
        defer hnsw_trailer.deinit(self.allocator);

        {
            for (&self.shards) |*shard| shard.mutex.lock();
            defer for (&self.shards) |*shard| shard.mutex.unlock();

            try records.ensureTotalCapacity(snap_alloc, self.live_keys.load(.monotonic));

            const VisitCtx = struct {
                snap_alloc: std.mem.Allocator,
                records: *std.ArrayListUnmanaged(SnapRec),
            };
            var vctx = VisitCtx{
                .snap_alloc = snap_alloc,
                .records = &records,
            };
            try self.ordered.visitAllSorted(&vctx, struct {
                fn visit(c: *VisitCtx, entry: *Entry) anyerror!void {
                    var flags = entry.flags;
                    flags.arena_owned = false;
                    try c.records.append(c.snap_alloc, .{
                        .key = try c.snap_alloc.dupe(u8, entry.key),
                        .value = try c.snap_alloc.dupe(u8, entry.value),
                        .flags = flags,
                        .timestamp = entry.timestamp,
                    });
                }
            }.visit);

            // Capture HNSW while shards are still locked so the trailer matches
            // the copied KV set (Copilot: unlocked writeTo raced with vinsert).
            if (self.vector_registry) |reg| {
                if (reg.map.count() > 0) {
                    const MemWriter = struct {
                        list: *std.ArrayListUnmanaged(u8),
                        allocator: std.mem.Allocator,
                        pub fn writeAll(mw: *@This(), data: []const u8) !void {
                            try mw.list.appendSlice(mw.allocator, data);
                        }
                    };
                    var mw = MemWriter{ .list = &hnsw_trailer, .allocator = self.allocator };
                    reg.writeTo(&mw) catch |err| {
                        std.log.warn("writeSnapshot: HNSW trailer skipped: {s}", .{@errorName(err)});
                        hnsw_trailer.clearRetainingCapacity();
                    };
                }
            }
        }

        const temp_snapshot_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.config.snapshot_path});
        defer self.allocator.free(temp_snapshot_path);

        const snapshot_file = try compat.Dir.createFile(core.compat.cwd(), temp_snapshot_path, .{ .read = true, .truncate = true });
        var file_open = true;
        defer if (file_open) compat.File.close(snapshot_file);

        var writer = BufferedFileWriter{
            .file = snapshot_file,
            .buf = try self.allocator.alloc(u8, SNAPSHOT_READ_BUF_SIZE),
        };
        defer self.allocator.free(writer.buf);

        try writer.writeAll(SNAPSHOT_MAGIC);

        var version_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, version_buf[0..4], SNAPSHOT_VERSION, .little);
        try writer.writeAll(version_buf[0..4]);

        var count_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, count_buf[0..8], @intCast(records.items.len), .little);
        try writer.writeAll(count_buf[0..8]);

        // Records are already in strict global ascending order from OrderedIndex.
        for (records.items) |rec| {
            var header_buf: [17]u8 = undefined;
            std.mem.writeInt(u32, header_buf[0..4], @intCast(rec.key.len), .little);
            std.mem.writeInt(u32, header_buf[4..8], @intCast(rec.value.len), .little);
            header_buf[8] = @bitCast(rec.flags);
            std.mem.writeInt(u64, header_buf[9..17], rec.timestamp, .little);
            try writer.writeAll(header_buf[0..]);
            try writer.writeAll(rec.key);
            try writer.writeAll(rec.value);
        }

        if (hnsw_trailer.items.len > 0) {
            try writer.writeAll(hnsw_trailer.items);
        }

        try writer.flush();
        try compat.File.sync(snapshot_file);
        compat.File.close(snapshot_file);
        file_open = false;

        try compat.Dir.rename(core.compat.cwd(), temp_snapshot_path, self.config.snapshot_path);
    }

    /// Buffered counterpart to BufferedFileReader for the snapshot write path.
    /// Exposes `.writeAll`, so the registry/HNSW serializers (which take
    /// `anytype` writers) stream through the same buffer. Callers must
    /// `flush()` before sync/close.
    const BufferedFileWriter = struct {
        file: std.Io.File,
        buf: []u8,
        end: usize = 0,

        pub fn writeAll(self: *@This(), data: []const u8) !void {
            // Writes at/above one buffer go straight to the file (after a
            // flush to preserve ordering) — no point double-copying.
            if (data.len >= self.buf.len) {
                try self.flush();
                return compat.File.writeAll(self.file, data);
            }
            if (self.end + data.len > self.buf.len) try self.flush();
            @memcpy(self.buf[self.end..][0..data.len], data);
            self.end += data.len;
        }

        pub fn flush(self: *@This()) !void {
            if (self.end == 0) return;
            try compat.File.writeAll(self.file, self.buf[0..self.end]);
            self.end = 0;
        }
    };

    /// Buffered sequential reader over an `std.Io.File`. Snapshot load parses
    /// six fields per entry; reading each straight from the file costs a kernel
    /// round-trip per field (tens of millions of syscalls on a multi-million-key
    /// snapshot — that, not disk bandwidth, dominated load time). Amortize them
    /// through one big buffer. Exposes the same `.readAll` contract as
    /// FileWriter's read twin, so the HNSW trailer consumes the tail through the
    /// same buffer (the raw file position has read ahead once buffering starts,
    /// so the file must not be read directly afterwards).
    const BufferedFileReader = struct {
        file: std.Io.File,
        buf: []u8,
        start: usize = 0,
        end: usize = 0,

        pub fn readAll(self: *@This(), dest: []u8) !usize {
            var total: usize = 0;
            while (total < dest.len) {
                const avail = self.end - self.start;
                if (avail == 0) {
                    // Requests at/above one buffer go straight to the file once
                    // the buffer is drained — no point double-copying.
                    if (dest.len - total >= self.buf.len) {
                        return total + try compat.File.readAll(self.file, dest[total..]);
                    }
                    self.start = 0;
                    self.end = try compat.File.readAll(self.file, self.buf);
                    if (self.end == 0) break; // EOF
                    continue;
                }
                const n = @min(avail, dest.len - total);
                @memcpy(dest[total..][0..n], self.buf[self.start..][0..n]);
                self.start += n;
                total += n;
            }
            return total;
        }
    };

    const SNAPSHOT_READ_BUF_SIZE: usize = 4 << 20;

    fn loadSnapshot(self: *Store) !void {
        const snapshot_file = compat.Dir.openFile(core.compat.cwd(), self.config.snapshot_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer compat.File.close(snapshot_file);

        const stat = try compat.File.stat(snapshot_file);
        if (stat.size == 0) {
            return;
        }

        var reader = BufferedFileReader{
            .file = snapshot_file,
            .buf = try self.allocator.alloc(u8, SNAPSHOT_READ_BUF_SIZE),
        };
        defer self.allocator.free(reader.buf);

        var magic_buf: [SNAPSHOT_MAGIC.len]u8 = undefined;
        if (try reader.readAll(magic_buf[0..]) != magic_buf.len) {
            return error.Corruption;
        }
        if (!std.mem.eql(u8, magic_buf[0..], SNAPSHOT_MAGIC)) {
            return error.Corruption;
        }

        var version_buf: [4]u8 = undefined;
        if (try reader.readAll(version_buf[0..4]) != version_buf.len) {
            return error.Corruption;
        }
        const version = std.mem.readInt(u32, version_buf[0..4], .little);
        if (version != 1 and version != 2) {
            return error.Corruption;
        }

        var count_buf: [8]u8 = undefined;
        if (try reader.readAll(count_buf[0..8]) != count_buf.len) {
            return error.Corruption;
        }
        const entry_count = std.mem.readInt(u64, count_buf[0..8], .little);
        // Every entry takes ≥17 header bytes on disk — a count beyond that is
        // a corrupt header, and it must not reach the presize @intCast below.
        if (entry_count > stat.size / 17) {
            return error.Corruption;
        }

        std.log.info("Loading snapshot: {d} entries...", .{entry_count});

        // Pre-size every shard for its expected share (uniform hash spread,
        // +1/8 headroom) so the load never rehashes or regrows mid-stream.
        const per_shard: u32 = @intCast(entry_count / SHARD_COUNT + entry_count / SHARD_COUNT / 8 + 16);
        for (&self.shards) |*shard| {
            try shard.data.ensureTotalCapacity(self.allocator, per_shard);
        }

        // All snapshot entries (key, value, Entry struct) come from the bump
        // arena: one pointer increment instead of three allocator round-trips
        // per entry, reclaimed wholesale at store deinit (see `snapshot_arena`).
        const arena = self.snapshot_arena.allocator();

        var i: u64 = 0;
        while (i < entry_count) : (i += 1) {
            if (i > 0 and i % 500_000 == 0) {
                std.log.info("Snapshot load progress: {d}/{d} entries loaded...", .{ i, entry_count });
            }
            // Fixed-size entry header in one read: key_len u32 | value_len u32
            // | flags u8 | timestamp u64.
            var header_buf: [17]u8 = undefined;
            if (try reader.readAll(header_buf[0..]) != header_buf.len) {
                return error.Corruption;
            }
            const key_len: usize = @intCast(std.mem.readInt(u32, header_buf[0..4], .little));
            const value_len: usize = @intCast(std.mem.readInt(u32, header_buf[4..8], .little));
            var flags: EntryFlags = @bitCast(header_buf[8]);
            flags.arena_owned = true; // never trust the on-disk bit; we own placement
            const timestamp = std.mem.readInt(u64, header_buf[9..17], .little);

            // No per-allocation errdefers: everything below is arena-owned, and
            // on a failed load the store's deinit reclaims the arena wholesale.
            const key = try arena.alloc(u8, key_len);
            if (try reader.readAll(key) != key.len) {
                return error.Corruption;
            }

            const value = try arena.alloc(u8, value_len);
            if (try reader.readAll(value) != value.len) {
                return error.Corruption;
            }

            const entry = try arena.create(Entry);
            entry.* = .{
                .key = key,
                .value = value,
                .timestamp = timestamp,
                .flags = flags,
            };

            const si = shardIndex(entry.key);
            const shard = &self.shards[si];
            const kh = std.hash_map.hashString(entry.key);
            try shard.data.ensureUnusedCapacity(self.allocator, 1);
            const gop = shard.data.getOrPutAssumeCapacityAdapted(entry.key, PrehashedStringCtx{ .h = kh });
            if (gop.found_existing) {
                const old_entry = gop.value_ptr.*;
                gop.key_ptr.* = entry.key;
                gop.value_ptr.* = entry;
                try self.ordered.finishBulkLoad();
                self.ordered.replaceValue(entry.key, entry);
                self.destroyEntry(old_entry);
            } else {
                gop.key_ptr.* = entry.key;
                gop.value_ptr.* = entry;
                try self.ordered.appendBulkUnlockedWithHash(entry.key, entry, kh, si);
                _ = self.live_keys.fetchAdd(1, .monotonic);
            }
        }
        try self.ordered.finishBulkLoad();

        std.log.info("Snapshot load complete.", .{});

        // ── v2 HNSW trailer (optional) ──
        // v1 files have nothing after the last KV entry; readFrom would
        // hit EOF and we'd swallow the error below. v2 files have a
        // WDBHNSW{1,2}-marked block that restores the registry.
        if (version >= 2 and self.vector_registry != null) {
            // Continue through the shared buffered reader — it holds read-ahead
            // bytes the raw file position is already past.
            const resolver = KvResolver{ .store = self };
            // Use a local const to satisfy the &-of-rvalue requirement.
            var resolver_mut = resolver;
            self.vector_registry.?.readFrom(
                &reader,
                KvResolver.resolve,
                @ptrCast(&resolver_mut),
            ) catch |err| switch (err) {
                // End-of-stream is normal if the file is v2 but happened
                // to be saved before any namespace was registered (or if
                // the snapshot was written by an older v1 writer — though
                // those would have version==1). Log and move on.
                error.EndOfStream => std.log.info("Snapshot: no HNSW trailer present.", .{}),
                else => {
                    std.log.warn("Snapshot: HNSW trailer load failed: {s}", .{@errorName(err)});
                },
            };
        }
    }

    /// Key-based vector resolver for NamespaceRegistry.readFrom. Looks the
    /// key up in the already-loaded KV shards and returns the raw value
    /// bytes (borrowed — the caller copies into aligned storage).
    const KvResolver = struct {
        store: *Store,
        fn resolve(raw_ctx: *anyopaque, key: []const u8) ?[]const u8 {
            const self: *KvResolver = @ptrCast(@alignCast(raw_ctx));
            const entry = self.store.getUnsafe(key) orelse return null;
            return entry.value;
        }
    };
};

test "Store basic operations" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_store.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const file = try compat.Dir.createFile(tmp_dir.dir, "test_store.wal", .{});
    compat.File.close(file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_store.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    };
    var store = try Store.init(testing.allocator, config);
    defer store.deinit();

    try store.set("key1", "value1", false);
    try testing.expectEqual(@as(usize, 1), store.count());

    const entry = store.get("key1");
    try testing.expect(entry != null);
    try testing.expectEqualStrings("value1", entry.?.value);

    try store.set("key1", "value2", false);
    const entry2 = store.get("key1");
    try testing.expectEqualStrings("value2", entry2.?.value);

    try store.delete("key1");
    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expect(store.get("key1") == null);
}

test "durable SET reserves live state before publishing WAL" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/reserve_before_wal.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    const file = try compat.Dir.createFile(tmp_dir.dir, "reserve_before_wal.wal", .{});
    compat.File.close(file);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/reserve_before_wal.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = true,
    });
    defer store.deinit();
    const before = try store.wal.?.size();
    store.fail_put_reserve_for_test = true;
    try testing.expectError(error.OutOfMemory, store.set("key", "first", true));
    try testing.expectEqual(before, try store.wal.?.size());
    try testing.expect(store.get("key") == null);

    store.fail_put_reserve_for_test = false;
    try store.set("key", "second", true);
    try testing.expectEqualStrings("second", store.get("key").?.value);
}

test "a set that cannot be indexed fails before anything is published" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/index_before_wal.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    const file = try compat.Dir.createFile(tmp_dir.dir, "index_before_wal.wal", .{});
    compat.File.close(file);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/index_before_wal.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = true,
    });
    defer store.deinit();

    try store.set("idx:a", "one", false);
    const wal_before = try store.wal.?.size();

    // New key, index insert fails: no WAL record, no hashmap entry, no index entry.
    store.fail_ordered_insert_for_test = true;
    try testing.expectError(error.OutOfMemory, store.set("idx:b", "two", false));
    {
        const pair = store.lockKeyPair("idx:c", "idx:c");
        defer store.unlockKeyPair(pair);
        try testing.expectError(error.OutOfMemory, store.setUnsafe("idx:c", "three", false));
    }
    try testing.expectEqual(wal_before, try store.wal.?.size());
    try testing.expect(store.get("idx:b") == null);
    try testing.expect(store.get("idx:c") == null);
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expectEqual(@as(usize, 1), store.countPrefix("idx:"));

    // Overwriting an existing key never touches the index, so it still succeeds.
    try store.set("idx:a", "uno", false);
    try testing.expectEqualStrings("uno", store.get("idx:a").?.value);

    store.fail_ordered_insert_for_test = false;
    try store.set("idx:b", "two", false);
    try testing.expectEqual(@as(usize, 2), store.count());
    try testing.expectEqual(@as(usize, 2), store.countPrefix("idx:"));
    const hits = try store.scanPrefix("idx:", 10, testing.allocator);
    defer {
        for (hits) |h| {
            testing.allocator.free(h.key);
            testing.allocator.free(h.value);
        }
        testing.allocator.free(hits);
    }
    try testing.expectEqual(@as(usize, 2), hits.len);
}

test "a set whose WAL append fails is taken back out of the ordered index" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/unindex_on_wal_fail.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    const file = try compat.Dir.createFile(tmp_dir.dir, "unindex_on_wal_fail.wal", .{});
    compat.File.close(file);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/unindex_on_wal_fail.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = true,
    });
    defer store.deinit();

    try store.set("idx:a", "one", false);

    // A long key is borrowed by the index, so a stale index entry would dangle
    // once the aborted entry is destroyed.
    const long_key = "idx:long-key-past-the-inline-key-capacity";
    store.wal.?.fail_sync_for_test = true;
    try testing.expectError(error.IoError, store.set(long_key, "two", false));
    store.wal.?.fail_sync_for_test = false;

    try testing.expect(store.get(long_key) == null);
    try testing.expectEqual(@as(usize, 1), store.count());
    try testing.expectEqual(@as(usize, 1), store.countPrefix("idx:"));
    const hits = try store.scanPrefix("idx:", 10, testing.allocator);
    defer {
        for (hits) |h| {
            testing.allocator.free(h.key);
            testing.allocator.free(h.value);
        }
        testing.allocator.free(hits);
    }
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("idx:a", hits[0].key);
}

test "WORM enforcement" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_worm.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const file = try compat.Dir.createFile(tmp_dir.dir, "test_worm.wal", .{});
    compat.File.close(file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_worm.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    };
    var store = try Store.init(testing.allocator, config);
    defer store.deinit();

    try store.set("worm_key", "immutable", true);
    try testing.expectError(error.WormViolation, store.set("worm_key", "modified", false));
    try testing.expectError(error.WormViolation, store.delete("worm_key"));

    try store.set("normal_key", "value1", false);
    try store.set("normal_key", "value2", false);
    try testing.expectEqualStrings("value2", store.get("normal_key").?.value);
}

test "WAL replay ignores records that would violate WORM" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_worm_replay_guard.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const file = try compat.Dir.createFile(tmp_dir.dir, "test_worm_replay_guard.wal", .{});
    compat.File.close(file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_worm_replay_guard.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    };

    {
        var store = try Store.init(testing.allocator, config);
        defer store.deinit();

        try store.setWithTimestamp("worm_key", "immutable", true, 100);
        try store.set("mutable_key", "first", false);
    }

    {
        var wal = try Wal.init(testing.allocator, wal_path, false);
        defer wal.deinit();

        const bad_set = try wal.appendSet("worm_key", "modified", .{ .is_worm = false, .is_deleted = false }, 200);
        bad_set.deinit(testing.allocator);
        testing.allocator.destroy(bad_set);
        try wal.appendDelete("worm_key");

        const mutable_set = try wal.appendSet("mutable_key", "second", .{ .is_worm = false, .is_deleted = false }, 201);
        mutable_set.deinit(testing.allocator);
        testing.allocator.destroy(mutable_set);
        try wal.appendDelete("mutable_key");
    }

    {
        var reloaded = try Store.init(testing.allocator, config);
        defer reloaded.deinit();

        try testing.expectEqualStrings("immutable", reloaded.get("worm_key").?.value);
        try testing.expect(reloaded.get("worm_key").?.flags.is_worm);
        try testing.expect(reloaded.get("mutable_key") == null);

        const meta = reloaded.getEntryMetadata("worm_key").?;
        try testing.expectEqual(@as(u64, 100), meta.timestamp);
    }
}

test "Store replay handles overwrite and delete safely" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_replay_ownership.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_replay_ownership.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const file = try compat.Dir.createFile(tmp_dir.dir, "test_replay_ownership.wal", .{});
    compat.File.close(file);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    };

    {
        var store = try Store.init(testing.allocator, config);
        defer store.deinit();

        try store.set("k", "v1", false);
        try store.set("k", "v2", false);
        try store.set("to-delete", "x", false);
        try store.delete("to-delete");
    }

    {
        var reloaded = try Store.init(testing.allocator, config);
        defer reloaded.deinit();

        try testing.expectEqual(@as(usize, 1), reloaded.count());
        try testing.expectEqualStrings("v2", reloaded.get("k").?.value);
        try testing.expect(reloaded.get("to-delete") == null);
    }
}

test "Store restores from snapshot then replays WAL" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_snapshot_restore.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_snapshot_restore.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const file = try compat.Dir.createFile(tmp_dir.dir, "test_snapshot_restore.wal", .{});
    compat.File.close(file);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
        .max_wal_size = 80,
    };

    {
        var store = try Store.init(testing.allocator, config);
        defer store.deinit();

        try store.set("k1", "12345678901234567890123456789012345678901234567890", false);
        try store.set("k2", "v2", true);
    }

    {
        var reloaded = try Store.init(testing.allocator, config);
        defer reloaded.deinit();

        try testing.expectEqual(@as(usize, 2), reloaded.count());
        try testing.expectEqualStrings("12345678901234567890123456789012345678901234567890", reloaded.get("k1").?.value);
        try testing.expectEqualStrings("v2", reloaded.get("k2").?.value);
        try testing.expect(reloaded.get("k2").?.flags.is_worm);
    }
}

test "concurrent manual snapshots and WAL compaction preserve reload" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try compat.Dir.realPathAlloc(tmp.dir, testing.allocator, ".");
    defer testing.allocator.free(dir);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/concurrent.wal", .{dir});
    defer testing.allocator.free(wal_path);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/concurrent.snapshot", .{dir});
    defer testing.allocator.free(snapshot_path);
    const config = Config{ .wal_path = wal_path, .snapshot_path = snapshot_path, .sync_writes = false, .max_wal_size = 128 };
    var store = try Store.init(testing.allocator, config);
    defer store.deinit();
    try store.set("immutable", "original", true);
    const Worker = struct {
        fn run(s: *Store, failures: *std.atomic.Value(usize)) void {
            for (0..12) |_| s.save() catch {
                _ = failures.fetchAdd(1, .monotonic);
            };
        }
    };
    var failures: std.atomic.Value(usize) = .init(0);
    var threads: [4]std.Thread = undefined;
    var spawned: usize = 0;
    {
        defer for (threads[0..spawned]) |thread| thread.join();
        for (&threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &store, &failures });
            spawned += 1;
        }
        for (0..30) |i| {
            var buf: [32]u8 = undefined;
            const value = try std.fmt.bufPrint(&buf, "value-{d}", .{i});
            try store.set("mutable", value, false);
            try store.set("deleted", "temporary", false);
            try store.delete("deleted");
        }
    }
    try testing.expectEqual(@as(usize, 0), failures.load(.acquire));
    // Reload before original deinit can hide corruption with a shutdown save.
    var reloaded = try Store.init(testing.allocator, config);
    defer reloaded.deinit();
    try testing.expectEqualStrings("value-29", reloaded.get("mutable").?.value);
    try testing.expectEqualStrings("original", reloaded.get("immutable").?.value);
    try testing.expect(reloaded.get("immutable").?.flags.is_worm);
    try testing.expect(reloaded.get("deleted") == null);
}

test "live_keys count is O(1) and tracks set/delete (#91)" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none, .sync_writes = false });
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), store.count());
    try store.set("a", "1", false);
    try store.set("b", "2", false);
    try testing.expectEqual(@as(usize, 2), store.count());
    try store.set("a", "1b", false); // replace — count unchanged
    try testing.expectEqual(@as(usize, 2), store.count());
    try store.delete("b");
    try testing.expectEqual(@as(usize, 1), store.count());
    store.deleteUnsafe("a");
    try testing.expectEqual(@as(usize, 0), store.count());
}

test "setUnsafe does not append to WAL under full persistence (#88)" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_setunsafe_nowal.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_setunsafe_nowal.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const file = try compat.Dir.createFile(tmp_dir.dir, "test_setunsafe_nowal.wal", .{});
    compat.File.close(file);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .persistence = .full,
        .sync_writes = false,
        .max_wal_size = 10 * 1024 * 1024,
    };

    {
        var store = try Store.init(testing.allocator, config);
        defer store.deinit();

        // setUnsafe requires the key's shard lock (procedure Ctx.lockKey contract).
        const set_unsafe = struct {
            fn call(s: *Store, key: []const u8, value: []const u8) !void {
                const si = shardIndex(key);
                s.shards[si].mutex.lock();
                defer s.shards[si].mutex.unlock();
                try s.setUnsafe(key, value, false);
            }
        }.call;

        const wal_before = try store.walSize();

        // Procedure-style hot write: live map only, no WAL growth.
        try set_unsafe(&store, "hot:counter", "1");
        try testing.expectEqual(wal_before, try store.walSize());
        try testing.expectEqualStrings("1", store.get("hot:counter").?.value);

        try set_unsafe(&store, "hot:counter", "2");
        try testing.expectEqual(wal_before, try store.walSize());
        try testing.expectEqualStrings("2", store.get("hot:counter").?.value);

        // Durable SET still enqueues WAL.
        try store.set("durable:k", "v", false);
        const wal_after_set = try store.walSize();
        try testing.expect(wal_after_set > wal_before);

        // More unsafe writes still must not grow WAL further.
        try set_unsafe(&store, "hot:other", "x");
        try testing.expectEqual(wal_after_set, try store.walSize());
    }

    // After restart: durable key replays; unsafe-only keys are gone.
    {
        var reloaded = try Store.init(testing.allocator, config);
        defer reloaded.deinit();

        try testing.expectEqualStrings("v", reloaded.get("durable:k").?.value);
        try testing.expect(reloaded.get("hot:counter") == null);
        try testing.expect(reloaded.get("hot:other") == null);
    }
}

test "memory vector HNSW rebuilds from WAL-replayed KV" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_mem_vector_wal_rebuild.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_mem_vector_wal_rebuild.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const wal_file = try compat.Dir.createFile(tmp_dir.dir, "test_mem_vector_wal_rebuild.wal", .{});
    compat.File.close(wal_file);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    };

    const vec_a = [_]f32{ 1, 0, 0, 0 };
    const vec_b = [_]f32{ 0, 1, 0, 0 };
    const vec_a_bytes_ptr: [*]const u8 = @ptrCast(&vec_a);
    const vec_b_bytes_ptr: [*]const u8 = @ptrCast(&vec_b);
    const vec_a_bytes = vec_a_bytes_ptr[0 .. 4 * @sizeOf(f32)];
    const vec_b_bytes = vec_b_bytes_ptr[0 .. 4 * @sizeOf(f32)];

    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var store = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer store.deinit();

        try store.set("__meta:mem:demo:config", "{\"embedder_id\":\"bge-m3\",\"metric\":\"dot\",\"created_at\":1}", false);
        try store.setWithTimestamp("vec:mem:demo:doc-a", vec_a_bytes, false, 111);
        try store.setWithTimestamp("vec:mem:demo:doc-b", vec_b_bytes, false, 222);

        try testing.expect(registry.get("vec:mem:demo:") == null);
    }

    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var reloaded = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer reloaded.deinit();

        const idx = registry.get("vec:mem:demo:").?;
        idx.lock.lockShared();
        defer idx.lock.unlockShared();

        try testing.expectEqual(Metric.dot, idx.metric);
        try testing.expectEqual(@as(usize, 2), idx.len());
        try testing.expect(idx.nodeIdFor("vec:mem:demo:doc-a") != null);
        try testing.expect(idx.nodeIdFor("vec:mem:demo:doc-b") != null);
        try testing.expectEqual(@as(u64, 111), idx.timestamps.items[idx.nodeIdFor("vec:mem:demo:doc-a").?]);
        try testing.expectEqual(@as(u64, 222), idx.timestamps.items[idx.nodeIdFor("vec:mem:demo:doc-b").?]);
    }
}

test "raw vector HNSW rebuilds from persisted namespace config" {
    const testing = std.testing;
    const vector_ops = @import("../procedures/vector_ops.zig");

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_raw_vector_wal_rebuild.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_raw_vector_wal_rebuild.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const wal_file = try compat.Dir.createFile(tmp_dir.dir, "test_raw_vector_wal_rebuild.wal", .{});
    compat.File.close(wal_file);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    };

    const vec_a = [_]f32{ 1, 2, 3, 4 };
    const vec_b = [_]f32{ 4, 3, 2, 1 };
    const vec_a_bytes_ptr: [*]const u8 = @ptrCast(&vec_a);
    const vec_b_bytes_ptr: [*]const u8 = @ptrCast(&vec_b);
    const vec_a_bytes = vec_a_bytes_ptr[0 .. 4 * @sizeOf(f32)];
    const vec_b_bytes = vec_b_bytes_ptr[0 .. 4 * @sizeOf(f32)];

    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var store = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer store.deinit();

        try vector_ops.applyVinsert(&store, null, null, &registry, testing.allocator, .{
            .key = "vec:raw:doc-a",
            .vector = vec_a_bytes,
            .worm = false,
            .namespace = "vec:raw:",
            .metric = .l2,
            .timestamp = 111,
            .replicate = false,
        });
        try vector_ops.applyVinsert(&store, null, null, &registry, testing.allocator, .{
            .key = "vec:raw:doc-b",
            .vector = vec_b_bytes,
            .worm = false,
            .namespace = "vec:raw:",
            .metric = .l2,
            .timestamp = 222,
            .replicate = false,
        });

        try testing.expect(store.get("__meta:vecns:vec:raw:") != null);
    }

    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var reloaded = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer reloaded.deinit();

        try testing.expect(reloaded.get("__meta:vecns:vec:raw:") != null);
        const idx = registry.get("vec:raw:").?;
        idx.lock.lockShared();
        defer idx.lock.unlockShared();

        try testing.expectEqual(Metric.l2, idx.metric);
        try testing.expectEqual(@as(usize, 2), idx.len());
        try testing.expect(idx.nodeIdFor("vec:raw:doc-a") != null);
        try testing.expect(idx.nodeIdFor("vec:raw:doc-b") != null);
        try testing.expectEqual(@as(u64, 111), idx.timestamps.items[idx.nodeIdFor("vec:raw:doc-a").?]);
        try testing.expectEqual(@as(u64, 222), idx.timestamps.items[idx.nodeIdFor("vec:raw:doc-b").?]);
    }
}

test "vector WAL metadata replays HNSW without namespace config" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_vector_wal_metadata.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_vector_wal_metadata.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const wal_file = try compat.Dir.createFile(tmp_dir.dir, "test_vector_wal_metadata.wal", .{});
    compat.File.close(wal_file);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    };

    const vec_a = [_]f32{ 1, 0, 0, 0 };
    const vec_b = [_]f32{ 0, 1, 0, 0 };
    const vec_a_bytes_ptr: [*]const u8 = @ptrCast(&vec_a);
    const vec_b_bytes_ptr: [*]const u8 = @ptrCast(&vec_b);
    const vec_a_bytes = vec_a_bytes_ptr[0 .. 4 * @sizeOf(f32)];
    const vec_b_bytes = vec_b_bytes_ptr[0 .. 4 * @sizeOf(f32)];

    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var store = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer store.deinit();

        try store.setWithTimestamp("vec:wal:doc-a", vec_a_bytes, false, 111);
        try store.appendVectorInsertWal("vec:wal:doc-a", "vec:wal:", "dot", false, false, 111);
        try store.setWithTimestamp("vec:wal:doc-b", vec_b_bytes, false, 222);
        try store.appendVectorInsertWal("vec:wal:doc-b", "vec:wal:", "dot", false, false, 222);
        try store.delete("vec:wal:doc-b");
        try store.appendVectorDeleteWal("vec:wal:doc-b", "vec:wal:");

        try testing.expect(registry.get("vec:wal:") == null);
        try testing.expect(store.get("__meta:vecns:vec:wal:") == null);
    }

    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var reloaded = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer reloaded.deinit();

        try testing.expect(reloaded.get("__meta:vecns:vec:wal:") == null);
        try testing.expect(reloaded.get("vec:wal:doc-a") != null);
        try testing.expect(reloaded.get("vec:wal:doc-b") == null);

        const idx = registry.get("vec:wal:").?;
        idx.lock.lockShared();
        defer idx.lock.unlockShared();

        try testing.expectEqual(Metric.dot, idx.metric);
        try testing.expectEqual(@as(usize, 2), idx.len());
        try testing.expectEqual(@as(u64, 111), idx.timestamps.items[idx.nodeIdFor("vec:wal:doc-a").?]);
        const deleted_id = idx.nodeIdFor("vec:wal:doc-b").?;
        try testing.expect(idx.isTombstoned(deleted_id));
    }
}

test "WAL truncation keeps state correct across restart" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_wal_truncate.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_wal_truncate.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const file = try compat.Dir.createFile(tmp_dir.dir, "test_wal_truncate.wal", .{});
    compat.File.close(file);

    const max_wal_size: usize = 90;
    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
        .max_wal_size = max_wal_size,
    };

    {
        var store = try Store.init(testing.allocator, config);
        defer store.deinit();

        try store.set("stable", "a", false);
        try store.set("stable", "b", false);
        try store.set("tmp", "to-delete", false);
        try store.delete("tmp");

        const wal_size = try store.walSize();
        try testing.expect(wal_size <= max_wal_size);
    }

    {
        var reloaded = try Store.init(testing.allocator, config);
        defer reloaded.deinit();

        try testing.expectEqualStrings("b", reloaded.get("stable").?.value);
        try testing.expect(reloaded.get("tmp") == null);
    }
}

test "Snapshot v2: HNSW trailer survives round trip" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_v2.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_v2.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const wal_file = try compat.Dir.createFile(tmp_dir.dir, "test_v2.wal", .{});
    compat.File.close(wal_file);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
        .persistence = .snapshot, // writes snapshot on deinit
    };

    // Raw vector bytes (4 floats each).
    const vec_a = [_]f32{ 1, 0, 0, 0 };
    const vec_b = [_]f32{ 0, 1, 0, 0 };
    const vec_a_bytes_ptr: [*]const u8 = @ptrCast(&vec_a);
    const vec_b_bytes_ptr: [*]const u8 = @ptrCast(&vec_b);
    const vec_a_bytes = vec_a_bytes_ptr[0 .. 4 * @sizeOf(f32)];
    const vec_b_bytes = vec_b_bytes_ptr[0 .. 4 * @sizeOf(f32)];

    // ── Write pass: store + insert into HNSW, then deinit to snapshot ──
    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var store = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer store.deinit();

        try store.set("vec:a", vec_a_bytes, true);
        try store.set("vec:b", vec_b_bytes, true);

        const idx = try registry.getOrCreate("vec:", .cosine);
        idx.lock.lock();
        defer idx.lock.unlock();
        const vec_a_align: []align(1) const f32 = @ptrCast(&vec_a);
        const vec_b_align: []align(1) const f32 = @ptrCast(&vec_b);
        _ = try idx.insertLocked("vec:a", vec_a_align, 111);
        _ = try idx.insertLocked("vec:b", vec_b_align, 222);
        _ = idx.markTombstoneLocked("vec:b");
    }

    // ── Read pass: fresh registry/store should restore HNSW state ──
    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var store = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer store.deinit();

        // KV survived
        try testing.expectEqual(@as(usize, 2), store.count());
        try testing.expectEqualSlices(u8, vec_a_bytes, store.get("vec:a").?.value);

        // HNSW survived
        const idx = registry.get("vec:").?;
        idx.lock.lockShared();
        defer idx.lock.unlockShared();
        try testing.expectEqual(@as(usize, 2), idx.len());
        try testing.expectEqual(@as(usize, 1), idx.tombstone_count);
        try testing.expect(idx.isTombstoned(idx.nodeIdFor("vec:b").?));
        try testing.expectEqual(@as(u64, 111), idx.timestamps.items[idx.nodeIdFor("vec:a").?]);
    }
}

test "Snapshot v1 loads without HNSW when registry provided" {
    // A snapshot written with no registry attached produces a bare v2
    // file (no HNSW trailer). Loading with a registry should succeed and
    // leave the registry empty — this exercises the "trailer absent"
    // branch in loadSnapshot.
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_v1_compat.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_v1_compat.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const wal_file = try compat.Dir.createFile(tmp_dir.dir, "test_v1_compat.wal", .{});
    compat.File.close(wal_file);

    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
        .persistence = .snapshot,
    };

    // Write without registry.
    {
        var store = try Store.init(testing.allocator, config);
        defer store.deinit();
        try store.set("plain", "value", false);
    }

    // Read with registry.
    {
        var registry = NamespaceRegistry.init(testing.allocator, .{});
        defer registry.deinit();

        var store = try Store.initWithRegistry(testing.allocator, config, &registry);
        defer store.deinit();

        try testing.expectEqualStrings("value", store.get("plain").?.value);
        try testing.expect(registry.get("vec:") == null);
    }
}

// ── Ordered per-shard key index ─────────────────────────────────────────────

fn freeScanResults(alloc: std.mem.Allocator, results: []Store.ScanResult) void {
    for (results) |r| {
        alloc.free(r.key);
        alloc.free(r.value);
    }
    alloc.free(results);
}

/// RAM-only store config for index tests (no WAL/snapshot file access).
const index_test_config = Config{
    .wal_path = "unused.wal",
    .snapshot_path = "unused.snapshot",
    .sync_writes = false,
    .persistence = .none,
};

test "ordered index: scanPrefix returns sorted matches and keep-last limit" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, index_test_config);
    defer store.deinit();

    // Insert out of order, across shards, with range-boundary decoys.
    try store.set("evt:doc:0003", "c", false);
    try store.set("evt:doc:0001", "a", false);
    try store.set("evt:doc:0002", "b", false);
    try store.set("evt:doc:0010", "j", false);
    try store.set("evt", "short", false); // shorter than the prefix — no match
    try store.set("evt;doc", "after", false); // ';' > ':' — sorts after the range
    try store.set("eva:doc", "before", false);
    try store.set("zzz", "tail", false);

    const all = try store.scanPrefix("evt:doc:", 0, testing.allocator);
    defer freeScanResults(testing.allocator, all);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqualStrings("evt:doc:0001", all[0].key);
    try testing.expectEqualStrings("evt:doc:0002", all[1].key);
    try testing.expectEqualStrings("evt:doc:0003", all[2].key);
    try testing.expectEqualStrings("evt:doc:0010", all[3].key);
    try testing.expectEqualStrings("a", all[0].value);

    // The limit keeps the LAST N ascending — the documented "newest last" cut.
    const last2 = try store.scanPrefix("evt:doc:", 2, testing.allocator);
    defer freeScanResults(testing.allocator, last2);
    try testing.expectEqual(@as(usize, 2), last2.len);
    try testing.expectEqualStrings("evt:doc:0003", last2[0].key);
    try testing.expectEqualStrings("evt:doc:0010", last2[1].key);

    // scanPrefixFirst keeps the FIRST N ascending — the autocomplete cut.
    const first2 = try store.scanPrefixFirst("evt:doc:", 2, testing.allocator);
    defer freeScanResults(testing.allocator, first2);
    try testing.expectEqual(@as(usize, 2), first2.len);
    try testing.expectEqualStrings("evt:doc:0001", first2[0].key);
    try testing.expectEqualStrings("evt:doc:0002", first2[1].key);

    // Without a limit both cuts return everything.
    const first_all = try store.scanPrefixFirst("evt:doc:", 0, testing.allocator);
    defer freeScanResults(testing.allocator, first_all);
    try testing.expectEqual(@as(usize, 4), first_all.len);
}

test "ordered index: countPrefix boundaries (short keys, empty prefix, 0xFF)" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, index_test_config);
    defer store.deinit();

    try store.set("ab", "1", false);
    try store.set("abc", "2", false);
    try store.set("abcd", "3", false);
    try store.set("abd", "4", false);
    try store.set("ac", "5", false);
    try testing.expectEqual(@as(usize, 2), store.countPrefix("abc"));
    try testing.expectEqual(@as(usize, 4), store.countPrefix("ab"));
    try testing.expectEqual(@as(usize, 5), store.countPrefix("a"));
    try testing.expectEqual(@as(usize, 5), store.countPrefix(""));
    try testing.expectEqual(@as(usize, 0), store.countPrefix("zzz"));

    // 0xFF boundary — the three-way compare needs no successor-key increment.
    try store.set("\xff\xfe", "x", false);
    try store.set("\xff\xff", "y", false);
    try store.set("\xff\xff\x01", "z", false);
    try testing.expectEqual(@as(usize, 2), store.countPrefix("\xff\xff"));
    try testing.expectEqual(@as(usize, 3), store.countPrefix("\xff"));
}

test "ordered index: overwrite keeps one slot; delete paths stay in sync" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, index_test_config);
    defer store.deinit();

    try store.set("k:1", "v1", false);
    try store.set("k:1", "v2", false);
    try testing.expectEqual(@as(usize, 1), store.countPrefix("k:"));
    const res = try store.scanPrefix("k:", 0, testing.allocator);
    defer freeScanResults(testing.allocator, res);
    try testing.expectEqual(@as(usize, 1), res.len);
    try testing.expectEqualStrings("v2", res[0].value);

    try store.delete("k:1");
    try testing.expectEqual(@as(usize, 0), store.countPrefix("k:"));

    // A refused WORM delete leaves the index intact; deleteUnsafe (the
    // procedure-context path) removes it and keeps the index in sync.
    try store.set("k:worm", "w", true);
    try testing.expectError(error.WormViolation, store.delete("k:worm"));
    try testing.expectEqual(@as(usize, 1), store.countPrefix("k:"));
    store.deleteUnsafe("k:worm");
    try testing.expectEqual(@as(usize, 0), store.countPrefix("k:"));
    try testing.expect(store.get("k:worm") == null);
}

const IndexCbCounter = struct {
    seen: usize = 0,
    stop_after: usize = 0,
};

fn indexCbCount(ctx: *anyopaque, key: []const u8, value: []const u8, ts: u64, is_worm: bool) Store.ScanAction {
    _ = key;
    _ = value;
    _ = ts;
    _ = is_worm;
    const c: *IndexCbCounter = @ptrCast(@alignCast(ctx));
    c.seen += 1;
    if (c.stop_after > 0 and c.seen >= c.stop_after) return .stop;
    return .cont;
}

test "ordered index: scanPrefixCallback yields matches and honors stop" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, index_test_config);
    defer store.deinit();

    try store.set("cb:a", "1", false);
    try store.set("cb:b", "2", false);
    try store.set("cb:c", "3", false);
    try store.set("cb:d", "4", false);
    try store.set("cb:e", "5", false);
    try store.set("other", "x", false);

    var all = IndexCbCounter{};
    try store.scanPrefixCallback("cb:", @ptrCast(&all), indexCbCount);
    try testing.expectEqual(@as(usize, 5), all.seen);

    var stopped = IndexCbCounter{ .stop_after = 2 };
    try store.scanPrefixCallback("cb:", @ptrCast(&stopped), indexCbCount);
    try testing.expectEqual(@as(usize, 2), stopped.seen);
}

test "ordered index survives snapshot load and WAL replay" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_index_reload.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_index_reload.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const file = try compat.Dir.createFile(tmp_dir.dir, "test_index_reload.wal", .{});
    compat.File.close(file);

    // Small WAL cap forces a snapshot + truncation mid-run, so the reload
    // exercises BOTH the snapshot-load and the WAL-replay index paths.
    const config = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
        .max_wal_size = 120,
    };

    {
        var store = try Store.init(testing.allocator, config);
        defer store.deinit();
        try store.set("p:0003", "c", false);
        try store.set("p:0001", "a", false);
        try store.set("q:zzzz", "other", false);
        try store.set("p:0002", "b", false);
        try store.set("p:gone", "x", false);
        try store.delete("p:gone");
    }

    {
        var reloaded = try Store.init(testing.allocator, config);
        defer reloaded.deinit();

        try testing.expectEqual(@as(usize, 3), reloaded.countPrefix("p:"));
        const res = try reloaded.scanPrefix("p:", 0, testing.allocator);
        defer freeScanResults(testing.allocator, res);
        try testing.expectEqual(@as(usize, 3), res.len);
        try testing.expectEqualStrings("p:0001", res[0].key);
        try testing.expectEqualStrings("p:0002", res[1].key);
        try testing.expectEqualStrings("p:0003", res[2].key);
        try testing.expect(reloaded.get("p:gone") == null);
    }
}

test "sst overlay: get, shadow, scan merge, worm enforcement" {
    const testing = std.testing;
    const sst_mod = @import("sst.zig");
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/frozen.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);
    const sst_path = try std.fmt.allocPrint(testing.allocator, "{s}/frozen.wsst", .{tmp_path});
    defer testing.allocator.free(sst_path);

    // Build the frozen dataset through the REAL pipeline: store -> snapshot -> sst.
    {
        var frozen_src = try Store.init(testing.allocator, .{
            .persistence = .snapshot,
            .snapshot_path = snapshot_path,
            .sync_writes = false,
        });
        try frozen_src.set("cep:1", "frozen-cep", false);
        try frozen_src.set("idx:a", "frozen-a", false);
        try frozen_src.set("idx:b", "frozen-b", false);
        try frozen_src.set("worm:x", "immutable", true);
        frozen_src.deinit(); // snapshot mode auto-saves on shutdown
    }
    const stats = try sst_mod.buildFromSnapshot(testing.allocator, snapshot_path, sst_path, 42);
    try testing.expectEqual(@as(u64, 4), stats.count);

    var sst = try Sst.open(testing.allocator, sst_path);
    defer sst.close(testing.allocator);

    // Mount on a fresh, EMPTY store (the frozen-dataset boot shape).
    var store = try Store.init(testing.allocator, .{ .persistence = .none, .sync_writes = false });
    defer store.deinit();
    store.attachSst(&sst);

    // GET falls through to the overlay; misses stay misses.
    const v = (try store.getValueDupe("cep:1", testing.allocator)).?;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("frozen-cep", v);
    try testing.expect((try store.getValueDupe("cep:none", testing.allocator)) == null);

    // Live write shadows the frozen key.
    try store.set("cep:1", "live-cep", false);
    const v2 = (try store.getValueDupe("cep:1", testing.allocator)).?;
    defer testing.allocator.free(v2);
    try testing.expectEqualStrings("live-cep", v2);

    // Scan merges frozen + live, live wins on duplicates, order ascending.
    try store.set("idx:a", "live-a", false);
    {
        const res = try store.scanPrefixFirst("idx:", 10, testing.allocator);
        defer {
            for (res) |r| {
                testing.allocator.free(r.key);
                testing.allocator.free(r.value);
            }
            testing.allocator.free(res);
        }
        try testing.expectEqual(@as(usize, 2), res.len);
        try testing.expectEqualStrings("idx:a", res[0].key);
        try testing.expectEqualStrings("live-a", res[0].value); // live shadows frozen
        try testing.expectEqualStrings("idx:b", res[1].key);
        try testing.expectEqualStrings("frozen-b", res[1].value);
        try testing.expectEqual(@as(u64, 42), res[1].timestamp); // segment build ts
    }

    // limit=1 keeps the FIRST match of the merged set.
    {
        const res = try store.scanPrefixFirst("idx:", 1, testing.allocator);
        defer {
            for (res) |r| {
                testing.allocator.free(r.key);
                testing.allocator.free(r.value);
            }
            testing.allocator.free(res);
        }
        try testing.expectEqual(@as(usize, 1), res.len);
        try testing.expectEqualStrings("idx:a", res[0].key);
    }

    // countPrefix covers frozen ranges (disjoint live/frozen here for idx:b).
    try testing.expectEqual(@as(usize, 1), store.countPrefix("worm:"));

    // A frozen WORM key may not be shadowed by a live write.
    try testing.expectError(error.WormViolation, store.set("worm:x", "overwrite", false));
}

test "background WAL: a torn batch is dropped on restart and later writes survive" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/torn_batch_restart.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    compat.File.close(try compat.Dir.createFile(tmp_dir.dir, "torn_batch_restart.wal", .{}));
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/torn_batch_restart.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const cfg = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .persistence = .full,
        .sync_writes = true,
    };

    {
        var store = try Store.init(testing.allocator, cfg);
        defer store.deinit();
        try store.startBackgroundTasks();
        try store.set("keep:1", "a", false);
        try store.set("keep:2", "b", false);
    }

    // A crash mid-sweep leaves a begin marker and part of the batch, no commit marker.
    {
        const f = try compat.Dir.openFile(compat.cwd(), wal_path, .{ .mode = .read_write });
        defer compat.File.close(f);
        try compat.File.seekTo(f, (try compat.File.stat(f)).size);
        var rec_buf: [256]u8 = undefined;
        const rec = Wal.encodeSetRecord(&rec_buf, "torn:1", "x", .{ .is_worm = false, .is_deleted = false }, 1);
        var marker: [Wal.BATCH_MARKER_LEN]u8 = undefined;
        // The batch claimed two records; only the first reached the disk.
        Wal.encodeBatchMarker(&marker, .batch_begin, rec.len * 2);
        try compat.File.writeAll(f, &marker);
        try compat.File.writeAll(f, rec);
    }

    {
        var store = try Store.init(testing.allocator, cfg);
        defer store.deinit();
        try store.startBackgroundTasks();
        try testing.expectEqualStrings("a", store.get("keep:1").?.value);
        try testing.expectEqualStrings("b", store.get("keep:2").?.value);
        try testing.expect(store.get("torn:1") == null);
        try store.set("after:1", "c", false);
    }

    // The write made after the restart is not hidden behind the torn batch.
    {
        var store = try Store.init(testing.allocator, cfg);
        defer store.deinit();
        try testing.expectEqualStrings("a", store.get("keep:1").?.value);
        try testing.expectEqualStrings("c", store.get("after:1").?.value);
        try testing.expect(store.get("torn:1") == null);
        try testing.expectEqual(@as(usize, 3), store.count());
    }
}

test "background WAL writer: concurrent SET, DELETE, and save preserve lock order" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/bg_lock_order.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/bg_lock_order.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .persistence = .full,
        .sync_writes = true,
    });
    defer store.deinit();
    try store.startBackgroundTasks();

    const Worker = struct {
        fn setLoop(s: *Store, tid: usize) void {
            var kbuf: [32]u8 = undefined;
            var vbuf: [32]u8 = undefined;
            for (0..200) |i| {
                const key = std.fmt.bufPrint(&kbuf, "k:{d}:{d}", .{ tid, i % 16 }) catch unreachable;
                const val = std.fmt.bufPrint(&vbuf, "val-{d:0>6}", .{i}) catch unreachable;
                s.set(key, val, false) catch {};
            }
        }
        fn delAndSnapLoop(s: *Store) void {
            var kbuf: [32]u8 = undefined;
            for (0..40) |i| {
                const key = std.fmt.bufPrint(&kbuf, "k:0:{d}", .{i % 16}) catch unreachable;
                s.delete(key) catch {};
                if (i % 10 == 0) s.save() catch {};
            }
        }
    };

    var t1 = try std.Thread.spawn(.{}, Worker.setLoop, .{ &store, 0 });
    var t2 = try std.Thread.spawn(.{}, Worker.setLoop, .{ &store, 1 });
    var t3 = try std.Thread.spawn(.{}, Worker.delAndSnapLoop, .{&store});
    t1.join();
    t2.join();
    t3.join();

    try testing.expect(store.count() >= 16);
}

test "Store.save truncates WAL in direct mode" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/save_trunc.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/save_trunc.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .persistence = .full,
        .sync_writes = false,
    });
    defer store.deinit();

    try store.set("a", "one", false);
    try store.set("b", "two", false);
    try testing.expect((try store.walSize()) > 0);

    try store.save();
    try testing.expectEqual(@as(usize, 0), try store.walSize());

    // Reload from compacted snapshot + empty WAL and confirm data survives.
    var reopened = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .persistence = .full,
        .sync_writes = false,
    });
    defer reopened.deinit();
    try testing.expectEqual(@as(usize, 2), reopened.count());
    try testing.expectEqualStrings("two", reopened.get("b").?.value);
}

test "Store.initWithRegistry preserves v2 HNSW snapshot and applies incremental WAL delta" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/hnsw_preserve.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/hnsw_preserve.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const v1 = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const v2 = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    const v3 = [_]f32{ 0.0, 0.0, 1.0, 0.0 };

    {
        var reg = NamespaceRegistry.init(testing.allocator, .{});
        defer reg.deinit();
        var store = try Store.initWithRegistry(testing.allocator, .{
            .wal_path = wal_path,
            .snapshot_path = snapshot_path,
            .persistence = .full,
            .sync_writes = false,
        }, &reg);
        defer store.deinit();

        try store.set("__meta:vecns:vec:demo:", "{\"metric\":\"cosine\"}", false);
        try store.set("vec:demo:1", std.mem.sliceAsBytes(&v1), false);
        try store.set("vec:demo:2", std.mem.sliceAsBytes(&v2), false);
        const ns_idx = try reg.getOrCreate("vec:demo:", .cosine);
        ns_idx.lock.lock();
        _ = try ns_idx.insertLocked("vec:demo:1", &v1, 100);
        _ = try ns_idx.insertLocked("vec:demo:2", &v2, 200);
        ns_idx.lock.unlock();

        try store.save();

        // Append a post-snapshot vector only to WAL (no second save).
        try store.set("vec:demo:3", std.mem.sliceAsBytes(&v3), false);
        try store.appendVectorInsertWal("vec:demo:3", "vec:demo:", "cosine", false, false, 300);
    }

    // Reopen: v1 & v2 come from WDBHNSW2, v3 is applied incrementally from WAL.
    var reg2 = NamespaceRegistry.init(testing.allocator, .{});
    defer reg2.deinit();
    var store2 = try Store.initWithRegistry(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .persistence = .full,
        .sync_writes = false,
    }, &reg2);
    defer store2.deinit();

    const idx2 = reg2.get("vec:demo:").?;
    try testing.expectEqual(@as(usize, 3), idx2.liveCount());
    try testing.expectEqual(@as(?usize, 4), idx2.expectedDim());
}

test "Store.scanPrefixAfter paginates across shards" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    try store.set("p:01", "a", false);
    try store.set("p:02", "b", false);
    try store.set("p:03", "c", false);
    try store.set("p:04", "d", false);
    try store.set("p:05", "e", false);

    const page1 = try store.scanPrefixAfter("p:", null, 2, testing.allocator, .first);
    defer {
        for (page1) |r| {
            testing.allocator.free(r.key);
            testing.allocator.free(r.value);
        }
        testing.allocator.free(page1);
    }
    try testing.expectEqual(@as(usize, 2), page1.len);
    try testing.expectEqualStrings("p:01", page1[0].key);
    try testing.expectEqualStrings("p:02", page1[1].key);

    const page2 = try store.scanPrefixAfter("p:", page1[1].key, 2, testing.allocator, .first);
    defer {
        for (page2) |r| {
            testing.allocator.free(r.key);
            testing.allocator.free(r.value);
        }
        testing.allocator.free(page2);
    }
    try testing.expectEqual(@as(usize, 2), page2.len);
    try testing.expectEqualStrings("p:03", page2[0].key);
    try testing.expectEqualStrings("p:04", page2[1].key);

    const page3 = try store.scanPrefixAfter("p:", page2[1].key, 2, testing.allocator, .first);
    defer {
        for (page3) |r| {
            testing.allocator.free(r.key);
            testing.allocator.free(r.value);
        }
        testing.allocator.free(page3);
    }
    try testing.expectEqual(@as(usize, 1), page3.len);
    try testing.expectEqualStrings("p:05", page3[0].key);
}

test "Store.scanPrefix sorts >256 keys with shared 8-byte suffix ties and NUL bytes" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    // 320 keys sharing the same first 10 suffix bytes ("shared_tie") to exercise both
    // heap_slots (>256) and prefix8 tie-breaking fallback.
    var kbuf: [64]u8 = undefined;
    var i: usize = 320;
    while (i > 0) {
        i -= 1;
        const k = try std.fmt.bufPrint(&kbuf, "t:shared_tie_{d:0>4}", .{i});
        try store.set(k, "v", false);
    }
    // Also check NUL-byte suffix ordering ("t:a" < "t:a\x00" < "t:a\x01")
    try store.set("t:a\x01", "3", false);
    try store.set("t:a\x00", "2", false);
    try store.set("t:a", "1", false);

    const res = try store.scanPrefix("t:", 0, testing.allocator);
    defer {
        for (res) |r| {
            testing.allocator.free(r.key);
            testing.allocator.free(r.value);
        }
        testing.allocator.free(res);
    }

    try testing.expectEqual(@as(usize, 323), res.len);
    try testing.expectEqualStrings("t:a", res[0].key);
    try testing.expectEqualStrings("t:a\x00", res[1].key);
    try testing.expectEqualStrings("t:a\x01", res[2].key);
    for (1..res.len) |idx| {
        try testing.expect(std.mem.lessThan(u8, res[idx - 1].key, res[idx].key));
    }
}

test "Store.getValueInto handles hit, exact fit, empty value, too_small, and miss" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    try store.set("k:small", "hello", false);
    try store.set("k:empty", "", false);
    try store.set("k:big", "0123456789abcdef", false);

    var buf: [8]u8 = undefined;

    switch (store.getValueInto("k:small", &buf)) {
        .hit => |slice| try testing.expectEqualStrings("hello", slice),
        else => return error.TestUnexpectedResult,
    }

    switch (store.getValueInto("k:small", buf[0..5])) {
        .hit => |slice| try testing.expectEqualStrings("hello", slice),
        else => return error.TestUnexpectedResult,
    }

    switch (store.getValueInto("k:empty", buf[0..0])) {
        .hit => |slice| try testing.expectEqual(@as(usize, 0), slice.len),
        else => return error.TestUnexpectedResult,
    }

    switch (store.getValueInto("k:big", &buf)) {
        .too_small => |needed| try testing.expectEqual(@as(usize, 16), needed),
        else => return error.TestUnexpectedResult,
    }

    switch (store.getValueInto("k:missing", &buf)) {
        .miss => {},
        else => return error.TestUnexpectedResult,
    }
}

test "Store.readWithCallback borrows value without copying and reports misses" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    const meta_json = "{\"mediaType\":\"image\",\"sharpness\":88}";
    try store.set("meta:42", meta_json, false);

    const Probe = struct {
        called: bool = false,
        len: usize = 0,
        has_image: bool = false,
        fn onVal(self: *@This(), val: []const u8) void {
            self.called = true;
            self.len = val.len;
            self.has_image = std.mem.indexOf(u8, val, "\"image\"") != null;
        }
    };

    var hit_probe = Probe{};
    try testing.expect(store.readWithCallback("meta:42", &hit_probe, Probe.onVal));
    try testing.expect(hit_probe.called);
    try testing.expectEqual(meta_json.len, hit_probe.len);
    try testing.expect(hit_probe.has_image);

    var miss_probe = Probe{};
    try testing.expect(!store.readWithCallback("meta:999", &miss_probe, Probe.onVal));
    try testing.expect(!miss_probe.called);
}

test "Store OrderedIndex concurrent inserts, overwrites, deletes, and prefix scans" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const testing = std.testing;

    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    // Pre-populate both short inline (<=16B) and long borrowed (>16B) keys.
    var kbuf: [64]u8 = undefined;
    for (0..300) |i| {
        const k = try std.fmt.bufPrint(&kbuf, "item:{d:0>6}", .{i});
        try store.set(k, "init-val", false);
        const kl = try std.fmt.bufPrint(&kbuf, "long_concurrent_prefix_key:{d:0>6}", .{i});
        try store.set(kl, "init-long-val", false);
    }

    const WorkerCtx = struct {
        store: *Store,
        alloc: std.mem.Allocator,
        tid: usize,
        stop: *std.atomic.Value(bool),
        err_count: std.atomic.Value(usize) = .init(0),

        fn runWriter(self: *@This()) void {
            var buf: [64]u8 = undefined;
            var vbuf: [32]u8 = undefined;
            for (0..600) |iter| {
                const idx = (self.tid * 97 + iter * 13) % 500;
                const k = std.fmt.bufPrint(&buf, "item:{d:0>6}", .{idx}) catch continue;
                const v = std.fmt.bufPrint(&vbuf, "v-{d}-{d}", .{ self.tid, iter }) catch continue;
                if ((iter & 7) == 0) {
                    _ = self.store.delete(k) catch {};
                } else {
                    self.store.set(k, v, false) catch {
                        _ = self.err_count.fetchAdd(1, .monotonic);
                    };
                }
                const kl = std.fmt.bufPrint(&buf, "long_concurrent_prefix_key:{d:0>6}", .{idx}) catch continue;
                if ((iter & 7) == 3) {
                    _ = self.store.delete(kl) catch {};
                } else {
                    self.store.set(kl, v, false) catch {
                        _ = self.err_count.fetchAdd(1, .monotonic);
                    };
                }
            }
        }

        fn runReader(self: *@This()) void {
            const CbCtx = struct {
                prev_len: usize = 0,
                prev_buf: [64]u8 = undefined,
                out_of_order: bool = false,
                fn onRow(raw: *anyopaque, key: []const u8, _: []const u8, _: u64, _: bool) Store.ScanAction {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    if (c.prev_len > 0 and std.mem.order(u8, c.prev_buf[0..c.prev_len], key) != .lt) {
                        c.out_of_order = true;
                        return .stop;
                    }
                    const n = @min(key.len, c.prev_buf.len);
                    @memcpy(c.prev_buf[0..n], key[0..n]);
                    c.prev_len = n;
                    return .cont;
                }
            };

            while (!self.stop.load(.acquire)) {
                const res = self.store.scanPrefixFirst("item:", 32, self.alloc) catch {
                    _ = self.err_count.fetchAdd(1, .monotonic);
                    continue;
                };
                for (1..res.len) |j| {
                    if (std.mem.order(u8, res[j - 1].key, res[j].key) != .lt) {
                        _ = self.err_count.fetchAdd(1, .monotonic);
                    }
                }
                for (res) |r| {
                    self.alloc.free(r.key);
                    self.alloc.free(r.value);
                }
                self.alloc.free(res);

                const last_res = self.store.scanPrefix("long_concurrent_prefix_key:", 16, self.alloc) catch {
                    _ = self.err_count.fetchAdd(1, .monotonic);
                    continue;
                };
                for (1..last_res.len) |j| {
                    if (std.mem.order(u8, last_res[j - 1].key, last_res[j].key) != .lt) {
                        _ = self.err_count.fetchAdd(1, .monotonic);
                    }
                }
                for (last_res) |r| {
                    self.alloc.free(r.key);
                    self.alloc.free(r.value);
                }
                self.alloc.free(last_res);

                _ = self.store.countPrefix("item:");

                var cb_ctx = CbCtx{};
                self.store.scanPrefixCallback("item:", &cb_ctx, CbCtx.onRow) catch {
                    _ = self.err_count.fetchAdd(1, .monotonic);
                    continue;
                };
                if (cb_ctx.out_of_order) {
                    _ = self.err_count.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var stop = std.atomic.Value(bool).init(false);
    var writers: [4]WorkerCtx = undefined;
    var readers: [4]WorkerCtx = undefined;
    var w_threads: [4]std.Thread = undefined;
    var r_threads: [4]std.Thread = undefined;

    for (0..4) |i| {
        readers[i] = .{ .store = &store, .alloc = testing.allocator, .tid = i, .stop = &stop };
        r_threads[i] = try std.Thread.spawn(.{}, WorkerCtx.runReader, .{&readers[i]});
    }
    for (0..4) |i| {
        writers[i] = .{ .store = &store, .alloc = testing.allocator, .tid = i, .stop = &stop };
        w_threads[i] = try std.Thread.spawn(.{}, WorkerCtx.runWriter, .{&writers[i]});
    }

    for (&w_threads) |th| th.join();
    stop.store(true, .release);
    for (&r_threads) |th| th.join();

    for (&writers) |*w| try testing.expectEqual(@as(usize, 0), w.err_count.load(.monotonic));
    for (&readers) |*r| try testing.expectEqual(@as(usize, 0), r.err_count.load(.monotonic));

    // Final consistency: OrderedIndex count must exactly match Store live key count.
    try testing.expectEqual(store.count(), store.countPrefix(""));
}
