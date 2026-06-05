//! AtomicAssets on-segment binary formats — the read subset.
//!
//! The frozen AtomicAssets `.wseg` segment (table ids 11..=21) is built by hyperion-tools
//! `crates/wseg-build` (`aa_tables.rs` / `aa_binfmt.rs`). This module ports the minimal DECODE path
//! WormDB needs to serve faceted reads from it: the hybrid posting-list *head* (page-1, newest-first)
//! and the asset forward record's core fields. All integers are little-endian and byte-match the Rust
//! builder. (Roaring-bitmap decode, attribute decode, and the live overlay are later packages.)

const std = @import("std");

/// AtomicAssets table ids in the shared segment namespace (Light-API owns 0..=10).
pub const TableId = struct {
    pub const fwd: u32 = 11; // asset_id -> asset forward record
    pub const by_owner: u32 = 12; // name(owner) -> posting of asset_ids
    pub const by_coll: u32 = 13; // name(collection) -> posting
    pub const by_schema: u32 = 14; // fnv1a64(coll \0 schema) -> posting
    pub const by_tmpl: u32 = 15; // template_id -> posting
    pub const data_attr: u32 = 16; // fnv1a64(coll \0 schema \0 field \0 value) -> posting
    pub const schemas: u32 = 17; // fnv1a64(coll \0 schema) -> schema format
    pub const sorted_id: u32 = 18; // sentinel 0 -> all asset_ids DESC
    pub const tmpl_fwd: u32 = 19; // template_id -> template immutable attrs
    pub const coll_fwd: u32 = 20; // name(collection) -> collection record (reserved)
    pub const sorted_tmpl: u32 = 21; // sentinel 0 -> (mint, asset_id) sorted
};

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}
fn rdi32(b: []const u8, off: usize) i32 {
    return std.mem.readInt(i32, b[off..][0..4], .little);
}

/// Write up to `out.len` of the NEWEST (largest) asset_ids from a hybrid posting blob into `out`,
/// DESCENDING, and return how many were written.
///
/// Hybrid posting format (`aa_binfmt::encode_posting_hybrid`): `[u8 format][u32 full_count]` then
///   format 0 RAW     : `[u64 × full_count]` ascending — the largest live at the TAIL.
///   format 1 ROARING : `[u32 head_n][u64 × head_n top-K DESC][roaring bytes]`.
/// Page-1 (newest-first) needs only the head — the top ids are the RAW tail or the ROARING head, both
/// stored uncompressed — so no roaring decoder is needed here.
pub fn postingHead(blob: []const u8, out: []u64) usize {
    if (blob.len < 5 or out.len == 0) return 0;
    const format = blob[0];
    const full: usize = rd32(blob, 1);
    if (format == 0) {
        // RAW: emit the tail (largest) in descending order.
        const n = @min(out.len, full);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = full - 1 - i; // (i+1)-th largest
            const off = 5 + idx * 8;
            if (off + 8 > blob.len) break;
            out[i] = rd64(blob, off);
        }
        return i;
    } else {
        // ROARING: the head is already top-K descending.
        if (blob.len < 9) return 0;
        const head_n: usize = rd32(blob, 5);
        const n = @min(out.len, head_n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const off = 9 + i * 8;
            if (off + 8 > blob.len) break;
            out[i] = rd64(blob, off);
        }
        return i;
    }
}

/// Total number of ids in a hybrid posting (the `full_count` field) — e.g. an owner's live asset count.
pub fn postingLen(blob: []const u8) u32 {
    if (blob.len < 5) return 0;
    return rd32(blob, 1);
}

/// The core (non-attribute) fields of an asset forward record. Byte layout from
/// `aa_binfmt::encode_asset`: `version(1) owner(u64) coll(u64) schema(u64) template_id(i32)
/// block_num(u32) template_mint(u32) | immutable attrs | mutable attrs`. Attrs are deferred.
pub const AssetCore = struct {
    owner: u64,
    collection: u64,
    schema: u64,
    template_id: i32, // -1 = no template
    block_num: u32,
    template_mint: u32,
};

