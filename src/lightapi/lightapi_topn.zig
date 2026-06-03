//! Generic Light-API top-N — serves /topholders, /topram, /topstake from a precomputed packed list.
//! EXEC lightapi_topn <key> <N> [fmt]
//!
//! The list (KV `<key>` = "acct\tv1[\tv2]\n…", value-desc, top-1000) is materialized at load time.
//! `fmt` selects the cc32d9 row shape (the three endpoints differ):
//!   "s"  -> [["acct","v1"],…]   (topholders: amount is a quoted string)
//!   "n"  -> [["acct",v1],…]     (topram: ram_bytes is a bare integer)
//!   "nn" -> [["acct",v1,v2],…]  (topstake: [acct, cpu_weight, net_weight], bare integers)
//! N must be in [10,1000] (else the cc32d9 plain-text "Invalid count: N"). O(N) slice.

const std = @import("std");
const Ctx = @import("../procedures/context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse return ctx.err("lightapi_topn requires <key> <N> [fmt]");
    const n_str = ctx.arg(1) orelse return ctx.err("lightapi_topn requires <key> <N> [fmt]");
    const fmt = ctx.arg(2) orelse "s";
    const a = ctx.allocator;

    const n = std.fmt.parseInt(usize, n_str, 10) catch 0;
    if (n < 10 or n > 1000) {
        return ctx.value(ctx.fmt("Invalid count: {s}", .{n_str}));
    }
    const quote = std.mem.eql(u8, fmt, "s"); // quote v1 (topholders amount)
    const two = std.mem.eql(u8, fmt, "nn"); // emit a second value (topstake net)

    const packed_list = try ctx.getCopy(key);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(a, '[');
    if (packed_list) |pt| {
        var i: usize = 0;
        var lines = std.mem.splitScalar(u8, pt, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (i >= n) break;
            var f = std.mem.splitScalar(u8, line, '\t');
            const acct = f.next() orelse continue;
            const v1 = f.next() orelse continue;
            if (i > 0) try json.append(a, ',');
            i += 1;
            try json.appendSlice(a, "[\"");
            try json.appendSlice(a, acct);
            try json.appendSlice(a, "\",");
            if (quote) try json.append(a, '"');
            try json.appendSlice(a, v1);
            if (quote) try json.append(a, '"');
            if (two) {
                const v2 = f.next() orelse "0";
                try json.append(a, ',');
                try json.appendSlice(a, v2);
            }
            try json.append(a, ']');
        }
    }
    try json.append(a, ']');
    return ctx.value(try json.toOwnedSlice(a));
}
