//! AtomicAssets subsystem — decode + serving support for the frozen AtomicAssets `.wseg` segment.
//!
//! Serves the AtomicAssets API from WormDB the way the Light-API tables are served: faceted reads over
//! the mmap'd segment (forward asset store + per-dimension posting lists + presorted orderings),
//! assembled into JSON by compiled `EXEC` procedures. The decode primitives live here; the procedures
//! live under `src/procedures/atomicassets_*`. The live faceted overlay is a later package.

pub const binfmt = @import("binfmt.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
