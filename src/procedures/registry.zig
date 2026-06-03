//! Stored procedure registry
//!
//! Maps procedure names to native Zig functions compiled into the server.
//! Each procedure receives a Ctx and returns a Result — the Ctx handles
//! locking, argument parsing, and response building automatically.
//!
//! The table is generic. Application-specific procedures are contributed by
//! optional modules and appended here behind a build flag — e.g. the Antelope
//! Light-API procedures are pulled from `src/lightapi/mod.zig` only when
//! `-Dlightapi=true`, so the default build names no blockchain code.

const std = @import("std");
const build_options = @import("build_options");
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

pub const ProcedureFn = *const fn (ctx: *Ctx) anyerror!Ctx.Result;

pub const Entry = struct {
    name: []const u8,
    func: ProcedureFn,
};

/// The generic, application-agnostic procedures — always compiled in.
const GENERIC_PROCEDURES = [_]Entry{
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
};

/// Application procedures contributed by optional, build-flag-gated modules.
/// When `-Dlightapi=true`, the Antelope Light-API procedures are appended; with
/// the flag off this is empty and no `src/lightapi/` code is referenced.
const APP_PROCEDURES = if (build_options.lightapi)
    @import("../lightapi/mod.zig").procedures
else
    [_]Entry{};

/// Comptime-generated procedure table: generic core + any enabled app modules.
const PROCEDURES = GENERIC_PROCEDURES ++ APP_PROCEDURES;

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
