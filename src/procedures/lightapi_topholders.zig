//! Light-API `/topholders/CHAIN/CONTRACT/SYM/N` — `[["acct","amount"],…]`, top N by amount.
//! EXEC lightapi_topholders <chain> <contract> <symbol> <N>
//!
//! Reads a precomputed top-1000 packed list (`th:<chain>:<contract>:<symbol>` = "acct\tamount\n…",
//! amount-desc) and emits the first N as the cc32d9 JSON array. N must be in [10,1000].

const std = @import("std");
const Ctx = @import("context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("need <chain> <contract> <symbol> <N>");
    const contract = ctx.arg(1) orelse return ctx.err("need <chain> <contract> <symbol> <N>");
    const symbol = ctx.arg(2) orelse return ctx.err("need <chain> <contract> <symbol> <N>");
    const n_str = ctx.arg(3) orelse return ctx.err("need <chain> <contract> <symbol> <N>");
    const a = ctx.allocator;

    const n = std.fmt.parseInt(usize, n_str, 10) catch 0;
    if (n < 10 or n > 1000) {
        return ctx.value(ctx.fmt("Invalid count: {s}", .{n_str}));
    }

    const packed_top = try ctx.getCopy(ctx.fmt("th:{s}:{s}:{s}", .{ chain, contract, symbol }));

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(a, '[');
    if (packed_top) |pt| {
        var i: usize = 0;
        var lines = std.mem.splitScalar(u8, pt, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (i >= n) break;
            var f = std.mem.splitScalar(u8, line, '\t');
            const acct = f.next() orelse continue;
            const amount = f.next() orelse continue;
            if (i > 0) try json.append(a, ',');
            i += 1;
            try json.appendSlice(a, "[\"");
            try json.appendSlice(a, acct);
            try json.appendSlice(a, "\",\"");
            try json.appendSlice(a, amount);
            try json.appendSlice(a, "\"]");
        }
    }
    try json.append(a, ']');
    return ctx.value(try json.toOwnedSlice(a));
}
