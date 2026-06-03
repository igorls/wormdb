//! Frozen segment — a read-only, externally-built, memory-mapped columnar store
//! for large *static* datasets (the Light-API-at-WAX tables).
//!
//! The generic `Store` (sharded `StringHashMap(*Entry)`) pays ~130–160 B of
//! fixed overhead per key — an `Entry` struct, a duplicated key, a value
//! allocation, and a hashmap slot — across three heap allocations. At WAX scale
//! (tens of millions of accounts) that overhead alone is many GB, and the
//! pre-rendered-JSON values multiply it. A frozen segment sidesteps all of it:
//!
//!   * keys are the natural Antelope `name` u64 (no string keys, no hashing of
//!     ASCII), held in one contiguous **sorted index** (16 B/entry) — binary
//!     search, zero per-entry allocation;
//!   * values live back-to-back in a **blob arena**, referenced by (off,len);
//!   * the whole file is **mmap'd** read-only, so resident memory is the working
//!     set the OS pages in — not the entire dataset — and boot is just `mmap`.
//!
//! The file is built offline (see hyperion-tools `wseg-build`) so there is no
//! write path here: open, look up, close. Small/aggregate values (chain block,
//! counts, top-N lists) stay in the normal KV store; only the huge per-account
//! tables live in a segment.
//!
//! On-disk format (all integers little-endian) — see docs/WSEG_FORMAT.md:
//!   Header (40 B): magic "WSEG0001" | version u32 | flags u32 | table_count u32
//!                  | _pad u32 | meta_off u64 | meta_len u64
//!   Table directory: table_count × 48 B:
//!     table_id u32 | key_stride u32 | key_count u64
//!     | index_off u64 | index_len u64 | blob_off u64 | blob_len u64
//!   Index region (per table): key_count × 20 B, sorted by key asc:
//!     key u64 | off u64 (into table's blob) | len u32
//!   Blob region (per table): concatenated payloads.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../core/compat.zig");

pub const MAGIC = "WSEG0001";
pub const VERSION: u32 = 1;

const HEADER_FIXED: usize = 40; // up to and including meta_off/meta_len
const DIR_ENTRY: usize = 48;
const INDEX_ENTRY: usize = 20; // key u64 | off u64 | len u32
const MAX_TABLES: usize = 16;

/// Stable table identifiers. The builder and reader must agree on these.
pub const TableId = enum(u32) {
    balances = 0, // holder name -> packed "<contract>\t<symbol>\t<dec>\t<amount>\n..."
    resources = 1, // (reserved) account -> binary resources
    perms = 2, // (reserved) account -> binary permission list
    delband_from = 3, // (reserved) `from` -> delegations made
    delband_to = 4, // (reserved) `to` -> delegations received
    accinfo = 5, // account name -> cc32d9 accinfo fragment ("resources":…,"linkauth":[…][,"code":…]})
    token_holders = 6, // tokenKey(contract,symbol) -> [u16 hdr]["contract:symbol"] + "acct\tamount\n"… (amount-desc)
    pub_keys = 7, // fnv1a64(pubkey EOS|PUB_K1) -> "account\tperm\tweight\n"… (holders of that key)
    _,
};

pub const SegmentError = error{
    SegmentTooSmall,
    SegmentBadMagic,
    SegmentBadVersion,
    SegmentTooManyTables,
    SegmentTruncated,
    SegmentBadIndex,
    SegmentShortRead,
    SegmentEmpty,
};

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

