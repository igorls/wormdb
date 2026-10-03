//! Built-in CHAT_SEND procedure
//!
//! Atomic chat message: generates unique key, stores message, publishes to channel.
//!
//! When authenticated (SCT token):
//!   EXEC chat_send <room> <message>        (username from ctx.identity())
//!
//! When unauthenticated (backward compatible):
//!   EXEC chat_send <room> <username> <message>
//!
//! - Stores as: chat:<room>:<timestamp_ms>:<random_hex> = {"user":"...","text":"...","ts":...}
//! - Returns the generated key

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const Config = @import("../core/config.zig").Config;
const EventBus = @import("../event/mod.zig").EventBus;
const Store = @import("../storage/store.zig").Store;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const room = ctx.arg(0) orelse return ctx.err("chat_send: missing room arg");

    // Identity-aware: if authenticated, username comes from token
    const identity = ctx.identity();
    const username: []const u8 = if (identity) |id| id else (ctx.arg(1) orelse return ctx.err("chat_send: missing username arg"));
    const message: []const u8 = if (identity != null)
        (ctx.arg(1) orelse return ctx.err("chat_send: missing message arg"))
    else
        (ctx.arg(2) orelse return ctx.err("chat_send: missing message arg"));

    // Generate timestamp + random suffix for unique, sortable key
    const ts = ctx.timestamp();
    const rand = ctx.randomHex(4); // 8 hex chars

    // Copy rand before fmt overwrites the buffer
    var rand_copy: [8]u8 = undefined;
    @memcpy(rand_copy[0..rand.len], rand);

    // Build key: chat:<room>:<ts>:<rand>
    const key = ctx.fmt("chat:{s}:{d}:{s}", .{ room, ts, rand_copy[0..rand.len] });

    // Copy key before building value (fmt reuses buffer)
    const key_dupe = try ctx.allocator.dupe(u8, key);

    // Build message JSON value
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(ctx.allocator, "{\"user\":\"");
    try appendJsonEscaped(&json, ctx.allocator, username);
    try json.appendSlice(ctx.allocator, "\",\"text\":\"");
    try appendJsonEscaped(&json, ctx.allocator, message);
    try json.appendSlice(ctx.allocator, "\",\"ts\":");
    var ts_buf: [20]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{ts}) catch "0";
    try json.appendSlice(ctx.allocator, ts_str);
    try json.append(ctx.allocator, '}');
    const value = try json.toOwnedSlice(ctx.allocator);

    // Store durably (WAL-backed — survives restarts)
    ctx.lockKey(key_dupe);
    try ctx.setDurable(key_dupe, value);

    const channel = try std.fmt.allocPrint(ctx.allocator, "chat:{s}", .{room});
    ctx.publish(channel, value);

    // Return the key so the client has a reference
    return ctx.value(key_dupe);
}

/// Escape a string for safe JSON embedding.
fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try list.appendSlice(alloc, "\\u00");
                    const hex = "0123456789abcdef";
                    try list.append(alloc, hex[c >> 4]);
                    try list.append(alloc, hex[c & 0x0f]);
                } else {
                    try list.append(alloc, c);
                }
            },
        }
    }
}

test "chat_send publishes stored message to room channel" {
    const testing = std.testing;

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Capture = struct {
        buf: []u8,
        len: usize = 0,

        fn write(raw: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const n = @min(self.buf.len, data.len);
            @memcpy(self.buf[0..n], data[0..n]);
            self.len = n;
        }
    };

    var capture = Capture{ .buf = try testing.allocator.alloc(u8, 1024) };
    defer testing.allocator.free(capture.buf);
    _ = try bus.subscribe("chat:lobby", Capture.write, @ptrCast(&capture));

    var ctx = Ctx.init(&store, &.{ "lobby", "ada", "hello" }, arena, null, null, &bus, null);
    defer ctx.deinit();

    const result = try execute(&ctx);
    try testing.expect(result == .value);
    try testing.expect(capture.len > 0);

    const event = capture.buf[0..capture.len];
    try testing.expect(std.mem.startsWith(u8, event, ">EVENT chat:lobby\r\n"));
    try testing.expect(std.mem.containsAtLeast(u8, event, 1, "\"user\":\"ada\""));
    try testing.expect(std.mem.containsAtLeast(u8, event, 1, "\"text\":\"hello\""));
}
