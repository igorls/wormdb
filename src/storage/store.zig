//! In-memory key-value store with WAL persistence

const std = @import("std");
const core = @import("../core/mod.zig");
const wal_mod = @import("wal.zig");

const Entry = core.types.Entry;
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
    mutex: core.compat.Mutex,
    data: std.StringHashMap(*Entry),
    /// The shard's entries sorted by key ascending — the same `*Entry` objects
    /// as `data`, never owned separately. Maintained by `shardPutLocked` /
    /// `shardRemoveLocked` on every mutation, it turns prefix scans and counts
    /// into O(log n) range seeks instead of full-shard walks. Snapshot files
    /// store keys globally sorted, so snapshot load appends at the tail and
    /// pays no memmove churn; random-order writes pay an ordered insert
    /// (memmove within one shard ≈ n/SHARD_COUNT pointers, trivial next to the
    /// WAL write they accompany).
    sorted: std.ArrayListUnmanaged(*Entry),
};

/// Three-way comparison of a key against a prefix *range*:
///   .lt — key sorts before every key carrying `prefix`
///   .eq — key carries `prefix`
///   .gt — key sorts after every key carrying `prefix`
/// Comparing against the range (rather than computing a successor key) avoids
/// the 0xFF-increment edge cases entirely and needs no allocation.
fn prefixCompare(key: []const u8, prefix: []const u8) std.math.Order {
    const n = @min(key.len, prefix.len);
    const ord = std.mem.order(u8, key[0..n], prefix[0..n]);
    if (ord != .eq) return ord;
    if (key.len >= prefix.len) return .eq;
    return .lt; // key is a strict prefix of `prefix` — sorts before the range
}

/// First index in the sorted shard index whose key does not sort before `key`.
fn lowerBoundKey(items: []const *Entry, key: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, items[mid].key, key) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

const PrefixRange = struct { lo: usize, hi: usize };

/// Half-open index range [lo, hi) of keys carrying `prefix` in a sorted shard
/// index — two binary searches over `prefixCompare`.
fn prefixRange(items: []const *Entry, prefix: []const u8) PrefixRange {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) { // lower bound: first key not .lt the range
        const mid = lo + (hi - lo) / 2;
        if (prefixCompare(items[mid].key, prefix) == .lt) lo = mid + 1 else hi = mid;
    }
    const start = lo;
    hi = items.len;
    while (lo < hi) { // upper bound: first key .gt the range
        const mid = lo + (hi - lo) / 2;
        if (prefixCompare(items[mid].key, prefix) == .gt) hi = mid else lo = mid + 1;
    }
    return .{ .lo = start, .hi = lo };
}

