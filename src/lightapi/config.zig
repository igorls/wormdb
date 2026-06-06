//! Light-API serving config — the per-network chain metadata. Lives in the
//! Light-API domain, NOT core: `core/config.zig` exposes a generic `loadTyped`
//! so a domain parses its own section from the shared `wormdb.json`, keeping core
//! free of any blockchain config type.

const std = @import("std");
const core_config = @import("../core/config.zig");

/// One Light-API network's static metadata (the cc32d9 `chain{}` block). WormDB
/// builds the chain block from this at startup and seeds `lacfgs:<chain>` + `lachains`
/// into KV — so serving a snapshot segment needs no external loader. `chainid`/
/// `decimals`/`systoken` come from the chain; `block_num` is the segment's snapshot
/// block (the live feed updates it thereafter).
pub const LightApiNetwork = struct {
    chain: []const u8,
    network: ?[]const u8 = null, // defaults to `chain`
    systoken: []const u8 = "",
    decimals: u8 = 4,
    chainid: []const u8 = "",
    description: []const u8 = "",
    rex_enabled: bool = false,
    production: bool = true,
    block_num: u64 = 0,
};

/// Light-API serving metadata (seeded into KV at startup).
pub const LightApiConfig = struct {
    networks: []const LightApiNetwork = &.{},
};

/// The `{ "lightapi": {…} }` slice of the shared config file.
const File = struct {
    lightapi: LightApiConfig = .{},
};

/// Parse the Light-API networks from the shared config file (empty if the file or the
/// `lightapi` section is absent). Strings live for the process lifetime (leaky parse).
pub fn loadNetworks(path: []const u8, allocator: std.mem.Allocator) ![]const LightApiNetwork {
    const f = try core_config.loadTyped(File, path, allocator);
    return f.lightapi.networks;
}

test {
    @import("std").testing.refAllDecls(@This());
}
