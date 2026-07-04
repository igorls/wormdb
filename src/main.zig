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

const Args = struct {
    port: u16 = 6389,
    data: []const u8 = "./data",
    persistence: PersistenceMode = .full,
    no_sync: bool = false,
    cluster_name: ?[]const u8 = null,
    seed: ?[]const u8 = null,
    replicas: usize = 0,
    gossip_port: u16 = 51821,
    wg_port: u16 = 51830,
    /// JSON config file (currently consumed for the `org_trust` section;
    /// CLI flags keep overriding everything else).
    config_path: []const u8 = "./wormdb.json",
    /// Explicit acknowledgement that cluster replication runs unauthenticated.
    /// Without org_trust configured, a cluster refuses to start unless this
    /// flag is passed (deny-by-default, mirroring meshguard's open-mode gate).
    cluster_open: bool = false,
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
        if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.port = try std.fmt.parseInt(u16, args[i], 10);
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
        } else if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.config_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--cluster-open")) {
            out.cluster_open = true;
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
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.Io.Dir.cwd().createDirPath(io, args.data);

    // Load the JSON config file (missing file ⇒ all defaults). Currently only
    // the org_trust section is consumed here; CLI flags own everything else.
    const file_cfg = wormdb.core.config.loadFromFile(args.config_path, allocator) catch |err| {
        std.log.err("failed to load config '{s}': {s}", .{ args.config_path, @errorName(err) });
        std.process.exit(1);
    };

    // Build runtime org trust once; shared read-only by the cluster (outbound
    // handshake) and the TCP server (inbound handshake + per-frame checks).
    // Lives on this frame, which outlives both.
    const org_trust = wormdb.cluster.OrgTrust.fromConfig(allocator, file_cfg.org_trust) catch |err| {
        std.log.err("invalid org_trust config in '{s}': {s}", .{ args.config_path, @errorName(err) });
        std.process.exit(1);
    };

    // Deny-by-default gate (#63): a cluster with no org trust serves an
    // unauthenticated replication endpoint. That must be an explicit,
    // acknowledged choice — never a silent default.
    if (args.cluster_name != null and !org_trust.enforce) {
        if (!args.cluster_open) {
            std.log.err("cluster replication is OPEN (unauthenticated) — configure org_trust in {s} or pass --cluster-open to acknowledge", .{args.config_path});
            std.process.exit(1);
        }
        std.log.warn("cluster replication is OPEN (unauthenticated) — --cluster-open acknowledged; any peer can replicate arbitrary keys", .{});
    }
    if (org_trust.enforce and args.cluster_name != null and org_trust.node_cert == null) {
        std.log.warn("org_trust enforced but no node_cert_path set — this node cannot authenticate its own outbound replication (enforcing peers will reject it)", .{});
    }

    const wal_path = try std.fmt.allocPrint(allocator, "{s}/wormdb.wal", .{args.data});
    defer allocator.free(wal_path);

    var vector_registry = NamespaceRegistry.init(allocator, .{});
    defer vector_registry.deinit();

    var store = try Store.initWithRegistry(allocator, .{
        .wal_path = wal_path,
        .sync_writes = !args.no_sync,
        .persistence = args.persistence,
    }, &vector_registry);
    defer store.deinit();

    if (args.persistence == .full) try store.startBackgroundTasks();

    var event_bus = EventBus.init(allocator);
    defer event_bus.deinit();

    var cluster: ?Cluster = null;
    if (args.cluster_name != null) {
        if (comptime wormdb.server.is_linux) {
            var seed_slice: [1][]const u8 = undefined;
            const seeds: []const []const u8 = if (args.seed) |seed| blk: {
                seed_slice[0] = seed;
                break :blk seed_slice[0..1];
            } else &.{};

            cluster = Cluster.init(allocator, &store, &event_bus, .{
                .seed_addrs = seeds,
                .replication_factor = args.replicas,
                .peer_port = args.port,
                .config_dir = args.data,
                .gossip_port = args.gossip_port,
                .wg_port = args.wg_port,
                .org_trust = &org_trust,
            });
            cluster.?.attachVectorRegistry(&vector_registry);
        } else {
            std.log.warn("cluster '{s}' requested, but clustering is Linux-only; running single-node", .{args.cluster_name.?});
        }
    }
    defer if (cluster != null) cluster.?.deinit();

    var server = Server.init(allocator, &store, &event_bus, .{
        .port = args.port,
        .cluster = if (cluster) |*c| c else null,
        .vector_registry = &vector_registry,
        .org_trust = &org_trust,
    });

    if (cluster) |*c| c.start();

    std.log.info("WormDB starting on port {d}", .{args.port});
    std.log.info("Data directory: {s}", .{args.data});
    std.log.info("Persistence: {s}", .{@tagName(args.persistence)});
    if (args.cluster_name) |name| {
        std.log.info("Cluster: {s} (replication: {d})", .{ name, args.replicas });
        if (org_trust.enforce) {
            std.log.info("Org trust: ENFORCED ({d} grant(s), node cert: {s})", .{
                org_trust.grants.len,
                if (org_trust.node_cert != null) "yes" else "no",
            });
        }
    }

    try server.run();
}

fn printHelp() !void {
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(),
        \\WormDB - Distributed Key-Value Store with WORM and Event Streaming
        \\
        \\Usage:
        \\  wormdb [options]
        \\
        \\Options:
        \\  --port <port>             TCP port to listen on (default: 6389)
        \\  --data <path>             Data directory for WAL/snapshots (default: ./data)
        \\  --persistence <mode>      Persistence mode: full (default), snapshot, none
        \\  --no-sync                 Disable fsync per write
        \\  --cluster <name>          Cluster name for mesh discovery (Linux-only)
        \\  --seed <host:port>        Seed node gossip address for joining cluster
        \\  --replicas <n>            Replication factor (default: 0 = all peers)
        \\  --gossip-port <port>      SWIM gossip UDP port (default: 51821)
        \\  --wg-port <port>          WireGuard listen port (default: 51830)
        \\  --config <path>           JSON config file (default: ./wormdb.json;
        \\                            consumed for the org_trust section)
        \\  --cluster-open            Acknowledge running cluster replication OPEN
        \\                            (unauthenticated). Required to start a cluster
        \\                            without org_trust configured.
        \\  --help, -h                Show this help
        \\
        \\Examples:
        \\  wormdb --port 6389 --data ./data
        \\  wormdb --cluster myapp --port 6389
        \\  wormdb --cluster myapp --seed 10.0.0.1:51821 --port 6390
        \\
    );
}
