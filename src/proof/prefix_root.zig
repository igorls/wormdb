//! Deterministic prefix roots for compact anti-entropy checks.
//!
//! The root is over sorted `(key, value, is_worm, timestamp)` leaves for a
//! store prefix. It is diagnostic/repair metadata, not a replacement for
//! append-log checkpoint signatures.

const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const Config = @import("../core/config.zig").Config;

pub const ROOT_ALG = "prefix-sha256-v1";
pub const HASH_LEN = 32;
pub const Hash = [HASH_LEN]u8;

pub const Summary = struct {
    entry_count: usize,
    root: Hash,
};

pub fn compute(
    allocator: std.mem.Allocator,
    store: *Store,
    prefix: []const u8,
    first_limit: usize,
) !Summary {
    return computeInternal(allocator, store, prefix, if (first_limit == 0) null else first_limit);
}

pub fn computeFirstN(
    allocator: std.mem.Allocator,
    store: *Store,
    prefix: []const u8,
    first_count: usize,
) !Summary {
    return computeInternal(allocator, store, prefix, first_count);
}

fn computeInternal(
    allocator: std.mem.Allocator,
    store: *Store,
    prefix: []const u8,
    first_limit: ?usize,
) !Summary {
    if (first_limit != null and first_limit.? == 0) {
        return .{
            .entry_count = 0,
            .root = try merkleRoot(allocator, prefix, &.{}),
        };
    }

    const results = try store.scanPrefixFirst(prefix, first_limit orelse 0, allocator);
    defer freeScanResults(allocator, results);

    var leaves: std.ArrayListUnmanaged(Hash) = .empty;
    defer leaves.deinit(allocator);
    try leaves.ensureTotalCapacity(allocator, results.len);

    for (results) |r| {
        leaves.appendAssumeCapacity(leafHash(r));
    }

    return .{
        .entry_count = results.len,
        .root = try merkleRoot(allocator, prefix, leaves.items),
    };
}

fn leafHash(entry: Store.ScanResult) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("wormdb.prefix-root.leaf.v1");
    updateLenBytes(&h, entry.key);
    updateLenBytes(&h, entry.value);
    h.update(&[_]u8{if (entry.is_worm) 1 else 0});
    var ts_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ts_buf, entry.timestamp, .big);
    h.update(&ts_buf);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

fn merkleRoot(allocator: std.mem.Allocator, prefix: []const u8, leaves: []const Hash) !Hash {
    if (leaves.len == 0) {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("wormdb.prefix-root.empty.v1");
        updateLenBytes(&h, prefix);
        var out: Hash = undefined;
        h.final(&out);
        return out;
    }

    var level = try allocator.dupe(Hash, leaves);
    defer allocator.free(level);
    var len = level.len;
    while (len > 1) {
        var out_i: usize = 0;
        var in_i: usize = 0;
        while (in_i < len) {
            if (in_i + 1 == len) {
                level[out_i] = level[in_i];
                in_i += 1;
            } else {
                level[out_i] = nodeHash(level[in_i], level[in_i + 1]);
                in_i += 2;
            }
            out_i += 1;
        }
        len = out_i;
    }
    return level[0];
}

fn nodeHash(left: Hash, right: Hash) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("wormdb.prefix-root.node.v1");
    h.update(&left);
    h.update(&right);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}

fn updateLenBytes(h: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, bytes.len, .big);
    h.update(&len_buf);
    h.update(bytes);
}

fn freeScanResults(allocator: std.mem.Allocator, results: []Store.ScanResult) void {
    for (results) |r| {
        allocator.free(r.key);
        allocator.free(r.value);
    }
    allocator.free(results);
}

test "prefix root is deterministic across insert order" {
    const testing = std.testing;

    var a = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer a.deinit();
    var b = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer b.deinit();

    try a.setWithTimestamp("p:b", "two", true, 20);
    try a.setWithTimestamp("p:a", "one", true, 10);
    try b.setWithTimestamp("p:a", "one", true, 10);
    try b.setWithTimestamp("p:b", "two", true, 20);

    const root_a = try compute(testing.allocator, &a, "p:", 0);
    const root_b = try compute(testing.allocator, &b, "p:", 0);
    try testing.expectEqual(@as(usize, 2), root_a.entry_count);
    try testing.expectEqualSlices(u8, root_a.root[0..], root_b.root[0..]);
}

test "prefix root changes with timestamp or worm flag" {
    const testing = std.testing;

    var a = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer a.deinit();
    var b = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer b.deinit();

    try a.setWithTimestamp("p:a", "one", true, 10);
    try b.setWithTimestamp("p:a", "one", false, 11);

    const root_a = try compute(testing.allocator, &a, "p:", 0);
    const root_b = try compute(testing.allocator, &b, "p:", 0);
    try testing.expect(!std.mem.eql(u8, root_a.root[0..], root_b.root[0..]));
}
