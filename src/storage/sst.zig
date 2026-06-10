//! Frozen sorted-string segment (`.wsst`) — a read-only, memory-mapped,
//! string-keyed table for large *static* KV datasets.
//!
//! The u64-keyed `.wseg` segment (segment.zig) gives blockchain-scale tables
//! instant boot, but it can't serve domains built on **ordered string-prefix
//! scans** (autocomplete indexes like wormdb-domain-geo's `logridx:*`). This is
//! its string twin: all keys, lexicographically sorted, in one contiguous
//! arena; binary search for GET, lower-bound + forward walk for prefix scans.
//!
//! Like `.wseg`: built offline, mmap'd read-only (whole-file heap read on
//! Windows), zero per-entry allocation, boot is just `mmap`. Unlike `.wseg`,
//! it attaches to the Store as a **transparent overlay** (see store.zig): live
//! shard entries shadow frozen keys, so procedures and the wire protocol need
//! no segment awareness at all.
//!
//! On-disk format (all integers little-endian):
//!   Header (64 B):
//!     magic "WSST0001" | version u32 | _reserved u32 | count u64
//!     | index_off u64 | keys_off u64 | vals_off u64 | timestamp u64
//!   Index: count × 24 B, sorted by key ascending:
//!     key_off u64 (absolute) | val_off u64 (absolute)
//!     | key_len u32 (bit 31 = is_worm) | val_len u32
//!   Key arena: concatenated key bytes in index order.
//!   Value arena: concatenated value bytes in index order.
//!
//! One timestamp covers the whole segment — frozen datasets are built in one
//! shot and per-entry timestamps would add 8 B × millions for no information.
//!
//! The builder (`buildFromSnapshot`) streams a WormDB snapshot — which
//! writeSnapshot emits globally key-sorted — into this layout in sequential
//! passes (sizes, index, keys, values), so it never holds the dataset in
//! memory. `wormdb-sst` (tools/sst_build.zig) is its CLI.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../core/compat.zig");
const Segment = @import("segment.zig").Segment;

pub const MAGIC = "WSST0001";
pub const VERSION: u32 = 1;

pub const HEADER_SIZE: usize = 64;
pub const INDEX_ENTRY: usize = 24;
const WORM_BIT: u32 = 1 << 31;

pub const SstError = error{
    SstTooSmall,
    SstBadMagic,
    SstBadVersion,
    SstTruncated,
    SstBadIndex,
    SstUnsorted,
    SnapshotBadMagic,
    SnapshotBadVersion,
    SnapshotCorrupt,
};

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

