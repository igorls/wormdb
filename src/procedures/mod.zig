//! Procedures module - native stored procedures
//!
//! Comptime-compiled Zig procedures that execute inside the server
//! process with direct store access under a single lock scope.

pub const context = @import("context.zig");
pub const registry = @import("registry.zig");
pub const domain = @import("domain.zig");
pub const predicate = @import("predicate.zig");
pub const auth_mint_scoped = @import("auth_mint_scoped.zig");
pub const transfer = @import("transfer.zig");
pub const increment = @import("increment.zig");
pub const kv_put = @import("kv_put.zig");
pub const kv_get = @import("kv_get.zig");
pub const kv_stats = @import("kv_stats.zig");
pub const scan = @import("scan.zig");
pub const chat_send = @import("chat_send.zig");
pub const chat_history = @import("chat_history.zig");
pub const vsearch = @import("vsearch.zig");
pub const vsearch_cluster = @import("vsearch_cluster.zig");
pub const vsim = @import("vsim.zig");
pub const vinsert = @import("vinsert.zig");
pub const vstats = @import("vstats.zig");
pub const memory = @import("memory.zig");
pub const append_log = @import("append_log.zig");
pub const coordination = @import("coordination.zig");
pub const cluster_presence = @import("cluster_presence.zig");
pub const proof_prefix_root = @import("proof_prefix_root.zig");
pub const trust_log = @import("trust_log.zig");
// Light-API + AtomicAssets procedures are NOT here — they live in their own packages
// (wormdb-domain-lightapi, wormdb-domain-atomicassets) and register via the manifest at startup.

test {
    @import("std").testing.refAllDecls(@This());
}
