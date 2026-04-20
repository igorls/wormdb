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

const SNAPSHOT_MAGIC = "WDBSNAP1";
const SNAPSHOT_VERSION: u32 = 1;

const SHARD_COUNT: usize = 256;

pub fn shardIndex(key: []const u8) usize {
    var hash = std.hash.Fnv1a_64.init();
    hash.update(key);
    return @intCast(hash.final() & (SHARD_COUNT - 1));
}

const Shard = struct {
    mutex: core.compat.Mutex,
    data: std.StringHashMap(*Entry),
};

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

    pub fn init(allocator: std.mem.Allocator, config: Config) !Store {
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
            };
        }

        var store = Store{
            .allocator = allocator,
            .shards = shards,
            .wal = wal,
            .wal_enqueue_mutex = .{},
            .config = config,
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
        }
    }

    pub fn destroyEntry(self: *Store, entry: *Entry) void {
        entry.deinit(self.allocator);
        self.allocator.destroy(entry);
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
        const si = shardIndex(key);
        const shard = &self.shards[si];
        const timestamp: u64 = @intCast(std.time.milliTimestamp());

        // Phase 1: Check WORM under shard lock
        shard.mutex.lock();
        if (shard.data.get(key)) |existing| {
            if (existing.flags.is_worm) {
                shard.mutex.unlock();
                return error.WormViolation;
            }
        }
        shard.mutex.unlock();

        // Phase 2: Create entry (+ WAL enqueue if full persistence) — no shard lock held
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

        // Phase 3: Re-acquire shard lock and insert
        shard.mutex.lock();
        defer shard.mutex.unlock();

        // Re-check WORM (another thread could have set it while we were unlocked)
        if (shard.data.get(key)) |existing| {
            if (existing.flags.is_worm) {
                self.destroyEntry(entry);
                return error.WormViolation;
            }
        }

        if (shard.data.fetchRemove(key)) |removed| {
            self.destroyEntry(removed.value);
        }

        shard.data.put(entry.key, entry) catch {
            self.destroyEntry(entry);
            return error.OutOfMemory;
        };

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
        const timestamp: u64 = @intCast(std.time.milliTimestamp());

        if (shard.data.get(key)) |existing| {
            if (existing.flags.is_worm) return error.WormViolation;
        }

        if (shard.data.fetchRemove(key)) |removed| {
            self.destroyEntry(removed.value);
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

        try shard.data.put(entry.key, entry);

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

            if (shard.data.fetchRemove(key)) |removed| {
                self.destroyEntry(removed.value);
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

    /// Scan for keys matching a prefix. Returns arena-allocated copies sorted by key (ascending).
    /// Locks each shard individually — does NOT require the caller to hold any locks.
    /// O(N) over total keys in the store; cap with `limit` to bound cost.
    pub fn scanPrefix(
        self: *Store,
        prefix: []const u8,
        limit: usize,
        alloc: std.mem.Allocator,
    ) ![]ScanResult {
        var results: std.ArrayListUnmanaged(ScanResult) = .{};
        errdefer {
            for (results.items) |r| {
                alloc.free(r.key);
                alloc.free(r.value);
            }
            results.deinit(alloc);
        }

        // Scan each shard independently
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            var iter = shard.data.iterator();
            while (iter.next()) |entry| {
                const e = entry.value_ptr.*;
                if (e.key.len >= prefix.len and std.mem.eql(u8, e.key[0..prefix.len], prefix)) {
                    // Copy key and value into the arena so they survive after unlock
                    const key_copy = try alloc.dupe(u8, e.key);
                    errdefer alloc.free(key_copy);
                    const val_copy = try alloc.dupe(u8, e.value);

                    try results.append(alloc, .{
                        .key = key_copy,
                        .value = val_copy,
                        .timestamp = e.timestamp,
                        .is_worm = e.flags.is_worm,
                    });
                }
            }
        }

        // Sort by key ascending (lexicographic = chronological for timestamp-keyed data)
        std.sort.heap(ScanResult, results.items, {}, struct {
            fn lessThan(_: void, a: ScanResult, b: ScanResult) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lessThan);

        // Apply limit (keep last N for "newest last" ordering)
        if (limit > 0 and results.items.len > limit) {
            // Free the excess oldest entries
            const excess = results.items.len - limit;
            for (results.items[0..excess]) |r| {
                alloc.free(r.key);
                alloc.free(r.value);
            }
            // Shift the remaining items
            std.mem.copyForwards(ScanResult, results.items[0..limit], results.items[excess..]);
            results.shrinkRetainingCapacity(limit);
        }

        return try results.toOwnedSlice(alloc);
    }

    /// Count keys matching a prefix. Lightweight — no allocation, no value copying.
    pub fn countPrefix(self: *Store, prefix: []const u8) usize {
        var total: usize = 0;
        for (&self.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            var iter = shard.data.iterator();
            while (iter.next()) |entry| {
                const key = entry.value_ptr.*.key;
                if (key.len >= prefix.len and std.mem.eql(u8, key[0..prefix.len], prefix)) {
                    total += 1;
                }
            }
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
                    const si = shardIndex(set_rec.key);
                    const shard = &self.shards[si];

                    if (shard.data.fetchRemove(set_rec.key)) |removed| {
                        self.destroyEntry(removed.value);
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
                    try shard.data.put(entry.key, entry);
                },
                .delete => |key| {
                    const si = shardIndex(key);
                    const shard = &self.shards[si];
                    if (shard.data.fetchRemove(key)) |removed| {
                        self.destroyEntry(removed.value);
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

        try compat.File.sync(snapshot_file);
        compat.File.close(snapshot_file);

        try compat.Dir.rename(core.compat.cwd(), temp_snapshot_path, self.config.snapshot_path);
    }

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
        if (version != SNAPSHOT_VERSION) {
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
            errdefer self.allocator.destroy(entry);
            entry.* = .{
                .key = key,
                .value = value,
                .timestamp = timestamp,
                .flags = flags,
            };
            errdefer self.destroyEntry(entry);

            const si = shardIndex(entry.key);
            const shard = &self.shards[si];

            if (shard.data.fetchRemove(entry.key)) |removed| {
                self.destroyEntry(removed.value);
            }

            try shard.data.put(entry.key, entry);
        }

        std.log.info("Snapshot load complete.", .{});
    }
};

test "Store basic operations" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_store.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const file = try tmp_dir.dir.createFile("test_store.wal", .{});
    file.close();

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

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_worm.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const file = try tmp_dir.dir.createFile("test_worm.wal", .{});
    file.close();

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

test "Store replay handles overwrite and delete safely" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_replay_ownership.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_replay_ownership.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const file = try tmp_dir.dir.createFile("test_replay_ownership.wal", .{});
    file.close();

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

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_snapshot_restore.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_snapshot_restore.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const file = try tmp_dir.dir.createFile("test_snapshot_restore.wal", .{});
    file.close();

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

    const tmp_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_wal_truncate.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_wal_truncate.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const file = try tmp_dir.dir.createFile("test_wal_truncate.wal", .{});
    file.close();

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
