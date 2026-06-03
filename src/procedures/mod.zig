//! Procedures module - native stored procedures
//!
//! Comptime-compiled Zig procedures that execute inside the server
//! process with direct store access under a single lock scope.

pub const context = @import("context.zig");
pub const registry = @import("registry.zig");
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
pub const lightapi_balances = @import("lightapi_balances.zig");
pub const lightapi_account = @import("lightapi_account.zig");
pub const lightapi_accinfo = @import("lightapi_accinfo.zig");
pub const lightapi_tokenbalance = @import("lightapi_tokenbalance.zig");
pub const lightapi_get = @import("lightapi_get.zig");
pub const lightapi_topholders = @import("lightapi_topholders.zig");
pub const lightapi_holdercount = @import("lightapi_holdercount.zig");
pub const lightapi_topn = @import("lightapi_topn.zig");
pub const lightapi_sync = @import("lightapi_sync.zig");
pub const lightapi_status = @import("lightapi_status.zig");
pub const lightapi_ws = @import("lightapi_ws.zig");
pub const lightapi_rexbalance = @import("lightapi_rexbalance.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
