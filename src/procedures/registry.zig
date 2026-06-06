//! Stored procedure registry
//!
//! Maps procedure names to native Zig functions compiled into the server.
//! Each procedure receives a Ctx and returns a Result — the Ctx handles
//! locking, argument parsing, and response building automatically.

const std = @import("std");
const domain = @import("domain.zig");

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
// Light-API + AtomicAssets procedures are NOT imported here — they live in their own packages
// (wormdb-domain-lightapi, wormdb-domain-atomicassets) and are registered at startup via
// registerDomains() from each package's manifest.

pub const ProcedureFn = domain.ProcFn;

const Entry = domain.Entry;

/// Domain procedures contributed by external domain packages, set ONCE at startup by the
/// composition root (main.zig) from each domain's manifest. Kept separate from the comptime
/// PROCEDURES so the engine core imports no domain code — this is the seam that lets a domain
/// live in its own package/repository. Written before serving begins; read-only thereafter.
var domain_procedures: []const Entry = &.{};

/// Register a domain package's procedures into the EXEC registry. Call at startup, before
/// serving. Names must not collide with the built-ins or each other (composition-root concern).
pub fn registerDomains(procs: []const Entry) void {
    domain_procedures = procs;
}

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
};

/// Look up a procedure by name. O(n) scan — n is tiny at comptime-known size.
pub fn lookup(name: []const u8) ?ProcedureFn {
    for (&PROCEDURES) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.func;
    }
    // External domain procedures (registered at startup from package manifests).
    for (domain_procedures) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.func;
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
