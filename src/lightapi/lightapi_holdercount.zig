//! Light-API `/holdercount/CHAIN/CONTRACT/SYM` — plain-text holder count (or "0").
//! EXEC lightapi_holdercount <chain> <contract> <symbol>
//!
//! Counts the lines in the token's `token_holders` segment entry. A KV override (`hc:<chain>:…`,
//! e.g. from a precompute/feed) wins if present, for forward-compat.

const std = @import("std");
const Ctx = @import("../procedures/context.zig").Ctx;
const topholders = @import("lightapi_topholders.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("need <chain> <contract> <symbol>");
    const contract = ctx.arg(1) orelse return ctx.err("need <chain> <contract> <symbol>");
    const symbol = ctx.arg(2) orelse return ctx.err("need <chain> <contract> <symbol>");

    // KV override first (precompute/feed), else count the segment token_holders lines.
    if (try ctx.getCopy(ctx.fmt("hc:{s}:{s}:{s}", .{ chain, contract, symbol }))) |v| {
        return ctx.value(v);
    }
    var count: usize = 0;
    if (topholders.holderLines(ctx, contract, symbol)) |lines| {
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            if (line.len != 0) count += 1;
        }
    }
    return ctx.value(ctx.fmt("{d}", .{count}));
}
