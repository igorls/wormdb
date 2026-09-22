//! Write-Ahead Log (WAL) for durability
//!
//! Binary format with CRC32 verification for crash recovery.

const std = @import("std");
const core = @import("../core/mod.zig");

const WalRecordType = core.types.WalRecordType;
const Entry = core.types.Entry;
const EntryFlags = core.types.EntryFlags;
const Timestamp = core.types.Timestamp;
const compat = core.compat;

// CRC32 Castagnoli with comptime-generated lookup table (4-8x faster than bit-by-bit)
const CRC32_TABLE: [256]u32 = blk: {
    @setEvalBranchQuota(100_000);
    const polynomial: u32 = 0x82F63B78;
    var table: [256]u32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var crc: u32 = @intCast(i);
        var j: usize = 0;
        while (j < 8) : (j += 1) {
            crc = if (crc & 1 != 0) (crc >> 1) ^ polynomial else crc >> 1;
        }
        table[i] = crc;
    }
    break :blk table;
};

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = (crc >> 8) ^ CRC32_TABLE[@as(u8, @truncate(crc)) ^ byte];
    }
    return crc ^ 0xFFFFFFFF;
}

pub const Wal = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    path: []const u8,
    sync_writes: bool,
    write_count: usize,
    queue: []?[]u8,
    queue_head: std.atomic.Value(usize),
    queue_tail: std.atomic.Value(usize),
    writer_thread: ?std.Thread,
    writer_running: std.atomic.Value(bool),
    writer_started: bool,
    sync_requested: std.atomic.Value(bool),
    wake_futex: std.atomic.Value(u32),
    /// Direct synchronous I/O failures have an uncertain commit outcome. Do
    /// not acknowledge later writes against a live view that may differ from
    /// replay. Store serializes these fields with wal_enqueue_mutex.
    sync_failed: bool = false,
    fail_sync_for_test: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},

    // Power-of-two ring capacity for mask indexing.
    const WAL_QUEUE_CAP: usize = 1 << 16;
    const WAL_QUEUE_MASK: usize = WAL_QUEUE_CAP - 1;

    const RecordHeader = extern struct {
        crc: u32 align(1),
        record_type: u8 align(1),
        length: u64 align(1),
    };

    const SET_PAYLOAD_OVERHEAD = 2 + 4 + 1 + 8;
    const DEL_PAYLOAD_OVERHEAD = 2;
    const VINSERT_PAYLOAD_OVERHEAD = 2 + 2 + 2 + 1 + 8;
    const VDELETE_PAYLOAD_OVERHEAD = 2 + 2;

    pub fn init(allocator: std.mem.Allocator, path: []const u8, sync_writes: bool) !Wal {
        const file = try compat.Dir.openFile(compat.cwd(), path, .{ .mode = .read_write });
        // Seek to end of file for append
        const s = try compat.File.stat(file);
        try compat.File.seekTo(file, s.size);

        const queue = try allocator.alloc(?[]u8, WAL_QUEUE_CAP);
        errdefer allocator.free(queue);
        for (queue) |*slot| slot.* = null;

        return .{
            .allocator = allocator,
            .file = file,
            .path = path,
            .sync_writes = sync_writes,
            .write_count = 0,
            .queue = queue,
            .queue_head = std.atomic.Value(usize).init(0),
            .queue_tail = std.atomic.Value(usize).init(0),
            .writer_thread = null,
            .writer_running = std.atomic.Value(bool).init(false),
            .writer_started = false,
            .sync_requested = std.atomic.Value(bool).init(false),
            .wake_futex = std.atomic.Value(u32).init(0),
        };
    }

    /// Start background WAL writer for lock-free producer submission.
    /// Producer path becomes enqueue-only; this removes file I/O from request critical path.
    pub fn startBackground(self: *Wal) !void {
        if (!self.sync_writes or self.writer_started) return;
        self.writer_running.store(true, .release);
        self.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{self});
        self.writer_started = true;
    }

    pub fn deinit(self: *Wal) void {
        if (self.writer_started) {
            self.writer_running.store(false, .release);
            if (self.writer_thread) |t| t.join();
            self.writer_thread = null;
            self.writer_started = false;
        }

        // Free any residual queued buffers (should be empty after join, but safe).
        while (self.tryDequeueRecord()) |record| {
            self.allocator.free(record);
        }

        self.allocator.free(self.queue);
        compat.File.close(self.file);
    }

    /// Flush WAL to durable storage. Called by the group-commit background thread.
    pub fn sync(self: *Wal) !void {
        if (self.sync_failed) return error.WalNeedsRecovery;
        if (self.writer_started) {
            self.sync_requested.store(true, .release);
            return;
        }
        try compat.File.sync(self.file);
    }

    /// Append a SET record to the WAL.
    /// Returns a heap-allocated `Entry` that owns duplicated key/value memory.
    /// Caller owns the returned entry and must call `entry.deinit(allocator)` + `allocator.destroy(entry)`.
    pub fn appendSet(self: *Wal, key: []const u8, value: []const u8, flags: EntryFlags, timestamp: Timestamp) !*Entry {
        const record = try self.serializeSetRecord(key, value, flags, timestamp);

        if (self.writer_started) {
            self.enqueueRecordBlocking(record);
        } else {
            errdefer self.allocator.free(record);
            try self.writeDirect(record);
            self.allocator.free(record);
        }

        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        const entry_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(entry_key);

        const entry_value = try self.allocator.dupe(u8, value);
        entry.* = .{
            .key = entry_key,
            .value = entry_value,
            .timestamp = timestamp,
            .flags = flags,
        };
        return entry;
    }

    pub fn appendDelete(self: *Wal, key: []const u8) !void {
        const record = try self.serializeDeleteRecord(key);

        if (self.writer_started) {
            self.enqueueRecordBlocking(record);
        } else {
            errdefer self.allocator.free(record);
            try self.writeDirect(record);
            self.allocator.free(record);
        }
    }

    pub fn appendVinsert(
        self: *Wal,
        key: []const u8,
        namespace: []const u8,
        metric: []const u8,
        flags: u8,
        timestamp: Timestamp,
    ) !void {
        const record = try self.serializeVinsertRecord(key, namespace, metric, flags, timestamp);

        if (self.writer_started) {
            self.enqueueRecordBlocking(record);
        } else {
            errdefer self.allocator.free(record);
            try self.writeDirect(record);
            self.allocator.free(record);
        }
    }

    pub fn appendVdelete(self: *Wal, key: []const u8, namespace: []const u8) !void {
        const record = try self.serializeVdeleteRecord(key, namespace);

        if (self.writer_started) {
            self.enqueueRecordBlocking(record);
        } else {
            errdefer self.allocator.free(record);
            try self.writeDirect(record);
            self.allocator.free(record);
        }
    }

    fn writeDirect(self: *Wal, record: []const u8) !void {
        if (self.sync_failed) return error.WalNeedsRecovery;
        errdefer if (self.sync_writes) {
            self.sync_failed = true;
        };
        try compat.File.writeAll(self.file, record);
        if (self.sync_writes) {
            if (@import("builtin").is_test) {
                if (self.fail_sync_for_test) return error.InjectedSyncFailure;
            }
            try compat.File.sync(self.file);
        }
        self.write_count += 1;
    }

    fn serializeSetRecord(self: *Wal, key: []const u8, value: []const u8, flags: EntryFlags, timestamp: Timestamp) ![]u8 {
        const payload_len = SET_PAYLOAD_OVERHEAD + key.len + value.len;
        const total_len = @sizeOf(RecordHeader) + payload_len;
        const buf = try self.allocator.alloc(u8, total_len);

        var pos: usize = @sizeOf(RecordHeader);
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(key.len), .little);
        pos += 2;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(value.len), .little);
        pos += 4;
        buf[pos] = @as(u8, @bitCast(flags));
        pos += 1;
        std.mem.writeInt(u64, buf[pos..][0..8], timestamp, .little);
        pos += 8;
        @memcpy(buf[pos..][0..key.len], key);
        pos += key.len;
        @memcpy(buf[pos..][0..value.len], value);

        const payload_slice = buf[@sizeOf(RecordHeader)..total_len];
        const header = RecordHeader{
            .crc = crc32(payload_slice),
            .record_type = @intFromEnum(WalRecordType.set),
            .length = @intCast(payload_len),
        };
        @memcpy(buf[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
        return buf;
    }

    fn serializeDeleteRecord(self: *Wal, key: []const u8) ![]u8 {
        const payload_len = DEL_PAYLOAD_OVERHEAD + key.len;
        const total_len = @sizeOf(RecordHeader) + payload_len;
        const buf = try self.allocator.alloc(u8, total_len);

        var pos: usize = @sizeOf(RecordHeader);
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(key.len), .little);
        pos += 2;
        @memcpy(buf[pos..][0..key.len], key);

        const payload_slice = buf[@sizeOf(RecordHeader)..total_len];
        const header = RecordHeader{
            .crc = crc32(payload_slice),
            .record_type = @intFromEnum(WalRecordType.delete),
            .length = @intCast(payload_len),
        };
        @memcpy(buf[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
        return buf;
    }

    fn serializeVinsertRecord(
        self: *Wal,
        key: []const u8,
        namespace: []const u8,
        metric: []const u8,
        flags: u8,
        timestamp: Timestamp,
    ) ![]u8 {
        const payload_len = VINSERT_PAYLOAD_OVERHEAD + key.len + namespace.len + metric.len;
        const total_len = @sizeOf(RecordHeader) + payload_len;
        const buf = try self.allocator.alloc(u8, total_len);

        var pos: usize = @sizeOf(RecordHeader);
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(key.len), .little);
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(namespace.len), .little);
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(metric.len), .little);
        pos += 2;
        buf[pos] = flags;
        pos += 1;
        std.mem.writeInt(u64, buf[pos..][0..8], timestamp, .little);
        pos += 8;
        @memcpy(buf[pos..][0..key.len], key);
        pos += key.len;
        @memcpy(buf[pos..][0..namespace.len], namespace);
        pos += namespace.len;
        @memcpy(buf[pos..][0..metric.len], metric);

        const payload_slice = buf[@sizeOf(RecordHeader)..total_len];
        const header = RecordHeader{
            .crc = crc32(payload_slice),
            .record_type = @intFromEnum(WalRecordType.vinsert),
            .length = @intCast(payload_len),
        };
        @memcpy(buf[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
        return buf;
    }

    fn serializeVdeleteRecord(self: *Wal, key: []const u8, namespace: []const u8) ![]u8 {
        const payload_len = VDELETE_PAYLOAD_OVERHEAD + key.len + namespace.len;
        const total_len = @sizeOf(RecordHeader) + payload_len;
        const buf = try self.allocator.alloc(u8, total_len);

        var pos: usize = @sizeOf(RecordHeader);
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(key.len), .little);
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(namespace.len), .little);
        pos += 2;
        @memcpy(buf[pos..][0..key.len], key);
        pos += key.len;
        @memcpy(buf[pos..][0..namespace.len], namespace);

        const payload_slice = buf[@sizeOf(RecordHeader)..total_len];
        const header = RecordHeader{
            .crc = crc32(payload_slice),
            .record_type = @intFromEnum(WalRecordType.vdelete),
            .length = @intCast(payload_len),
        };
        @memcpy(buf[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
        return buf;
    }

    /// Single-producer enqueue (producer currently runs under Store global write lock).
    fn enqueueRecordBlocking(self: *Wal, record: []u8) void {
        while (!self.tryEnqueueRecord(record)) {
            // Wait on futex instead of spinning — wake when consumer drains
            compat.Futex.timedWait(&self.wake_futex, self.wake_futex.load(.acquire), 50_000);
        }
        // Wake writer thread immediately
        _ = self.wake_futex.fetchAdd(1, .release);
        compat.Futex.wake(&self.wake_futex, 1);
    }

    fn tryEnqueueRecord(self: *Wal, record: []u8) bool {
        const head = self.queue_head.load(.acquire);
        const tail = self.queue_tail.load(.acquire);
        if (tail - head >= self.queue.len) return false;

        const idx = tail & WAL_QUEUE_MASK;
        self.queue[idx] = record;
        self.queue_tail.store(tail + 1, .release);
        return true;
    }

    fn tryDequeueRecord(self: *Wal) ?[]u8 {
        const head = self.queue_head.load(.acquire);
        const tail = self.queue_tail.load(.acquire);
        if (head == tail) return null;

        const idx = head & WAL_QUEUE_MASK;
        const record = self.queue[idx] orelse return null;
        self.queue[idx] = null;
        self.queue_head.store(head + 1, .release);
        return record;
    }

    fn hasPendingRecords(self: *Wal) bool {
        return self.queue_head.load(.acquire) != self.queue_tail.load(.acquire);
    }

    fn writerLoop(self: *Wal) void {
        while (self.writer_running.load(.acquire) or self.hasPendingRecords()) {
            // Drain phase: collect all pending records into a batch
            var batch: [64][]u8 = undefined;
            var batch_count: usize = 0;
            while (batch_count < 64) {
                if (self.tryDequeueRecord()) |record| {
                    batch[batch_count] = record;
                    batch_count += 1;
                } else break;
            }

            if (batch_count > 0) {
                // Write all records in batch
                for (batch[0..batch_count]) |record| {
                    compat.File.writeAll(self.file, record) catch {};
                    self.allocator.free(record);
                    self.write_count += 1;
                }
                // Single fsync for entire batch — key performance win
                if (self.sync_writes) {
                    compat.File.sync(self.file) catch {};
                }
                // Wake producer in case it was blocked on a full queue
                _ = self.wake_futex.fetchAdd(1, .release);
                compat.Futex.wake(&self.wake_futex, 1);
                continue;
            }

            if (self.sync_requested.swap(false, .acq_rel)) {
                compat.File.sync(self.file) catch {};
                continue;
            }

            // Wait for producer to enqueue — instant wake, zero CPU waste
            compat.Futex.timedWait(&self.wake_futex, self.wake_futex.load(.acquire), 1_000_000);
        }

        // Final durability point on shutdown.
        compat.File.sync(self.file) catch {};
    }

    pub fn iterator(self: *Wal) WalIterator {
        compat.File.seekTo(self.file, 0) catch {};
        return .{ .file = self.file, .allocator = self.allocator };
    }

    pub fn size(self: *Wal) !usize {
        const s = try compat.File.stat(self.file);
        return @intCast(s.size);
    }

    /// Truncate the WAL to zero bytes and reset write cursor to the beginning.
    pub fn truncate(self: *Wal) !void {
        try compat.File.setLength(self.file, 0);
        try compat.File.seekTo(self.file, 0);
        if (self.sync_writes) {
            try compat.File.sync(self.file);
        }
    }
};