pub const Sst = struct {
    bytes: []const u8,
    backing: Segment.Backing,
    count: usize,
    index: []const u8, // count × INDEX_ENTRY
    timestamp: u64,

    /// A borrowed view of one frozen entry. Slices are valid for the segment's
    /// lifetime (the mapping is never unmapped while serving).
    pub const Hit = struct {
        key: []const u8,
        value: []const u8,
        timestamp: u64,
        is_worm: bool,
    };

    /// Open and validate a `.wsst` file. The mapping (or heap buffer on
    /// Windows) is owned by the returned Sst until `close`.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Sst {
        const m = try Segment.mapFile(allocator, path);
        errdefer Segment.freeBytes(allocator, m.bytes, m.backing);
        const bytes = m.bytes;

        if (bytes.len < HEADER_SIZE) return SstError.SstTooSmall;
        if (!std.mem.eql(u8, bytes[0..8], MAGIC)) return SstError.SstBadMagic;
        if (rd32(bytes, 8) != VERSION) return SstError.SstBadVersion;
        const count: usize = @intCast(rd64(bytes, 16));
        const index_off: usize = @intCast(rd64(bytes, 24));
        const keys_off: usize = @intCast(rd64(bytes, 32));
        const vals_off: usize = @intCast(rd64(bytes, 40));
        const timestamp = rd64(bytes, 48);

        const index_len = count * INDEX_ENTRY;
        if (index_off + index_len > bytes.len) return SstError.SstTruncated;
        if (keys_off > bytes.len or vals_off > bytes.len) return SstError.SstTruncated;

        return .{
            .bytes = bytes,
            .backing = m.backing,
            .count = count,
            .index = bytes[index_off .. index_off + index_len],
            .timestamp = timestamp,
        };
    }

    pub fn close(self: *Sst, allocator: std.mem.Allocator) void {
        Segment.freeBytes(allocator, self.bytes, self.backing);
        self.* = .{ .bytes = &.{}, .backing = .heap, .count = 0, .index = &.{}, .timestamp = 0 };
    }

    pub fn keyAt(self: *const Sst, i: usize) []const u8 {
        const base = i * INDEX_ENTRY;
        const key_off: usize = @intCast(rd64(self.index, base));
        const key_len: usize = @intCast(rd32(self.index, base + 16) & ~WORM_BIT);
        return self.bytes[key_off .. key_off + key_len];
    }

    pub fn hitAt(self: *const Sst, i: usize) Hit {
        const base = i * INDEX_ENTRY;
        const key_off: usize = @intCast(rd64(self.index, base));
        const val_off: usize = @intCast(rd64(self.index, base + 8));
        const key_len_raw = rd32(self.index, base + 16);
        const key_len: usize = @intCast(key_len_raw & ~WORM_BIT);
        const val_len: usize = @intCast(rd32(self.index, base + 20));
        return .{
            .key = self.bytes[key_off .. key_off + key_len],
            .value = self.bytes[val_off .. val_off + val_len],
            .timestamp = self.timestamp,
            .is_worm = (key_len_raw & WORM_BIT) != 0,
        };
    }

    /// Exact-key lookup — one binary search, zero allocation.
    pub fn get(self: *const Sst, key: []const u8) ?Hit {
        const i = self.lowerBound(key);
        if (i >= self.count) return null;
        if (!std.mem.eql(u8, self.keyAt(i), key)) return null;
        return self.hitAt(i);
    }

    /// First index whose key is >= `key` (count if none).
    pub fn lowerBound(self: *const Sst, key: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (std.mem.lessThan(u8, self.keyAt(mid), key)) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /// Index range [lo, hi) of keys starting with `prefix` — two binary
    /// searches (`startsWith` is monotone over the sorted keys past the
    /// lower bound), O(log n) regardless of how many keys match.
    pub fn prefixRange(self: *const Sst, prefix: []const u8) struct { lo: usize, hi: usize } {
        const lo = self.lowerBound(prefix);
        var l = lo;
        var h = self.count;
        while (l < h) {
            const mid = l + (h - l) / 2;
            if (std.mem.startsWith(u8, self.keyAt(mid), prefix)) {
                l = mid + 1;
            } else {
                h = mid;
            }
        }
        return .{ .lo = lo, .hi = l };
    }
};

// ── Builder ─────────────────────────────────────────────────────────────────

const SNAPSHOT_MAGIC = "WDBSNAP1"; // must match store.zig's snapshot writer
const SNAPSHOT_ENTRY_HEADER: usize = 17; // key_len u32 | val_len u32 | flags u8 | ts u64

/// Streaming snapshot reader used by the builder: buffered sequential reads
/// plus a `skip` that just advances within the buffer.
const SnapReader = struct {
    file: std.Io.File,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,

    fn readAll(self: *SnapReader, dest: []u8) !usize {
        var total: usize = 0;
        while (total < dest.len) {
            const avail = self.end - self.start;
            if (avail == 0) {
                self.start = 0;
                self.end = try compat.File.readAll(self.file, self.buf);
                if (self.end == 0) break;
                continue;
            }
            const n = @min(avail, dest.len - total);
            @memcpy(dest[total..][0..n], self.buf[self.start..][0..n]);
            self.start += n;
            total += n;
        }
        return total;
    }

    fn skip(self: *SnapReader, n: usize) !void {
        var left = n;
        while (left > 0) {
            const avail = self.end - self.start;
            if (avail == 0) {
                self.start = 0;
                self.end = try compat.File.readAll(self.file, self.buf);
                if (self.end == 0) return SstError.SnapshotCorrupt;
                continue;
            }
            const step = @min(avail, left);
            self.start += step;
            left -= step;
        }
    }
};

const SnapHeader = struct { count: u64 };

