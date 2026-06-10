//! wormdb-sst — build a frozen sorted-string segment (`.wsst`) from a WormDB
//! snapshot. The snapshot is already globally key-sorted (writeSnapshot), so
//! this is a streaming format conversion; see storage/sst.zig for the format
//! and the overlay semantics.
//!
//! Usage: wormdb-sst <snapshot> <out.wsst>

const std = @import("std");
const wormdb = @import("wormdb");
const sst = wormdb.storage.sst;
const compat = wormdb.core.compat;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len != 3) {
        std.log.err("usage: wormdb-sst <snapshot> <out.wsst>", .{});
        std.process.exit(2);
    }

    const t0 = compat.nowMs();
    const stats = try sst.buildFromSnapshot(
        allocator,
        args[1],
        args[2],
        @intCast(t0),
    );
    const secs = @as(f64, @floatFromInt(compat.nowMs() - t0)) / 1000.0;
    std.log.info(
        "wrote {s}: {d} entries, {d:.1} MB keys + {d:.1} MB values, {d:.1} MB total in {d:.1}s",
        .{
            args[2],
            stats.count,
            @as(f64, @floatFromInt(stats.key_bytes)) / (1 << 20),
            @as(f64, @floatFromInt(stats.val_bytes)) / (1 << 20),
            @as(f64, @floatFromInt(stats.file_bytes)) / (1 << 20),
            secs,
        },
    );
}
