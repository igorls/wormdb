//! WormDB - Distributed key-value store with WORM and event streaming
//!
//! Module structure:
//! - core:      Fundamental types and configuration
//! - storage:   WAL and in-memory store
//! - protocol:  Wire protocol parsing
//! - server:    TCP server
//! - event:     Pub/sub event bus
//! - cluster:   Distributed features

pub const core = @import("core/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const protocol = @import("protocol/mod.zig");
pub const server = @import("server/mod.zig");
pub const event = @import("event/mod.zig");
pub const cluster = @import("cluster/mod.zig");
pub const procedures = @import("procedures/mod.zig");
pub const vector = @import("vector/mod.zig");

// Domain serving layers — these depend on the engine above; the engine never
// depends on them. Blockchain/Antelope knowledge lives only here and in `procedures`.
// (AtomicAssets now lives in its own package, wormdb-domain-atomicassets, composed in by
// the binary at build time — see build.zig + main.zig.)
pub const antelope = @import("antelope/mod.zig");
pub const lightapi = @import("lightapi/mod.zig");

// Re-export commonly used types
pub const Entry = core.types.Entry;
pub const Command = core.types.Command;
pub const Response = core.types.Response;
pub const Store = storage.Store;
pub const EventBus = event.EventBus;
pub const Config = core.config.Config;
pub const Server = server.Server;

test {
    @import("std").testing.refAllDecls(@This());
}