pub const Segment = struct {
    bytes: []const u8,
    backing: Backing,
    tables: [MAX_TABLES]?Table = [_]?Table{null} ** MAX_TABLES,

    pub const Backing = enum { mmap, heap };

    const Table = struct {
        key_count: u64,
        index: []const u8, // key_count * INDEX_ENTRY, sorted by key asc
        blob: []const u8,
    };

    const Mapped = struct { bytes: []const u8, backing: Backing };

    /// Open and validate a segment file. The mapping (or heap buffer) is owned
    /// by the returned Segment until `close`.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Segment {
        const m = try mapFile(allocator, path);
        errdefer freeBytes(allocator, m.bytes, m.backing);
        const bytes = m.bytes;

        if (bytes.len < HEADER_FIXED) return SegmentError.SegmentTooSmall;
        if (!std.mem.eql(u8, bytes[0..8], MAGIC)) return SegmentError.SegmentBadMagic;
        if (rd32(bytes, 8) != VERSION) return SegmentError.SegmentBadVersion;
        const table_count = rd32(bytes, 16);
        if (table_count > MAX_TABLES) return SegmentError.SegmentTooManyTables;

        const dir_start = HEADER_FIXED;
        if (dir_start + @as(usize, table_count) * DIR_ENTRY > bytes.len) return SegmentError.SegmentTruncated;

        var seg = Segment{ .bytes = bytes, .backing = m.backing };
        var ti: usize = 0;
        while (ti < table_count) : (ti += 1) {
            const base = dir_start + ti * DIR_ENTRY;
            const table_id = rd32(bytes, base + 0);
            const key_count = rd64(bytes, base + 8);
            const index_off = rd64(bytes, base + 16);
            const index_len = rd64(bytes, base + 24);
            const blob_off = rd64(bytes, base + 32);
            const blob_len = rd64(bytes, base + 40);

            if (index_off + index_len > bytes.len) return SegmentError.SegmentTruncated;
            if (blob_off + blob_len > bytes.len) return SegmentError.SegmentTruncated;
            if (index_len != key_count * INDEX_ENTRY) return SegmentError.SegmentBadIndex;
            if (table_id >= MAX_TABLES) continue; // unknown table — ignore, stay forward-compatible

            seg.tables[table_id] = .{
                .key_count = key_count,
                .index = bytes[@intCast(index_off)..@intCast(index_off + index_len)],
                .blob = bytes[@intCast(blob_off)..@intCast(blob_off + blob_len)],
            };
        }
        return seg;
    }

    pub fn close(self: *Segment, allocator: std.mem.Allocator) void {
        freeBytes(allocator, self.bytes, self.backing);
        self.bytes = &.{};
        self.tables = [_]?Table{null} ** MAX_TABLES;
    }

    pub fn has(self: *const Segment, table: TableId) bool {
        return self.tables[@intFromEnum(table)] != null;
    }

    /// Number of keys in a table (0 if absent). `accinfo` key count = the account universe (every
    /// account has ≥1 permission) = cc32d9 `usercount`.
    pub fn keyCount(self: *const Segment, table: TableId) u64 {
        return if (self.tables[@intFromEnum(table)]) |t| t.key_count else 0;
    }

    /// Binary-search a table for `key`. Returns the borrowed blob slice (valid
    /// for the segment's lifetime — the mapping is never unmapped while
    /// serving) or null if the key (or table) is absent.
    pub fn lookup(self: *const Segment, table: TableId, key: u64) ?[]const u8 {
        const t = self.tables[@intFromEnum(table)] orelse return null;
        var lo: usize = 0;
        var hi: usize = @intCast(t.key_count);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = mid * INDEX_ENTRY;
            const k = rd64(t.index, e);
            if (k == key) {
                const off: usize = @intCast(rd64(t.index, e + 8));
                const len: usize = rd32(t.index, e + 16);
                if (off + len > t.blob.len) return null;
                return t.blob[off .. off + len];
            } else if (k < key) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return null;
    }

    // --- file mapping ---

    fn mapFile(allocator: std.mem.Allocator, path: []const u8) !Mapped {
        if (comptime builtin.os.tag == .windows) {
            // No mmap on the Windows single-node build — read the whole file.
            // (The WAX serving target is Linux; this keeps the reader testable
            // and usable on Windows, losing only the OS-paging RSS benefit.)
            const f = try compat.Dir.openFile(compat.cwd(), path, .{ .mode = .read_only });
            defer compat.File.close(f);
            const st = try compat.File.stat(f);
            const sz: usize = @intCast(st.size);
            if (sz == 0) return SegmentError.SegmentEmpty;
            const buf = try allocator.alloc(u8, sz);
            errdefer allocator.free(buf);
            var read: usize = 0;
            while (read < sz) {
                const n = try compat.File.readAll(f, buf[read..]);
                if (n == 0) break;
                read += n;
            }
            if (read != sz) return SegmentError.SegmentShortRead;
            return .{ .bytes = buf, .backing = .heap };
        } else {
            // `std.posix.open`/`fstat` were removed in Zig 0.16, but
            // `std.posix.mmap` remains and takes a raw fd — which the
            // cross-platform `std.Io.File` exposes as `.handle` on POSIX. So
            // open + size via the same compat IO the rest of the codebase uses,
            // then mmap the handle. The mapping outlives the fd on POSIX.
            const f = try compat.Dir.openFile(compat.cwd(), path, .{ .mode = .read_only });
            const st = compat.File.stat(f) catch |e| {
                compat.File.close(f);
                return e;
            };
            const sz: usize = @intCast(st.size);
            if (sz == 0) {
                compat.File.close(f);
                return SegmentError.SegmentEmpty;
            }
            const mem = std.posix.mmap(
                null,
                sz,
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                f.handle,
                0,
            ) catch |e| {
                compat.File.close(f);
                return e;
            };
            compat.File.close(f);
            return .{ .bytes = mem, .backing = .mmap };
        }
    }

    fn freeBytes(allocator: std.mem.Allocator, bytes: []const u8, backing: Backing) void {
        if (bytes.len == 0) return;
        switch (backing) {
            .heap => allocator.free(bytes),
            .mmap => {
                if (comptime builtin.os.tag != .windows) {
                    std.posix.munmap(@alignCast(bytes));
                }
            },
        }
    }
};

