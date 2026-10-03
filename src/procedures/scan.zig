//! Built-in SCAN procedure
//!
//! Scans keys by prefix, returning matching entries as JSON.
//! EXEC scan <prefix> [limit] [cut]
//!
//! - prefix: key prefix to match (e.g., "chat:general:", "user:")
//! - limit: max results (default: 100, max: 1000)
//! - cut: which end of the ascending match set the limit keeps —
//!   "last" (default; newest-last for timestamp-keyed data) or
//!   "first" (autocomplete / forward pagination)
//! - Returns JSON array: [{"k":"key","v":"value","ts":1709...}, ...]
//! - Results sorted by key ascending (lexicographic order)

const std = @import("std");
const Ctx = @import("context.zig").Ctx;

const DEFAULT_LIMIT: usize = 100;
const MAX_LIMIT: usize = 1000;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const prefix = ctx.arg(0) orelse return ctx.err("scan requires at least 1 arg: <prefix> [limit] [cut]");

    // Parse optional limit
    var limit: usize = DEFAULT_LIMIT;
    if (ctx.argInt(usize, 1)) |l| {
        limit = @min(l, MAX_LIMIT);
        if (limit == 0) limit = DEFAULT_LIMIT;
    }

    // Parse optional cut ("last" default, "first" for autocomplete).
    var keep_first = false;
    if (ctx.arg(2)) |cut| {
        if (std.mem.eql(u8, cut, "first")) {
            keep_first = true;
        } else if (!std.mem.eql(u8, cut, "last")) {
            return ctx.err("scan cut must be 'first' or 'last'");
        }
    }

    // Execute prefix scan (arena-allocated, safe after shard unlock)
    const results = if (keep_first)
        try ctx.scanFirst(prefix, limit)
    else
        try ctx.scan(prefix, limit);

    // Build JSON response
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(ctx.allocator, '[');

    for (results, 0..) |r, i| {
        if (i > 0) try json.append(ctx.allocator, ',');
        try json.appendSlice(ctx.allocator, "{\"k\":\"");
        try appendJsonEscaped(&json, ctx.allocator, r.key);
        try json.appendSlice(ctx.allocator, "\",\"v\":\"");
        try appendJsonEscaped(&json, ctx.allocator, r.value);
        try json.appendSlice(ctx.allocator, "\",\"ts\":");
        var ts_buf: [20]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{r.timestamp}) catch "0";
        try json.appendSlice(ctx.allocator, ts_str);
        try json.append(ctx.allocator, '}');
    }

    try json.append(ctx.allocator, ']');
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
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
                    // Control character — emit as \u00XX
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
