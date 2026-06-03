//! Light-API `/status` — `OK`, or `OUT_OF_SYNC <chain>:<delay>;…` per lagging chain, computed at
//! request time over the feed-written `syncchains` (CSV of chains the feed manages). Mirrors the
//! cc32d9 / light-api status rollup; reuses lightapi_sync's request-time delay so a stalled feed
//! surfaces here too.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const sync = @import("lightapi_sync.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const a = ctx.allocator;
    const chains = (try ctx.getCopy("syncchains")) orelse return ctx.value("OK");

    var lagging: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, chains, ',');
    while (it.next()) |raw| {
        const chain = std.mem.trim(u8, raw, " \r\n");
        if (chain.len == 0) continue;
        const delay = sync.delaySecs(ctx, chain) orelse {
            try lagging.appendSlice(a, ctx.fmt(" {s}:0;", .{chain}));
            continue;
        };
        if (delay > sync.threshold(ctx, chain)) {
            try lagging.appendSlice(a, ctx.fmt(" {s}:{d};", .{ chain, delay }));
        }
    }
    if (lagging.items.len == 0) return ctx.value("OK");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "OUT_OF_SYNC");
    try out.appendSlice(a, lagging.items);
    return ctx.value(try out.toOwnedSlice(a));
}
