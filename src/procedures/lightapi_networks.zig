//! Light-API `/networks` — the array of configured chain blocks, each with LIVE
//! block_num/block_time/sync. EXEC lightapi_networks
//!
//! Iterates `lachains` (comma-separated chain names, seeded at startup) and emits `[<block>,…]` via
//! the shared lightapi_chain builder — so /networks reports the same live freshness the per-account
//! `chain{}` envelope does, instead of the static snapshot block.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const chainmod = @import("lightapi_chain.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const a = ctx.allocator;
    const chains = (try ctx.getCopy("lachains")) orelse return ctx.value("[]");

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(a, '[');
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, chains, ',');
    while (it.next()) |chain| {
        if (chain.len == 0) continue;
        const cb = (try chainmod.block(ctx, a, chain)) orelse continue;
        if (i > 0) try json.append(a, ',');
        i += 1;
        try json.appendSlice(a, cb);
    }
    try json.append(a, ']');
    return ctx.value(try json.toOwnedSlice(a));
}

test {
    std.testing.refAllDecls(@This());
}
