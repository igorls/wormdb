//! Procedures module - native stored procedures
//!
//! Comptime-compiled Zig procedures that execute inside the server
//! process with direct store access under a single lock scope.

pub const context = @import("context.zig");
pub const registry = @import("registry.zig");
pub const domain = @import("domain.zig");
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
pub const memory = @import("memory.zig");
pub const append_log = @import("append_log.zig");
// Light-API + AtomicAssets procedures are NOT here — they live in their own packages
// (wormdb-domain-lightapi, wormdb-domain-atomicassets) and register via the manifest at startup.

test {
    @import("std").testing.refAllDecls(@This());
}
