//! Shared cc32d9 `chain{}` block builder with LIVE block_num/block_time/sync from the SHiP feed.
//!
//! Static fields come from `lacfgs:<chain>` (seeded at startup, tab-separated:
//! `net \t decimals \t systoken \t chainid \t production \t description \t rex_enabled \t snap_block`).
//! Live fields overlay the feed's KV: block_num = `syncblock:<chain>` (else the snapshot block);
//! block_time = ISO of `synctime:<chain>` ms (else ""); sync = now - synctime seconds (else 0).
//!
//! Returns null when the chain is not configured — callers turn that into `ctx.err`, which the
//! gateway maps to HTTP 404 (so an unknown chain no longer 200s with an empty `chain:{}`).

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const sync = @import("lightapi_sync.zig");

/// Format epoch-ms to cc32d9 `block_time` — "YYYY-MM-DDTHH:MM:SS.mmm" (no zone, matches nodeos).
fn isoFromMs(ms: i64, buf: []u8) []const u8 {
    if (ms <= 0) return "";
    const secs: u64 = @intCast(@divFloor(ms, 1000));
    const millis: u64 = @intCast(@mod(ms, 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        yd.year,
        md.month.numeric(),
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
        millis,
    }) catch "";
}

/// Build the cc32d9 chain block for `chain` (arena-owned), or null if the chain is not configured.
pub fn block(ctx: *Ctx, a: std.mem.Allocator, chain: []const u8) !?[]const u8 {
    const raw = (try ctx.getCopy(ctx.fmt("lacfgs:{s}", .{chain}))) orelse return null;
    var f = std.mem.splitScalar(u8, raw, '\t');
    const net = f.next() orelse return null;
    const decimals = f.next() orelse return null;
    const systoken = f.next() orelse return null;
    const chainid = f.next() orelse return null;
    const production = f.next() orelse return null;
    const description = f.next() orelse return null;
    const rex_enabled = f.next() orelse return null;
    const snap_block = f.next() orelse "0";

    const sync_val: i64 = sync.delaySecs(ctx, chain) orelse 0;

    // block_num: the feed's latest applied block, else the snapshot block.
    const block_num: []const u8 = if (try ctx.getCopy(ctx.fmt("syncblock:{s}", .{chain}))) |sb|
        std.mem.trim(u8, sb, " \r\n")
    else
        snap_block;

    // block_time: ISO of the feed's last applied-block wall time, else "".
    var bt_buf: [32]u8 = undefined;
    const block_time: []const u8 = if (try ctx.getCopy(ctx.fmt("synctime:{s}", .{chain}))) |st| blk: {
        const ms = std.fmt.parseInt(i64, std.mem.trim(u8, st, " \r\n"), 10) catch break :blk "";
        break :blk isoFromMs(ms, &bt_buf);
    } else "";

    return try std.fmt.allocPrint(
        a,
        "{{\"network\":\"{s}\",\"sync\":{d},\"decimals\":{s},\"systoken\":\"{s}\",\"chainid\":\"{s}\",\"production\":{s},\"block_num\":{s},\"block_time\":\"{s}\",\"description\":\"{s}\",\"rex_enabled\":{s}}}",
        .{ net, sync_val, decimals, systoken, chainid, production, block_num, block_time, description, rex_enabled },
    );
}

test {
    std.testing.refAllDecls(@This());
}