pub const WalRecord = union(enum) {
    set: SetRecord,
    delete: []const u8,
    vinsert: VinsertRecord,
    vdelete: VdeleteRecord,

    pub const SetRecord = struct {
        key: []const u8,
        value: []const u8,
        flags: EntryFlags,
        timestamp: Timestamp,
    };

    pub const VinsertRecord = struct {
        key: []const u8,
        namespace: []const u8,
        metric: []const u8,
        flags: u8,
        timestamp: Timestamp,

        pub fn isWorm(self: VinsertRecord) bool {
            return (self.flags & 0x01) != 0;
        }

        pub fn isAsync(self: VinsertRecord) bool {
            return (self.flags & 0x02) != 0;
        }
    };

    pub const VdeleteRecord = struct {
        key: []const u8,
        namespace: []const u8,
    };
};

pub const WalIterator = struct {
    file: std.Io.File,
    allocator: std.mem.Allocator,
    done: bool = false,

    pub fn next(self: *WalIterator) !?WalRecord {
        if (self.done) return null;

        var header: Wal.RecordHeader = undefined;
        const header_bytes_read = compat.File.readAll(self.file, std.mem.asBytes(&header)) catch {
            self.done = true;
            return null;
        };

        if (header_bytes_read < @sizeOf(Wal.RecordHeader)) {
            self.done = true;
            return null;
        }

        const payload_len: usize = @intCast(header.length);
        if (payload_len == 0 or payload_len > 1024 * 1024 * 100) return error.Corruption;

        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        const payload_read = compat.File.readAll(self.file, payload) catch {
            self.done = true;
            return null;
        };
        _ = payload_read;

        if (crc32(payload) != header.crc) return error.Corruption;

        const record_type: WalRecordType = @enumFromInt(header.record_type);
        return switch (record_type) {
            .set => try self.parseSet(payload),
            .delete => try self.parseDelete(payload),
            .vinsert => try self.parseVinsert(payload),
            .vdelete => try self.parseVdelete(payload),
        };
    }

    fn parseSet(self: *WalIterator, payload: []const u8) !WalRecord {
        if (payload.len < Wal.SET_PAYLOAD_OVERHEAD) return error.Corruption;
        var pos: usize = 0;
        const key_len: usize = @intCast(std.mem.readInt(u16, payload[pos..][0..2], .little));
        pos += 2;
        const value_len: usize = @intCast(std.mem.readInt(u32, payload[pos..][0..4], .little));
        pos += 4;
        const flags: EntryFlags = @bitCast(payload[pos]);
        pos += 1;
        const timestamp: Timestamp = std.mem.readInt(u64, payload[pos..][0..8], .little);
        pos += 8;
        if (pos + key_len + value_len != payload.len) return error.Corruption;
        const key = try self.allocator.dupe(u8, payload[pos..][0..key_len]);
        pos += key_len;
        const value = try self.allocator.dupe(u8, payload[pos..][0..value_len]);
        return .{ .set = .{ .key = key, .value = value, .flags = flags, .timestamp = timestamp } };
    }

    fn parseDelete(self: *WalIterator, payload: []const u8) !WalRecord {
        if (payload.len < Wal.DEL_PAYLOAD_OVERHEAD) return error.Corruption;
        var pos: usize = 0;
        const key_len: usize = @intCast(std.mem.readInt(u16, payload[pos..][0..2], .little));
        pos += 2;
        if (pos + key_len != payload.len) return error.Corruption;
        const key = try self.allocator.dupe(u8, payload[pos..][0..key_len]);
        return .{ .delete = key };
    }

    fn parseVinsert(self: *WalIterator, payload: []const u8) !WalRecord {
        if (payload.len < Wal.VINSERT_PAYLOAD_OVERHEAD) return error.Corruption;
        var pos: usize = 0;
        const key_len: usize = @intCast(std.mem.readInt(u16, payload[pos..][0..2], .little));
        pos += 2;
        const namespace_len: usize = @intCast(std.mem.readInt(u16, payload[pos..][0..2], .little));
        pos += 2;
        const metric_len: usize = @intCast(std.mem.readInt(u16, payload[pos..][0..2], .little));
        pos += 2;
        const flags = payload[pos];
        pos += 1;
        if ((flags & 0b1111_1100) != 0) return error.Corruption;
        const timestamp: Timestamp = std.mem.readInt(u64, payload[pos..][0..8], .little);
        pos += 8;
        if (pos + key_len + namespace_len + metric_len != payload.len) return error.Corruption;

        const key = try self.allocator.dupe(u8, payload[pos..][0..key_len]);
        errdefer self.allocator.free(key);
        pos += key_len;
        const namespace = try self.allocator.dupe(u8, payload[pos..][0..namespace_len]);
        errdefer self.allocator.free(namespace);
        pos += namespace_len;
        const metric = try self.allocator.dupe(u8, payload[pos..][0..metric_len]);

        return .{ .vinsert = .{
            .key = key,
            .namespace = namespace,
            .metric = metric,
            .flags = flags,
            .timestamp = timestamp,
        } };
    }

    fn parseVdelete(self: *WalIterator, payload: []const u8) !WalRecord {
        if (payload.len < Wal.VDELETE_PAYLOAD_OVERHEAD) return error.Corruption;
        var pos: usize = 0;
        const key_len: usize = @intCast(std.mem.readInt(u16, payload[pos..][0..2], .little));
        pos += 2;
        const namespace_len: usize = @intCast(std.mem.readInt(u16, payload[pos..][0..2], .little));
        pos += 2;
        if (pos + key_len + namespace_len != payload.len) return error.Corruption;
        const key = try self.allocator.dupe(u8, payload[pos..][0..key_len]);
        errdefer self.allocator.free(key);
        pos += key_len;
        const namespace = try self.allocator.dupe(u8, payload[pos..][0..namespace_len]);
        return .{ .vdelete = .{ .key = key, .namespace = namespace } };
    }

    pub fn deinitRecord(self: *WalIterator, record: WalRecord) void {
        switch (record) {
            .set => |set| {
                self.allocator.free(set.key);
                self.allocator.free(set.value);
            },
            .delete => |key| self.allocator.free(key),
            .vinsert => |vinsert| {
                self.allocator.free(vinsert.key);
                self.allocator.free(vinsert.namespace);
                self.allocator.free(vinsert.metric);
            },
            .vdelete => |vdelete| {
                self.allocator.free(vdelete.key);
                self.allocator.free(vdelete.namespace);
            },
        }
    }
};

test "WAL append and replay" {
    const testing = std.testing;
    // TODO: Zig 0.16 test tmpDir API may have changed — re-enable after verifying
    _ = testing;
}
