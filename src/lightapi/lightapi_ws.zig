//! Helper procedures for the cc32d9 WebSocket JSON-RPC API (gateway.zig handleJsonRpc). Each returns
//! the raw row data the WS notifications stream; the gateway wraps them in the JSON-RPC envelope.

const std = @import("std");
const Ctx = @import("../procedures/context.zig").Ctx;
const name = @import("name.zig");
const tables = @import("tables.zig");
const balances = @import("lightapi_balances.zig");
const topholders = @import("lightapi_topholders.zig");

/// ws_balances <chain> <account> → `{"account":"<a>","balances":[{"contract","currency","amount"}]}`
/// (the WS get_balances row shape — no decimals field, unlike HTTP /balances).
pub fn balancesRow(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("need <chain> <account>");
    const account = ctx.arg(1) orelse return ctx.err("need <chain> <account>");
    const a = ctx.allocator;
    const pb = try balances.packedBalances(ctx, chain, account);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(a, "{\"account\":\"");
    try json.appendSlice(a, account);
    try json.appendSlice(a, "\",\"balances\":[");
    if (pb) |list| {
        var first = true;
        var lines = std.mem.splitScalar(u8, list, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var f = std.mem.splitScalar(u8, line, '\t');
            const contract = f.next() orelse continue;
            const symbol = f.next() orelse continue;
            _ = f.next() orelse continue; // decimals (omitted in WS shape)
            const amount = f.next() orelse continue;
            if (!first) try json.append(a, ',');
            first = false;
            try json.appendSlice(a, "{\"contract\":\"");
            try json.appendSlice(a, contract);
            try json.appendSlice(a, "\",\"currency\":\"");
            try json.appendSlice(a, symbol);
            try json.appendSlice(a, "\",\"amount\":\"");
            try json.appendSlice(a, amount);
            try json.appendSlice(a, "\"}");
        }
    }
    try json.appendSlice(a, "]}");
    return ctx.value(try json.toOwnedSlice(a));
}

/// ws_holders <contract> <symbol> → the token's holder lines ("account\tamount\n"…), or "".
/// The gateway streams one {account, amount} notification per line.
pub fn holderRows(ctx: *Ctx) anyerror!Ctx.Result {
    const contract = ctx.arg(0) orelse return ctx.err("need <contract> <symbol>");
    const symbol = ctx.arg(1) orelse return ctx.err("need <contract> <symbol>");
    const lines = topholders.holderLines(ctx, contract, symbol) orelse "";
    return ctx.value(lines);
}

/// ws_keyrows <pubkey> → the key's holder lines ("account\tperm\tweight\n"…), or "".
/// The gateway streams one {account_name, perm, weight, pubkey} notification per line.
pub fn keyRows(ctx: *Ctx) anyerror!Ctx.Result {
    const pubkey = ctx.arg(0) orelse return ctx.err("need <pubkey>");
    const seg = ctx.store.frozen_segment orelse return ctx.value("");
    const blob = seg.lookup(tables.pub_keys, name.keyHash(pubkey)) orelse return ctx.value("");
    return ctx.value(blob);
}
