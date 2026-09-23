//! Basic WormDB executable composition root.
//!
//! The engine remains exported as the `wormdb` module from build.zig. This file
//! provides the repo-local database binary for basic usage: TCP WormWire server,
//! built-in procedures, vector registry, optional Linux cluster wiring, and no
//! external domain packages.

const std = @import("std");
const wormdb = @import("wormdb");

const Store = wormdb.storage.Store;
const EventBus = wormdb.event.EventBus;
const Server = wormdb.server.Server;
const Cluster = wormdb.cluster.Cluster;
const NamespaceRegistry = wormdb.vector.NamespaceRegistry;
const PersistenceMode = wormdb.core.config.PersistenceMode;
const WormDBConfig = wormdb.core.config.WormDBConfig;

const Args = struct {
    config_path: []const u8 = "./wormdb.json",
    port: ?u16 = null,
    bind_address: ?[]const u8 = null,
    data: ?[]const u8 = null,
    persistence: ?PersistenceMode = null,
    no_sync: bool = false,
    cluster_name: ?[]const u8 = null,
    seed: ?[]const u8 = null,
    replicas: ?usize = null,
    gossip_port: ?u16 = null,
    wg_port: ?u16 = null,
    require_auth: ?bool = null,
    server_auth_enabled: ?bool = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const parsed = try parseArgs(args);
    try runServer(allocator, parsed);
}

fn parseArgs(args: []const []const u8) !Args {
    var out = Args{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.config_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--bind")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.bind_address = args[i];
        } else if (std.mem.eql(u8, args[i], "--data")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.data = args[i];
        } else if (std.mem.eql(u8, args[i], "--persistence")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            if (std.mem.eql(u8, args[i], "full")) {
                out.persistence = .full;
            } else if (std.mem.eql(u8, args[i], "snapshot")) {
                out.persistence = .snapshot;
            } else if (std.mem.eql(u8, args[i], "none")) {
                out.persistence = .none;
            } else {
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, args[i], "--no-sync")) {
            out.no_sync = true;
        } else if (std.mem.eql(u8, args[i], "--cluster")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.cluster_name = args[i];
        } else if (std.mem.eql(u8, args[i], "--seed")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.seed = args[i];
        } else if (std.mem.eql(u8, args[i], "--replicas")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.replicas = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--gossip-port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.gossip_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--wg-port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.wg_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--require-auth")) {
            out.require_auth = true;
        } else if (std.mem.eql(u8, args[i], "--no-auth")) {
            out.require_auth = false;
        } else if (std.mem.eql(u8, args[i], "--tcp-auth")) {
            out.server_auth_enabled = true;
        } else if (std.mem.eql(u8, args[i], "--no-tcp-auth")) {
            out.server_auth_enabled = false;
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try printHelp();
            std.process.exit(0);
        } else {
            std.log.err("Unknown argument: {s}", .{args[i]});
            return error.InvalidArgs;
        }
    }
    return out;
}

fn runServer(allocator: std.mem.Allocator, args: Args) !void {
    var cfg = try wormdb.core.config.loadFromFile(args.config_path, allocator);
    applyCliOverrides(&cfg, args);

    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, cfg.data);

    const wal_path = try std.fmt.allocPrint(allocator, "{s}/wormdb.wal", .{cfg.data});
    defer allocator.free(wal_path);

    var vector_registry = NamespaceRegistry.init(allocator, .{});
    defer vector_registry.deinit();

    var store = try Store.initWithRegistry(allocator, .{
        .wal_path = wal_path,
        .sync_writes = cfg.store.sync_writes,
        .persistence = cfg.store.persistence,
    }, &vector_registry);
    defer store.deinit();

    if (cfg.store.persistence == .full) try store.startBackgroundTasks();

    var event_bus = EventBus.init(allocator);
    defer event_bus.deinit();

    var cluster: ?Cluster = null;
    if (cfg.cluster.name != null) {
        if (comptime wormdb.server.is_linux) {
            var seed_slice: [1][]const u8 = undefined;
            const seeds: []const []const u8 = if (cfg.cluster.seed) |seed| blk: {
                seed_slice[0] = seed;
                break :blk seed_slice[0..1];
            } else &.{};

            cluster = Cluster.init(allocator, &store, &event_bus, .{
                .seed_addrs = seeds,
                .replication_factor = cfg.cluster.replication_factor,
                .peer_port = cfg.server.port,
                .config_dir = cfg.data,
                .gossip_port = cfg.cluster.gossip_port,
                .wg_port = cfg.cluster.wg_port,
            });
            cluster.?.attachVectorRegistry(&vector_registry);
        } else {
            std.log.warn("cluster '{s}' requested, but clustering is Linux-only; running single-node", .{cfg.cluster.name.?});
        }
    }
    defer if (cluster != null) cluster.?.deinit();

    const tcp_auth_enforce = cfg.auth.require_auth and cfg.server.auth_enabled;
    if (!tcp_auth_enforce) {
        std.log.warn("TCP authentication is disabled; protected commands are unauthenticated on {s}:{d}", .{ cfg.server.bind_address, cfg.server.port });
    }

    var server = Server.init(allocator, &store, &event_bus, .{
        .bind_address = cfg.server.bind_address,
        .port = cfg.server.port,
        .cluster = if (cluster) |*c| c else null,
        .vector_registry = &vector_registry,
        .auth_enforce = tcp_auth_enforce,
    });

    if (cluster) |*c| c.start();

    std.log.info("WormDB starting on {s}:{d}", .{ cfg.server.bind_address, cfg.server.port });
    std.log.info("Data directory: {s}", .{cfg.data});
    std.log.info("Persistence: {s}", .{@tagName(cfg.store.persistence)});
    std.log.info("TCP auth: {s}", .{if (tcp_auth_enforce) "enforced" else "disabled"});
    if (cfg.cluster.name) |name| {
        std.log.info("Cluster: {s} (replication: {d})", .{ name, cfg.cluster.replication_factor });
    }

    try server.run();
}

