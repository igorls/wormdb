//! Light-API `/account` = accinfo + balances, assembled server-side in one round-trip.
//! EXEC lightapi_account <chain> <account>
//!
//! The accinfo body (`{account_name, chain, resources, permissions, …}`) is stored under
//! `acci:<chain>:<account>`; this procedure splices the `balances` array (built from the packed
//! `bal:<chain>:<account>` list) into it — the cc32d9 `/account` shape, no app tier.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const balances = @import("lightapi_balances.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("lightapi_account requires <chain> <account>");
    const account = ctx.arg(1) orelse return ctx.err("lightapi_account requires <chain> <account>");
    const a = ctx.allocator;

    const acci = try ctx.getCopy(ctx.fmt("acci:{s}:{s}", .{ chain, account }));
    const pb = try ctx.getCopy(ctx.fmt("bal:{s}:{s}", .{ chain, account }));

    var json: std.ArrayListUnmanaged(u8) = .empty;
    if (acci) |body| if (body.len > 0 and body[body.len - 1] == '}') {
        // Splice `,"balances":[...]` before the accinfo body's closing brace.
        try json.appendSlice(a, body[0 .. body.len - 1]);
        try json.appendSlice(a, ",\"balances\":");
        try balances.appendBalancesArray(&json, a, pb);
        try json.append(a, '}');
        return ctx.value(try json.toOwnedSlice(a));
    };

    // Fallback (no stored accinfo): minimal {account_name, chain, balances}.
    const chain_json = (try ctx.getCopy(ctx.fmt("lacfg:{s}", .{chain}))) orelse "{}";
    try json.appendSlice(a, "{\"account_name\":\"");
    try json.appendSlice(a, account);
    try json.appendSlice(a, "\",\"chain\":");
    try json.appendSlice(a, chain_json);
    try json.appendSlice(a, ",\"balances\":");
    try balances.appendBalancesArray(&json, a, pb);
    try json.append(a, '}');
    return ctx.value(try json.toOwnedSlice(a));
}
