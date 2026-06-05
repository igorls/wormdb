//! AtomicAssets `assets` as compiled procedures (read path over the frozen segment).
//!
//! EXEC atomicassets_assets_by_owner <owner> [limit]
//!
//! Page-1 (newest-first) of an owner's assets, assembled server-side from the mmap'd AtomicAssets
//! segment in one round-trip: BY_OWNER(12) posting head -> FWD(11) decode -> JSON. No application tier.
//!
//! This is the first AtomicAssets endpoint served by WormDB itself (WP-010 Phase B). The shape is a
//! minimal asset core; the full eosio-contract-api shape (resolved `data`, collection/schema/template
//! objects) and the live overlay are later packages.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const name = @import("../core/name.zig");
const aa = @import("../atomicassets/binfmt.zig");
const ov = @import("../atomicassets/overlay.zig");

const MAX_LIMIT: usize = 100;

/// EXEC atomicassets_assets_by_owner <owner> [limit]
/// Page-1 (newest-first) of an owner's CURRENT assets: the base BY_OWNER posting head merged with the live
/// overlay (per-owner add-set), each candidate validated against the current forward record (overlay
/// override → base) — the re-validation spine, so a transferred-out/burned asset drops out without any
/// posting surgery.
pub fn byOwner(ctx: *Ctx) anyerror!Ctx.Result {
    const owner = ctx.arg(0) orelse
        return ctx.err("atomicassets_assets_by_owner requires <owner> [limit]");
    var limit: usize = ctx.argInt(usize, 1) orelse MAX_LIMIT;
    if (limit == 0 or limit > MAX_LIMIT) limit = MAX_LIMIT;

    const seg = ctx.store.atomicassets_segment orelse
        return ctx.err("no atomicassets segment attached");
    const a = ctx.allocator;
    const target = name.encode(owner);

    // Candidate asset_ids (newest-first): the base posting head (fetch the full head for over-scan
    // headroom past stale candidates) ∪ the overlay add-set (mints + transfer-ins since the base).
    var cand: std.ArrayListUnmanaged(u64) = .empty;
    defer cand.deinit(a);
    if (seg.lookup(@enumFromInt(aa.TableId.by_owner), target)) |posting| {
        var head: [MAX_LIMIT]u64 = undefined;
        const n = aa.postingHead(posting, head[0..]);
        try cand.appendSlice(a, head[0..n]);
    }
    if (try ctx.getCopy(try ov.ownerKey(a, owner))) |add| {
        var i: usize = 0;
        while (i < ov.addCount(add)) : (i += 1) try cand.append(a, ov.addId(add, i));
    }
    std.mem.sort(u64, cand.items, {}, std.sort.desc(u64));

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(a, "{\"success\":true,\"data\":[");
    var nbuf: [13]u8 = undefined;
    var first = true;
    var emitted: usize = 0;
    var prev: u64 = 0;
    var has_prev = false;
    for (cand.items) |asset_id| {
        if (has_prev and asset_id == prev) continue; // dedup (the list is sorted)
        has_prev = true;
        prev = asset_id;
        if (emitted >= limit) break;

        // Resolve current state (overlay override → base) and validate ownership.
        const blob = (try ov.currentAsset(ctx.store, a, asset_id)) orelse continue; // tombstoned / unknown
        const asset = aa.decodeAsset(blob) orelse continue;
        if (asset.owner != target) continue; // transferred away → drop the stale base candidate

        emitted += 1;
        if (!first) try json.append(a, ',');
        first = false;
        try json.appendSlice(a, "{\"asset_id\":\"");
        try appendU64(&json, a, asset_id);
        try json.appendSlice(a, "\",\"owner\":\"");
        try json.appendSlice(a, name.decode(asset.owner, &nbuf));
        try json.appendSlice(a, "\",\"collection_name\":\"");
        try json.appendSlice(a, name.decode(asset.collection, &nbuf));
        try json.appendSlice(a, "\",\"schema_name\":\"");
        try json.appendSlice(a, name.decode(asset.schema, &nbuf));
        try json.appendSlice(a, "\",\"template_id\":");
        if (asset.template_id < 0) {
            try json.appendSlice(a, "null");
        } else {
            try appendI64(&json, a, asset.template_id);
        }
        try json.appendSlice(a, ",\"template_mint\":");
        try appendU64(&json, a, asset.template_mint);
        try json.append(a, '}');
    }

    try json.appendSlice(a, "]}");
    return ctx.value(try json.toOwnedSlice(a));
}

