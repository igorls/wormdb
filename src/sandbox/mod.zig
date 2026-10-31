//! Sandboxed procedures: stored procedures shipped as wasm instead of compiled into the binary.
//!
//! A module is decoded and checked once (`module`), then each call runs in a fresh, fuel-metered
//! instance (`interp`). The EXEC side — scopes, the write overlay, the call log and replay — lives
//! in procedures/sandbox.zig. See docs/sandbox.md.

pub const module = @import("module.zig");
pub const interp = @import("interp.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
