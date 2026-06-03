//! Light-API startup seeding.
//!
//! Builds the cc32d9 `chain{}` block(s) from the `[lightapi]` config and seeds
//! `lacfg:<chain>` + `lanet` (+ `uc:<chain>` from the frozen segment's accinfo
//! key count) into KV — so serving a snapshot segment needs no external loader.
//! Extracted verbatim from the old `main.zig::seedLightApi`/`buildChainBlock`;
//! the live feed overwrites `block_num`/`sync` later.

const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const cfg_mod = @import("config.zig");
const tables = @import("tables.zig");

const LightApiNetwork = cfg_mod.LightApiNetwork;

/// Build the cc32d9 `chain{}` block for one configured network into `out`.
fn buildChainBlock(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, n: LightApiNetwork) !void {
    const net = n.network orelse n.chain;
    var buf: [512]u8 = undefined;
    const s = try std.fmt.bufPrint(
        &buf,
        "{{\"network\":\"{s}\",\"sync\":0,\"decimals\":{d},\"systoken\":\"{s}\",\"chainid\":\"{s}\",\"production\":{d},\"block_num\":{d},\"block_time\":\"\",\"description\":\"{s}\",\"rex_enabled\":{d}}}",
        .{ net, n.decimals, n.systoken, n.chainid, @as(u8, if (n.production) 1 else 0), n.block_num, n.description, @as(u8, if (n.rex_enabled) 1 else 0) },
    );
    try out.appendSlice(a, s);
}

/// Seed `lacfg:<chain>` (per network) + `lanet` (the /networks array) into KV from config.
pub fn seed(store: *Store, allocator: std.mem.Allocator, nets: []const LightApiNetwork) !void {
    if (nets.len == 0) return;

    var lanet: std.ArrayListUnmanaged(u8) = .empty;
    defer lanet.deinit(allocator);
    try lanet.append(allocator, '[');

    for (nets, 0..) |n, i| {
        var block: std.ArrayListUnmanaged(u8) = .empty;
        defer block.deinit(allocator);
        try buildChainBlock(&block, allocator, n);

        const key = try std.fmt.allocPrint(allocator, "lacfg:{s}", .{n.chain});
        defer allocator.free(key);
        try store.set(key, block.items, false);

        if (i > 0) try lanet.append(allocator, ',');
        try lanet.appendSlice(allocator, block.items);

        // usercount is free from the segment: the accinfo table's key count is the account universe
        // (every account has ≥1 permission). Seed `uc:<chain>` so /usercount serves a real number
        // without a precompute pass or the live feed.
        if (store.frozen_segment) |s| {
            const uc = s.keyCount(tables.accinfo);
            if (uc > 0) {
                const uk = try std.fmt.allocPrint(allocator, "uc:{s}", .{n.chain});
                defer allocator.free(uk);
                var ub: [24]u8 = undefined;
                try store.set(uk, try std.fmt.bufPrint(&ub, "{d}", .{uc}), false);
            }
        }
        std.log.info("Light-API chain seeded: {s} ({s}, {d} decimals)", .{ n.chain, n.systoken, n.decimals });
    }
    try lanet.append(allocator, ']');
    try store.set("lanet", lanet.items, false);
}

test {
    std.testing.refAllDecls(@This());
}