fn appendU64(json: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: u64) !void {
    var b: [20]u8 = undefined;
    try json.appendSlice(a, std.fmt.bufPrint(&b, "{d}", .{v}) catch "0");
}

fn appendI64(json: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: anytype) !void {
    var b: [21]u8 = undefined;
    try json.appendSlice(a, std.fmt.bufPrint(&b, "{d}", .{v}) catch "0");
}

// ── Tests ──

const testing = std.testing;
const Store = @import("../storage/store.zig").Store;
const Segment = @import("../storage/segment.zig").Segment;
const compat = @import("../core/compat.zig");

const SegEntry = struct { key: u64, val: []const u8 };
const SegTable = struct { id: u32, entries: []const SegEntry };

fn wle(comptime T: type, b: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try b.appendSlice(a, &buf);
}

/// Build an asset forward record (core fields + empty attr lists), matching aa_binfmt::encode_asset.
fn makeAsset(a: std.mem.Allocator, owner: []const u8, coll: []const u8, schema: []const u8, tid: i32, block: u32, mint: u32) ![]u8 {
    var b: std.ArrayListUnmanaged(u8) = .empty;
    errdefer b.deinit(a);
    try b.append(a, 1); // version
    try wle(u64, &b, a, name.encode(owner));
    try wle(u64, &b, a, name.encode(coll));
    try wle(u64, &b, a, name.encode(schema));
    try wle(i32, &b, a, tid);
    try wle(u32, &b, a, block);
    try wle(u32, &b, a, mint);
    try wle(u16, &b, a, 0); // immutable attr count
    try wle(u16, &b, a, 0); // mutable attr count
    return b.toOwnedSlice(a);
}

/// Write a multi-table `.wseg` (WSEG0001) for tests. Entries must be sorted by key per table.
fn buildSeg(a: std.mem.Allocator, tables: []const SegTable) ![]u8 {
    const HDR: usize = 40;
    const DIR: usize = 48;
    const IDX: usize = 20;
    var total: usize = HDR + DIR * tables.len;
    for (tables) |t| {
        total += IDX * t.entries.len;
        for (t.entries) |e| total += e.val.len;
    }
    var out = try a.alloc(u8, total);
    @memset(out, 0);
    @memcpy(out[0..8], "WSEG0001");
    std.mem.writeInt(u32, out[8..12], 1, .little); // version
    std.mem.writeInt(u32, out[16..20], @intCast(tables.len), .little); // table_count

    var cursor: usize = HDR + DIR * tables.len;
    var di: usize = HDR;
    for (tables) |t| {
        const index_off = cursor;
        const index_len = IDX * t.entries.len;
        const blob_off = index_off + index_len;
        var boff: usize = 0;
        var ii = index_off;
        for (t.entries) |e| {
            std.mem.writeInt(u64, out[ii..][0..8], e.key, .little);
            std.mem.writeInt(u64, out[ii + 8 ..][0..8], @intCast(boff), .little);
            std.mem.writeInt(u32, out[ii + 16 ..][0..4], @intCast(e.val.len), .little);
            @memcpy(out[blob_off + boff ..][0..e.val.len], e.val);
            boff += e.val.len;
            ii += IDX;
        }
        std.mem.writeInt(u32, out[di..][0..4], t.id, .little);
        std.mem.writeInt(u32, out[di + 4 ..][0..4], @intCast(IDX), .little); // key_stride
        std.mem.writeInt(u64, out[di + 8 ..][0..8], @intCast(t.entries.len), .little);
        std.mem.writeInt(u64, out[di + 16 ..][0..8], @intCast(index_off), .little);
        std.mem.writeInt(u64, out[di + 24 ..][0..8], @intCast(index_len), .little);
        std.mem.writeInt(u64, out[di + 32 ..][0..8], @intCast(blob_off), .little);
        std.mem.writeInt(u64, out[di + 40 ..][0..8], @intCast(boff), .little);
        di += DIR;
        cursor = blob_off + boff;
    }
    return out;
}

