//! Light-API serving metadata (the `[lightapi]` config block).
//!
//! This is the Antelope-specific slice of WormDB configuration. The generic
//! `core/config.zig` keeps only a neutral `segment: ?[]const u8` path; the
//! `[lightapi]` networks block lives here and is parsed from the same JSON file
//! via a neutral extension struct (`ConfigExt`) so the generic config parser
//! never names a blockchain field. Wired in only when `-Dlightapi=true`.

const std = @import("std");

/// One Light-API network's static metadata (the `chain{}` block). WormDB builds the cc32d9 chain
/// block from this at startup and seeds `lacfg:<chain>` + `lanet` into KV — so serving a snapshot
/// segment needs no external loader. `chainid`/`decimals`/`systoken` come from the chain; `block_num`
/// is the segment's snapshot block (the live feed updates it thereafter).
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

/// Neutral JSON extension: the slice of the top-level config object the
/// Light-API module owns. The generic loader parses `WormDBConfig` with
/// `ignore_unknown_fields`, so the `"lightapi"` key is invisible to it; this
/// struct (also parsed with `ignore_unknown_fields`) picks just that key back
/// out of the same JSON buffer.
pub const ConfigExt = struct {
    lightapi: LightApiConfig = .{},
};

/// Parse the Light-API config slice out of the raw config JSON. Returns the
/// default (no networks) on any parse failure or a missing `lightapi` key —
/// the generic config has already validated the document.
pub fn parse(json: []const u8, allocator: std.mem.Allocator) LightApiConfig {
    const ext = std.json.parseFromSliceLeaky(ConfigExt, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch return .{};
    return ext.lightapi;
}

test "parse picks the lightapi block out of a full config" {
    // `parse` is leaky by design (parsed slices live for the process lifetime in
    // production); an arena gives the test the same ownership model with no leak.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = parse(
        \\{
        \\  "data": "./data",
        \\  "server": { "port": 6389 },
        \\  "lightapi": { "networks": [ { "chain": "wax", "systoken": "WAX", "decimals": 8 } ] }
        \\}
    , arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), cfg.networks.len);
    try std.testing.expectEqualStrings("wax", cfg.networks[0].chain);
    try std.testing.expectEqualStrings("WAX", cfg.networks[0].systoken);
    try std.testing.expectEqual(@as(u8, 8), cfg.networks[0].decimals);
}

test "parse returns defaults when lightapi is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = parse("{\"data\":\"./data\"}", arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), cfg.networks.len);
}

test {
    std.testing.refAllDecls(@This());
}
