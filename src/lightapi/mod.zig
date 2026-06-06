//! Light-API serving layer — config (chain metadata), KV seeding, and the
//! frozen-segment table-id namespace (0..=10). A domain module: it depends on the
//! engine core; core never depends on it.

pub const config = @import("config.zig");
pub const seed = @import("seed.zig");
pub const tables = @import("tables.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