pub fn decodeAsset(blob: []const u8) ?AssetCore {
    if (blob.len < 37) return null; // 1 + 8 + 8 + 8 + 4 + 4 + 4
    return .{
        .owner = rd64(blob, 1),
        .collection = rd64(blob, 9),
        .schema = rd64(blob, 17),
        .template_id = rdi32(blob, 25),
        .block_num = rd32(blob, 29),
        .template_mint = rd32(blob, 33),
    };
}

// ── Tests ──

const testing = std.testing;

fn writeLe(comptime T: type, buf: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try buf.appendSlice(a, &b);
}

test "postingHead RAW returns the largest ids descending" {
    const a = testing.allocator;
    var blob: std.ArrayListUnmanaged(u8) = .empty;
    defer blob.deinit(a);
    // RAW: [0][u32 count][u64 × count] ascending
    try blob.append(a, 0);
    const ids = [_]u64{ 10, 20, 30, 40, 50 }; // ascending, as the builder stores them
    try writeLe(u32, &blob, a, ids.len);
    for (ids) |id| try writeLe(u64, &blob, a, id);

    var out: [3]u64 = undefined;
    const n = postingHead(blob.items, &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u64, 50), out[0]); // newest first
    try testing.expectEqual(@as(u64, 40), out[1]);
    try testing.expectEqual(@as(u64, 30), out[2]);
    try testing.expectEqual(@as(u32, 5), postingLen(blob.items));

    // asking for more than present returns only what's there
    var out2: [10]u64 = undefined;
    try testing.expectEqual(@as(usize, 5), postingHead(blob.items, &out2));
    try testing.expectEqual(@as(u64, 10), out2[4]);
}

test "postingHead ROARING reads the descending head" {
    const a = testing.allocator;
    var blob: std.ArrayListUnmanaged(u8) = .empty;
    defer blob.deinit(a);
    // ROARING: [1][u32 full][u32 head_n][u64 × head_n DESC][roaring bytes…]
    try blob.append(a, 1);
    try writeLe(u32, &blob, a, 1000); // full_count (the roaring body, not read here)
    const head = [_]u64{ 999, 998, 997 }; // top-K, descending
    try writeLe(u32, &blob, a, head.len);
    for (head) |id| try writeLe(u64, &blob, a, id);
    try blob.appendSlice(a, "ROARINGBYTES"); // ignored by the head reader

    var out: [2]u64 = undefined;
    const n = postingHead(blob.items, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u64, 999), out[0]);
    try testing.expectEqual(@as(u64, 998), out[1]);
    try testing.expectEqual(@as(u32, 1000), postingLen(blob.items));
}

test "decodeAsset reads the core fields at the right offsets" {
    const a = testing.allocator;
    const name = @import("../core/name.zig");
    var blob: std.ArrayListUnmanaged(u8) = .empty;
    defer blob.deinit(a);
    try blob.append(a, 1); // version
    try writeLe(u64, &blob, a, name.encode("alice")); // owner @1
    try writeLe(u64, &blob, a, name.encode("mycol")); // collection @9
    try writeLe(u64, &blob, a, name.encode("mysch")); // schema @17
    try writeLe(i32, &blob, a, 7); // template_id @25
    try writeLe(u32, &blob, a, 409250749); // block_num @29
    try writeLe(u32, &blob, a, 1422); // template_mint @33
    try blob.appendSlice(a, &[_]u8{ 0, 0 }); // empty immutable+mutable attr counts (u16 each)

    const asset = decodeAsset(blob.items).?;
    try testing.expectEqual(name.encode("alice"), asset.owner);
    try testing.expectEqual(name.encode("mycol"), asset.collection);
    try testing.expectEqual(name.encode("mysch"), asset.schema);
    try testing.expectEqual(@as(i32, 7), asset.template_id);
    try testing.expectEqual(@as(u32, 1422), asset.template_mint);
    try testing.expect(decodeAsset("short") == null);
}

test {
    testing.refAllDecls(@This());
}
