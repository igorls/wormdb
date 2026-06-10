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
fn shardRemoveLocked(shard: *Shard, key: []const u8) ?*Entry {
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
    return removed.value;
}

pub const LockPair = struct {
    low: usize,
    high: ?usize,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    shards: [SHARD_COUNT]Shard,
    wal: ?Wal,
    wal_enqueue_mutex: core.compat.Mutex,
    config: Config,
    /// Optional HNSW registry back-reference. Attached by main.zig after
    /// both objects exist; snapshot write/load use it when present.
    vector_registry: ?*NamespaceRegistry = null,
    /// Registry of frozen read-only segments (mmap'd `.wseg`), addressed by an
    /// opaque caller-chosen name. The engine is domain-agnostic: a serving layer
    /// attaches and looks up "its" segment by a string it owns (e.g. "lightapi",
    /// "atomicassets"), so no blockchain/domain identity lives in the store.
    /// Attached by the composition root (`main.zig`) after construction; each
    /// segment (and its name) must outlive the store. Small fixed capacity —
    /// there are only a handful of serving domains.
    segments_buf: [MAX_SEGMENTS]NamedSegment = undefined,
    segment_count: usize = 0,

    /// Attach the per-namespace HNSW registry to this store so snapshots
    /// persist and restore graph state alongside KV data. Call after both
    /// the store and the registry have been constructed (see main.zig).
    pub fn attachVectorRegistry(self: *Store, registry: *NamespaceRegistry) void {
        self.vector_registry = registry;
    }

    const MAX_SEGMENTS: usize = 8;
    const NamedSegment = struct { name: []const u8, seg: *const Segment };

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
        };

        // Load snapshot for full and snapshot modes, skip for none
        if (config.persistence != .none) {
            try store.loadSnapshot();
        }
        // Only replay WAL in full mode
        if (config.persistence == .full) {
            try store.replayWal();
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
    }

    pub fn destroyEntry(self: *Store, entry: *Entry) void {
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
        }
    }

    /// Delete without WAL or WORM checks — the procedure-context (`Ctx.del`)
    /// escape hatch. Caller must hold the key's shard lock. Unlike a raw
    /// `data.fetchRemove`, this keeps the ordered index in sync.
    pub fn deleteUnsafe(self: *Store, key: []const u8) void {
        const shard = &self.shards[shardIndex(key)];
        if (shardRemoveLocked(shard, key)) |removed| {
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
    pub fn getValueDupe(self: *Store, key: []const u8, alloc: std.mem.Allocator) !?[]const u8 {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        defer self.shards[si].mutex.unlock();
        if (self.shards[si].data.get(key)) |entry| {
            return try alloc.dupe(u8, entry.value);
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

    /// Write without acquiring a lock. Caller must hold the key shard lock.
    pub fn setUnsafe(self: *Store, key: []const u8, value: []const u8, is_worm: bool) StoreError!void {
        return self.setInternalLocked(shardIndex(key), key, value, is_worm);
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

        shard.mutex.lock();
        defer shard.mutex.unlock();

        if (shard.data.get(key)) |existing| {
            if (existing.flags.is_worm) {
                return error.WormViolation;
            }
        }

        const entry = if (self.config.persistence == .full) blk: {
            self.wal_enqueue_mutex.lock();
            const e = self.wal.?.appendSet(key, value, .{ .is_worm = is_worm, .is_deleted = false }, timestamp) catch {
                self.wal_enqueue_mutex.unlock();
                return error.IoError;
            };
            self.wal_enqueue_mutex.unlock();
            break :blk e;
        } else blk: {
            // snapshot/none mode: create Entry directly, no WAL IO
            const e = self.allocator.create(Entry) catch return error.OutOfMemory;
            errdefer self.allocator.destroy(e);
            const ek = self.allocator.dupe(u8, key) catch {
                self.allocator.destroy(e);
                return error.OutOfMemory;
            };
            const ev = self.allocator.dupe(u8, value) catch {
                self.allocator.free(ek);
                self.allocator.destroy(e);
                return error.OutOfMemory;
            };
            e.* = .{ .key = ek, .value = ev, .timestamp = timestamp, .flags = .{ .is_worm = is_worm, .is_deleted = false } };
            break :blk e;
        };
        errdefer self.destroyEntry(entry);

        // Insert into the hashmap + ordered index together. The shard lock is
        // held for the whole operation (upstream restructure), so no WORM
        // re-check is needed; on error the errdefer above destroys `entry`.
        try self.shardPutLocked(shard, entry);

        // Release shard lock before snapshot check to avoid deadlock
        // (writeSnapshot locks ALL shards).
        shard.mutex.unlock();

        if (self.config.persistence == .full) {
            self.maybeSnapshotAndTruncate() catch {};
        }

        // shard.mutex was unlocked above — re-lock so the defer unlock is safe
        shard.mutex.lock();
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

    fn setInternalLocked(self: *Store, si: usize, key: []const u8, value: []const u8, is_worm: bool) StoreError!void {
        const shard = &self.shards[si];
        const timestamp: u64 = @intCast(compat.nowMs());

        if (shard.data.get(key)) |existing| {
            if (existing.flags.is_worm) return error.WormViolation;
        }

        const entry = if (self.config.persistence == .full) blk: {
            self.wal_enqueue_mutex.lock();
            const e = self.wal.?.appendSet(key, value, .{ .is_worm = is_worm, .is_deleted = false }, timestamp) catch {
                self.wal_enqueue_mutex.unlock();
                return error.IoError;
            };
            self.wal_enqueue_mutex.unlock();
            break :blk e;
        } else blk: {
            const e = self.allocator.create(Entry) catch return error.OutOfMemory;
            errdefer self.allocator.destroy(e);
            const ek = self.allocator.dupe(u8, key) catch {
                self.allocator.destroy(e);
                return error.OutOfMemory;
            };
            const ev = self.allocator.dupe(u8, value) catch {
                self.allocator.free(ek);
                self.allocator.destroy(e);
                return error.OutOfMemory;
            };
            e.* = .{ .key = ek, .value = ev, .timestamp = timestamp, .flags = .{ .is_worm = is_worm, .is_deleted = false } };
            break :blk e;
        };
        errdefer self.destroyEntry(entry);

        try self.shardPutLocked(shard, entry);

        if (self.config.persistence == .full) {
            self.maybeSnapshotAndTruncate() catch {};
        }
    }

    /// Delete a key.
    pub fn delete(self: *Store, key: []const u8) StoreError!void {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        defer self.shards[si].mutex.unlock();
        const shard = &self.shards[si];

        if (shard.data.get(key)) |existing| {
            if (existing.flags.is_worm) return error.WormViolation;

            if (self.config.persistence == .full) {
                self.wal_enqueue_mutex.lock();
                self.wal.?.appendDelete(key) catch {
                    self.wal_enqueue_mutex.unlock();
                    return error.IoError;
                };
                self.wal_enqueue_mutex.unlock();
            }

            if (shardRemoveLocked(shard, key)) |removed| {
                self.destroyEntry(removed);
            }

            if (self.config.persistence == .full) {
                self.maybeSnapshotAndTruncate() catch {};
            }
        }
    }

    pub fn exists(self: *Store, key: []const u8) bool {
        const si = shardIndex(key);
        self.shards[si].mutex.lock();
        defer self.shards[si].mutex.unlock();
        return self.shards[si].data.contains(key);
    }

    pub fn count(self: *Store) usize {
        var total: usize = 0;
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            total += shard.data.count();
            shard.mutex.unlock();
        }
        return total;
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
                            if (shardRemoveLocked(shard, key)) |removed| {
                                self.destroyEntry(removed);
                            }
                        }
                    }
                    self.allocator.free(key);
                },
            }
            record_count += 1;
        }

        if (record_count > 0) {
            std.log.info("WAL replay complete. Processed {d} records.", .{record_count});
        }
    }

    fn maybeSnapshotAndTruncate(self: *Store) !void {
        // Background WAL writer and truncation are not coordinated yet.
        // Keep truncation disabled in sync_writes mode to avoid races.
        if (self.config.sync_writes) return;
        if (self.config.max_wal_size == 0) return;
        if (self.wal) |*w| {
            const wal_size = try w.size();
            if (wal_size < self.config.max_wal_size) return;
            try self.writeSnapshot();
            try w.truncate();
        }
    }

    fn writeSnapshot(self: *Store) !void {
        for (&self.shards) |*shard| shard.mutex.lock();
        defer for (&self.shards) |*shard| shard.mutex.unlock();

        const temp_snapshot_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.config.snapshot_path});
        defer self.allocator.free(temp_snapshot_path);

        const snapshot_file = try compat.Dir.createFile(core.compat.cwd(), temp_snapshot_path, .{ .read = true, .truncate = true });
        errdefer compat.File.close(snapshot_file);

        var data_count: usize = 0;
        for (&self.shards) |*shard| data_count += shard.data.count();

        var entries = try self.allocator.alloc(*Entry, data_count);
        defer self.allocator.free(entries);

        var entry_index: usize = 0;
        for (&self.shards) |*shard| {
            var iter = shard.data.iterator();
            while (iter.next()) |item| {
                entries[entry_index] = item.value_ptr.*;
                entry_index += 1;
            }
        }

        std.sort.heap(*Entry, entries[0..entry_index], {}, struct {
            fn lessThan(_: void, lhs: *Entry, rhs: *Entry) bool {
                return std.mem.lessThan(u8, lhs.key, rhs.key);
            }
        }.lessThan);

        try compat.File.writeAll(snapshot_file, SNAPSHOT_MAGIC);

        var version_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, version_buf[0..4], SNAPSHOT_VERSION, .little);
        try compat.File.writeAll(snapshot_file, version_buf[0..4]);

        var count_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, count_buf[0..8], @intCast(entry_index), .little);
        try compat.File.writeAll(snapshot_file, count_buf[0..8]);

        for (entries[0..entry_index]) |entry| {
            var key_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, key_len_buf[0..4], @intCast(entry.key.len), .little);
            try compat.File.writeAll(snapshot_file, key_len_buf[0..4]);

            var value_len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, value_len_buf[0..4], @intCast(entry.value.len), .little);
            try compat.File.writeAll(snapshot_file, value_len_buf[0..4]);

            const flags_byte: u8 = @bitCast(entry.flags);
            try compat.File.writeAll(snapshot_file, &[_]u8{flags_byte});

            var timestamp_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, timestamp_buf[0..8], entry.timestamp, .little);
            try compat.File.writeAll(snapshot_file, timestamp_buf[0..8]);

            try compat.File.writeAll(snapshot_file, entry.key);
            try compat.File.writeAll(snapshot_file, entry.value);
        }

        // ── v2 HNSW trailer (optional) ──
        // Only written when a registry is attached and has at least one
        // namespace. Shards are still locked at this point (from the top
        // of writeSnapshot's defer), so no new vinsert can race with the
        // per-namespace write-locks we acquire inside registry.writeTo.
        if (self.vector_registry) |reg| {
            if (reg.map.count() > 0) {
                var snap_writer = FileWriter{ .file = snapshot_file };
                reg.writeTo(&snap_writer) catch |err| {
                    std.log.warn("writeSnapshot: HNSW trailer skipped: {s}", .{@errorName(err)});
                };
            }
        }

        try compat.File.sync(snapshot_file);
        compat.File.close(snapshot_file);

        try compat.Dir.rename(core.compat.cwd(), temp_snapshot_path, self.config.snapshot_path);
    }

    /// Thin adapter exposing `.writeAll` over an `std.Io.File`. Needed
    /// because the registry/HNSW serializers take `anytype` writers and
    /// `compat.File.writeAll` is a free function, not a method.
    const FileWriter = struct {
        file: std.Io.File,
        pub fn writeAll(self: *@This(), data: []const u8) !void {
            try compat.File.writeAll(self.file, data);
        }
    };

    /// Thin adapter exposing `.readAll` over an `std.Io.File`. Mirrors
    /// FileWriter for the read path.
    const FileReader = struct {
        file: std.Io.File,
        pub fn readAll(self: *@This(), dest: []u8) !usize {
            return compat.File.readAll(self.file, dest);
        }
    };

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

        var magic_buf: [SNAPSHOT_MAGIC.len]u8 = undefined;
        if (try compat.File.readAll(snapshot_file, magic_buf[0..]) != magic_buf.len) {
            return error.Corruption;
        }
        if (!std.mem.eql(u8, magic_buf[0..], SNAPSHOT_MAGIC)) {
            return error.Corruption;
        }

        var version_buf: [4]u8 = undefined;
        if (try compat.File.readAll(snapshot_file, version_buf[0..4]) != version_buf.len) {
            return error.Corruption;
        }
        const version = std.mem.readInt(u32, version_buf[0..4], .little);
        if (version != 1 and version != 2) {
            return error.Corruption;
        }

        var count_buf: [8]u8 = undefined;
        if (try compat.File.readAll(snapshot_file, count_buf[0..8]) != count_buf.len) {
            return error.Corruption;
        }
        const entry_count = std.mem.readInt(u64, count_buf[0..8], .little);

        std.log.info("Loading snapshot: {d} entries...", .{entry_count});

        var i: u64 = 0;
        while (i < entry_count) : (i += 1) {
            if (i > 0 and i % 500_000 == 0) {
                std.log.info("Snapshot load progress: {d}/{d} entries loaded...", .{ i, entry_count });
            }
            var key_len_buf: [4]u8 = undefined;
            if (try compat.File.readAll(snapshot_file, key_len_buf[0..4]) != key_len_buf.len) {
                return error.Corruption;
            }
            const key_len: usize = @intCast(std.mem.readInt(u32, key_len_buf[0..4], .little));

            var value_len_buf: [4]u8 = undefined;
            if (try compat.File.readAll(snapshot_file, value_len_buf[0..4]) != value_len_buf.len) {
                return error.Corruption;
            }
            const value_len: usize = @intCast(std.mem.readInt(u32, value_len_buf[0..4], .little));

            var flags_buf: [1]u8 = undefined;
            if (try compat.File.readAll(snapshot_file, flags_buf[0..1]) != flags_buf.len) {
                return error.Corruption;
            }
            const flags: EntryFlags = @bitCast(flags_buf[0]);

            var timestamp_buf: [8]u8 = undefined;
            if (try compat.File.readAll(snapshot_file, timestamp_buf[0..8]) != timestamp_buf.len) {
                return error.Corruption;
            }
            const timestamp = std.mem.readInt(u64, timestamp_buf[0..8], .little);

            const key = try self.allocator.alloc(u8, key_len);
            errdefer self.allocator.free(key);
            if (try compat.File.readAll(snapshot_file, key) != key.len) {
                return error.Corruption;
            }

            const value = try self.allocator.alloc(u8, value_len);
            errdefer self.allocator.free(value);
            if (try compat.File.readAll(snapshot_file, value) != value.len) {
                return error.Corruption;
            }

            const entry = try self.allocator.create(Entry);
            entry.* = .{
                .key = key,
                .value = value,
                .timestamp = timestamp,
                .flags = flags,
            };

            // On failure shardPutLocked leaves the shard untouched — free only
            // the Entry struct here; the errdefers above still own key/value
            // (a destroyEntry would double-free them).
            const shard = &self.shards[shardIndex(entry.key)];
            self.shardPutLocked(shard, entry) catch |err| {
                self.allocator.destroy(entry);
                return err;
            };
        }

        std.log.info("Snapshot load complete.", .{});

        // ── v2 HNSW trailer (optional) ──
        // v1 files have nothing after the last KV entry; readFrom would
        // hit EOF and we'd swallow the error below. v2 files have a
        // WDBHNSW{1,2}-marked block that restores the registry.
        if (version >= 2 and self.vector_registry != null) {
            var reader = FileReader{ .file = snapshot_file };
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
