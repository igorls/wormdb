//! Light-API `/topholders/CHAIN/CONTRACT/SYM/N` — `[["acct","amount"],…]`, top N holders by amount.
//! EXEC lightapi_topholders <chain> <contract> <symbol> <N>
//!
//! Reads the frozen `token_holders` segment table (per token, holders sorted amount-desc) and emits
//! the first N as the cc32d9 JSON array. N must be in [10,1000]. The shared `holderLines` helper
//! (segment lookup + collision-guarded header) is reused by /holdercount and the WS get_token_holders.

const std = @import("std");
const Ctx = @import("../procedures/context.zig").Ctx;
const name = @import("name.zig");
const tables = @import("tables.zig");

/// Return the holder lines ("acct\tamount\n"…, amount-desc) for a token from the segment's
/// token_holders table, or null if the token/table is absent. The blob is `[u16 hdr_len][hdr]` then
/// the lines; `hdr` = "contract:symbol" guards against the (astronomically rare) hash collision.
pub fn holderLines(ctx: *Ctx, contract: []const u8, symbol: []const u8) ?[]const u8 {
    const seg = ctx.store.frozen_segment orelse return null;
    const blob = seg.lookup(tables.token_holders, name.tokenKey(contract, symbol)) orelse return null;
    if (blob.len < 2) return null;
    const hdr_len = std.mem.readInt(u16, blob[0..2], .little);
    if (2 + @as(usize, hdr_len) > blob.len) return null;
    const hdr = blob[2 .. 2 + hdr_len];
    // verify "contract:symbol" (collision guard)
    const ok = hdr.len == contract.len + 1 + symbol.len and
        std.mem.startsWith(u8, hdr, contract) and hdr[contract.len] == ':' and
        std.mem.endsWith(u8, hdr, symbol);
    if (!ok) return null;
    return blob[2 + hdr_len ..];
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("need <chain> <contract> <symbol> <N>");
    _ = chain;
    const contract = ctx.arg(1) orelse return ctx.err("need <chain> <contract> <symbol> <N>");
    const symbol = ctx.arg(2) orelse return ctx.err("need <chain> <contract> <symbol> <N>");
    const n_str = ctx.arg(3) orelse return ctx.err("need <chain> <contract> <symbol> <N>");
    const a = ctx.allocator;

    const n = std.fmt.parseInt(usize, n_str, 10) catch 0;
    if (n < 10 or n > 1000) {
        return ctx.value(ctx.fmt("Invalid count: {s}", .{n_str}));
    }

    const lines = holderLines(ctx, contract, symbol);
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(a, '[');
    if (lines) |pt| {
        var i: usize = 0;
        var it = std.mem.splitScalar(u8, pt, '\n');
        while (it.next()) |line| {
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
