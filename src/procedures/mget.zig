//! Built-in MGET procedure — batch key lookup in one round-trip.
//!
//! EXEC mget <key1> [<key2> ...]
//!
//! Fetches up to MAX_KEYS keys in a single request and returns a JSON array
//! aligned with the input argument order, using `null` for missing keys:
//!   ["val1",null,"val3"]

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const Store = @import("../storage/store.zig").Store;

pub const MAX_KEYS: usize = 2000;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const count = ctx.argCount();
    if (count == 0) return ctx.err("mget requires at least 1 key");
    if (count > MAX_KEYS) return ctx.err("mget exceeds max batch size (2000)");

    // Enforce read authorization on every requested key upfront.
    for (0..count) |i| {
        const key = ctx.arg(i).?;
        try ctx.requireRead(key);
    }

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(ctx.allocator, '[');

    for (0..count) |i| {
        if (i > 0) try json.append(ctx.allocator, ',');
        const key = ctx.arg(i).?;
        if (try ctx.getCopy(key)) |val| {
            try json.append(ctx.allocator, '"');
            try appendJsonEscaped(&json, ctx.allocator, val);
            try json.append(ctx.allocator, '"');
        } else {
            try json.appendSlice(ctx.allocator, "null");
        }
    }

    try json.append(ctx.allocator, ']');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    var chunk_start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 0x20) "" else null,
        };
        if (esc) |e| {
            if (i > chunk_start) {
                try list.appendSlice(alloc, s[chunk_start..i]);
            }
            if (e.len > 0) {
                try list.appendSlice(alloc, e);
            } else {
                const hex = "0123456789abcdef";
                const u_esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try list.appendSlice(alloc, &u_esc);
            }
            chunk_start = i + 1;
        }
    }
    if (chunk_start < s.len) {
        try list.appendSlice(alloc, s[chunk_start..]);
    }
}

test "mget returns values and nulls in input order" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, .{ .persistence = .none });
    defer store.deinit();

    try store.set("k:1", "alpha", false);
    try store.set("k:3", "gamma\nline", false);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const args = &[_][]const u8{ "k:1", "k:2", "k:3" };
    var ctx = Ctx.init(&store, args, arena.allocator(), null, null, null, null);
    defer ctx.deinit();

    const res = try execute(&ctx);
    try testing.expectEqualStrings("[\"alpha\",null,\"gamma\\nline\"]", res.value.?);
}
