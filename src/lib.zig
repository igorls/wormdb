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
pub const proof = @import("proof/mod.zig");

// The compile-time build options (e.g. `quic`). Exposed so the composition root (the server exe)
// reads the SAME instance the engine compiled against — a second build_options module would conflict.
pub const build_options = @import("build_options");

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
