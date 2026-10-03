//! Built-in proof prefix root procedure.
//!
//! EXEC proof_prefix_root [prefix] [limit=<first_n>]
//!
//! Computes a deterministic compact root over sorted Store entries matching
//! `prefix`. `limit` keeps the first N sorted entries and is used by cluster
//! anti-entropy to prove that a peer's root is a prefix of local state before
//! sending only the missing tail.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const prefix_root = @import("../proof/prefix_root.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    var prefix: []const u8 = "";
    var first_limit: usize = 0;

    var i: usize = 0;
    if (i < ctx.argCount()) {
        const first = ctx.arg(i).?;
        if (!std.mem.startsWith(u8, first, "limit=")) {
            prefix = first;
            i += 1;
        }
    }

    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "limit=")) {
            first_limit = std.fmt.parseUnsigned(usize, arg["limit=".len..], 10) catch
                return ctx.err("proof_prefix_root: invalid limit=<first_n>");
        } else {
            return ctx.err("proof_prefix_root: unknown option");
        }
    }

    const summary = prefix_root.compute(ctx.allocator, ctx.store, prefix, first_limit) catch
        return ctx.err("proof_prefix_root: root computation failed");

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.appendSlice(ctx.allocator, "{\"root_alg\":\"");
    try json.appendSlice(ctx.allocator, prefix_root.ROOT_ALG);
    try json.appendSlice(ctx.allocator, "\",\"prefix_hex\":\"");
    try appendHexBytes(&json, ctx.allocator, prefix);
    try json.appendSlice(ctx.allocator, "\",\"entry_count\":");
    try appendUsize(&json, ctx.allocator, summary.entry_count);
    try json.appendSlice(ctx.allocator, ",\"root\":\"");
    try appendHexBytes(&json, ctx.allocator, summary.root[0..]);
    try json.appendSlice(ctx.allocator, "\"}");
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

fn appendHexBytes(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try list.append(allocator, alphabet[byte >> 4]);
        try list.append(allocator, alphabet[byte & 0x0f]);
    }
}

fn appendUsize(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: usize) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(allocator, s);
}

fn runProc(store: *@import("../storage/store.zig").Store, args: []const []const u8, allocator: std.mem.Allocator) !@import("../core/types.zig").Response {
    var ctx = Ctx.init(store, args, allocator, null, null, null, null);
    defer ctx.deinit();
    return try execute(&ctx);
}

test "proof_prefix_root returns full and limited roots" {
    const testing = std.testing;
    const Store = @import("../storage/store.zig").Store;
    const Config = @import("../core/config.zig").Config;

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();
    try store.setWithTimestamp("p:a", "one", true, 10);
    try store.setWithTimestamp("p:b", "two", true, 20);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const all = try runProc(&store, &.{"p:"}, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, all.value.?, 1, "\"entry_count\":2"));
    try testing.expect(std.mem.containsAtLeast(u8, all.value.?, 1, "\"root_alg\":\"prefix-sha256-v1\""));

    const limited = try runProc(&store, &.{ "p:", "limit=1" }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, limited.value.?, 1, "\"entry_count\":1"));
}