test "atomicassets_assets_by_owner serves an owner's newest assets from the segment" {
    const a = testing.allocator;

    const asset1000 = try makeAsset(a, "alice", "mycol", "mysch", 7, 100, 1);
    defer a.free(asset1000);
    const asset1001 = try makeAsset(a, "alice", "mycol", "mysch", 7, 100, 2);
    defer a.free(asset1001);
    // BY_OWNER[alice] RAW posting: [0][u32 2][u64 1000][u64 1001] (ascending; head = 1001, 1000 DESC)
    var posting: [21]u8 = undefined;
    posting[0] = 0;
    std.mem.writeInt(u32, posting[1..5], 2, .little);
    std.mem.writeInt(u64, posting[5..13], 1000, .little);
    std.mem.writeInt(u64, posting[13..21], 1001, .little);

    const fwd_entries = [_]SegEntry{ .{ .key = 1000, .val = asset1000 }, .{ .key = 1001, .val = asset1001 } };
    const owner_entries = [_]SegEntry{.{ .key = name.encode("alice"), .val = &posting }};
    const tables = [_]SegTable{
        .{ .id = aa.TableId.fwd, .entries = &fwd_entries },
        .{ .id = aa.TableId.by_owner, .entries = &owner_entries },
    };
    const seg_bytes = try buildSeg(a, &tables);
    defer a.free(seg_bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try compat.Dir.realPathAlloc(tmp.dir, a, ".");
    defer a.free(dir_path);
    const seg_path = try std.fmt.allocPrint(a, "{s}/aa.wseg", .{dir_path});
    defer a.free(seg_path);
    const sf = try compat.Dir.createFile(tmp.dir, "aa.wseg", .{});
    try compat.File.writeAll(sf, seg_bytes);
    compat.File.close(sf);
    var seg = try Segment.open(a, seg_path);
    defer seg.close(a);

    const wal_path = try std.fmt.allocPrint(a, "{s}/t.wal", .{dir_path});
    defer a.free(wal_path);
    const snap_path = try std.fmt.allocPrint(a, "{s}/t.snap", .{dir_path});
    defer a.free(snap_path);
    const wf = try compat.Dir.createFile(tmp.dir, "t.wal", .{});
    compat.File.close(wf);
    var store = try Store.init(a, .{ .wal_path = wal_path, .snapshot_path = snap_path, .sync_writes = false });
    defer store.deinit();
    store.attachAtomicAssetsSegment(&seg);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const args = [_][]const u8{"alice"};
    var ctx = Ctx.init(&store, &args, arena.allocator(), null, null, null, null);
    defer ctx.deinit();
    const json = (try byOwner(&ctx)).value.?;

    const at1001 = std.mem.indexOf(u8, json, "\"asset_id\":\"1001\"");
    const at1000 = std.mem.indexOf(u8, json, "\"asset_id\":\"1000\"");
    try testing.expect(at1001 != null and at1000 != null);
    try testing.expect(at1001.? < at1000.?); // newest (largest id) first
    try testing.expect(std.mem.indexOf(u8, json, "\"owner\":\"alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"collection_name\":\"mycol\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"schema_name\":\"mysch\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"template_id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"template_mint\":2") != null);

    // owner with no assets -> empty data array
    const args2 = [_][]const u8{"bob"};
    var ctx2 = Ctx.init(&store, &args2, arena.allocator(), null, null, null, null);
    defer ctx2.deinit();
    try testing.expectEqualStrings("{\"success\":true,\"data\":[]}", (try byOwner(&ctx2)).value.?);
}

test "byOwner reflects live mint/transfer/burn via the overlay" {
    const a = testing.allocator;
    const apply = @import("atomicassets_apply.zig");

    // segment baseline: alice owns 1000,1001; bob owns 2000.
    const a1000 = try makeAsset(a, "alice", "mycol", "mysch", 7, 100, 1);
    defer a.free(a1000);
    const a1001 = try makeAsset(a, "alice", "mycol", "mysch", 7, 100, 2);
    defer a.free(a1001);
    const a2000 = try makeAsset(a, "bob", "mycol", "mysch", 7, 100, 5);
    defer a.free(a2000);
    var p_alice: [21]u8 = undefined; // RAW posting [0][u32 2][1000][1001]
    p_alice[0] = 0;
    std.mem.writeInt(u32, p_alice[1..5], 2, .little);
    std.mem.writeInt(u64, p_alice[5..13], 1000, .little);
    std.mem.writeInt(u64, p_alice[13..21], 1001, .little);
    var p_bob: [13]u8 = undefined; // [0][u32 1][2000]
    p_bob[0] = 0;
    std.mem.writeInt(u32, p_bob[1..5], 1, .little);
    std.mem.writeInt(u64, p_bob[5..13], 2000, .little);

    const fwd_entries = [_]SegEntry{
        .{ .key = 1000, .val = a1000 },
        .{ .key = 1001, .val = a1001 },
        .{ .key = 2000, .val = a2000 },
    };
    var owner_entries = [_]SegEntry{
        .{ .key = name.encode("alice"), .val = &p_alice },
        .{ .key = name.encode("bob"), .val = &p_bob },
    };
    std.sort.pdq(SegEntry, &owner_entries, {}, struct {
        fn lt(_: void, x: SegEntry, y: SegEntry) bool {
            return x.key < y.key;
        }
    }.lt);
    const tables = [_]SegTable{
        .{ .id = aa.TableId.fwd, .entries = &fwd_entries },
        .{ .id = aa.TableId.by_owner, .entries = &owner_entries },
    };
    const seg_bytes = try buildSeg(a, &tables);
    defer a.free(seg_bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try compat.Dir.realPathAlloc(tmp.dir, a, ".");
    defer a.free(dir_path);
    const seg_path = try std.fmt.allocPrint(a, "{s}/aa.wseg", .{dir_path});
    defer a.free(seg_path);
    const sf = try compat.Dir.createFile(tmp.dir, "aa.wseg", .{});
    try compat.File.writeAll(sf, seg_bytes);
    compat.File.close(sf);
    var seg = try Segment.open(a, seg_path);
    defer seg.close(a);

    const wal_path = try std.fmt.allocPrint(a, "{s}/t.wal", .{dir_path});
    defer a.free(wal_path);
    const snap_path = try std.fmt.allocPrint(a, "{s}/t.snap", .{dir_path});
    defer a.free(snap_path);
    const wf = try compat.Dir.createFile(tmp.dir, "t.wal", .{});
    compat.File.close(wf);
    var store = try Store.init(a, .{ .wal_path = wal_path, .snapshot_path = snap_path, .sync_writes = false });
    defer store.deinit();
    store.attachAtomicAssetsSegment(&seg);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    const Run = struct {
        fn run(s: *Store, ara: std.mem.Allocator, proc: *const fn (*Ctx) anyerror!Ctx.Result, args: []const []const u8) ![]const u8 {
            var c = Ctx.init(s, args, ara, null, null, null, null);
            defer c.deinit();
            return switch (try proc(&c)) {
                .value => |v| v orelse "",
                .err => |e| {
                    std.debug.print("proc err: {s}\n", .{e});
                    return error.ProcErr;
                },
                else => "",
            };
        }
    };
    const has = struct {
        fn f(j: []const u8, id: []const u8) bool {
            return std.mem.indexOf(u8, j, id) != null;
        }
    }.f;

    // baseline
    const j0 = try Run.run(&store, ar, byOwner, &.{"alice"});
    try testing.expect(has(j0, "\"asset_id\":\"1001\"") and has(j0, "\"asset_id\":\"1000\""));

    // transfer 1000 alice -> bob
    _ = try Run.run(&store, ar, apply.transfer, &.{ "1000", "bob" });
    const ja = try Run.run(&store, ar, byOwner, &.{"alice"});
    try testing.expect(!has(ja, "\"asset_id\":\"1000\"") and has(ja, "\"asset_id\":\"1001\"")); // moved off alice
    const jb = try Run.run(&store, ar, byOwner, &.{"bob"});
    try testing.expect(has(jb, "\"asset_id\":\"2000\"") and has(jb, "\"asset_id\":\"1000\"")); // now under bob
    try testing.expect(std.mem.indexOf(u8, jb, "\"2000\"").? < std.mem.indexOf(u8, jb, "\"1000\"").?); // newest-first

    // burn 1001 -> alice empties (1000 already moved, 1001 burned)
    _ = try Run.run(&store, ar, apply.burn, &.{"1001"});
    try testing.expectEqualStrings("{\"success\":true,\"data\":[]}", try Run.run(&store, ar, byOwner, &.{"alice"}));

    // mint 3000 to alice -> appears newest-first with the minted fields
    _ = try Run.run(&store, ar, apply.mint, &.{ "3000", "alice", "newcol", "newsch", "9", "200", "1" });
    const jm = try Run.run(&store, ar, byOwner, &.{"alice"});
    try testing.expect(has(jm, "\"asset_id\":\"3000\"") and has(jm, "\"collection_name\":\"newcol\""));
}

test {
    testing.refAllDecls(@This());
}
