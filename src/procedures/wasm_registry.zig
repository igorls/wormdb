//! Procedure registry for the wasm32 entry root.
//!
//! An explicit ALLOWLIST, not a filtered copy of the full registry: a procedure is available
//! only if it is named here. Zig cannot inspect another module's imports at comptime, so the
//! enforcement is the build step `scripts/check-wasm-allowlist.zig` (run by `zig build
//! wasm`/`wasm-smoke`/`ffi` on a wasm target) — it reads the allowlisted files and fails the build,
//! naming the file and line, if one reaches the cluster or socket-bearing graph. An earlier version
//! of this comment claimed a comptime check here; no such check exists, which is exactly why the
//! build step does.
//!
//! Procedures that need clustering are absent rather than stubbed. A caller asking for one gets
//! "unknown procedure", which is honest; a stub that silently succeeded would pretend to
//! replicate to nobody.

const std = @import("std");
const domain = @import("domain.zig");

pub const ProcedureFn = domain.ProcFn;

// Every module below must be free of `server` and `cluster`.
const transfer = @import("transfer.zig");
const increment = @import("increment.zig");
const kv_put = @import("kv_put.zig");
const kv_get = @import("kv_get.zig");
const kv_stats = @import("kv_stats.zig");
const scan = @import("scan.zig");
const chat_send = @import("chat_send.zig");
const chat_history = @import("chat_history.zig");
const vsearch = @import("vsearch.zig");
const vsim = @import("vsim.zig");
const vinsert = @import("vinsert.zig");
const vstats = @import("vstats.zig");
const vreindex = @import("vreindex.zig");
const vrabitq = @import("vrabitq.zig");
const vdelete = @import("vdelete.zig");
const vnsdrop = @import("vnsdrop.zig");
const memory = @import("memory.zig");
const append_log = @import("append_log.zig");

pub const Entry = struct {
    name: []const u8,
    func: ProcedureFn,
};

/// The allowlist. Anything needing cluster (vsearch_cluster, cluster_presence, trust_grant,
/// trust_revoke, trust_fold, …) is not here.
pub const PROCEDURES = [_]Entry{
    .{ .name = "transfer", .func = transfer.execute },
    .{ .name = "increment", .func = increment.execute },
    .{ .name = "kv_put", .func = kv_put.execute },
    .{ .name = "kv_get", .func = kv_get.execute },
    .{ .name = "kv_stats", .func = kv_stats.execute },
    .{ .name = "scan", .func = scan.execute },
    .{ .name = "chat_send", .func = chat_send.execute },
    .{ .name = "chat_history", .func = chat_history.execute },
    .{ .name = "vsearch", .func = vsearch.execute },
    .{ .name = "vsearch_local_raw", .func = vsearch.executeLocalRaw },
    .{ .name = "vsim", .func = vsim.execute },
    .{ .name = "vinsert", .func = vinsert.execute },
    .{ .name = "vstats", .func = vstats.execute },
    .{ .name = "vreindex", .func = vreindex.execute },
    .{ .name = "vrabitq", .func = vrabitq.execute },
    .{ .name = "vdelete", .func = vdelete.execute },
    .{ .name = "vnsdrop", .func = vnsdrop.execute },
    .{ .name = "append_log_append", .func = append_log.appendExecute },
    .{ .name = "append_log_verify", .func = append_log.verifyExecute },
    .{ .name = "mem_range", .func = memory.memRange },
    .{ .name = "mem_stats", .func = memory.memStats },
    .{ .name = "mem_health", .func = memory.memHealth },
    .{ .name = "mem_verify", .func = memory.memVerify },
    .{ .name = "mem_drop", .func = memory.memDrop },
    .{ .name = "mem_reset_index", .func = memory.memResetIndex },
    .{ .name = "mem_capabilities", .func = memory.memCapabilities },
};

/// The full-root registry exposes `registry.lookup` via this same file's namespace; ffi.zig
/// refers to `procedures.registry`. Alias so the FFI entry is identical on both roots.
pub const registry = @This();
/// ffi.zig names this under `procedures.`, so mirror it on the reduced root.
pub const context = @import("context.zig");

/// Comptime guard: an allowlisted procedure must not reach `cluster`. If one starts to, this
/// is a compile error rather than a link failure somewhere further out, and it names the
/// offender. The check reads each module's own declaration list, so it holds for the graph as
/// written rather than for the imports I happened to review.
/// Look up a procedure by name. O(n) scan — n is tiny.
pub fn lookup(name: []const u8) ?ProcedureFn {
    for (&PROCEDURES) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.func;
    }
    return null;
}

pub fn list() []const Entry {
    return &PROCEDURES;
}
