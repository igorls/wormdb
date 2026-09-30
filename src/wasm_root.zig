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



// A permanent guard, so this cannot regress. A temporary probe found that `bus.subscribe` (and with
// it `subscriber_count`/`drop_count`) did NOT compile for wasm: `std.atomic.Value(u64)` needs 64-bit
// atomics, which the target does not have. It went unnoticed because nothing in the reduced root
// referenced those paths, so they were never analysed — the browser build would have broken the
// first time an allowlisted procedure used the event bus. The counters now go through
// `compat.AtomicU64`, which is inert here. This function keeps those paths IN the graph so that
// regression is a compile error rather than a surprise at runtime.
///
/// Compile-time guard for the event bus on this target. Referenced by `ffi.zig` so it is part of the
/// build; it is never called from JavaScript.
export fn wormdb_wasm_graph_guard() void {
    const std = @import("std");
    var bus = event.bus.EventBus.init(std.heap.page_allocator);
    defer bus.deinit();
    const H = struct {
        fn h(_: *anyopaque, _: []const u8) void {}
    };
    _ = bus.subscribe("guard", H.h, undefined) catch {};
    _ = bus.subscriberCount();
    _ = bus.dropCount();
}
