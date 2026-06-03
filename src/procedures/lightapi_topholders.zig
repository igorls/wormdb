//! Light-API `/topholders/CHAIN/CONTRACT/SYM/N` — `[["acct","amount"],…]`, top N holders by amount.
//! EXEC lightapi_topholders <chain> <contract> <symbol> <N>
//!
//! Reads the frozen `token_holders` segment table (per token, holders sorted amount-desc) and emits
//! the first N as the cc32d9 JSON array. N must be in [10,1000]. The shared `holderLines` helper
//! (segment lookup + collision-guarded header) is reused by /holdercount and the WS get_token_holders.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const name = @import("../core/name.zig");

/// Locate a token's token_holders blob and return `.{ count, lines }` — the holder count (u32 in the
/// blob header, so /holdercount is O(1)) and the amount-desc holder lines ("acct\tamount\n"…). Returns
/// null if the token/table is absent. Blob = `[u16 hdr_len][hdr]["contract:symbol" collision guard]
/// [u32 count][lines]`.
const TokenHolders = struct { count: u32, lines: []const u8 };
fn lookupToken(ctx: *Ctx, contract: []const u8, symbol: []const u8) ?TokenHolders {
    const seg = ctx.store.lightapi_segment orelse return null;
    const blob = seg.lookup(.token_holders, name.tokenKey(contract, symbol)) orelse return null;
    if (blob.len < 2) return null;
    const hdr_len = std.mem.readInt(u16, blob[0..2], .little);
    const after_hdr = 2 + @as(usize, hdr_len);
    if (after_hdr + 4 > blob.len) return null;
    const hdr = blob[2..after_hdr];
    // verify "contract:symbol" (collision guard)
    const ok = hdr.len == contract.len + 1 + symbol.len and
        std.mem.startsWith(u8, hdr, contract) and hdr[contract.len] == ':' and
        std.mem.endsWith(u8, hdr, symbol);
    if (!ok) return null;
    const count = std.mem.readInt(u32, blob[after_hdr..][0..4], .little);
    return .{ .count = count, .lines = blob[after_hdr + 4 ..] };
}

/// The amount-desc holder lines for a token, or null. (topholders / WS get_token_holders.)
pub fn holderLines(ctx: *Ctx, contract: []const u8, symbol: []const u8) ?[]const u8 {
    return if (lookupToken(ctx, contract, symbol)) |t| t.lines else null;
}

/// The holder count for a token — O(1) from the blob header. (holdercount.)
pub fn holderCount(ctx: *Ctx, contract: []const u8, symbol: []const u8) ?u32 {
    return if (lookupToken(ctx, contract, symbol)) |t| t.count else null;
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
