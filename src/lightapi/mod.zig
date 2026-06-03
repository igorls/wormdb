//! Light-API module — the optional Antelope ("eosio_light_api" / cc32d9) feature
//! built on top of the generic WormDB core. Compiled in ONLY when
//! `-Dlightapi=true`; with the flag off, nothing in `src/lightapi/` reaches the
//! binary and the core carries zero blockchain symbols.
//!
//! This is the single seam the core wires to (all gated on `build_options.lightapi`):
//!   * `procedures`            — the EXEC handlers the registry appends to its table.
//!   * `routeHttp` / `Sink` /
//!     `handleWsText` / `ExecCtx` /
//!     `RouteResult`           — the gateway request-handler hooks.
//!   * `onStart`               — the startup seeding hook (`startServer` calls it).
//!   * `Config` / `parseConfig`— the `[lightapi]` config block + its JSON extractor.
//!
//! Antelope-specific internals (the `name`/base58 codecs, the binary accinfo
//! renderer, the frozen-segment table-id constants) live beside this file and are
//! reachable from here for tests, but the core never names them.

const std = @import("std");
const registry = @import("../procedures/registry.zig");
const routes = @import("routes.zig");
const seed_mod = @import("seed.zig");
const cfg_mod = @import("config.zig");
const Store = @import("../storage/store.zig").Store;

// --- Antelope internals (kept reachable so refAllDecls walks their tests) ---
pub const name = @import("name.zig");
pub const keyenc = @import("keyenc.zig");
pub const accinfo_bin = @import("accinfo_bin.zig");
pub const tables = @import("tables.zig");

// --- Config ---
pub const Config = cfg_mod.LightApiConfig;
pub const Network = cfg_mod.LightApiNetwork;
/// Pull the `[lightapi]` block out of the raw config JSON.
pub const parseConfig = cfg_mod.parse;

// --- Gateway hooks ---
pub const ExecCtx = routes.ExecCtx;
pub const RouteResult = routes.RouteResult;
pub const Sink = routes.Sink;
pub const routeHttp = routes.routeHttp;
pub const handleWsText = routes.handleWsText;

// --- Procedure contributions ---
//
// The procedure modules. Imported here (not by the core registry) so the core
// names no Antelope file; `registry.zig` pulls `procedures` from this module
// only under `if (build_options.lightapi)`.
const lightapi_balances = @import("lightapi_balances.zig");
const lightapi_account = @import("lightapi_account.zig");
const lightapi_accinfo = @import("lightapi_accinfo.zig");
const lightapi_tokenbalance = @import("lightapi_tokenbalance.zig");
const lightapi_get = @import("lightapi_get.zig");
const lightapi_topholders = @import("lightapi_topholders.zig");
const lightapi_holdercount = @import("lightapi_holdercount.zig");
const lightapi_topn = @import("lightapi_topn.zig");
const lightapi_sync = @import("lightapi_sync.zig");
const lightapi_status = @import("lightapi_status.zig");
const lightapi_ws = @import("lightapi_ws.zig");
const lightapi_rexbalance = @import("lightapi_rexbalance.zig");

/// The Light-API EXEC procedures, appended to the core registry table when the
/// flag is on. Same `Entry` shape as the generic procedures.
pub const procedures = [_]registry.Entry{
    .{ .name = "lightapi_balances", .func = lightapi_balances.execute },
    .{ .name = "lightapi_account", .func = lightapi_account.execute },
    .{ .name = "lightapi_accinfo", .func = lightapi_accinfo.execute },
    .{ .name = "lightapi_tokenbalance", .func = lightapi_tokenbalance.execute },
    .{ .name = "lightapi_get", .func = lightapi_get.execute },
    .{ .name = "lightapi_topholders", .func = lightapi_topholders.execute },
    .{ .name = "lightapi_holdercount", .func = lightapi_holdercount.execute },
    .{ .name = "lightapi_topn", .func = lightapi_topn.execute },
    .{ .name = "lightapi_sync", .func = lightapi_sync.execute },
    .{ .name = "lightapi_status", .func = lightapi_status.execute },
    .{ .name = "lightapi_ws_balances", .func = lightapi_ws.balancesRow },
    .{ .name = "lightapi_ws_holders", .func = lightapi_ws.holderRows },
    .{ .name = "lightapi_ws_keyrows", .func = lightapi_ws.keyRows },
    .{ .name = "lightapi_rexbalance", .func = lightapi_rexbalance.execute },
};

// --- Startup hook ---

/// Called from `startServer` (only when `-Dlightapi=true`) after the store is up
/// and any frozen segment is attached. Parses the `[lightapi]` networks from the
/// config file at `config_path` and seeds the chain metadata into KV. Best-effort
/// — failures are logged, never fatal.
pub fn onStart(store: *Store, allocator: std.mem.Allocator, config_path: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    // Re-read the same config file the generic loader used. Slices in the parsed
    // networks point into this buffer, which is intentionally leaked for the
    // process lifetime (the seeded KV copies the bytes anyway).
    const content = cwd.readFileAlloc(io, config_path, allocator, .limited(1024 * 1024)) catch |err| {
        if (err != error.FileNotFound) {
            std.log.warn("Light-API: failed to read config '{s}': {s}", .{ config_path, @errorName(err) });
        }
        return;
    };
    const config = cfg_mod.parse(content, allocator);
    seed_mod.seed(store, allocator, config.networks) catch |err| {
        std.log.warn("Light-API metadata seed failed: {s}", .{@errorName(err)});
    };
}

test {
    std.testing.refAllDecls(@This());
}