// ── Tests ──

/// Minimal in-memory writer used only by the tests below — the production
/// builder lives in hyperion-tools (Rust). Keeps the format honest from the
/// reader's own side and documents the byte layout.
const TestEntry = struct { key: u64, val: []const u8 };

fn buildOneTableSegment(
    allocator: std.mem.Allocator,
    table_id: u32,
    entries: []const TestEntry,
) ![]u8 {
    var blob: std.ArrayListUnmanaged(u8) = .empty;
    defer blob.deinit(allocator);
    var index: std.ArrayListUnmanaged(u8) = .empty;
    defer index.deinit(allocator);

    for (entries) |e| {
        const off: u64 = blob.items.len;
        const len: u32 = @intCast(e.val.len);
        try blob.appendSlice(allocator, e.val);
        var ib: [20]u8 = undefined;
        std.mem.writeInt(u64, ib[0..8], e.key, .little);
        std.mem.writeInt(u64, ib[8..16], off, .little);
        std.mem.writeInt(u32, ib[16..20], len, .little);
        try index.appendSlice(allocator, &ib);
    }

    const dir_start = HEADER_FIXED;
    const index_off = dir_start + DIR_ENTRY; // one table
    const blob_off = index_off + index.items.len;
    const total = blob_off + blob.items.len;

    var out = try allocator.alloc(u8, total);
    @memset(out, 0);
    @memcpy(out[0..8], MAGIC);
    std.mem.writeInt(u32, out[8..12], VERSION, .little);
    std.mem.writeInt(u32, out[12..16], 0, .little); // flags
    std.mem.writeInt(u32, out[16..20], 1, .little); // table_count
    std.mem.writeInt(u32, out[20..24], 0, .little); // pad
    std.mem.writeInt(u64, out[24..32], 0, .little); // meta_off
    std.mem.writeInt(u64, out[32..40], 0, .little); // meta_len
    // table dir entry
    std.mem.writeInt(u32, out[dir_start + 0 ..][0..4], table_id, .little);
    std.mem.writeInt(u32, out[dir_start + 4 ..][0..4], INDEX_ENTRY, .little);
    std.mem.writeInt(u64, out[dir_start + 8 ..][0..8], @intCast(entries.len), .little);
    std.mem.writeInt(u64, out[dir_start + 16 ..][0..8], @intCast(index_off), .little);
    std.mem.writeInt(u64, out[dir_start + 24 ..][0..8], @intCast(index.items.len), .little);
    std.mem.writeInt(u64, out[dir_start + 32 ..][0..8], @intCast(blob_off), .little);
    std.mem.writeInt(u64, out[dir_start + 40 ..][0..8], @intCast(blob.items.len), .little);
    @memcpy(out[index_off .. index_off + index.items.len], index.items);
    @memcpy(out[blob_off .. blob_off + blob.items.len], blob.items);
    return out;
}

