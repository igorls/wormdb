//! AtomicAssets live overlay — KV-tier shadow of the frozen AA segment (WP-011).
//!
//! The frozen segment (table ids 11..=21) is the snapshot baseline; live mint/transfer/burn deltas are
//! applied as KV keys that shadow it, exactly like the Light-API feed shadows its segment with `bal:`/
//! `acci:` keys. Overlay state is durable (WAL + snapshot) and replicated because it lives in the KV tier.
//!
//! Keys:
//!   aa:f:<asset_id>  -> the asset's FORWARD OVERRIDE: the asset forward blob (segment FWD byte layout;
//!                       value[0] = version 1) for a live asset, or the single byte 0x00 for a tombstone
//!                       (burned). Absent -> fall through to base FWD(11).
//!   aa:o:<owner>     -> the owner's overlay ADD-SET: asset_ids added to this owner since the base (mints +
//!                       transfer-ins), packed [u64 LE × n]. Removals fall out of the re-validation spine
//!                       at read time, so no rem-set is needed for page reads.

const std = @import("std");
const binfmt = @import("binfmt.zig");
const Store = @import("../storage/store.zig").Store;

pub const FWD_PREFIX = "aa:f:"; // aa:f:<asset_id>
pub const OWNER_PREFIX = "aa:o:"; // aa:o:<owner>

/// The single-byte tombstone marker (asset blobs start with version byte 1, so 0x00 never collides).
pub const TOMB: []const u8 = &[_]u8{0};

pub fn fwdKey(a: std.mem.Allocator, asset_id: u64) ![]const u8 {
    return std.fmt.allocPrint(a, FWD_PREFIX ++ "{d}", .{asset_id});
}
pub fn ownerKey(a: std.mem.Allocator, owner: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, OWNER_PREFIX ++ "{s}", .{owner});
}

pub fn isTomb(value: []const u8) bool {
    return value.len == 1 and value[0] == 0;
}

/// Build a fresh asset forward record (core fields + empty attr lists) — a mint override. 41 bytes:
/// version(1) owner(8) coll(8) schema(8) template_id(4) block_num(4) template_mint(4) + 2×u16 attr counts.
pub fn encodeAssetCore(
    a: std.mem.Allocator,
    owner: u64,
    collection: u64,
    schema: u64,
    template_id: i32,
    block_num: u32,
    template_mint: u32,
) ![]u8 {
    const b = try a.alloc(u8, 41);
    @memset(b, 0);
    b[0] = 1; // version
    std.mem.writeInt(u64, b[1..9], owner, .little);
    std.mem.writeInt(u64, b[9..17], collection, .little);
    std.mem.writeInt(u64, b[17..25], schema, .little);
    std.mem.writeInt(i32, b[25..29], template_id, .little);
    std.mem.writeInt(u32, b[29..33], block_num, .little);
    std.mem.writeInt(u32, b[33..37], template_mint, .little);
    // b[37..41] = two u16 zero attr counts (already zeroed)
    return b;
}

/// Copy a live asset blob with its owner field (offset 1, u64) replaced — a transfer override.
pub fn withOwner(a: std.mem.Allocator, blob: []const u8, new_owner: u64) ![]u8 {
    const out = try a.dupe(u8, blob);
    std.mem.writeInt(u64, out[1..9], new_owner, .little);
    return out;
}

/// Resolve an asset's CURRENT forward blob: the overlay override (`aa:f:<id>`) wins; else the base
/// segment FWD(11). Returns null if the asset is tombstoned (burned) or unknown. The override copy is
/// allocator-owned; a base hit is borrowed from the mmap (valid for the request). The single arbiter of
/// current state — the re-validation spine reads through this so stale base postings are harmless.
pub fn currentAsset(store: *Store, a: std.mem.Allocator, id: u64) !?[]const u8 {
    const fk = try fwdKey(a, id);
    if (try store.getValueDupe(fk, a)) |override| {
        if (isTomb(override)) return null;
        return override;
    }
    const seg = store.atomicassets_segment orelse return null;
    return seg.lookup(@enumFromInt(binfmt.TableId.fwd), id);
}

// ── add-set (packed [u64 LE]) ──
pub fn addCount(value: []const u8) usize {
    return value.len / 8;
}
pub fn addId(value: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, value[i * 8 ..][0..8], .little);
}
pub fn addContains(value: []const u8, id: u64) bool {
    var i: usize = 0;
    while (i < addCount(value)) : (i += 1) {
        if (addId(value, i) == id) return true;
    }
    return false;
}
/// Append `id` (dedup), returning a new arena-owned value.
pub fn addAppend(a: std.mem.Allocator, value: []const u8, id: u64) ![]u8 {
    if (addContains(value, id)) return a.dupe(u8, value);
    const out = try a.alloc(u8, value.len + 8);
    @memcpy(out[0..value.len], value);
    std.mem.writeInt(u64, out[value.len..][0..8], id, .little);
    return out;
}
/// Remove `id`, returning a new arena-owned value (a copy if absent).
pub fn addRemove(a: std.mem.Allocator, value: []const u8, id: u64) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < addCount(value)) : (i += 1) {
        const x = addId(value, i);
        if (x != id) {
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, x, .little);
            try out.appendSlice(a, &b);
        }
    }
    return out.toOwnedSlice(a);
}

// ── Tests ──
const testing = std.testing;

test "forward override: tomb marker vs live blob" {
    try testing.expect(isTomb(TOMB));
    try testing.expect(!isTomb(&[_]u8{1})); // version byte
    const a = testing.allocator;
    const blob = try encodeAssetCore(a, 100, 200, 300, 7, 9, 3);
    defer a.free(blob);
    try testing.expect(!isTomb(blob));
    const asset = binfmt.decodeAsset(blob).?;
    try testing.expectEqual(@as(u64, 100), asset.owner);
    try testing.expectEqual(@as(i32, 7), asset.template_id);
    try testing.expectEqual(@as(u32, 3), asset.template_mint);
    const moved = try withOwner(a, blob, 999);
    defer a.free(moved);
    try testing.expectEqual(@as(u64, 999), binfmt.decodeAsset(moved).?.owner);
    try testing.expectEqual(@as(u64, 200), binfmt.decodeAsset(moved).?.collection); // other fields kept
}

test "add-set append/remove/contains" {
    const a = testing.allocator;
    const v: []u8 = try a.dupe(u8, "");
    defer a.free(v);
    const v1 = try addAppend(a, v, 1000);
    defer a.free(v1);
    const v2 = try addAppend(a, v1, 1001);
    defer a.free(v2);
    const v2b = try addAppend(a, v2, 1001); // dedup
    defer a.free(v2b);
    try testing.expectEqual(@as(usize, 2), addCount(v2b));
    try testing.expect(addContains(v2b, 1000) and addContains(v2b, 1001) and !addContains(v2b, 9));
    const v3 = try addRemove(a, v2b, 1000);
    defer a.free(v3);
    try testing.expectEqual(@as(usize, 1), addCount(v3));
    try testing.expectEqual(@as(u64, 1001), addId(v3, 0));
}

test {
    testing.refAllDecls(@This());
}
