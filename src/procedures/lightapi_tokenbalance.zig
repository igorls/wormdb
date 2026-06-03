//! Light-API `/tokenbalance/CHAIN/ACCT/CONTRACT/SYM` — plain-text amount (or "0"), read from the
//! packed per-account balance list. EXEC lightapi_tokenbalance <chain> <account> <contract> <symbol>

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const balances = @import("lightapi_balances.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("need <chain> <account> <contract> <symbol>");
    const account = ctx.arg(1) orelse return ctx.err("need <chain> <account> <contract> <symbol>");
    const contract = ctx.arg(2) orelse return ctx.err("need <chain> <account> <contract> <symbol>");
    const symbol = ctx.arg(3) orelse return ctx.err("need <chain> <account> <contract> <symbol>");

    // Segment (by name u64) when attached, else KV — same source as /balances.
    const pb = try balances.packedBalances(ctx, chain, account);
    if (pb) |packed_list| {
        var lines = std.mem.splitScalar(u8, packed_list, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, '\t');
            const c = f.next() orelse continue;
            const s = f.next() orelse continue;
            _ = f.next() orelse continue; // decimals
            const amount = f.next() orelse continue;
            if (std.mem.eql(u8, c, contract) and std.mem.eql(u8, s, symbol)) {
                return ctx.value(amount);
            }
        }
    }
    return ctx.value("0");
}
