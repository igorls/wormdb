//! Built-in CHAT_HISTORY procedure
//!
//! Load recent messages for a chat room.
//! EXEC chat_history <room> [limit]
//!
//! - Scans keys with prefix chat:<room>:
//! - Returns JSON array of messages, sorted chronologically (oldest first)
//! - Default limit: 50, max: 200
//! - Each message: {"user":"...","text":"...","ts":...}
//!
//! The key format `chat:<room>:<timestamp>:<random>` ensures lexicographic
//! sorting equals chronological ordering.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;

const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 200;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const room = ctx.arg(0) orelse return ctx.err("chat_history requires at least 1 arg: <room> [limit]");

    // Parse optional limit
    var limit: usize = DEFAULT_LIMIT;
    if (ctx.argInt(usize, 1)) |l| {
        limit = @min(l, MAX_LIMIT);
        if (limit == 0) limit = DEFAULT_LIMIT;
    }

    // Build prefix: chat:<room>:
    const prefix = try std.fmt.allocPrint(ctx.allocator, "chat:{s}:", .{room});

    // Scan for matching messages (already sorted by key = chronological)
    const results = try ctx.scan(prefix, limit);

    // Build JSON response — values are already JSON objects from chat_send
    // We return them as a JSON array directly
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(ctx.allocator, '[');

    for (results, 0..) |r, i| {
        if (i > 0) try json.append(ctx.allocator, ',');
        // r.value is already a JSON object from chat_send: {"user":"...","text":"...","ts":...}
        try json.appendSlice(ctx.allocator, r.value);
    }

    try json.append(ctx.allocator, ']');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}
