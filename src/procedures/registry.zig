//! Stored procedure registry
//!
//! Maps procedure names to native Zig functions compiled into the server.
//! Each procedure receives a Ctx and returns a Result — the Ctx handles
//! locking, argument parsing, and response building automatically.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;

pub const transfer = @import("transfer.zig");
pub const increment = @import("increment.zig");
pub const kv_put = @import("kv_put.zig");
pub const kv_get = @import("kv_get.zig");
pub const kv_stats = @import("kv_stats.zig");
pub const scan = @import("scan.zig");
pub const chat_send = @import("chat_send.zig");
pub const chat_history = @import("chat_history.zig");
pub const vsearch = @import("vsearch.zig");
pub const vsim = @import("vsim.zig");
pub const vinsert = @import("vinsert.zig");
pub const vstats = @import("vstats.zig");
pub const vreindex = @import("vreindex.zig");
pub const vrabitq = @import("vrabitq.zig");
pub const vdelete = @import("vdelete.zig");
pub const vnsdrop = @import("vnsdrop.zig");
pub const memory = @import("memory.zig");
pub const lightapi_balances = @import("lightapi_balances.zig");
pub const lightapi_account = @import("lightapi_account.zig");
pub const lightapi_tokenbalance = @import("lightapi_tokenbalance.zig");
pub const lightapi_get = @import("lightapi_get.zig");
pub const lightapi_topholders = @import("lightapi_topholders.zig");
pub const lightapi_rexbalance = @import("lightapi_rexbalance.zig");

pub const ProcedureFn = *const fn (ctx: *Ctx) anyerror!Ctx.Result;

const Entry = struct {
    name: []const u8,
    func: ProcedureFn,
};

/// Comptime-generated procedure table.
const PROCEDURES = [_]Entry{
    .{ .name = "transfer", .func = transfer.execute },
    .{ .name = "increment", .func = increment.execute },
    .{ .name = "kv_put", .func = kv_put.execute },
    .{ .name = "kv_get", .func = kv_get.execute },
    .{ .name = "kv_stats", .func = kv_stats.execute },
    .{ .name = "scan", .func = scan.execute },
    .{ .name = "chat_send", .func = chat_send.execute },
    .{ .name = "chat_history", .func = chat_history.execute },
    .{ .name = "vsearch", .func = vsearch.execute },
    .{ .name = "vsim", .func = vsim.execute },
    .{ .name = "vinsert", .func = vinsert.execute },
    .{ .name = "vstats", .func = vstats.execute },
    .{ .name = "vreindex", .func = vreindex.execute },
    .{ .name = "vrabitq", .func = vrabitq.execute },
    .{ .name = "vdelete", .func = vdelete.execute },
    .{ .name = "vnsdrop", .func = vnsdrop.execute },
    .{ .name = "mem_init", .func = memory.memInit },
    .{ .name = "mem_add", .func = memory.memAdd },
    .{ .name = "mem_get", .func = memory.memGet },
    .{ .name = "mem_query", .func = memory.memQuery },
    .{ .name = "mem_stats", .func = memory.memStats },
    .{ .name = "mem_drop", .func = memory.memDrop },
    .{ .name = "mem_reset_index", .func = memory.memResetIndex },
    .{ .name = "mem_capabilities", .func = memory.memCapabilities },
    .{ .name = "lightapi_balances", .func = lightapi_balances.execute },
    .{ .name = "lightapi_account", .func = lightapi_account.execute },
    .{ .name = "lightapi_tokenbalance", .func = lightapi_tokenbalance.execute },
    .{ .name = "lightapi_get", .func = lightapi_get.execute },
    .{ .name = "lightapi_topholders", .func = lightapi_topholders.execute },
    .{ .name = "lightapi_rexbalance", .func = lightapi_rexbalance.execute },
};

/// Look up a procedure by name. O(n) scan — n is tiny at comptime-known size.
pub fn lookup(name: []const u8) ?ProcedureFn {
    for (&PROCEDURES) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry.func;
        }
    }
    return null;
}

/// Return the list of registered procedure names (for STATUS/introspection).
pub fn list() []const Entry {
    return &PROCEDURES;
}

test {
    @import("std").testing.refAllDecls(@This());
}
