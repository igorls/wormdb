//! Seed Light-API chain metadata into KV at startup. Domain code — the composition
//! root (`main.zig`) calls `run` after the store and any segments are attached.
//!
//! Seeds `lacfgs:<chain>` (static chain fields, tab-separated) + `lachains` (the chain
//! list). The cc32d9 chain block is assembled at REQUEST time by `lightapi_chain.zig`,
//! which overlays live block_num/block_time/sync from the feed — so /networks and every
//! embedded `chain{}` report real freshness instead of the static snapshot block.

const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const config = @import("config.zig");
const tables = @import("tables.zig");

pub fn run(store: *Store, allocator: std.mem.Allocator, networks: []const config.LightApiNetwork) !void {
    if (networks.len == 0) return;

    var lachains: std.ArrayListUnmanaged(u8) = .empty;
    defer lachains.deinit(allocator);

    for (networks, 0..) |n, i| {
        const net = n.network orelse n.chain;
        // net \t decimals \t systoken \t chainid \t production \t description \t rex_enabled \t snap_block
        const cfgs = try std.fmt.allocPrint(allocator, "{s}\t{d}\t{s}\t{s}\t{d}\t{s}\t{d}\t{d}", .{
            net,                                 n.decimals, n.systoken, n.chainid,
            @as(u8, if (n.production) 1 else 0), n.description,
            @as(u8, if (n.rex_enabled) 1 else 0), n.block_num,
        });
        defer allocator.free(cfgs);
        const key = try std.fmt.allocPrint(allocator, "lacfgs:{s}", .{n.chain});
        defer allocator.free(key);
        try store.set(key, cfgs, false);

        if (i > 0) try lachains.append(allocator, ',');
        try lachains.appendSlice(allocator, n.chain);

        // usercount is free from the segment: the accinfo table's key count is the account universe
        // (every account has ≥1 permission). Seed `uc:<chain>` so /usercount serves a real number
        // without a precompute pass or the live feed.
        if (store.segment("lightapi")) |s| {
            const uc = s.keyCount(tables.TableId.accinfo);
            if (uc > 0) {
                const uk = try std.fmt.allocPrint(allocator, "uc:{s}", .{n.chain});
                defer allocator.free(uk);
                var ub: [24]u8 = undefined;
                try store.set(uk, try std.fmt.bufPrint(&ub, "{d}", .{uc}), false);
            }
        }
        std.log.info("Light-API chain seeded: {s} ({s}, {d} decimals)", .{ n.chain, n.systoken, n.decimals });
    }
    try store.set("lachains", lachains.items, false);
}

test {
    std.testing.refAllDecls(@This());
}
