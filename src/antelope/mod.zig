//! Antelope codecs — domain primitives shared by the Light-API and AtomicAssets
//! serving layers. These are NOT engine core: the store/segment are key-agnostic
//! (u64 keys, u32 table ids); the meaning of those keys (an Antelope `name`, a
//! public key) is a domain concern and lives here. Procedures import these
//! directly; nothing under `src/core`, `src/storage`, `src/server`, or
//! `src/protocol` depends on this module.

pub const name = @import("name.zig");
pub const keyenc = @import("keyenc.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
