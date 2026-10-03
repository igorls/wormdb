//! Reduced engine root for the wasm32 target.
//!
//! Why a separate root: the full `src/lib.zig` re-exports `server`, whose tcp/gateway code
//! imports `cluster`, which imports meshguard, whose membership lock uses `std.Io.RwLock` —
//! and that lowers to `memory.atomic.wait32`, an instruction wasm32 does not have without the
//! threads proposal. That is a property of the dependency graph, not of any one call site, so
//! gating import by import only ever removed the last error until another appeared.
//!
//! This root is the only one the wasm target compiles. It never imports `server`, `cluster`,
//! or anything under them, and the procedure registry it exposes is an explicit allowlist.
//! `src/lib.zig` and the native public API are untouched.
//!
//! What is deliberately absent, and why, is documented in `docs/wasm.md`.

pub const core = @import("core/mod.zig");
pub const storage = @import("storage/mod.zig");
pub const protocol = @import("protocol/mod.zig");
pub const event = @import("event/mod.zig");
pub const vector = @import("vector/mod.zig");
pub const proof = @import("proof/mod.zig");
pub const procedures = @import("procedures/wasm_registry.zig");

pub const build_options = @import("build_options");

pub const Entry = core.types.Entry;
pub const Command = core.types.Command;
pub const Response = core.types.Response;
pub const Store = storage.Store;
pub const EventBus = event.EventBus;
pub const Config = core.config.Config;

// `Server` and `Cluster` are intentionally not exported: both are absent from this root, and
// naming them here would pull the graph back in.
