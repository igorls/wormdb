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
    /// Bytes written directly (before startBackground or in direct mode) plus initial file size,
    /// plus the batch markers the background writer adds around each sweep.
    /// Background mode tracks per-lane enqueued bytes in `lanes[i].bytes_enqueued` to avoid
    /// global cache-line bouncing on hot multi-threaded writes.
    wal_bytes: std.atomic.Value(usize),
    /// 32 independent cache-line-isolated byte-ring lanes indexed by `shardIndex(key) & WAL_LANE_MASK`.
    /// Deterministic key -> lane routing preserves strict per-key FIFO order on disk while
    /// eliminating global queue_mutex contention and cross-thread per-record malloc/free churn.
    lanes: [WAL_LANES]WalLane,
    /// Consumer staging buffer (WRITER_STAGE_CAP bytes), lazily allocated in `startBackground()`.
    writer_stage: []u8,
    writer_thread: ?std.Thread,
    writer_running: std.atomic.Value(bool),
    writer_started: bool,
    sync_requested: std.atomic.Value(bool),
    /// Consumer parking state isolated on its own cache line so busy producers read
    /// `consumer_parked == false` from Shared L1D with zero coherence traffic.
    consumer_parked: std.atomic.Value(bool) align(64),
    wake_futex: std.atomic.Value(u32),
    /// Direct synchronous I/O failures have an uncertain commit outcome. Do
    /// not acknowledge later writes against a live view that may differ from
    /// replay. Store serializes these fields with wal_enqueue_mutex.
    sync_failed: bool = false,
    fail_sync_for_test: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},

    /// Number of independent WAL byte-ring lanes (power of two).
    pub const WAL_LANES: usize = 32;
    pub const WAL_LANE_MASK: usize = WAL_LANES - 1;
    /// Per-lane byte-ring capacity (power of two): 256 KiB * 32 = 8 MiB total, allocated lazily
    /// only when `startBackground()` starts the writer thread.
    pub const LANE_RING_CAP: usize = 256 * 1024;
    const LANE_RING_MASK: usize = LANE_RING_CAP - 1;
    /// Records up to 64 KiB copy directly into the lane byte-ring with zero heap allocation.
    /// Rare larger records (up to 16 MiB) drain the lane ring first and hand off via `large_pending`
    /// to preserve strict per-lane FIFO ordering.
    pub const LANE_MAX_INLINE: usize = 64 * 1024;
    const WRITER_STAGE_CAP: usize = 256 * 1024;
    /// Lock-free attempts at a consistent lane cut before producers are frozen for one scan.
    const CUT_RETRIES: usize = 8;
    const BATCH_MARKER_PAYLOAD: usize = 8;
    /// On-disk size of a `batch_begin` / `batch_commit` marker record.
    pub const BATCH_MARKER_LEN: usize = @sizeOf(RecordHeader) + BATCH_MARKER_PAYLOAD;

    const WalLane = struct {
        /// Leaf mutex serializing multi-producer writes onto this lane.
        /// Lock order: Store.wal_enqueue_mutex -> Store.snapshot_mutex -> Shard.mutex -> Wal.lanes[i].mutex.
        mutex: compat.Mutex align(64) = .{},
        ring: []u8 = &.{},
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        cached_head: usize = 0,
        bytes_enqueued: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        /// Pointer to an oversized (>LANE_MAX_INLINE) heap-owned record waiting for the consumer.
        /// Uses 32-bit pointer atomics on wasm32 (narrow-atomics safe).
        large_pending: std.atomic.Value(?[*]u8) = std.atomic.Value(?[*]u8).init(null),
        large_pending_len: usize = 0,

        // Consumer-updated cache line (rarely touched by producers thanks to `cached_head`).
        head: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0),
        producer_parked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        producer_futex: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };

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

        var lanes: [WAL_LANES]WalLane = undefined;
        for (&lanes) |*lane| lane.* = .{};

        return .{
            .allocator = allocator,
            .file = file,
            .path = path,
            .sync_writes = sync_writes,
            .write_count = 0,
            .wal_bytes = std.atomic.Value(usize).init(@intCast(s.size)),
            .lanes = lanes,
            .writer_stage = &.{},
            .writer_thread = null,
            .writer_running = std.atomic.Value(bool).init(false),
            .writer_started = false,
            .sync_requested = std.atomic.Value(bool).init(false),
            .consumer_parked = std.atomic.Value(bool).init(false),
            .wake_futex = std.atomic.Value(u32).init(0),
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

        // Lazily allocate the staging buffer and 32 lane byte-rings only when bg mode starts.
        if (self.writer_stage.len == 0) {
            self.writer_stage = try self.allocator.alloc(u8, WRITER_STAGE_CAP);
            // Pre-fault OS pages once at startup so the first client writes don't pay page-fault stalls.
            var p: usize = 0;
            while (p < self.writer_stage.len) : (p += 4096) self.writer_stage[p] = 0;
        }
        errdefer {
            for (&self.lanes) |*lane| {
                if (lane.ring.len != 0) {
                    self.allocator.free(lane.ring);
                    lane.ring = &.{};
                }
            }
            if (self.writer_stage.len != 0) {
                self.allocator.free(self.writer_stage);
                self.writer_stage = &.{};
            }
        }

        for (&self.lanes) |*lane| {
            if (lane.ring.len == 0) {
                lane.ring = try self.allocator.alloc(u8, LANE_RING_CAP);
                var p: usize = 0;
                while (p < lane.ring.len) : (p += 4096) lane.ring[p] = 0;
            }
            lane.head.store(0, .monotonic);
            lane.tail.store(0, .monotonic);
            lane.cached_head = 0;
            lane.large_pending.store(null, .monotonic);
            lane.large_pending_len = 0;
            lane.producer_parked.store(false, .monotonic);
            lane.producer_futex.store(0, .monotonic);
        }

        self.writer_running.store(true, .seq_cst);
        errdefer self.writer_running.store(false, .seq_cst);
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

        for (&self.lanes) |*lane| {
            if (lane.large_pending.swap(null, .acq_rel)) |ptr| {
                self.allocator.free(ptr[0..lane.large_pending_len]);
                lane.large_pending_len = 0;
            }
            if (lane.ring.len != 0) {
                self.allocator.free(lane.ring);
                lane.ring = &.{};
            }
        }
        if (self.writer_stage.len != 0) {
            self.allocator.free(self.writer_stage);
            self.writer_stage = &.{};
        }

        compat.File.close(self.file);
    }

    /// Flush WAL to durable storage. Called by the group-commit background thread.
    pub fn sync(self: *Wal) !void {
        if (self.sync_failed) return error.WalNeedsRecovery;
        if (self.writer_started) {
            self.sync_requested.store(true, .seq_cst);
            self.wakeConsumerIfParked();
            return;
        }
        try compat.File.sync(self.file);
    }

    inline fn wakeConsumerIfParked(self: *Wal) void {
        if (self.consumer_parked.load(.seq_cst)) {
            if (self.consumer_parked.swap(false, .acq_rel)) {
                _ = self.wake_futex.fetchAdd(1, .release);
                compat.Futex.wake(&self.wake_futex, 1);
            }
        }
    }

    /// Zero-malloc commit path: commits already-encoded record bytes to the lane derived from
    /// `lane_key` (typically `Store.shardIndex(key)`).
    /// - In background mode: copies `<= LANE_MAX_INLINE` records straight into the lane's byte-ring
    ///   with zero heap allocation, or hands off oversized records in strict per-lane FIFO order.
    /// - In direct mode: writes directly to `self.file` with zero heap allocation.
    pub fn commitRecordBytesForLane(self: *Wal, lane_key: usize, record: []const u8) !void {
        if (self.writer_started) {
            const lane = &self.lanes[lane_key & WAL_LANE_MASK];
            if (record.len <= LANE_MAX_INLINE) {
                self.enqueueInlineBlocking(lane, record);
            } else {
                const owned = try self.allocator.dupe(u8, record);
                self.enqueueLargeBlocking(lane, owned);
            }
        } else {
            try self.writeDirect(record);
        }
    }

    /// Commit a pre-serialized WAL record buffer (legacy ownership API, routes to lane 0).
    /// Takes ownership of `record` on success; on error, caller still owns `record` and must free it.
    pub fn commitSerializedRecord(self: *Wal, record: []u8) !void {
        if (self.writer_started) {
            const lane = &self.lanes[0];
            if (record.len <= LANE_MAX_INLINE) {
                self.enqueueInlineBlocking(lane, record);
                self.allocator.free(record);
            } else {
                // Hand ownership straight to consumer without a redundant copy.
                self.enqueueLargeBlocking(lane, record);
            }
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
        const total_len = setRecordSize(key.len, value.len);
        var stack_buf: [4096]u8 = undefined;
        const heap_buf: ?[]u8 = if (total_len > stack_buf.len) try self.allocator.alloc(u8, total_len) else null;
        defer if (heap_buf) |hb| self.allocator.free(hb);
        const rec_slice = encodeSetRecord(if (heap_buf) |hb| hb else stack_buf[0..total_len], key, value, flags, timestamp);

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

        try self.commitRecordBytesForLane(0, rec_slice);
        return entry;
    }

    pub fn appendDelete(self: *Wal, key: []const u8) !void {
        try self.appendDeleteForLane(0, key);
    }

    pub fn appendDeleteForLane(self: *Wal, lane_key: usize, key: []const u8) !void {
        const total_len = deleteRecordSize(key.len);
        var stack_buf: [512]u8 = undefined;
        const heap_buf: ?[]u8 = if (total_len > stack_buf.len) try self.allocator.alloc(u8, total_len) else null;
        defer if (heap_buf) |hb| self.allocator.free(hb);
        const rec_slice = encodeDeleteRecord(if (heap_buf) |hb| hb else stack_buf[0..total_len], key);
        try self.commitRecordBytesForLane(lane_key, rec_slice);
    }

    pub fn appendVinsert(
        self: *Wal,
        key: []const u8,
        namespace: []const u8,
        metric: []const u8,
        flags: u8,
        timestamp: Timestamp,
    ) !void {
        try self.appendVinsertForLane(0, key, namespace, metric, flags, timestamp);
    }

    pub fn appendVinsertForLane(
        self: *Wal,
        lane_key: usize,
        key: []const u8,
        namespace: []const u8,
        metric: []const u8,
        flags: u8,
        timestamp: Timestamp,
    ) !void {
        const total_len = vinsertRecordSize(key.len, namespace.len, metric.len);
        var stack_buf: [1024]u8 = undefined;
        const heap_buf: ?[]u8 = if (total_len > stack_buf.len) try self.allocator.alloc(u8, total_len) else null;
        defer if (heap_buf) |hb| self.allocator.free(hb);
        const rec_slice = encodeVinsertRecord(if (heap_buf) |hb| hb else stack_buf[0..total_len], key, namespace, metric, flags, timestamp);
        try self.commitRecordBytesForLane(lane_key, rec_slice);
    }

    pub fn appendVdelete(self: *Wal, key: []const u8, namespace: []const u8) !void {
        try self.appendVdeleteForLane(0, key, namespace);
    }

    pub fn appendVdeleteForLane(self: *Wal, lane_key: usize, key: []const u8, namespace: []const u8) !void {
        const total_len = vdeleteRecordSize(key.len, namespace.len);
        var stack_buf: [1024]u8 = undefined;
        const heap_buf: ?[]u8 = if (total_len > stack_buf.len) try self.allocator.alloc(u8, total_len) else null;
        defer if (heap_buf) |hb| self.allocator.free(hb);
        const rec_slice = encodeVdeleteRecord(if (heap_buf) |hb| hb else stack_buf[0..total_len], key, namespace);
        try self.commitRecordBytesForLane(lane_key, rec_slice);
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

    pub inline fn setRecordSize(key_len: usize, value_len: usize) usize {
        return @sizeOf(RecordHeader) + SET_PAYLOAD_OVERHEAD + key_len + value_len;
    }

    pub fn encodeSetRecord(dst: []u8, key: []const u8, value: []const u8, flags: EntryFlags, timestamp: Timestamp) []const u8 {
        const payload_len = SET_PAYLOAD_OVERHEAD + key.len + value.len;
        const total_len = @sizeOf(RecordHeader) + payload_len;
        const buf = dst[0..total_len];

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

    pub fn serializeSetRecord(self: *Wal, key: []const u8, value: []const u8, flags: EntryFlags, timestamp: Timestamp) ![]u8 {
        const total_len = setRecordSize(key.len, value.len);
        const buf = try self.allocator.alloc(u8, total_len);
        _ = encodeSetRecord(buf, key, value, flags, timestamp);
        return buf;
    }

    pub inline fn deleteRecordSize(key_len: usize) usize {
        return @sizeOf(RecordHeader) + DEL_PAYLOAD_OVERHEAD + key_len;
    }

    pub fn encodeDeleteRecord(dst: []u8, key: []const u8) []const u8 {
        const payload_len = DEL_PAYLOAD_OVERHEAD + key.len;
        const total_len = @sizeOf(RecordHeader) + payload_len;
        const buf = dst[0..total_len];

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

    pub fn serializeDeleteRecord(self: *Wal, key: []const u8) ![]u8 {
        const total_len = deleteRecordSize(key.len);
        const buf = try self.allocator.alloc(u8, total_len);
        _ = encodeDeleteRecord(buf, key);
        return buf;
    }

    pub inline fn vinsertRecordSize(key_len: usize, namespace_len: usize, metric_len: usize) usize {
        return @sizeOf(RecordHeader) + VINSERT_PAYLOAD_OVERHEAD + key_len + namespace_len + metric_len;
    }

    pub fn encodeVinsertRecord(
        dst: []u8,
        key: []const u8,
        namespace: []const u8,
        metric: []const u8,
        flags: u8,
        timestamp: Timestamp,
    ) []const u8 {
        const payload_len = VINSERT_PAYLOAD_OVERHEAD + key.len + namespace.len + metric.len;
        const total_len = @sizeOf(RecordHeader) + payload_len;
        const buf = dst[0..total_len];

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

    pub fn serializeVinsertRecord(
        self: *Wal,
        key: []const u8,
        namespace: []const u8,
        metric: []const u8,
        flags: u8,
        timestamp: Timestamp,
    ) ![]u8 {
        const total_len = vinsertRecordSize(key.len, namespace.len, metric.len);
        const buf = try self.allocator.alloc(u8, total_len);
        _ = encodeVinsertRecord(buf, key, namespace, metric, flags, timestamp);
        return buf;
    }

    pub inline fn vdeleteRecordSize(key_len: usize, namespace_len: usize) usize {
        return @sizeOf(RecordHeader) + VDELETE_PAYLOAD_OVERHEAD + key_len + namespace_len;
    }

    pub fn encodeVdeleteRecord(dst: []u8, key: []const u8, namespace: []const u8) []const u8 {
        const payload_len = VDELETE_PAYLOAD_OVERHEAD + key.len + namespace.len;
        const total_len = @sizeOf(RecordHeader) + payload_len;
        const buf = dst[0..total_len];

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

    pub fn serializeVdeleteRecord(self: *Wal, key: []const u8, namespace: []const u8) ![]u8 {
        const total_len = vdeleteRecordSize(key.len, namespace.len);
        const buf = try self.allocator.alloc(u8, total_len);
        _ = encodeVdeleteRecord(buf, key, namespace);
        return buf;
    }

    /// Producer enqueue for inline (`<= LANE_MAX_INLINE`) records into a sharded byte-ring.
    /// Releases `lane.mutex` before parking on full ring / pending oversized record.
    fn enqueueInlineBlocking(self: *Wal, lane: *WalLane, record: []const u8) void {
        lane.mutex.lock();
        while (true) {
            if (lane.large_pending.load(.acquire) == null) {
                const tail = lane.tail.load(.monotonic);
                var free_space = LANE_RING_CAP - (tail -% lane.cached_head);
                if (free_space < record.len) {
                    lane.cached_head = lane.head.load(.acquire);
                    free_space = LANE_RING_CAP - (tail -% lane.cached_head);
                }
                if (free_space >= record.len) {
                    const pos = tail & LANE_RING_MASK;
                    const first = @min(record.len, LANE_RING_CAP - pos);
                    @memcpy(lane.ring[pos .. pos + first], record[0..first]);
                    if (first < record.len) {
                        @memcpy(lane.ring[0 .. record.len - first], record[first..]);
                    }
                    // Plain monotonic update under lane.mutex (zero global lock xadd).
                    lane.bytes_enqueued.store(lane.bytes_enqueued.load(.monotonic) + record.len, .monotonic);
                    // .seq_cst store pairs with consumer_parked.load(.seq_cst) below and
                    // consumer_parked.store(true, .seq_cst) -> hasPendingRecords() in writerLoop.
                    lane.tail.store(tail +% record.len, .seq_cst);
                    lane.mutex.unlock();
                    self.wakeConsumerIfParked();
                    return;
                }
            }

            // Lane ring is temporarily full (or an oversized record is ahead in FIFO order).
            const futex_val = lane.producer_futex.load(.acquire);
            lane.producer_parked.store(true, .seq_cst);
            // Re-check after publishing producer_parked=true (Dekker handshake with consumer).
            if (lane.large_pending.load(.acquire) == null) {
                const tail = lane.tail.load(.monotonic);
                lane.cached_head = lane.head.load(.acquire);
                if (LANE_RING_CAP - (tail -% lane.cached_head) >= record.len) {
                    continue;
                }
            }
            lane.mutex.unlock();
            self.wakeConsumerIfParked();
            compat.Futex.timedWait(&lane.producer_futex, futex_val, 50_000);
            lane.mutex.lock();
        }
    }

    /// Producer enqueue for rare oversized (`> LANE_MAX_INLINE`) records.
    /// Waits until the lane's byte-ring is drained (`head == tail`) and no prior `large_pending`
    /// exists, guaranteeing strict per-lane FIFO ordering on disk. Takes ownership of `owned`.
    fn enqueueLargeBlocking(self: *Wal, lane: *WalLane, owned: []u8) void {
        lane.mutex.lock();
        while (true) {
            const tail = lane.tail.load(.monotonic);
            const head = lane.head.load(.acquire);
            lane.cached_head = head;
            if (head == tail and lane.large_pending.load(.acquire) == null) {
                lane.large_pending_len = owned.len;
                lane.bytes_enqueued.store(lane.bytes_enqueued.load(.monotonic) + owned.len, .monotonic);
                lane.large_pending.store(owned.ptr, .seq_cst);
                lane.mutex.unlock();
                self.wakeConsumerIfParked();
                return;
            }

            const futex_val = lane.producer_futex.load(.acquire);
            lane.producer_parked.store(true, .seq_cst);
            const tail2 = lane.tail.load(.monotonic);
            const head2 = lane.head.load(.acquire);
            lane.cached_head = head2;
            if (head2 == tail2 and lane.large_pending.load(.acquire) == null) {
                continue;
            }
            lane.mutex.unlock();
            self.wakeConsumerIfParked();
            compat.Futex.timedWait(&lane.producer_futex, futex_val, 50_000);
            lane.mutex.lock();
        }
    }

    fn hasPendingRecords(self: *Wal) bool {
        for (&self.lanes) |*lane| {
            if (lane.head.load(.acquire) != lane.tail.load(.acquire)) return true;
            if (lane.large_pending.load(.acquire) != null) return true;
        }
        return false;
    }

    inline fn wakeLaneProducers(lane: *WalLane) void {
        if (lane.producer_parked.load(.seq_cst)) {
            lane.producer_parked.store(false, .release);
            _ = lane.producer_futex.fetchAdd(1, .release);
            compat.Futex.wake(&lane.producer_futex, std.math.maxInt(u32));
        }
    }

    fn stageAppend(self: *Wal, stage_pos: *usize, data: []const u8) void {
        const stage = self.writer_stage;
        if (data.len >= stage.len) {
            if (stage_pos.* > 0) {
                compat.File.writeAll(self.file, stage[0..stage_pos.*]) catch {};
                stage_pos.* = 0;
            }
            compat.File.writeAll(self.file, data) catch {};
            return;
        }
        if (stage_pos.* + data.len > stage.len) {
            compat.File.writeAll(self.file, stage[0..stage_pos.*]) catch {};
            stage_pos.* = 0;
        }
        @memcpy(stage[stage_pos.* .. stage_pos.* + data.len], data);
        stage_pos.* += data.len;
    }

    /// What the background writer will drain in one batch: every lane's published tail
    /// and pending oversized record, all as of one instant.
    const LaneCut = struct {
        tails: [WAL_LANES]usize,
        larges: [WAL_LANES]?[*]u8,

        fn eql(a: *const LaneCut, b: *const LaneCut) bool {
            return std.mem.eql(usize, &a.tails, &b.tails) and std.mem.eql(?[*]u8, &a.larges, &b.larges);
        }
    };

    fn collectLanes(self: *Wal, cut: *LaneCut) void {
        for (&self.lanes, 0..) |*lane, i| {
            cut.tails[i] = lane.tail.load(.seq_cst);
            cut.larges[i] = lane.large_pending.load(.seq_cst);
        }
    }

    /// Take a consistent cut across all lanes: the returned state is one that every lane
    /// held at the same instant. Draining lanes one at a time against their live tails
    /// would not be: a record published on lane 20 while the sweep is at lane 10 could
    /// reach disk without an earlier record that landed on lane 5 just after the sweep
    /// passed it.
    ///
    /// Tails only grow, and only this thread clears `large_pending`, so two successive
    /// scans that read identical values prove no lane changed between them. If producers
    /// keep publishing between every pair of scans, freeze them for one scan by taking
    /// each lane mutex (the same leaf mutex a producer holds to publish).
    fn snapshotLanes(self: *Wal, cut: *LaneCut) void {
        var prev: LaneCut = undefined;
        self.collectLanes(&prev);
        var tries: usize = 0;
        while (tries < CUT_RETRIES) : (tries += 1) {
            self.collectLanes(cut);
            if (prev.eql(cut)) return;
            prev = cut.*;
        }
        for (&self.lanes) |*lane| lane.mutex.lock();
        self.collectLanes(cut);
        for (&self.lanes) |*lane| lane.mutex.unlock();
    }

    fn writerLoop(self: *Wal) void {
        const stage = self.writer_stage;
        var cut: LaneCut = undefined;
        while (self.writer_running.load(.acquire) or self.hasPendingRecords()) {
            var stage_pos: usize = 0;

            self.snapshotLanes(&cut);
            var batch_bytes: u64 = 0;
            for (&self.lanes, 0..) |*lane, i| {
                batch_bytes += cut.tails[i] -% lane.head.load(.monotonic);
                // `large_pending_len` is written before the pointer is published.
                if (cut.larges[i] != null) batch_bytes += lane.large_pending_len;
            }

            if (batch_bytes > 0) {
                // One batch = everything published up to the cut, bracketed by markers so
                // replay applies it whole or not at all (see `WalIterator`). Records from
                // different lanes never interleave mid-frame.
                var marker: [BATCH_MARKER_LEN]u8 = undefined;
                encodeBatchMarker(&marker, .batch_begin, batch_bytes);
                self.stageAppend(&stage_pos, &marker);

                for (&self.lanes, 0..) |*lane, i| {
                    const head = lane.head.load(.monotonic);
                    const avail = cut.tails[i] -% head;
                    if (avail > 0) {
                        const pos = head & LANE_RING_MASK;
                        const first = @min(avail, LANE_RING_CAP - pos);
                        self.stageAppend(&stage_pos, lane.ring[pos .. pos + first]);
                        if (first < avail) {
                            self.stageAppend(&stage_pos, lane.ring[0 .. avail - first]);
                        }
                        lane.head.store(head +% avail, .seq_cst);
                        wakeLaneProducers(lane);
                    }

                    if (cut.larges[i]) |ptr| {
                        // Flush staged bytes first so any earlier ring records from this lane hit disk first.
                        if (stage_pos > 0) {
                            compat.File.writeAll(self.file, stage[0..stage_pos]) catch {};
                            stage_pos = 0;
                        }
                        const len = lane.large_pending_len;
                        compat.File.writeAll(self.file, ptr[0..len]) catch {};
                        self.allocator.free(ptr[0..len]);
                        lane.large_pending_len = 0;
                        lane.large_pending.store(null, .seq_cst);
                        wakeLaneProducers(lane);
                    }
                }

                encodeBatchMarker(&marker, .batch_commit, batch_bytes);
                self.stageAppend(&stage_pos, &marker);
                if (stage_pos > 0) {
                    compat.File.writeAll(self.file, stage[0..stage_pos]) catch {};
                }
                _ = self.wal_bytes.fetchAdd(2 * BATCH_MARKER_LEN, .monotonic);
                self.write_count += 1;
                // Single fsync for the entire multi-lane batch — group commit durability.
                if (self.sync_writes) {
                    compat.File.sync(self.file) catch {};
                }
                continue;
            }

            if (self.sync_requested.swap(false, .acq_rel)) {
                compat.File.sync(self.file) catch {};
                continue;
            }

            // Park consumer and wait for producer to enqueue — Dekker handshake
            // with producer's lane.tail/large_pending.store(.seq_cst) + consumer_parked.load(.seq_cst).
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

    /// Encode a batch marker record: a normal record header plus the batch body length.
    pub fn encodeBatchMarker(dst: *[BATCH_MARKER_LEN]u8, kind: WalRecordType, batch_bytes: u64) void {
        std.mem.writeInt(u64, dst[@sizeOf(RecordHeader)..][0..8], batch_bytes, .little);
        const header = RecordHeader{
            .crc = crc32(dst[@sizeOf(RecordHeader)..]),
            .record_type = @backingInt(kind),
            .length = BATCH_MARKER_PAYLOAD,
        };
        @memcpy(dst[0..@sizeOf(RecordHeader)], std.mem.asBytes(&header));
    }

    /// Call once after replaying the log with `iter`, before anything is appended.
    /// If the log ended in a torn batch (or a cut-off header or marker), that tail is
    /// removed so new appends cannot be glued onto it and committed by a later marker.
    /// Leaves the file positioned for append either way.
    pub fn finishReplay(self: *Wal, iter: *const WalIterator) !void {
        const file_size = (try compat.File.stat(self.file)).size;
        // A read error is not evidence of a torn tail: leave the file alone.
        if (iter.tail_torn and !iter.read_failed and iter.valid_end < file_size) {
            std.log.warn("WAL: discarding {d} bytes of torn tail at offset {d}", .{ file_size - iter.valid_end, iter.valid_end });
            try compat.File.setLength(self.file, iter.valid_end);
            if (self.sync_writes) try compat.File.sync(self.file);
            self.wal_bytes.store(@intCast(iter.valid_end), .monotonic);
            try compat.File.seekTo(self.file, iter.valid_end);
            return;
        }
        try compat.File.seekTo(self.file, file_size);
    }

    pub fn iterator(self: *Wal) WalIterator {
        compat.File.seekTo(self.file, 0) catch {};
        return .{ .file = self.file, .allocator = self.allocator };
    }

    pub fn size(self: *Wal) !usize {
        var total = self.wal_bytes.load(.monotonic);
        for (&self.lanes) |*lane| {
            total += lane.bytes_enqueued.load(.monotonic);
        }
        return total;
    }

    /// Truncate the WAL to zero bytes and reset write cursor to the beginning.
    pub fn truncate(self: *Wal) !void {
        try compat.File.setLength(self.file, 0);
        try compat.File.seekTo(self.file, 0);
        self.wal_bytes.store(0, .monotonic);
        for (&self.lanes) |*lane| {
            lane.bytes_enqueued.store(0, .monotonic);
        }
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

/// Sequential reader over the log's data records.
///
/// The background writer brackets everything it drains in one sweep with a
/// `batch_begin` / `batch_commit` marker pair, each carrying the batch body length.
/// A batch whose commit marker is not on disk was cut short by a crash; because it
/// mixes lanes, a prefix of it could hold a later write without an earlier write to
/// another key, so the iterator ends the log at that batch's begin marker instead of
/// yielding any of it. Records outside a batch (direct-mode writes, logs written before
/// markers existed) are each complete on their own. Markers are never yielded.
pub const WalIterator = struct {
    file: std.Io.File,
    allocator: std.mem.Allocator,
    read_buf: [65536]u8 = undefined,
    buf_pos: usize = 0,
    buf_end: usize = 0,
    done: bool = false,
    /// Bytes pulled from the file so far (the OS file position).
    file_read: u64 = 0,
    /// Log offset of the next unconsumed byte.
    consumed: u64 = 0,
    /// Offset just past the last complete record or batch. Everything after it is a
    /// torn tail; see `Wal.finishReplay`.
    valid_end: u64 = 0,
    /// End offset of the committed batch being read, if any.
    batch_end: ?u64 = null,
    /// A read error ended the iteration, so `valid_end` says nothing about the tail.
    read_failed: bool = false,
    /// The log ended in something only an interrupted write leaves behind: a batch
    /// with no commit marker, or a cut-off header or marker. `Wal.finishReplay` removes
    /// it. A data record cut short outside a batch does not set this; that case keeps
    /// its long-standing behaviour of ending the log without touching the file.
    tail_torn: bool = false,

    fn readBuffered(self: *WalIterator, dest: []u8) !usize {
        var total: usize = 0;
        while (total < dest.len) {
            const avail = self.buf_end - self.buf_pos;
            if (avail == 0) {
                if (dest.len - total >= self.read_buf.len) {
                    const n = try compat.File.readAll(self.file, dest[total..]);
                    self.file_read += n;
                    self.consumed += n;
                    return total + n;
                }
                self.buf_pos = 0;
                self.buf_end = try compat.File.readAll(self.file, &self.read_buf);
                self.file_read += self.buf_end;
                if (self.buf_end == 0) break;
                continue;
            }
            const n = @min(avail, dest.len - total);
            @memcpy(dest[total..][0..n], self.read_buf[self.buf_pos..][0..n]);
            self.buf_pos += n;
            self.consumed += n;
            total += n;
        }
        return total;
    }

    fn isBatchMarker(raw_type: u8) bool {
        return raw_type == @backingInt(WalRecordType.batch_begin) or
            raw_type == @backingInt(WalRecordType.batch_commit);
    }

    /// Whether a valid commit marker for a `batch_bytes`-long batch sits at `offset`.
    /// Reads at an absolute position, then restores the sequential read position.
    fn commitMarkerAt(self: *WalIterator, offset: u64, batch_bytes: u64) bool {
        var raw: [Wal.BATCH_MARKER_LEN]u8 = undefined;
        compat.File.seekTo(self.file, offset) catch return false;
        const n = compat.File.readAll(self.file, &raw) catch 0;
        compat.File.seekTo(self.file, self.file_read) catch {
            // The sequential position is lost; stop rather than read from the wrong place.
            self.read_failed = true;
            self.done = true;
            return false;
        };
        if (n < raw.len) return false;
        const header: *align(1) const Wal.RecordHeader = @ptrCast(&raw);
        const payload = raw[@sizeOf(Wal.RecordHeader)..];
        if (header.record_type != @backingInt(WalRecordType.batch_commit)) return false;
        if (header.length != payload.len) return false;
        if (crc32(payload) != header.crc) return false;
        return std.mem.readInt(u64, payload[0..8], .little) == batch_bytes;
    }

    pub fn next(self: *WalIterator) !?WalRecord {
        while (true) {
            if (self.done) return null;
            const record_start = self.consumed;

            var header: Wal.RecordHeader = undefined;
            const header_bytes_read = self.readBuffered(std.mem.asBytes(&header)) catch {
                self.read_failed = true;
                self.done = true;
                return null;
            };

            if (header_bytes_read < @sizeOf(Wal.RecordHeader)) {
                // Fewer bytes than a header: nothing recoverable, safe to drop.
                if (header_bytes_read > 0) self.tail_torn = true;
                self.done = true;
                return null;
            }

            const payload_len: usize = @intCast(header.length);
            if (payload_len == 0 or payload_len > 1024 * 1024 * 100) return error.Corruption;

            // Zero-copy fast path when payload is already contiguous in read_buf
            var heap_payload: ?[]u8 = null;
            defer if (heap_payload) |hp| self.allocator.free(hp);
            const payload: []const u8 = if (self.buf_end - self.buf_pos >= payload_len) blk: {
                const in_buf = self.read_buf[self.buf_pos .. self.buf_pos + payload_len];
                self.buf_pos += payload_len;
                self.consumed += payload_len;
                break :blk in_buf;
            } else blk: {
                const hp = try self.allocator.alloc(u8, payload_len);
                heap_payload = hp;
                const payload_read = self.readBuffered(hp) catch {
                    self.read_failed = true;
                    self.done = true;
                    return null;
                };
                if (payload_read < payload_len) {
                    if (isBatchMarker(header.record_type)) self.tail_torn = true;
                    self.done = true;
                    return null;
                }
                break :blk hp;
            };

            if (crc32(payload) != header.crc) return error.Corruption;

            // A type this build does not know is corruption, not undefined behaviour.
            const record_type = std.enums.fromInt(WalRecordType, header.record_type) orelse return error.Corruption;
            switch (record_type) {
                .batch_begin => {
                    if (self.batch_end != null or payload.len != 8) return error.Corruption;
                    const batch_bytes = std.mem.readInt(u64, payload[0..8], .little);
                    const body_end = std.math.add(u64, self.consumed, batch_bytes) catch return error.Corruption;
                    if (!self.commitMarkerAt(body_end, batch_bytes)) {
                        if (self.read_failed) return null;
                        // Nothing is written after a batch until its commit marker is
                        // down, so a batch without one is torn only if it is the last
                        // thing in the file. Anything else is damage, not a crash.
                        const file_size = (compat.File.stat(self.file) catch return error.Corruption).size;
                        if (file_size > body_end + Wal.BATCH_MARKER_LEN) return error.Corruption;
                        // Torn batch: the log ends before its begin marker.
                        self.tail_torn = true;
                        self.done = true;
                        return null;
                    }
                    self.batch_end = body_end;
                    continue;
                },
                .batch_commit => {
                    const body_end = self.batch_end orelse return error.Corruption;
                    if (record_start != body_end) return error.Corruption;
                    self.batch_end = null;
                    self.valid_end = self.consumed;
                    continue;
                },
                .set, .delete, .vinsert, .vdelete => {
                    if (self.batch_end) |body_end| {
                        if (self.consumed > body_end) return error.Corruption;
                    }
                    const record: WalRecord = switch (record_type) {
                        .set => try self.parseSet(payload),
                        .delete => try self.parseDelete(payload),
                        .vinsert => try self.parseVinsert(payload),
                        .vdelete => try self.parseVdelete(payload),
                        .batch_begin, .batch_commit => unreachable,
                    };
                    if (self.batch_end == null) self.valid_end = self.consumed;
                    return record;
                },
            }
        }
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

test "sharded bg-WAL handles multi-threaded writes, single-lane ring wrap-around, and exact replay" {
    if (!Wal.use_background_writer) return;
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try compat.Dir.realPathAlloc(tmp.dir, allocator, ".");
    defer allocator.free(path);
    const file = try std.fmt.allocPrint(allocator, "{s}/sharded_mt.wal", .{path});
    defer allocator.free(file);

    const created = try compat.Dir.createFile(compat.cwd(), file, .{});
    compat.File.close(created);

    const n_threads: usize = 8;
    const ops_per_thread: usize = 400; // Thread 0 alone writes ~400 * 1050B > 400 KiB (> 256 KiB ring) on lane 0!

    {
        var wal = try Wal.init(allocator, file, true);
        defer wal.deinit();
        try wal.startBackground();

        const Worker = struct {
            fn run(w: *Wal, tid: usize) void {
                var key_buf: [32]u8 = undefined;
                var val_buf: [1024]u8 = undefined;
                var rec_buf: [2048]u8 = undefined;
                const flags = EntryFlags{ .is_worm = false, .is_deleted = false };

                for (0..ops_per_thread) |seq| {
                    const key = std.fmt.bufPrint(&key_buf, "t{d}:k{d}", .{ tid, seq % 16 }) catch unreachable;
                    const fill: u8 = @intCast('a' + ((tid + seq) % 26));
                    @memset(&val_buf, fill);
                    // Put seq into the first 4 bytes so we can verify strict per-key FIFO ordering!
                    std.mem.writeInt(u32, val_buf[0..4], @intCast(seq), .little);
                    const rec = Wal.encodeSetRecord(&rec_buf, key, &val_buf, flags, @intCast(seq));
                    // Thread 0 hammers lane 0 exclusively to force ring wrap-around (> 256 KiB);
                    // other threads spread across multiple lanes deterministically by key.
                    const lane_key: usize = if (tid == 0) 0 else (tid * 3 + (seq % 16));
                    w.commitRecordBytesForLane(lane_key, rec) catch unreachable;
                }
            }
        };

        var threads: [n_threads]std.Thread = undefined;
        for (0..n_threads) |t| {
            threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &wal, t });
        }
        for (&threads) |th| th.join();

        try testing.expect((try wal.size()) > Wal.LANE_RING_CAP);
    }

    // Replay WAL and verify total record count, CRC integrity, and strict FIFO per-key ordering.
    var wal_ro = try Wal.init(allocator, file, false);
    defer wal_ro.deinit();
    var iter = wal_ro.iterator();

    var seen_total: usize = 0;
    var last_seq: [n_threads * 16]i64 = @splat(-1);
    while (try iter.next()) |rec| {
        defer iter.deinitRecord(rec);
        switch (rec) {
            .set => |s| {
                seen_total += 1;
                try testing.expectEqual(@as(usize, 1024), s.value.len);
                const seq: i64 = @intCast(std.mem.readInt(u32, s.value[0..4], .little));
                // Parse "t<tid>:k<slot>"
                const colon = std.mem.indexOfScalar(u8, s.key, ':').?;
                const tid = try std.fmt.parseInt(usize, s.key[1..colon], 10);
                const slot = try std.fmt.parseInt(usize, s.key[colon + 2 ..], 10);
                const idx = tid * 16 + slot;
                // Because each (tid, slot) routes deterministically to one lane and is written
                // in ascending seq order, replay MUST observe strictly increasing seq per key!
                try testing.expect(seq > last_seq[idx]);
                last_seq[idx] = seq;
            },
            else => return error.UnexpectedRecordType,
        }
    }
    try testing.expectEqual(n_threads * ops_per_thread, seen_total);
    // Final seq for each slot `s` out of `0..ops_per_thread` is the largest `seq` with `seq % 16 == s`.
    for (0..n_threads) |t| {
        for (0..16) |s| {
            const expected_last: i64 = @intCast(((ops_per_thread - 1 - s) / 16) * 16 + s);
            try testing.expectEqual(expected_last, last_seq[t * 16 + s]);
        }
    }
}

test "sharded bg-WAL preserves strict FIFO ordering across inline and >64 KiB oversized records on same lane" {
    if (!Wal.use_background_writer) return;
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try compat.Dir.realPathAlloc(tmp.dir, allocator, ".");
    defer allocator.free(path);
    const file = try std.fmt.allocPrint(allocator, "{s}/oversized_fifo.wal", .{path});
    defer allocator.free(file);

    const created = try compat.Dir.createFile(compat.cwd(), file, .{});
    compat.File.close(created);

    const big_len: usize = 96 * 1024; // > LANE_MAX_INLINE (64 KiB)
    const big_val = try allocator.alloc(u8, big_len);
    defer allocator.free(big_val);
    @memset(big_val, 'B');

    const flags = EntryFlags{ .is_worm = false, .is_deleted = false };
    const lane_key: usize = 7;

    {
        var wal = try Wal.init(allocator, file, true);
        defer wal.deinit();
        try wal.startBackground();

        var small_buf: [256]u8 = undefined;
        // 1. Inline SET before oversized record
        try wal.commitRecordBytesForLane(lane_key, Wal.encodeSetRecord(&small_buf, "same_key", "step1_inline", flags, 1));
        // 2. Oversized 96 KiB SET on the SAME lane
        const big_rec = try wal.serializeSetRecord("same_key", big_val, flags, 2);
        defer allocator.free(big_rec);
        try wal.commitRecordBytesForLane(lane_key, big_rec);
        // 3. Inline SET after oversized record
        try wal.commitRecordBytesForLane(lane_key, Wal.encodeSetRecord(&small_buf, "same_key", "step3_inline", flags, 3));
        // 4. Second oversized 96 KiB SET on the SAME lane
        @memset(big_val, 'D');
        const big_rec2 = try wal.serializeSetRecord("same_key", big_val, flags, 4);
        defer allocator.free(big_rec2);
        try wal.commitRecordBytesForLane(lane_key, big_rec2);
        // 5. Final inline DELETE on the SAME lane
        try wal.appendDeleteForLane(lane_key, "same_key");
    }

    var wal_ro = try Wal.init(allocator, file, false);
    defer wal_ro.deinit();
    var iter = wal_ro.iterator();

    // Verify exact 1 -> 2 -> 3 -> 4 -> 5 on-disk order!
    const r1 = (try iter.next()).?;
    defer iter.deinitRecord(r1);
    try testing.expectEqualStrings("step1_inline", r1.set.value);
    try testing.expectEqual(@as(u64, 1), r1.set.timestamp);

    const r2 = (try iter.next()).?;
    defer iter.deinitRecord(r2);
    try testing.expectEqual(big_len, r2.set.value.len);
    try testing.expectEqual(@as(u8, 'B'), r2.set.value[0]);
    try testing.expectEqual(@as(u8, 'B'), r2.set.value[big_len - 1]);
    try testing.expectEqual(@as(u64, 2), r2.set.timestamp);

    const r3 = (try iter.next()).?;
    defer iter.deinitRecord(r3);
    try testing.expectEqualStrings("step3_inline", r3.set.value);
    try testing.expectEqual(@as(u64, 3), r3.set.timestamp);

    const r4 = (try iter.next()).?;
    defer iter.deinitRecord(r4);
    try testing.expectEqual(big_len, r4.set.value.len);
    try testing.expectEqual(@as(u8, 'D'), r4.set.value[0]);
    try testing.expectEqual(@as(u64, 4), r4.set.timestamp);

    const r5 = (try iter.next()).?;
    defer iter.deinitRecord(r5);
    try testing.expectEqualStrings("same_key", r5.delete);

    try testing.expect((try iter.next()) == null);
}

/// Builds raw log bytes for the batch-marker tests.
const BatchTestLog = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    const alloc = std.testing.allocator;

    fn deinit(self: *BatchTestLog) void {
        self.bytes.deinit(alloc);
    }

    fn set(self: *BatchTestLog, key: []const u8) !void {
        var buf: [256]u8 = undefined;
        const rec = Wal.encodeSetRecord(&buf, key, "value", .{ .is_worm = false, .is_deleted = false }, 7);
        try self.bytes.appendSlice(alloc, rec);
    }

    fn marker(self: *BatchTestLog, kind: WalRecordType, batch_bytes: u64) !void {
        var raw: [Wal.BATCH_MARKER_LEN]u8 = undefined;
        Wal.encodeBatchMarker(&raw, kind, batch_bytes);
        try self.bytes.appendSlice(alloc, &raw);
    }

    /// A batch body holding one SET per key, with its begin marker and, unless
    /// `commit` is false, its commit marker.
    fn batch(self: *BatchTestLog, keys: []const []const u8, commit: bool) !void {
        var body = BatchTestLog{};
        defer body.deinit();
        for (keys) |k| try body.set(k);
        try self.marker(.batch_begin, body.bytes.items.len);
        try self.bytes.appendSlice(alloc, body.bytes.items);
        if (commit) try self.marker(.batch_commit, body.bytes.items.len);
    }

    /// Replace the file at `path` with the first `len` bytes of the log.
    fn writeTo(self: *const BatchTestLog, path: []const u8, len: usize) !void {
        const f = try compat.Dir.createFile(compat.cwd(), path, .{});
        defer compat.File.close(f);
        try compat.File.writeAll(f, self.bytes.items[0..len]);
    }
};

const BatchReplay = struct {
    /// Keys of the SET records the iterator yielded, comma-joined.
    keys: []u8,
    tail_torn: bool,
    valid_end: u64,
};

/// Replay the log at `path`. With `finish`, also run `Wal.finishReplay`.
fn replayBatchTestLog(path: []const u8, finish: bool) !BatchReplay {
    const alloc = std.testing.allocator;
    var wal = try Wal.init(alloc, path, false);
    defer wal.deinit();
    var iter = wal.iterator();
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    errdefer joined.deinit(alloc);
    while (try iter.next()) |rec| {
        defer iter.deinitRecord(rec);
        if (joined.items.len > 0) try joined.append(alloc, ',');
        try joined.appendSlice(alloc, rec.set.key);
    }
    if (finish) try wal.finishReplay(&iter);
    return .{ .keys = try joined.toOwnedSlice(alloc), .tail_torn = iter.tail_torn, .valid_end = iter.valid_end };
}

fn batchTestPath(tmp: *std.testing.TmpDir, name: []const u8) ![]u8 {
    const alloc = std.testing.allocator;
    const dir = try compat.Dir.realPathAlloc(tmp.dir, alloc, ".");
    defer alloc.free(dir);
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
}

test "background writer brackets each sweep with batch markers that replay hides" {
    if (!Wal.use_background_writer) return;
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try batchTestPath(&tmp, "batch_markers.wal");
    defer allocator.free(file);
    compat.File.close(try compat.Dir.createFile(compat.cwd(), file, .{}));

    const flags = EntryFlags{ .is_worm = false, .is_deleted = false };
    {
        var wal = try Wal.init(allocator, file, true);
        defer wal.deinit();
        try wal.startBackground();
        var buf: [256]u8 = undefined;
        try wal.commitRecordBytesForLane(1, Wal.encodeSetRecord(&buf, "lane1", "a", flags, 1));
        try wal.commitRecordBytesForLane(9, Wal.encodeSetRecord(&buf, "lane9", "b", flags, 2));
        try wal.commitRecordBytesForLane(30, Wal.encodeSetRecord(&buf, "lane30", "c", flags, 3));
    }

    // The raw file opens with a begin marker and closes with a commit marker.
    const raw_file = try compat.Dir.openFile(compat.cwd(), file, .{ .mode = .read_only });
    defer compat.File.close(raw_file);
    const size: usize = @intCast((try compat.File.stat(raw_file)).size);
    const raw = try allocator.alloc(u8, size);
    defer allocator.free(raw);
    try testing.expectEqual(size, try compat.File.readAll(raw_file, raw));
    try testing.expect(size > 2 * Wal.BATCH_MARKER_LEN);
    const first: *align(1) const Wal.RecordHeader = @ptrCast(raw.ptr);
    try testing.expectEqual(@backingInt(WalRecordType.batch_begin), first.record_type);
    const last: *align(1) const Wal.RecordHeader = @ptrCast(raw.ptr + size - Wal.BATCH_MARKER_LEN);
    try testing.expectEqual(@backingInt(WalRecordType.batch_commit), last.record_type);

    // Replay yields the three data records and nothing else, with no tail to drop.
    var wal_ro = try Wal.init(allocator, file, false);
    defer wal_ro.deinit();
    var iter = wal_ro.iterator();
    var seen: usize = 0;
    while (try iter.next()) |rec| {
        defer iter.deinitRecord(rec);
        try testing.expect(rec == .set);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
    try testing.expect(!iter.tail_torn);
    try testing.expectEqual(@as(u64, size), iter.valid_end);
    // `size()` accounts for the marker bytes too.
    try testing.expectEqual(size, try wal_ro.size());
}

test "replay ends at a batch with no commit marker and finishReplay removes it" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try batchTestPath(&tmp, "torn_batch.wal");
    defer allocator.free(file);

    var log = BatchTestLog{};
    defer log.deinit();
    try log.set("direct"); // written outside any batch: complete on its own
    try log.batch(&.{ "a1", "a2" }, true);
    const committed_len = log.bytes.items.len;
    try log.batch(&.{ "b1", "b2" }, false); // crash before the commit marker
    try log.writeTo(file, log.bytes.items.len);

    const first = try replayBatchTestLog(file, true);
    defer allocator.free(first.keys);
    try testing.expectEqualStrings("direct,a1,a2", first.keys);
    try testing.expect(first.tail_torn);
    try testing.expectEqual(@as(u64, committed_len), first.valid_end);

    // The torn batch is gone from the file, so a later append is not glued onto it.
    {
        var wal = try Wal.init(allocator, file, false);
        defer wal.deinit();
        try testing.expectEqual(committed_len, try wal.size());
        var buf: [256]u8 = undefined;
        const rec = Wal.encodeSetRecord(&buf, "after", "value", .{ .is_worm = false, .is_deleted = false }, 9);
        try wal.commitRecordBytesForLane(0, rec);
    }
    const second = try replayBatchTestLog(file, true);
    defer allocator.free(second.keys);
    try testing.expectEqualStrings("direct,a1,a2,after", second.keys);
    try testing.expect(!second.tail_torn);
}

test "a log cut anywhere inside its last batch replays only the batches before it" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try batchTestPath(&tmp, "cut_anywhere.wal");
    defer allocator.free(file);

    var log = BatchTestLog{};
    defer log.deinit();
    try log.batch(&.{ "a1", "a2" }, true);
    const end_a = log.bytes.items.len;
    try log.batch(&.{ "b1", "b2", "b3" }, true);
    const end_b = log.bytes.items.len;

    var cut = end_a;
    while (cut <= end_b) : (cut += 1) {
        try log.writeTo(file, cut);
        const got = try replayBatchTestLog(file, true);
        defer allocator.free(got.keys);
        if (cut == end_b) {
            try testing.expectEqualStrings("a1,a2,b1,b2,b3", got.keys);
            try testing.expect(!got.tail_torn);
        } else {
            // Never a prefix of batch B, whatever the cut point.
            try testing.expectEqualStrings("a1,a2", got.keys);
            try testing.expectEqual(cut != end_a, got.tail_torn);
        }
        try testing.expectEqual(@as(u64, if (cut == end_b) end_b else end_a), got.valid_end);

        // After finishReplay the file holds exactly the complete batches.
        var wal = try Wal.init(allocator, file, false);
        defer wal.deinit();
        try testing.expectEqual(@as(usize, if (cut == end_b) end_b else end_a), try wal.size());
    }
}

test "a log from before batch markers replays unchanged" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try batchTestPath(&tmp, "legacy.wal");
    defer allocator.free(file);

    var log = BatchTestLog{};
    defer log.deinit();
    try log.set("k1");
    try log.set("k2");
    try log.set("k3");
    const full = log.bytes.items.len;

    try log.writeTo(file, full);
    const whole = try replayBatchTestLog(file, true);
    defer allocator.free(whole.keys);
    try testing.expectEqualStrings("k1,k2,k3", whole.keys);
    try testing.expect(!whole.tail_torn);

    // A data record cut short outside a batch still just ends the log; the file is
    // left as it was.
    try log.writeTo(file, full - 3);
    const short = try replayBatchTestLog(file, true);
    defer allocator.free(short.keys);
    try testing.expectEqualStrings("k1,k2", short.keys);
    try testing.expect(!short.tail_torn);
    var wal = try Wal.init(allocator, file, false);
    defer wal.deinit();
    try testing.expectEqual(full - 3, try wal.size());
}

test "damage in a committed batch, misplaced markers and unknown record types are corruption" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try batchTestPath(&tmp, "batch_corruption.wal");
    defer allocator.free(file);

    // A flipped byte inside a batch whose commit marker is present.
    {
        var log = BatchTestLog{};
        defer log.deinit();
        try log.batch(&.{ "a1", "a2" }, true);
        log.bytes.items[Wal.BATCH_MARKER_LEN + @sizeOf(Wal.RecordHeader) + 2] ^= 0xFF;
        try log.writeTo(file, log.bytes.items.len);
        try testing.expectError(error.Corruption, replayBatchTestLog(file, false));
    }
    // No commit marker where the batch ends, but more log after it: not a torn tail.
    {
        var log = BatchTestLog{};
        defer log.deinit();
        try log.batch(&.{"a1"}, false);
        try log.set("later1");
        try log.set("later2");
        try log.writeTo(file, log.bytes.items.len);
        try testing.expectError(error.Corruption, replayBatchTestLog(file, false));
    }
    // A commit marker with no batch open.
    {
        var log = BatchTestLog{};
        defer log.deinit();
        try log.set("k1");
        try log.marker(.batch_commit, 0);
        try log.writeTo(file, log.bytes.items.len);
        try testing.expectError(error.Corruption, replayBatchTestLog(file, false));
    }
    // A record type this build does not know (the CRC covers the payload only).
    {
        var log = BatchTestLog{};
        defer log.deinit();
        try log.set("k1");
        log.bytes.items[@offsetOf(Wal.RecordHeader, "record_type")] = 0x7F;
        try log.writeTo(file, log.bytes.items.len);
        try testing.expectError(error.Corruption, replayBatchTestLog(file, false));
    }
}
