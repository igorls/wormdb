//! Write-Ahead Log (WAL) for durability
//!
//! Binary format with CRC32 verification for crash recovery.

const std = @import("std");
const build_options = @import("build_options");
const core = @import("../core/mod.zig");

const WalRecordType = core.types.WalRecordType;
const Entry = core.types.Entry;
const EntryFlags = core.types.EntryFlags;
const Timestamp = core.types.Timestamp;
const compat = core.compat;

fn crc32(data: []const u8) u32 {
    return std.hash.crc.@"CRC-32/ISCSI".hash(data);
}

pub const Wal = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    path: []const u8,
    sync_writes: bool,
    write_count: usize,
    wal_bytes: std.atomic.Value(usize),
    queue: []?[]u8,
    queue_head: std.atomic.Value(usize) align(64),
    queue_tail: std.atomic.Value(usize) align(64),
    /// Leaf mutex serializing multi-producer ring-buffer slot reservation.
    /// Lock order: Store.wal_enqueue_mutex -> Store.snapshot_mutex -> Shard.mutex -> Wal.queue_mutex.
    queue_mutex: compat.Mutex = .{},
    writer_thread: ?std.Thread,
    writer_running: std.atomic.Value(bool),
    writer_started: bool,
    sync_requested: std.atomic.Value(bool),
    wake_futex: std.atomic.Value(u32) align(64),
    consumer_parked: std.atomic.Value(bool),
    producer_futex: std.atomic.Value(u32) align(64),
    producer_parked: std.atomic.Value(bool),
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
        @memset(queue, null);

        return .{
            .allocator = allocator,
            .file = file,
            .path = path,
            .sync_writes = sync_writes,
            .write_count = 0,
            .wal_bytes = std.atomic.Value(usize).init(@intCast(s.size)),
            .queue = queue,
            .queue_head = std.atomic.Value(usize).init(0),
            .queue_tail = std.atomic.Value(usize).init(0),
            .queue_mutex = .{},
            .writer_thread = null,
            .writer_running = std.atomic.Value(bool).init(false),
            .writer_started = false,
            .sync_requested = std.atomic.Value(bool).init(false),
            .wake_futex = std.atomic.Value(u32).init(0),
            .consumer_parked = std.atomic.Value(bool).init(false),
            .producer_futex = std.atomic.Value(u32).init(0),
            .producer_parked = std.atomic.Value(bool).init(false),
        };
    }

    /// Whether the background writer is used at all. A named constant rather than an inline
    /// `build_options.single_threaded` so the decision is assertable: a wasm target cannot run
    /// `zig build test` (the test binary itself needs threads), so a test that only skipped on a
    /// threaded build would assert nothing anywhere. The test checks this predicate directly.
    pub const use_background_writer = !build_options.single_threaded;

    /// Start background WAL writer for producer submission.
    /// Producer path becomes enqueue-only; this removes file I/O from request critical path.
    pub fn startBackground(self: *Wal) !void {
        if (!self.sync_writes or self.writer_started) return;
        // A single-threaded build (wasm32) has no thread to hand the queue to. NOT starting the
        // writer is also the safer path here, and it is the one that preserves the durability
        // semantics: with writer_started false the producer uses `writeDirect`, which fsyncs
        // immediately on every record (2e5a914) and sets `sync_failed` when a write or sync
        // fails so later writes are fenced (a46f517). A queued single-threaded drain would
        // batch and swallow those failures instead, so the queue is not used at all here.
        if (!use_background_writer) return;
        self.writer_running.store(true, .seq_cst);
        self.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{self});
        self.writer_started = true;
    }

    pub fn deinit(self: *Wal) void {
        // Guarded so the join is not analysed on a single-threaded target: std.Thread.join's
        // wasm path contains the atomic-wait asm, and no thread exists here to join.
        if (self.writer_started and !build_options.single_threaded) {
            self.writer_running.store(false, .seq_cst);
            self.consumer_parked.store(false, .seq_cst);
            _ = self.wake_futex.fetchAdd(1, .release);
            compat.Futex.wake(&self.wake_futex, 1);
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
            self.sync_requested.store(true, .seq_cst);
            if (self.consumer_parked.load(.seq_cst)) {
                self.consumer_parked.store(false, .release);
                _ = self.wake_futex.fetchAdd(1, .release);
                compat.Futex.wake(&self.wake_futex, 1);
            }
            return;
        }
        try compat.File.sync(self.file);
    }

    /// Commit a pre-serialized WAL record buffer. Takes ownership of `record` on success;
    /// on error, caller still owns `record` and must free it.
    pub fn commitSerializedRecord(self: *Wal, record: []u8) !void {
        const rec_len = record.len;
        if (self.writer_started) {
            self.enqueueRecordBlocking(record);
            _ = self.wal_bytes.fetchAdd(rec_len, .monotonic);
        } else {
            try self.writeDirect(record);
            self.allocator.free(record);
        }
    }

    pub fn freeRecord(self: *Wal, record: []u8) void {
        self.allocator.free(record);
    }

    /// Append a SET record to the WAL.
    /// Returns a heap-allocated `Entry` that owns duplicated key/value memory.
    /// Caller owns the returned entry and must call `entry.deinit(allocator)` + `allocator.destroy(entry)`.
    pub fn appendSet(self: *Wal, key: []const u8, value: []const u8, flags: EntryFlags, timestamp: Timestamp) !*Entry {
        const record = try self.serializeSetRecord(key, value, flags, timestamp);
        errdefer self.allocator.free(record);

        // Finish every fallible live-entry allocation before publishing the
        // durable record. Once the append succeeds, returning the Entry cannot
        // fail and the caller can install the exact acknowledged bytes.
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        const entry_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(entry_key);
        const entry_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(entry_value);
        entry.* = .{
            .key = entry_key,
            .value = entry_value,
            .timestamp = timestamp,
            .flags = flags,
        };

        try self.commitSerializedRecord(record);
        return entry;
    }

    pub fn appendDelete(self: *Wal, key: []const u8) !void {
        const record = try self.serializeDeleteRecord(key);
        errdefer self.allocator.free(record);
        try self.commitSerializedRecord(record);
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
        errdefer self.allocator.free(record);
        try self.commitSerializedRecord(record);
    }

    pub fn appendVdelete(self: *Wal, key: []const u8, namespace: []const u8) !void {
        const record = try self.serializeVdeleteRecord(key, namespace);
        errdefer self.allocator.free(record);
        try self.commitSerializedRecord(record);
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
        _ = self.wal_bytes.fetchAdd(record.len, .monotonic);
    }

    pub fn serializeSetRecord(self: *Wal, key: []const u8, value: []const u8, flags: EntryFlags, timestamp: Timestamp) ![]u8 {
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
            .record_type = @backingInt(WalRecordType.set),
            .length = @intCast(payload_len),
        };
        @memcpy(buf[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
        return buf;
    }

    pub fn serializeDeleteRecord(self: *Wal, key: []const u8) ![]u8 {
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
            .record_type = @backingInt(WalRecordType.delete),
            .length = @intCast(payload_len),
        };
        @memcpy(buf[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
        return buf;
    }

    pub fn serializeVinsertRecord(
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
            .record_type = @backingInt(WalRecordType.vinsert),
            .length = @intCast(payload_len),
        };
        @memcpy(buf[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
        return buf;
    }

    pub fn serializeVdeleteRecord(self: *Wal, key: []const u8, namespace: []const u8) ![]u8 {
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
            .record_type = @backingInt(WalRecordType.vdelete),
            .length = @intCast(payload_len),
        };
        @memcpy(buf[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
        return buf;
    }

    /// Producer enqueue protected by leaf `queue_mutex` (always innermost in lock order).
    fn enqueueRecordBlocking(self: *Wal, record: []u8) void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        while (!self.tryEnqueueRecord(record)) {
            self.producer_parked.store(true, .seq_cst);
            if (self.tryEnqueueRecord(record)) {
                self.producer_parked.store(false, .release);
                break;
            }
            // Wait on futex instead of spinning — wake when consumer drains
            compat.Futex.timedWait(&self.producer_futex, self.producer_futex.load(.acquire), 50_000);
        }
        // Dekker pair with consumer_parked: tryEnqueueRecord published queue_tail
        // with .seq_cst before this .seq_cst load, preventing lost wake-ups.
        if (self.consumer_parked.load(.seq_cst)) {
            self.consumer_parked.store(false, .release);
            _ = self.wake_futex.fetchAdd(1, .release);
            compat.Futex.wake(&self.wake_futex, 1);
        }
    }

    fn tryEnqueueRecord(self: *Wal, record: []u8) bool {
        const head = self.queue_head.load(.seq_cst);
        const tail = self.queue_tail.load(.monotonic);
        if (tail - head >= self.queue.len) return false;

        const idx = tail & WAL_QUEUE_MASK;
        self.queue[idx] = record;
        // .seq_cst store forms a Dekker pair with consumer_parked.load(.seq_cst)
        // in enqueueRecordBlocking and consumer_parked.store(true, .seq_cst) ->
        // hasPendingRecords() in writerLoop.
        self.queue_tail.store(tail + 1, .seq_cst);
        return true;
    }

    fn tryDequeueRecord(self: *Wal) ?[]u8 {
        const head = self.queue_head.load(.monotonic);
        const tail = self.queue_tail.load(.acquire);
        if (head == tail) return null;

        const idx = head & WAL_QUEUE_MASK;
        const record = self.queue[idx] orelse return null;
        self.queue[idx] = null;
        self.queue_head.store(head + 1, .seq_cst);
        return record;
    }

    fn hasPendingRecords(self: *Wal) bool {
        return self.queue_head.load(.seq_cst) != self.queue_tail.load(.seq_cst);
    }

    fn writerLoop(self: *Wal) void {
        var write_buf: [65536]u8 = undefined;
        while (self.writer_running.load(.acquire) or self.hasPendingRecords()) {
            // Drain phase: coalesce pending records into a single 64 KiB write buffer
            var batch_count: usize = 0;
            var write_pos: usize = 0;
            while (batch_count < 256) {
                if (self.tryDequeueRecord()) |record| {
                    if (record.len > write_buf.len) {
                        if (write_pos > 0) {
                            compat.File.writeAll(self.file, write_buf[0..write_pos]) catch {};
                            write_pos = 0;
                        }
                        compat.File.writeAll(self.file, record) catch {};
                    } else {
                        if (write_pos + record.len > write_buf.len) {
                            compat.File.writeAll(self.file, write_buf[0..write_pos]) catch {};
                            write_pos = 0;
                        }
                        @memcpy(write_buf[write_pos..][0..record.len], record);
                        write_pos += record.len;
                    }
                    self.allocator.free(record);
                    self.write_count += 1;
                    batch_count += 1;
                } else break;
            }

            if (batch_count > 0) {
                if (write_pos > 0) {
                    compat.File.writeAll(self.file, write_buf[0..write_pos]) catch {};
                }
                // Single fsync for entire batch — key performance win
                if (self.sync_writes) {
                    compat.File.sync(self.file) catch {};
                }
                // Wake producer ONLY if it was blocked on a full queue
                if (self.producer_parked.swap(false, .seq_cst)) {
                    _ = self.producer_futex.fetchAdd(1, .release);
                    compat.Futex.wake(&self.producer_futex, 1);
                }
                continue;
            }

            if (self.sync_requested.swap(false, .acq_rel)) {
                compat.File.sync(self.file) catch {};
                continue;
            }

            // Park consumer and wait for producer to enqueue — Dekker handshake
            // with producer's queue_tail.store(.seq_cst) + consumer_parked.load(.seq_cst).
            const futex_val = self.wake_futex.load(.acquire);
            self.consumer_parked.store(true, .seq_cst);
            if (!self.hasPendingRecords() and !self.sync_requested.load(.seq_cst) and self.writer_running.load(.seq_cst)) {
                compat.Futex.timedWait(&self.wake_futex, futex_val, 1_000_000);
            }
            self.consumer_parked.store(false, .release);
        }

        // Final durability point on shutdown.
        compat.File.sync(self.file) catch {};
    }

    pub fn iterator(self: *Wal) WalIterator {
        compat.File.seekTo(self.file, 0) catch {};
        return .{ .file = self.file, .allocator = self.allocator };
    }

    pub fn size(self: *Wal) !usize {
        return self.wal_bytes.load(.monotonic);
    }

    /// Truncate the WAL to zero bytes and reset write cursor to the beginning.
    pub fn truncate(self: *Wal) !void {
        try compat.File.setLength(self.file, 0);
        try compat.File.seekTo(self.file, 0);
        self.wal_bytes.store(0, .monotonic);
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
    read_buf: [65536]u8 = undefined,
    buf_pos: usize = 0,
    buf_end: usize = 0,
    done: bool = false,

    fn readBuffered(self: *WalIterator, dest: []u8) !usize {
        var total: usize = 0;
        while (total < dest.len) {
            const avail = self.buf_end - self.buf_pos;
            if (avail == 0) {
                if (dest.len - total >= self.read_buf.len) {
                    return total + try compat.File.readAll(self.file, dest[total..]);
                }
                self.buf_pos = 0;
                self.buf_end = try compat.File.readAll(self.file, &self.read_buf);
                if (self.buf_end == 0) break;
                continue;
            }
            const n = @min(avail, dest.len - total);
            @memcpy(dest[total..][0..n], self.read_buf[self.buf_pos..][0..n]);
            self.buf_pos += n;
            total += n;
        }
        return total;
    }

    pub fn next(self: *WalIterator) !?WalRecord {
        if (self.done) return null;

        var header: Wal.RecordHeader = undefined;
        const header_bytes_read = self.readBuffered(std.mem.asBytes(&header)) catch {
            self.done = true;
            return null;
        };

        if (header_bytes_read < @sizeOf(Wal.RecordHeader)) {
            self.done = true;
            return null;
        }

        const payload_len: usize = @intCast(header.length);
        if (payload_len == 0 or payload_len > 1024 * 1024 * 100) return error.Corruption;

        // Zero-copy fast path when payload is already contiguous in read_buf
        if (self.buf_end - self.buf_pos >= payload_len) {
            const payload = self.read_buf[self.buf_pos .. self.buf_pos + payload_len];
            self.buf_pos += payload_len;
            if (crc32(payload) != header.crc) return error.Corruption;
            const record_type: WalRecordType = @fromBackingInt(@intCast(header.record_type));
            return switch (record_type) {
                .set => try self.parseSet(payload),
                .delete => try self.parseDelete(payload),
                .vinsert => try self.parseVinsert(payload),
                .vdelete => try self.parseVdelete(payload),
            };
        }

        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);

        const payload_read = self.readBuffered(payload) catch {
            self.done = true;
            return null;
        };
        if (payload_read < payload_len) {
            self.done = true;
            return null;
        }

        if (crc32(payload) != header.crc) return error.Corruption;

        const record_type: WalRecordType = @fromBackingInt(@intCast(header.record_type));
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

test "WAL CRC32C check value matches Castagnoli standard 0xE3069283" {
    try std.testing.expectEqual(@as(u32, 0xE3069283), crc32("123456789"));
}

/// The single-threaded path must keep the durability semantics the threaded path has:
/// every direct write fsyncs immediately (2e5a914) and a failed write or sync fences all
/// later writes via `sync_failed` (a46f517). A single-threaded build never starts the
/// background writer, so these are the properties a wasm build depends on, and they are
/// asserted here rather than assumed.
///
/// There is NO `_single_threaded` parameter. There used to be one, and it was discarded in the
/// body — so the call site read as if both modes were exercised when only one was, which is the
/// same shape of problem as the tautological assertion below. What the path actually depends on is
/// `writer_started`, so that is what the body drives.
fn expectSingleThreadedDurability() !void {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try compat.Dir.realPathAlloc(tmp.dir, allocator, ".");
    defer allocator.free(path);
    const file = try std.fmt.allocPrint(allocator, "{s}/wal.log", .{path});
    defer allocator.free(file);

    // Wal.init opens read_write without create, so the log file must exist first.
    const created = try compat.Dir.createFile(compat.cwd(), file, .{});
    compat.File.close(created);

    var wal = try Wal.init(allocator, file, true);
    defer wal.deinit();

    // Not started: this is the state a single-threaded build stays in, because
    // startBackground returns early there.
    try testing.expect(!wal.writer_started);

    // A direct write reaches the file and fsyncs immediately, so the bytes are readable
    // back without any flush step from the test.
    const ts: Timestamp = 1234;
    const entry = try wal.appendSet("k", "v", .{ .is_worm = false, .is_deleted = false }, ts);
    entry.deinit(allocator);
    allocator.destroy(entry);
    try testing.expect(wal.write_count == 1);
    try testing.expect(!wal.sync_failed);

    // Read it back through an ordinary file open, the way the rest of the repo does, so the
    // check does not depend on a helper compat does not provide.
    const file_handle = try compat.Dir.openFile(compat.cwd(), file, .{ .mode = .read_only });
    defer compat.File.close(file_handle);
    const size = (try compat.File.stat(file_handle)).size;
    try testing.expect(size > 0);

    // An uncertain sync fences every later write instead of acknowledging it.
    wal.fail_sync_for_test = true;
    const failed = wal.appendSet("k2", "v2", .{ .is_worm = false, .is_deleted = false }, ts);
    try testing.expectError(error.InjectedSyncFailure, failed);
    try testing.expect(wal.sync_failed);
    wal.fail_sync_for_test = false;

    const fenced = wal.appendSet("k3", "v3", .{ .is_worm = false, .is_deleted = false }, ts);
    try testing.expectError(error.WalNeedsRecovery, fenced);
    try testing.expectError(error.WalNeedsRecovery, wal.sync());
}

test "single-threaded direct writes fsync immediately and fence uncertain writes" {
    try expectSingleThreadedDurability();
}

test "the background writer is used exactly when the build has threads" {
    // The old test passed `true` to a helper that discarded it and never called startBackground, so
    // it only proved that a Wal whose writer was never started writes directly — it would have kept
    // passing if startBackground stopped returning early, which is the one behaviour that matters
    // for wasm.
    //
    // It cannot be tested by calling startBackground, because a wasm target cannot run
    // `zig build test` at all: the test binary itself needs threads (std.Thread.spawn in
    // std/Thread.zig fails to compile in single-threaded mode). A test that only skipped on a
    // threaded build would therefore assert nothing on any target. So the DECISION is extracted as
    // `use_background_writer` and asserted here, which runs and is meaningful on a threaded build:
    const builtin = @import("builtin");
    // NOTE: `expectEqual(!build_options.single_threaded, Wal.use_background_writer)` used to sit
    // here and was TAUTOLOGICAL — `use_background_writer` IS defined as that expression, so it
    // compared a value to its own definition and could never fail. Removed. What is worth asserting
    // is the DRIFT check below: `builtin.single_threaded` is what std.Io and compat key off, so a
    // build where the two disagree would have some code taking the threaded path and some the
    // single-threaded one.
    try std.testing.expectEqual(!builtin.single_threaded, Wal.use_background_writer);
}