fn applyCliOverrides(cfg: *WormDBConfig, args: Args) void {
    if (args.port) |port| cfg.server.port = port;
    if (args.bind_address) |bind_address| cfg.server.bind_address = bind_address;
    if (args.data) |data| cfg.data = data;
    if (args.persistence) |persistence| cfg.store.persistence = persistence;
    if (args.no_sync) cfg.store.sync_writes = false;
    if (args.cluster_name) |cluster_name| cfg.cluster.name = cluster_name;
    if (args.seed) |seed| cfg.cluster.seed = seed;
    if (args.replicas) |replicas| cfg.cluster.replication_factor = replicas;
    if (args.gossip_port) |gossip_port| cfg.cluster.gossip_port = gossip_port;
    if (args.wg_port) |wg_port| cfg.cluster.wg_port = wg_port;
    if (args.require_auth) |require_auth| cfg.auth.require_auth = require_auth;
    if (args.server_auth_enabled) |server_auth_enabled| cfg.server.auth_enabled = server_auth_enabled;
}

fn printHelp() !void {
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(),
        \\WormDB - Distributed Key-Value Store with WORM and Event Streaming
        \\
        \\Usage:
        \\  wormdb [options]
        \\
        \\Options:
        \\  --config <path>          JSON config file (default: ./wormdb.json if present)
        \\  --port <port>             TCP port to listen on (default: 6389)
        \\  --bind <addr>             TCP bind address (default: 0.0.0.0)
        \\  --data <path>             Data directory for WAL/snapshots (default: ./data)
        \\  --persistence <mode>      Persistence mode: full (default), snapshot, none
        \\  --no-sync                 Disable fsync per write
        \\  --cluster <name>          Cluster name for mesh discovery (Linux-only)
        \\  --seed <host:port>        Seed node gossip address for joining cluster
        \\  --replicas <n>            Replication factor (default: 0 = all peers)
        \\  --gossip-port <port>      SWIM gossip UDP port (default: 51821)
        \\  --wg-port <port>          WireGuard listen port (default: 51830)
        \\  --require-auth           Require auth for protected TCP commands (default)
        \\  --no-auth                Disable auth globally (trusted networks only)
        \\  --tcp-auth               Enforce auth on the TCP listener (default)
        \\  --no-tcp-auth            Disable auth on the TCP listener (trusted networks only)
        \\  --help, -h                Show this help
        \\
        \\Examples:
        \\  wormdb --port 6389 --data ./data
        \\  wormdb --cluster myapp --port 6389
        \\  wormdb --cluster myapp --seed 10.0.0.1:51821 --port 6390
        \\
    );
}

test "parseArgs captures config, bind, and TCP auth overrides" {
    const parsed = try parseArgs(&.{
        "wormdb",
        "--config",
        "secure.json",
        "--bind",
        "127.0.0.1",
        "--port",
        "7777",
        "--no-auth",
        "--no-tcp-auth",
    });

    try std.testing.expectEqualStrings("secure.json", parsed.config_path);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.bind_address.?);
    try std.testing.expectEqual(@as(u16, 7777), parsed.port.?);
    try std.testing.expectEqual(false, parsed.require_auth.?);
    try std.testing.expectEqual(false, parsed.server_auth_enabled.?);
}

test "applyCliOverrides preserves secure config defaults unless explicitly disabled" {
    var cfg = WormDBConfig{};
    applyCliOverrides(&cfg, Args{});
    try std.testing.expectEqual(true, cfg.auth.require_auth);
    try std.testing.expectEqual(true, cfg.server.auth_enabled);

    applyCliOverrides(&cfg, .{
        .bind_address = "127.0.0.1",
        .require_auth = false,
        .server_auth_enabled = false,
    });
    try std.testing.expectEqualStrings("127.0.0.1", cfg.server.bind_address);
    try std.testing.expectEqual(false, cfg.auth.require_auth);
    try std.testing.expectEqual(false, cfg.server.auth_enabled);
}
