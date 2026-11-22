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

    // Build prefix: chat:<room>: using stack buffer for typical room names.
    var prefix_stack: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_stack, "chat:{s}:", .{room}) catch
        try std.fmt.allocPrint(ctx.allocator, "chat:{s}:", .{room});
    try ctx.requirePrefix(prefix, .read);

    // Scan for matching messages (already sorted by key = chronological)
    const results = try ctx.scan(prefix, limit);

    // Build JSON response — values are already JSON objects from chat_send.
    // Exact byte length is known up front, so allocate once and copy directly.
    var total_len: usize = 2 + (if (results.len > 1) results.len - 1 else 0);
    for (results) |r| total_len += r.value.len;
    const out = try ctx.allocator.alloc(u8, total_len);
    var pos: usize = 0;
    out[pos] = '[';
    pos += 1;
    for (results, 0..) |r, i| {
        if (i > 0) {
            out[pos] = ',';
            pos += 1;
        }
        @memcpy(out[pos..][0..r.value.len], r.value);
        pos += r.value.len;
    }
    out[pos] = ']';
    return ctx.value(out);
}