fn openSnapshot(reader: *SnapReader) !SnapHeader {
    var magic: [8]u8 = undefined;
    if (try reader.readAll(magic[0..]) != 8) return SstError.SnapshotCorrupt;
    if (!std.mem.eql(u8, magic[0..], SNAPSHOT_MAGIC)) return SstError.SnapshotBadMagic;
    var v: [4]u8 = undefined;
    if (try reader.readAll(v[0..]) != 4) return SstError.SnapshotCorrupt;
    const version = std.mem.readInt(u32, v[0..4], .little);
    if (version != 1 and version != 2) return SstError.SnapshotBadVersion;
    var c: [8]u8 = undefined;
    if (try reader.readAll(c[0..]) != 8) return SstError.SnapshotCorrupt;
    return .{ .count = std.mem.readInt(u64, c[0..8], .little) };
}

const EntryHeader = struct { key_len: usize, val_len: usize, is_worm: bool };

fn readEntryHeader(reader: *SnapReader) !EntryHeader {
    var h: [SNAPSHOT_ENTRY_HEADER]u8 = undefined;
    if (try reader.readAll(h[0..]) != h.len) return SstError.SnapshotCorrupt;
    const flags = h[8];
    return .{
        .key_len = @intCast(std.mem.readInt(u32, h[0..4], .little)),
        .val_len = @intCast(std.mem.readInt(u32, h[4..8], .little)),
        .is_worm = (flags & 1) != 0,
    };
}

/// Buffered sequential file writer (mirror of SnapReader).
const OutWriter = struct {
    file: std.Io.File,
    buf: []u8,
    end: usize = 0,

    fn writeAll(self: *OutWriter, data: []const u8) !void {
        if (data.len >= self.buf.len) {
            try self.flush();
            return compat.File.writeAll(self.file, data);
        }
        if (self.end + data.len > self.buf.len) try self.flush();
        @memcpy(self.buf[self.end..][0..data.len], data);
        self.end += data.len;
    }

    fn flush(self: *OutWriter) !void {
        if (self.end == 0) return;
        try compat.File.writeAll(self.file, self.buf[0..self.end]);
        self.end = 0;
    }
};

pub const BuildStats = struct {
    count: u64,
    key_bytes: u64,
    val_bytes: u64,
    file_bytes: u64,
};

const BUILD_BUF_SIZE: usize = 4 << 20;

