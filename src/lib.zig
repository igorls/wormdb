//! WormDB - Distributed key-value store with WORM and event streaming
//!
//! Module structure:
//! - core:      Fundamental types and configuration
//! - storage:   WAL and in-memory store
//! - protocol:  Wire protocol parsing
//! - server:    TCP server
//! - event:     Pub/sub event bus
//! - cluster:   Distributed features
//! - lightapi:  Optional Antelope Light-API feature (only with -Dlightapi=true)

const build_options = @import("build_options");

pub const core = @import("core/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const protocol = @import("protocol/mod.zig");
pub const server = @import("server/mod.zig");
pub const event = @import("event/mod.zig");
pub const cluster = @import("cluster/mod.zig");
pub const procedures = @import("procedures/mod.zig");
pub const vector = @import("vector/mod.zig");

/// Optional Antelope Light-API module. Gated like `quic_gateway` — an empty
/// struct unless `-Dlightapi=true`. Exposed here so it is instantiated once
/// inside this library module (the gateway/registry reach the same instance) and
/// so the test build's refAllDecls walks its tests when the flag is on.
pub const lightapi = if (build_options.lightapi) @import("lightapi/mod.zig") else struct {};

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