test "segment round-trip via temp file" {
    const testing = std.testing;
    const name = @import("../core/name.zig");

    // Build a balances segment with keys that exercise the sorted-index search.
    var entries = [_]TestEntry{
        .{ .key = name.encode("a"), .val = "tok\tA\t4\t1.0000" },
        .{ .key = name.encode("eosio"), .val = "eosio.token\tWAX\t8\t10.00000000" },
        .{ .key = name.encode("waxupbitcold"), .val = "eosio.token\tWAX\t8\t999.99999999" },
        .{ .key = name.encode("zzz"), .val = "x\tY\t0\t7" },
    };
    // Index must be sorted by key ascending.
    std.sort.pdq(TestEntry, &entries, {}, struct {
        fn lt(_: void, x: TestEntry, y: TestEntry) bool {
            return x.key < y.key;
        }
    }.lt);

    const bytes = try buildOneTableSegment(testing.allocator, @intFromEnum(TableId.balances), &entries);
    defer testing.allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try compat.Dir.realPathAlloc(tmp.dir, testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const seg_path = try std.fmt.allocPrint(testing.allocator, "{s}/test.wseg", .{dir_path});
    defer testing.allocator.free(seg_path);

    const f = try compat.Dir.createFile(tmp.dir, "test.wseg", .{});
    try compat.File.writeAll(f, bytes);
    compat.File.close(f);

    var seg = try Segment.open(testing.allocator, seg_path);
    defer seg.close(testing.allocator);

    try testing.expect(seg.has(.balances));
    try testing.expect(!seg.has(.perms));
    try testing.expectEqualStrings(
        "eosio.token\tWAX\t8\t999.99999999",
        seg.lookup(.balances, name.encode("waxupbitcold")).?,
    );
    try testing.expectEqualStrings("tok\tA\t4\t1.0000", seg.lookup(.balances, name.encode("a")).?);
    try testing.expectEqualStrings("x\tY\t0\t7", seg.lookup(.balances, name.encode("zzz")).?);
    try testing.expect(seg.lookup(.balances, name.encode("missing")) == null);
    try testing.expect(seg.lookup(.resources, name.encode("a")) == null);
}

test "rejects a bad-magic file" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try compat.Dir.realPathAlloc(tmp.dir, testing.allocator, ".");
    defer testing.allocator.free(dir_path);
    const seg_path = try std.fmt.allocPrint(testing.allocator, "{s}/bad.wseg", .{dir_path});
    defer testing.allocator.free(seg_path);

    const f = try compat.Dir.createFile(tmp.dir, "bad.wseg", .{});
    try compat.File.writeAll(f, "NOTASEG!" ++ ([_]u8{0} ** 40));
    compat.File.close(f);

    try testing.expectError(SegmentError.SegmentBadMagic, Segment.open(testing.allocator, seg_path));
}

test {
    std.testing.refAllDecls(@This());
}
