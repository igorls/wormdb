//! Light-API `/topram/CHAIN/N` and `/topstake/CHAIN/N` — top-N account rankings from the frozen
//! segment. EXEC lightapi_topram <chain> <N> → `[["owner",ram],…]`; EXEC lightapi_topstake <chain>
//! <N> → `[["owner",cpu,net],…]` (cc32d9 emits cpu/net separately; ranking is by their sum).
//!
//! Each table holds ONE blob at sentinel key 0: `[u32 count]["owner\tv1[\tv2]\n"…]` (value-desc,
//! capped at the builder's TOP_CAP). The reader slices the first N lines and emits the owner quoted
//! plus every remaining tab field as a bare integer. N must be in [10,1000].

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const la = @import("../lightapi/tables.zig");

fn executeTop(ctx: *Ctx, table: u32) anyerror!Ctx.Result {
    _ = ctx.arg(0) orelse return ctx.err("need <chain> <N>"); // chain (the segment is single-chain)
    const n_str = ctx.arg(1) orelse return ctx.err("need <chain> <N>");
    const a = ctx.allocator;

    const n = std.fmt.parseInt(usize, n_str, 10) catch 0;
    if (n < 10 or n > 1000) return ctx.value(ctx.fmt("Invalid count: {s}", .{n_str}));

    const lines: []const u8 = blk: {
        const seg = ctx.store.segment("lightapi") orelse break :blk "";
        const blob = seg.lookup(table, 0) orelse break :blk "";
        break :blk if (blob.len >= 4) blob[4..] else ""; // skip the [u32 count] header
    };

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.append(a, '[');
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (i >= n) break;
        var f = std.mem.splitScalar(u8, line, '\t');
        const owner = f.next() orelse continue;
        if (i > 0) try json.append(a, ',');
        i += 1;
        try json.appendSlice(a, "[\"");
        try json.appendSlice(a, owner);
        try json.append(a, '"');
        while (f.next()) |val| { // ram (topram) or cpu,net (topstake) — bare integers
            try json.append(a, ',');
            try json.appendSlice(a, val);
        }
        try json.append(a, ']');
    }
    try json.append(a, ']');
    return ctx.value(try json.toOwnedSlice(a));
}

pub fn executeRam(ctx: *Ctx) anyerror!Ctx.Result {
    return executeTop(ctx, la.TableId.top_ram);
}

pub fn executeStake(ctx: *Ctx) anyerror!Ctx.Result {
    return executeTop(ctx, la.TableId.top_stake);
}

test {
    std.testing.refAllDecls(@This());
}