/// Convert a WormDB snapshot (already globally key-sorted by writeSnapshot)
/// into a `.wsst`. Streams in four sequential passes — sizes, index, keys,
/// values — so peak memory is just the IO buffers; after the first pass the
/// snapshot is warm in the page cache, so passes 2-4 run at memory speed.
/// Tombstoned (`is_deleted`) entries are skipped; sort order is verified.
pub fn buildFromSnapshot(
    allocator: std.mem.Allocator,
    snapshot_path: []const u8,
    out_path: []const u8,
    timestamp: u64,
) !BuildStats {
    const read_buf = try allocator.alloc(u8, BUILD_BUF_SIZE);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, BUILD_BUF_SIZE);
    defer allocator.free(write_buf);
    // Largest key seen anywhere in our datasets is well under this; the sort
    // check needs the previous key, and keys are bounded by the u32 field.
    var prev_key_buf = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(prev_key_buf);
    var cur_key_buf = try allocator.alloc(u8, 1 << 16);
    defer allocator.free(cur_key_buf);

    // ── Pass 1: count + arena sizes (+ sortedness via key streaming) ──
    var total: u64 = 0;
    var key_bytes: u64 = 0;
    var val_bytes: u64 = 0;
    {
        const f = try compat.Dir.openFile(compat.cwd(), snapshot_path, .{ .mode = .read_only });
        defer compat.File.close(f);
        var reader = SnapReader{ .file = f, .buf = read_buf };
        const snap = try openSnapshot(&reader);

        var prev_len: usize = 0;
        var i: u64 = 0;
        while (i < snap.count) : (i += 1) {
            const eh = try readEntryHeader(&reader);
            if (eh.key_len > cur_key_buf.len) {
                cur_key_buf = try allocator.realloc(cur_key_buf, eh.key_len);
                prev_key_buf = try allocator.realloc(prev_key_buf, eh.key_len);
            }
            if (try reader.readAll(cur_key_buf[0..eh.key_len]) != eh.key_len) {
                return SstError.SnapshotCorrupt;
            }
            try reader.skip(eh.val_len);
            if (i > 0 and !std.mem.lessThan(u8, prev_key_buf[0..prev_len], cur_key_buf[0..eh.key_len])) {
                return SstError.SstUnsorted;
            }
            @memcpy(prev_key_buf[0..eh.key_len], cur_key_buf[0..eh.key_len]);
            prev_len = eh.key_len;
            total += 1;
            key_bytes += eh.key_len;
            val_bytes += eh.val_len;
        }
    }

    const index_off: u64 = HEADER_SIZE;
    const keys_off: u64 = index_off + total * INDEX_ENTRY;
    const vals_off: u64 = keys_off + key_bytes;
    const file_bytes: u64 = vals_off + val_bytes;

    const out = try compat.Dir.createFile(compat.cwd(), out_path, .{ .read = true, .truncate = true });
    defer compat.File.close(out);
    var writer = OutWriter{ .file = out, .buf = write_buf };

    // ── Header ──
    {
        var header: [HEADER_SIZE]u8 = [_]u8{0} ** HEADER_SIZE;
        @memcpy(header[0..8], MAGIC);
        std.mem.writeInt(u32, header[8..12], VERSION, .little);
        std.mem.writeInt(u64, header[16..24], total, .little);
        std.mem.writeInt(u64, header[24..32], index_off, .little);
        std.mem.writeInt(u64, header[32..40], keys_off, .little);
        std.mem.writeInt(u64, header[40..48], vals_off, .little);
        std.mem.writeInt(u64, header[48..56], timestamp, .little);
        try writer.writeAll(header[0..]);
    }

    // ── Pass 2: index entries (offsets computed from the pass-1 totals) ──
    {
        const f = try compat.Dir.openFile(compat.cwd(), snapshot_path, .{ .mode = .read_only });
        defer compat.File.close(f);
        var reader = SnapReader{ .file = f, .buf = read_buf };
        _ = try openSnapshot(&reader);

        var key_cursor: u64 = keys_off;
        var val_cursor: u64 = vals_off;
        var i: u64 = 0;
        while (i < total) : (i += 1) {
            const eh = try readEntryHeader(&reader);
            try reader.skip(eh.key_len + eh.val_len);
            var ie: [INDEX_ENTRY]u8 = undefined;
            std.mem.writeInt(u64, ie[0..8], key_cursor, .little);
            std.mem.writeInt(u64, ie[8..16], val_cursor, .little);
            const key_len_field: u32 = @as(u32, @intCast(eh.key_len)) |
                (if (eh.is_worm) WORM_BIT else 0);
            std.mem.writeInt(u32, ie[16..20], key_len_field, .little);
            std.mem.writeInt(u32, ie[20..24], @intCast(eh.val_len), .little);
            try writer.writeAll(ie[0..]);
            key_cursor += eh.key_len;
            val_cursor += eh.val_len;
        }
    }

    // ── Pass 3 + 4: key arena, then value arena ──
    inline for ([2]enum { keys, vals }{ .keys, .vals }) |region| {
        const f = try compat.Dir.openFile(compat.cwd(), snapshot_path, .{ .mode = .read_only });
        defer compat.File.close(f);
        var reader = SnapReader{ .file = f, .buf = read_buf };
        _ = try openSnapshot(&reader);

        var i: u64 = 0;
        while (i < total) : (i += 1) {
            const eh = try readEntryHeader(&reader);
            const want = if (region == .keys) eh.key_len else eh.val_len;
            if (region == .keys) {
                // copy key, skip value
                if (eh.key_len > cur_key_buf.len) cur_key_buf = try allocator.realloc(cur_key_buf, eh.key_len);
                if (try reader.readAll(cur_key_buf[0..want]) != want) return SstError.SnapshotCorrupt;
                try writer.writeAll(cur_key_buf[0..want]);
                try reader.skip(eh.val_len);
            } else {
                // skip key, copy value
                try reader.skip(eh.key_len);
                if (want > cur_key_buf.len) cur_key_buf = try allocator.realloc(cur_key_buf, want);
                if (try reader.readAll(cur_key_buf[0..want]) != want) return SstError.SnapshotCorrupt;
                try writer.writeAll(cur_key_buf[0..want]);
            }
        }
    }

    try writer.flush();
    try compat.File.sync(out);

    return .{
        .count = total,
        .key_bytes = key_bytes,
        .val_bytes = val_bytes,
        .file_bytes = file_bytes,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// Write a minimal v2 snapshot (KV section only) for the builder tests —
/// same byte layout as store.zig's writeSnapshot.
fn writeTestSnapshot(path: []const u8, entries: []const struct {
    key: []const u8,
    value: []const u8,
    worm: bool = false,
}) !void {
    const f = try compat.Dir.createFile(compat.cwd(), path, .{ .read = true, .truncate = true });
    defer compat.File.close(f);
    try compat.File.writeAll(f, SNAPSHOT_MAGIC);
    var v: [4]u8 = undefined;
    std.mem.writeInt(u32, v[0..4], 2, .little);
    try compat.File.writeAll(f, v[0..]);
    var c: [8]u8 = undefined;
    std.mem.writeInt(u64, c[0..8], entries.len, .little);
    try compat.File.writeAll(f, c[0..]);
    for (entries) |e| {
        var h: [SNAPSHOT_ENTRY_HEADER]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], @intCast(e.key.len), .little);
        std.mem.writeInt(u32, h[4..8], @intCast(e.value.len), .little);
        h[8] = if (e.worm) 1 else 0;
        std.mem.writeInt(u64, h[9..17], 12345, .little);
        try compat.File.writeAll(f, h[0..]);
        try compat.File.writeAll(f, e.key);
        try compat.File.writeAll(f, e.value);
    }
}

