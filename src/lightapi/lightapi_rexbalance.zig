//! Light-API `/rexbalance/CHAIN/ACCT`. On rex-disabled chains (Libre) cc32d9 returns
//! `{account_name, chain}` with no `rex` field. EXEC lightapi_rexbalance <chain> <account>
//! (rex-enabled chains would add the computed `rex` block — not needed for the Libre matrix.)

const std = @import("std");
const Ctx = @import("../procedures/context.zig").Ctx;

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("need <chain> <account>");
    const account = ctx.arg(1) orelse return ctx.err("need <chain> <account>");
    const a = ctx.allocator;

    const chain_json = (try ctx.getCopy(ctx.fmt("lacfg:{s}", .{chain}))) orelse "{}";
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(a, "{\"account_name\":\"");
    try json.appendSlice(a, account);
    try json.appendSlice(a, "\",\"chain\":");
    try json.appendSlice(a, chain_json);
    try json.append(a, '}');
    return ctx.value(try json.toOwnedSlice(a));
}
