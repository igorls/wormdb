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
    var json: std.ArrayListUnmanaged(u8) = .{};
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