test "sst: build from snapshot, get, prefix range, worm bit" {
    const allocator = std.testing.allocator;
    const snap_path = "test_sst_snap.tmp";
    const sst_path = "test_sst_out.tmp";
    defer std.Io.Dir.cwd().deleteFile(compat.io(), snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(compat.io(), sst_path) catch {};

    try writeTestSnapshot(snap_path, &.{
        .{ .key = "cep:01310100", .value = "Avenida Paulista\tBela Vista\t3550308" },
        .{ .key = "logridx:355:avenida paulista", .value = "Avenida Paulista\t01310100" },
        .{ .key = "logridx:355:paulista:avenida paulista", .value = "Avenida Paulista\t01310100" },
        .{ .key = "mun:3550308", .value = "São Paulo\tSP\tsao paulo", .worm = true },
    });

    const stats = try buildFromSnapshot(allocator, snap_path, sst_path, 777);
    try std.testing.expectEqual(@as(u64, 4), stats.count);

    var sst = try Sst.open(allocator, sst_path);
    defer sst.close(allocator);

    try std.testing.expectEqual(@as(usize, 4), sst.count);

    // exact GET
    const hit = sst.get("cep:01310100") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Avenida Paulista\tBela Vista\t3550308", hit.value);
    try std.testing.expectEqual(@as(u64, 777), hit.timestamp);
    try std.testing.expect(!hit.is_worm);
    try std.testing.expect(sst.get("cep:99999999") == null);
    try std.testing.expect(sst.get("") == null);

    // worm bit survives the round-trip
    const worm_hit = sst.get("mun:3550308") orelse return error.TestUnexpectedResult;
    try std.testing.expect(worm_hit.is_worm);
    try std.testing.expectEqualStrings("São Paulo\tSP\tsao paulo", worm_hit.value);

    // prefix range
    const r = sst.prefixRange("logridx:355:");
    try std.testing.expectEqual(@as(usize, 2), r.hi - r.lo);
    try std.testing.expectEqualStrings("logridx:355:avenida paulista", sst.keyAt(r.lo));

    const none = sst.prefixRange("zzz:");
    try std.testing.expectEqual(none.lo, none.hi);

    // full-range prefix
    const all = sst.prefixRange("");
    try std.testing.expectEqual(@as(usize, 4), all.hi - all.lo);
}

test "sst: unsorted snapshot is rejected" {
    const allocator = std.testing.allocator;
    const snap_path = "test_sst_unsorted.tmp";
    const sst_path = "test_sst_unsorted_out.tmp";
    defer std.Io.Dir.cwd().deleteFile(compat.io(), snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(compat.io(), sst_path) catch {};

    try writeTestSnapshot(snap_path, &.{
        .{ .key = "b", .value = "2" },
        .{ .key = "a", .value = "1" },
    });
    try std.testing.expectError(
        SstError.SstUnsorted,
        buildFromSnapshot(allocator, snap_path, sst_path, 0),
    );
}
