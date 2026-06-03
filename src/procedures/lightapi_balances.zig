//! Light-API `/balances` as a compiled procedure.
//!
//! EXEC lightapi_balances <chain> <account>
//!
//! Assembles the cc32d9 `{account_name, chain, balances:[...]}` shape server-side in one round-trip.
//! Uses an O(1) per-account lookup (fair vs an indexed `find({scope})`) of a packed balance list, then
//! formats the JSON next to the data — no application tier, no per-lookup marshaling.
//!
//! Key layout (loaded once, e.g. from a snapshot):
//!   bal:<chain>:<account>   -> packed balances, one per line:
//!                              "<contract>\t<symbol>\t<decimals>\t<amount>\n..."
//!   lacfg:<chain>           -> the `chain{}` JSON block (static per chain)

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const name = @import("../core/name.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("lightapi_balances requires <chain> <account>");
    const account = ctx.arg(1) orelse return ctx.err("lightapi_balances requires <chain> <account>");

    const a = ctx.allocator;

    // Chain block: a small per-chain value, kept in KV (getCopy → arena-owned).
    const chain_json = (try ctx.getCopy(ctx.fmt("lacfg:{s}", .{chain}))) orelse "{}";
    // Packed balances: from the frozen segment (O(log n) binary search by name
    // u64, slice borrowed from the mmap) when attached, else the KV store.
    const packed_bals = try packedBalances(ctx, chain, account);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(a, "{\"account_name\":\"");
    try appendJsonEscaped(&json, a, account);
    try json.appendSlice(a, "\",\"chain\":");
    try json.appendSlice(a, chain_json);
    try json.appendSlice(a, ",\"balances\":");
    try appendBalancesArray(&json, a, packed_bals);
    try json.append(a, '}');
    return ctx.value(try json.toOwnedSlice(a));
}

/// Fetch an account's packed balance list — from the frozen Light-API segment
/// (binary search by Antelope `name` u64, slice borrowed from the mmap) when one
/// is attached, otherwise from the KV store (arena-owned copy). Shared by
/// lightapi_tokenbalance and lightapi_account.
pub fn packedBalances(ctx: *Ctx, chain: []const u8, account: []const u8) !?[]const u8 {
    if (ctx.store.lightapi_segment) |s| {
        return s.lookup(.balances, name.encode(account));
    }
    return ctx.getCopy(ctx.fmt("bal:{s}:{s}", .{ chain, account }));
}

/// Append the cc32d9 balances `[...]` array (built from the packed per-account list) to `json`.
/// Shared with lightapi_account (which splices it into the accinfo body).
pub fn appendBalancesArray(json: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, packed_bals: ?[]const u8) !void {
    try json.append(a, '[');
    if (packed_bals) |pb| {
        var first = true;
        var lines = std.mem.splitScalar(u8, pb, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // line = "<contract>\t<symbol>\t<decimals>\t<amount>"
            var f = std.mem.splitScalar(u8, line, '\t');
            const contract = f.next() orelse continue;
            const symbol = f.next() orelse continue;
            const decimals = f.next() orelse continue;
            const amount = f.next() orelse continue;

            if (!first) try json.append(a, ',');
            first = false;
            try json.appendSlice(a, "{\"contract\":\"");
            try appendJsonEscaped(json, a, contract);
            try json.appendSlice(a, "\",\"currency\":\"");
            try appendJsonEscaped(json, a, symbol);
            try json.appendSlice(a, "\",\"decimals\":\"");
            try appendJsonEscaped(json, a, decimals);
            try json.appendSlice(a, "\",\"amount\":\"");
            try appendJsonEscaped(json, a, amount);
            try json.appendSlice(a, "\"}");
        }
    }
    try json.append(a, ']');
}

/// Escape a string for safe JSON embedding (mirrors scan.zig).
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
