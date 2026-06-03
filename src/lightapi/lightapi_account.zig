//! Light-API `/account` = accinfo + balances, assembled server-side in one round-trip.
//! EXEC lightapi_account <chain> <account>
//!
//! Reads the account's accinfo fragment from the frozen segment (`accinfo` table) and its packed
//! balances (segment or KV), then emits the cc32d9 `/account` shape: the accinfo body with
//! `"balances":[…]` spliced in last. The chain block (KV `lacfg:<chain>`) is shared, not stored
//! per account.

const std = @import("std");
const Ctx = @import("../procedures/context.zig").Ctx;
const balances = @import("lightapi_balances.zig");
const name = @import("name.zig");
const tables = @import("tables.zig");
const accinfo_bin = @import("accinfo_bin.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("lightapi_account requires <chain> <account>");
    const account = ctx.arg(1) orelse return ctx.err("lightapi_account requires <chain> <account>");
    const a = ctx.allocator;

    const chain_json = (try ctx.getCopy(ctx.fmt("lacfg:{s}", .{chain}))) orelse "{}";
    // Live overlay (KV `acci:<chain>:<acct>`) shadows the frozen segment baseline.
    const frag: ?[]const u8 = blk: {
        if (try ctx.getCopy(ctx.fmt("acci:{s}:{s}", .{ chain, account }))) |o| break :blk o;
        if (ctx.store.frozen_segment) |s| break :blk s.lookup(tables.accinfo, name.encode(account));
        break :blk null;
    };
    const pb = try balances.packedBalances(ctx, chain, account);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(a, "{\"account_name\":\"");
    try json.appendSlice(a, account);
    try json.appendSlice(a, "\",\"chain\":");
    try json.appendSlice(a, chain_json);

    if (frag) |f| {
        // Get the accinfo fragment as JSON: render the binary record, or use the JSON directly.
        var rendered: std.ArrayListUnmanaged(u8) = .empty;
        defer rendered.deinit(a);
        const body: []const u8 = if (accinfo_bin.isBinary(f)) blk: {
            accinfo_bin.render(&rendered, a, f) catch break :blk f; // on corruption fall through
            break :blk rendered.items;
        } else f;
        if (body.len > 0 and body[body.len - 1] == '}') {
            // Splice `,"balances":[…]` before the fragment's closing brace (balances last).
            try json.append(a, ',');
            try json.appendSlice(a, body[0 .. body.len - 1]);
            try json.appendSlice(a, ",\"balances\":");
            try balances.appendBalancesArray(&json, a, pb);
            try json.append(a, '}');
            return ctx.value(try json.toOwnedSlice(a));
        }
    }

    // Fallback (no accinfo fragment): minimal empty accinfo shape + balances.
    try json.appendSlice(a, ",\"resources\":null,\"permissions\":[],\"delegated_to\":[],\"delegated_from\":[],\"linkauth\":[],\"balances\":");
    try balances.appendBalancesArray(&json, a, pb);
    try json.append(a, '}');
    return ctx.value(try json.toOwnedSlice(a));
}
