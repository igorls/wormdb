//! Light-API `/accinfo/CHAIN/ACCT` — assembled in-proc from the frozen segment.
//! EXEC lightapi_accinfo <chain> <account>
//!
//! The segment's `accinfo` table holds, per account, the cc32d9 accinfo body *minus* the
//! `{account_name, chain}` prefix (built offline by wseg-build, byte-identical to light-api). This
//! wraps it with the queried account name and the shared chain block (KV `lacfg:<chain>`) — so the
//! ~250 B chain block is stored once, not re-embedded 21.75M times, and there is no per-account
//! pre-rendered body sitting in RAM: the fragment is paged in from the mmap on demand.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const name = @import("../antelope/name.zig");
const la = @import("../lightapi/tables.zig");
const accinfo_bin = @import("accinfo_bin.zig");
const chainmod = @import("lightapi_chain.zig");

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("lightapi_accinfo requires <chain> <account>");
    const account = ctx.arg(1) orelse return ctx.err("lightapi_accinfo requires <chain> <account>");
    const a = ctx.allocator;

    // Live chain block (block_num/block_time/sync from the feed); null → unknown chain → 404.
    const chain_json = (try chainmod.block(ctx, a, chain)) orelse return ctx.err("unknown chain");
    // Live overlay (KV `acci:<chain>:<acct>`) shadows the frozen segment baseline.
    const frag: ?[]const u8 = blk: {
        if (try ctx.getCopy(ctx.fmt("acci:{s}:{s}", .{ chain, account }))) |o| break :blk o;
        if (ctx.store.segment("lightapi")) |s| break :blk s.lookup(la.TableId.accinfo, name.encode(account));
        break :blk null;
    };

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(a, "{\"account_name\":\"");
    try json.appendSlice(a, account);
    try json.appendSlice(a, "\",\"chain\":");
    try json.appendSlice(a, chain_json);
    if (frag) |f| {
        try json.append(a, ',');
        // Binary segment record → render; JSON overlay/legacy fragment → splice straight in.
        if (accinfo_bin.isBinary(f)) {
            accinfo_bin.render(&json, a, f) catch return ctx.err("corrupt accinfo record");
        } else {
            try json.appendSlice(a, f);
        }
    } else {
        // No accinfo row for this account — minimal empty shape.
        try json.appendSlice(a, ",\"resources\":null,\"permissions\":[],\"delegated_to\":[],\"delegated_from\":[],\"linkauth\":[]}");
    }
    return ctx.value(try json.toOwnedSlice(a));
}