/// Remove `key` from a shard's hashmap + ordered index. Caller must hold the
/// shard lock and owns destroying the returned entry.
fn shardRemoveLocked(store: *Store, shard: *Shard, key: []const u8) ?*Entry {
    const removed = shard.data.fetchRemove(key) orelse return null;
    const idx = lowerBoundKey(shard.sorted.items, key);
    if (idx < shard.sorted.items.len and shard.sorted.items[idx] == removed.value) {
        _ = shard.sorted.orderedRemove(idx);
    } else {
        // Unreachable if every mutation goes through the shard helpers — but
        // the caller is about to destroy the entry, so NEVER leave its pointer
        // behind: sweep the index for it before giving up (a dangling pointer
        // here would be a use-after-free on the next scan).
        const found = blk: {
            for (shard.sorted.items, 0..) |e, i| {
                if (e == removed.value) {
                    _ = shard.sorted.orderedRemove(i);
                    break :blk true;
                }
            }
            break :blk false;
        };
        if (found) {
            std.log.warn("store: ordered index position drift on remove of '{s}' (recovered)", .{key});
        } else {
            std.log.err("store: ordered index missing entry on remove of '{s}'", .{key});
        }
    }
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
    /// Frozen sorted-string segments (`.wsst`, see sst.zig) mounted as a
    /// TRANSPARENT overlay: GET/scan/EXEC consult live shards first, then each
    /// sst in attach order — so live writes shadow frozen keys and procedures
    /// need no segment awareness. Mounted by the composition root; each sst
    /// must outlive the store. v1 limitations (documented, enforced nowhere):
    /// DEL cannot mask a frozen key (it resurfaces), and STATUS/key counts
    /// cover live entries only.
    ssts_buf: [MAX_SSTS]*const Sst = undefined,
    sst_count: usize = 0,

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

    /// True if ANY live key starts with `prefix` — O(SHARDS·log n), no walk.
    /// Scan overlays use this to skip the per-key containsLive shadow probe
    /// entirely in the common frozen-dataset case (live store empty or
    /// disjoint), where per-yield lock+hash probes dominate large scans.
    fn livePrefixNonEmpty(self: *Store, prefix: []const u8) bool {
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();
            const range = prefixRange(shard.sorted.items, prefix);
            if (range.hi > range.lo) return true;
        }
        return false;
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
                .data = std.StringHashMap(*Entry).init(allocator),
                .sorted = .empty,
            };
        }

        var store = Store{
            .allocator = allocator,
            .shards = shards,
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
        // Only replay WAL in full mode
        if (config.persistence == .full) {
            try store.replayWal();
        }
        if (config.persistence != .none) {
            try store.rebuildVectorIndexesFromKv();
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
        for (&self.shards) |*shard| {
            var iter = shard.data.iterator();
            while (iter.next()) |entry| {
                self.destroyEntry(entry.value_ptr.*);
            }
            shard.data.deinit();
            shard.sorted.deinit(self.allocator);
        }
        self.snapshot_arena.deinit();
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
        const idx = lowerBoundKey(shard.sorted.items, entry.key);
        const replacing = idx < shard.sorted.items.len and
            std.mem.eql(u8, shard.sorted.items[idx].key, entry.key);

        shard.data.ensureUnusedCapacity(1) catch return error.OutOfMemory;
        if (replacing) {
            // Same key ⇒ same ordered position: swap the pointer in place. The
            // map must re-key to the NEW entry's key bytes (the old key memory
            // dies with the old entry), hence remove + re-insert.
            const old = shard.data.fetchRemove(entry.key).?.value;
            shard.data.putAssumeCapacity(entry.key, entry);
            shard.sorted.items[idx] = entry;
            self.destroyEntry(old);
        } else {
            shard.sorted.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
            shard.data.putAssumeCapacity(entry.key, entry);
            shard.sorted.insertAssumeCapacity(idx, entry);
            _ = self.live_keys.fetchAdd(1, .monotonic);
        }
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
        const si = shardIndex(key);
        const shard = &self.shards[si];

        // Durable path: hold the key shard only for WORM checks + map insert.
        // WAL enqueue uses wal_enqueue_mutex alone so snapshot+truncate can
        // exclude concurrent durable writers (see maybeSnapshotAndTruncate).
        //
        // Order: optional early WORM check → wal_enqueue → (append) → shard
        // re-check+put → release wal_enqueue → maybeSnapshot.
        // Holding wal_enqueue across append+put prevents a WORM race from
        // acknowledging failure after a durable WAL append was published to
        // concurrent snapshot truncation (#92 review).
        if (self.config.persistence == .full) {
            // Manual unlock (not defer): maybeSnapshotAndTruncate also takes
            // wal_enqueue_mutex — must not hold it across that call.
            self.wal_enqueue_mutex.lock();

            {
                shard.mutex.lock();
                defer shard.mutex.unlock();
                if (shard.data.get(key)) |existing| {
                    if (existing.flags.is_worm) {
                        self.wal_enqueue_mutex.unlock();
                        return error.WormViolation;
                    }
                } else if (self.sstHit(key)) |frozen| {
                    if (frozen.is_worm) {
                        self.wal_enqueue_mutex.unlock();
                        return error.WormViolation;
                    }
                }
            }

            const entry = self.wal.?.appendSet(key, value, .{ .is_worm = is_worm, .is_deleted = false }, timestamp) catch {
                self.wal_enqueue_mutex.unlock();
                return error.IoError;
            };

            {
                shard.mutex.lock();
                defer shard.mutex.unlock();
                // Durable WORM races serialize on wal_enqueue. setUnsafe WORM
                // under the shard lock is visible here.
                if (shard.data.get(key)) |existing| {
                    if (existing.flags.is_worm) {
                        self.destroyEntry(entry);
                        self.wal_enqueue_mutex.unlock();
                        return error.WormViolation;
                    }
                } else if (self.sstHit(key)) |frozen| {
                    if (frozen.is_worm) {
                        self.destroyEntry(entry);
                        self.wal_enqueue_mutex.unlock();
                        return error.WormViolation;
                    }
                }
                self.shardPutLocked(shard, entry) catch |err| {
                    self.destroyEntry(entry);
                    self.wal_enqueue_mutex.unlock();
                    return err;
                };
            }
            self.wal_enqueue_mutex.unlock();
        } else {
            shard.mutex.lock();
            defer shard.mutex.unlock();
            if (shard.data.get(key)) |existing| {
                if (existing.flags.is_worm) return error.WormViolation;
            } else if (self.sstHit(key)) |frozen| {
                if (frozen.is_worm) return error.WormViolation;
            }
            const entry = try self.createMemoryEntry(key, value, is_worm, timestamp);
            errdefer self.destroyEntry(entry);
            try self.shardPutLocked(shard, entry);
        }

        if (self.config.persistence == .full) {
            self.maybeSnapshotAndTruncate() catch {};
        }
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

        self.wal_enqueue_mutex.lock();
        defer self.wal_enqueue_mutex.unlock();
        self.wal.?.appendVinsert(key, namespace, metric, flags, timestamp) catch return error.IoError;
    }

    /// Append a vector-delete metadata record to the WAL. The KV deletion is
    /// already durable through the normal DELETE record.
    pub fn appendVectorDeleteWal(self: *Store, key: []const u8, namespace: []const u8) StoreError!void {
        if (self.config.persistence != .full) return;
        if (self.wal == null) return;

        self.wal_enqueue_mutex.lock();
        defer self.wal_enqueue_mutex.unlock();
        self.wal.?.appendVdelete(key, namespace) catch return error.IoError;
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

        if (shard.data.get(key)) |existing| {
            if (existing.flags.is_worm) return error.WormViolation;
        } else if (self.sstHit(key)) |frozen| {
            // A frozen WORM key may not be shadowed by a live write — that
            // would silently serve the new value over the immutable one.
            if (frozen.is_worm) return error.WormViolation;
        }

        const entry = try self.createMemoryEntry(key, value, is_worm, timestamp);
        errdefer self.destroyEntry(entry);
        try self.shardPutLocked(shard, entry);
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
        {
            // Match SET's wal_enqueue -> shard order and keep append+remove
            // together, so compaction cannot truncate an unapplied deletion.
            if (self.config.persistence == .full) self.wal_enqueue_mutex.lock();
            defer if (self.config.persistence == .full) self.wal_enqueue_mutex.unlock();
            const shard = &self.shards[si];
            shard.mutex.lock();
            defer shard.mutex.unlock();
            const existing = shard.data.get(key) orelse return;
            if (existing.flags.is_worm) return error.WormViolation;
            if (self.config.persistence == .full) self.wal.?.appendDelete(key) catch return error.IoError;

            if (shardRemoveLocked(self, shard, key)) |removed| {
                self.destroyEntry(removed);
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
        return self.scanPrefixCut(prefix, limit, alloc, .first);
    }

    fn scanPrefixCut(
        self: *Store,
        prefix: []const u8,
        limit: usize,
        alloc: std.mem.Allocator,
        cut: ScanCut,
    ) ![]ScanResult {
        var results: std.ArrayListUnmanaged(ScanResult) = .empty;
        errdefer {
            for (results.items) |r| {
                alloc.free(r.key);
                alloc.free(r.value);
            }
            results.deinit(alloc);
        }

        // Collect each shard's match range. With a limit, only a shard's
        // first/last `limit` matches (per the cut) can survive the global cut
        // below, so the rest are never copied.
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            const range = prefixRange(shard.sorted.items, prefix);
            var start = range.lo;
            var end = range.hi;
            if (limit > 0 and range.hi - range.lo > limit) {
                switch (cut) {
                    .first => end = range.lo + limit,
                    .last => start = range.hi - limit,
                }
            }
            for (shard.sorted.items[start..end]) |e| {
                // Copy key and value into the arena so they survive after unlock
                const key_copy = try alloc.dupe(u8, e.key);
                errdefer alloc.free(key_copy);
                const val_copy = try alloc.dupe(u8, e.value);
                errdefer alloc.free(val_copy);

                try results.append(alloc, .{
                    .key = key_copy,
                    .value = val_copy,
                    .timestamp = e.timestamp,
                    .is_worm = e.flags.is_worm,
                });
            }
        }

        // Frozen sst overlay: collect the same per-source window from each
        // mounted segment (two binary searches + an index slice). Keys present
        // in the live shards are skipped — live writes shadow frozen data.
        // No shard lock is held here, so the containsLive probe cannot deadlock.
        const live_may_shadow = self.sst_count > 0 and self.livePrefixNonEmpty(prefix);
        for (self.ssts_buf[0..self.sst_count]) |sst| {
            const range = sst.prefixRange(prefix);
            var start = range.lo;
            var end = range.hi;
            if (limit > 0 and range.hi - range.lo > limit) {
                switch (cut) {
                    .first => end = range.lo + limit,
                    .last => start = range.hi - limit,
                }
            }
            var i = start;
            while (i < end) : (i += 1) {
                const hit = sst.hitAt(i);
                if (live_may_shadow and self.containsLive(hit.key)) continue;

                const key_copy = try alloc.dupe(u8, hit.key);
                errdefer alloc.free(key_copy);
                const val_copy = try alloc.dupe(u8, hit.value);
                errdefer alloc.free(val_copy);

                try results.append(alloc, .{
                    .key = key_copy,
                    .value = val_copy,
                    .timestamp = hit.timestamp,
                    .is_worm = hit.is_worm,
                });
            }
        }

        // Sort by key ascending (lexicographic = chronological for timestamp-keyed data)
        std.sort.heap(ScanResult, results.items, {}, struct {
            fn lessThan(_: void, a: ScanResult, b: ScanResult) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan);

        // Apply the limit on the requested end of the ascending match set.
        if (limit > 0 and results.items.len > limit) {
            switch (cut) {
                .first => {
                    for (results.items[limit..]) |r| {
                        alloc.free(r.key);
                        alloc.free(r.value);
                    }
                    results.shrinkRetainingCapacity(limit);
                },
                .last => {
                    // Free the excess oldest entries
                    const excess = results.items.len - limit;
                    for (results.items[0..excess]) |r| {
                        alloc.free(r.key);
                        alloc.free(r.value);
                    }
                    // Shift the remaining items
                    std.mem.copyForwards(ScanResult, results.items[0..limit], results.items[excess..]);
                    results.shrinkRetainingCapacity(limit);
                },
            }
        }

        return try results.toOwnedSlice(alloc);
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
    ) void {
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            const range = prefixRange(shard.sorted.items, prefix);
            for (shard.sorted.items[range.lo..range.hi]) |e| {
                switch (callback(context, e.key, e.value, e.timestamp, e.flags.is_worm)) {
                    .cont => {},
                    .stop => return,
                }
            }
        }

        // Frozen sst overlay — yielded after the live shards (ascending within
        // each sst, like each shard), skipping live-shadowed keys. No shard
        // lock is held during the callback for these.
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

    /// Count keys matching a prefix. Pure binary search per shard —
    /// O(SHARDS·log n), no allocation, no walking of the matches.
    pub fn countPrefix(self: *Store, prefix: []const u8) usize {
        var total: usize = 0;
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            const range = prefixRange(shard.sorted.items, prefix);
            total += range.hi - range.lo;
        }
        // Frozen sst ranges are added raw: a live entry shadowing a frozen key
        // double-counts (walking arbitrarily large ranges to dedup would defeat
        // the O(log n) contract). Exact only when live and frozen keys are
        // disjoint — the normal frozen-dataset deployment.
        for (self.ssts_buf[0..self.sst_count]) |sst| {
            const range = sst.prefixRange(prefix);
            total += range.hi - range.lo;
        }
        return total;
    }

    /// Manually save current state as snapshot. Available in full and snapshot modes.
    pub fn save(self: *Store) !void {
        if (self.config.persistence == .none) return;
        try self.writeSnapshot();
    }

    fn replayWal(self: *Store) !void {
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
                            if (shardRemoveLocked(self, shard, key)) |removed| {
                                self.destroyEntry(removed);
                            }
                        }
                    }
                    self.allocator.free(key);
                },
                .vinsert => |vinsert| {
                    // Configured indexes are rebuilt from final live `vec:*`
                    // KV state after replay. Replaying all of their historical
                    // HNSW mutations first is redundant and very expensive.
                    // Unconfigured vector namespaces still depend on WAL
                    // metadata for their metric, so preserve that legacy path.
                    if (!self.vectorNamespaceHasConfig(vinsert.namespace)) {
                        self.replayVectorInsert(vinsert) catch |err| {
                            std.log.warn("WAL vector insert replay skipped '{s}': {s}", .{ vinsert.key, @errorName(err) });
                        };
                    }
                    self.allocator.free(vinsert.key);
                    self.allocator.free(vinsert.namespace);
                    self.allocator.free(vinsert.metric);
                },
                .vdelete => |vdelete| {
                    if (!self.vectorNamespaceHasConfig(vdelete.namespace)) {
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
        self.scanPrefixCallback(namespace, @ptrCast(&rb), rebuildVectorMatch);
        if (rb.oom) return error.OutOfMemory;
        if (rb.inserted > 0 or rb.skipped > 0) {
            std.log.info("startup vector rebuild: {s} inserted={d} skipped={d}", .{
                namespace,
                rb.inserted,
                rb.skipped,
            });
        }
    }

    fn rebuildVectorIndexesFromKv(self: *Store) !void {
        try self.rebuildConfiguredVectorIndexesFromKv();
        try self.rebuildMemoryVectorIndexesFromKv();
    }

    fn rebuildConfiguredVectorIndexesFromKv(self: *Store) !void {
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
            const metric_name = extractJsonField(cfg.value, "metric") orelse "cosine";
            const metric = Metric.fromStr(metric_name) orelse .cosine;
            try self.rebuildVectorNamespaceFromKv(namespace, metric);
        }
    }

    fn rebuildMemoryVectorIndexesFromKv(self: *Store) !void {
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

        // Phase 1: under all shard locks, deep-copy live KV (+ optional HNSW
        // trailer bytes) into owned buffers. Phase 2 (disk I/O) does NOT hold
        // shard locks — that froze STATUS/EXECs for the whole snapshot (#91).
        // Callers that truncate the WAL must hold wal_enqueue_mutex across
        // this function + truncate so durable writers cannot interleave.
        const SnapRec = struct {
            key: []u8,
            value: []u8,
            flags: EntryFlags,
            timestamp: u64,
        };

        var records: std.ArrayListUnmanaged(SnapRec) = .empty;
        defer {
            for (records.items) |rec| {
                self.allocator.free(rec.key);
                self.allocator.free(rec.value);
            }
            records.deinit(self.allocator);
        }

        var hnsw_trailer: std.ArrayListUnmanaged(u8) = .empty;
        defer hnsw_trailer.deinit(self.allocator);

        {
            for (&self.shards) |*shard| shard.mutex.lock();
            defer for (&self.shards) |*shard| shard.mutex.unlock();

            var data_count: usize = 0;
            for (&self.shards) |*shard| data_count += shard.data.count();
            try records.ensureTotalCapacity(self.allocator, data_count);

            for (&self.shards) |*shard| {
                var iter = shard.data.iterator();
                while (iter.next()) |item| {
                    const entry = item.value_ptr.*;
                    const k = try self.allocator.dupe(u8, entry.key);
                    errdefer self.allocator.free(k);
                    const v = try self.allocator.dupe(u8, entry.value);
                    var flags = entry.flags;
                    flags.arena_owned = false;
                    records.appendAssumeCapacity(.{
                        .key = k,
                        .value = v,
                        .flags = flags,
                        .timestamp = entry.timestamp,
                    });
                }
            }

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

        std.sort.heap(SnapRec, records.items, {}, struct {
            fn lessThan(_: void, lhs: SnapRec, rhs: SnapRec) bool {
                return std.mem.lessThan(u8, lhs.key, rhs.key);
            }
        }.lessThan);

        const temp_snapshot_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.config.snapshot_path});
        defer self.allocator.free(temp_snapshot_path);

        const snapshot_file = try compat.Dir.createFile(core.compat.cwd(), temp_snapshot_path, .{ .read = true, .truncate = true });
        var file_open = true;
        defer if (file_open) compat.File.close(snapshot_file);

        // Mirror of the load path's buffering: per-field raw writes cost a
        // kernel round-trip each (shutdown saves of multi-million-key stores
        // took minutes of syscall overhead).
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

        for (records.items) |rec| {
            // Fixed entry header (matches the load path's single 17-byte read):
            // key_len u32 | value_len u32 | flags u8 | timestamp u64.
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
            try shard.data.ensureTotalCapacity(per_shard);
            try shard.sorted.ensureTotalCapacity(self.allocator, per_shard);
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

            const shard = &self.shards[shardIndex(entry.key)];
            try self.shardPutLocked(shard, entry);
        }

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
    store.scanPrefixCallback("cb:", @ptrCast(&all), indexCbCount);
    try testing.expectEqual(@as(usize, 5), all.seen);

    var stopped = IndexCbCounter{ .stop_after = 2 };
    store.scanPrefixCallback("cb:", @ptrCast(&stopped), indexCbCount);
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
