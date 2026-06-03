//! Light-API `/sync/CHAIN` — `<delay_sec> OK|OUT_OF_SYNC`, computed at REQUEST time.
//! EXEC lightapi_sync <chain>
//!
//! The feed writes `synctime:<chain>` = epoch-ms of the newest block it has applied. This proc
//! returns `now - synctime` so the delay keeps growing if the feed stalls or dies (a feed-written
//! static delay could not). Threshold (in-sync cutoff, seconds) is `syncthr:<chain>` (default 30).

const std = @import("std");
const Ctx = @import("../procedures/context.zig").Ctx;

/// Seconds since the feed's last applied block, or null if never synced.
pub fn delaySecs(ctx: *Ctx, chain: []const u8) ?i64 {
    const st = (ctx.getCopy(ctx.fmt("synctime:{s}", .{chain})) catch null) orelse return null;
    const head_ms = std.fmt.parseInt(i64, std.mem.trim(u8, st, " \r\n"), 10) catch return null;
    const now_ms: i64 = @intCast(ctx.timestamp());
    const d = now_ms - head_ms;
    return if (d < 0) 0 else @divFloor(d, 1000);
}

/// In-sync cutoff in seconds (`syncthr:<chain>`, default 30).
pub fn threshold(ctx: *Ctx, chain: []const u8) i64 {
    const t = (ctx.getCopy(ctx.fmt("syncthr:{s}", .{chain})) catch null) orelse return 30;
    return std.fmt.parseInt(i64, std.mem.trim(u8, t, " \r\n"), 10) catch 30;
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const chain = ctx.arg(0) orelse return ctx.err("lightapi_sync requires <chain>");
    const delay = delaySecs(ctx, chain) orelse return ctx.value("0 OUT_OF_SYNC");
    const tag: []const u8 = if (delay <= threshold(ctx, chain)) "OK" else "OUT_OF_SYNC";
    return ctx.value(ctx.fmt("{d} {s}", .{ delay, tag }));
}
