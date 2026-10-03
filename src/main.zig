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
const Backend = wormdb.core.config.Backend;

const Args = struct {
    port: ?u16 = null,
    bind_address: ?[]const u8 = null,
    backend: ?Backend = null,
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
    /// WebSocket gateway port. Setting it enables the gateway (overrides the
    /// config file's `gateway.port`; `gateway.enabled` in the file also works).
    gateway_port: ?u16 = null,
    /// JSON config file. Only explicitly supplied CLI flags override its values.
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
        } else if (std.mem.eql(u8, args[i], "--bind")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.bind_address = args[i];
        } else if (std.mem.eql(u8, args[i], "--backend")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.backend = std.meta.stringToEnum(Backend, args[i]) orelse return error.InvalidArgs;
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
        } else if (std.mem.eql(u8, args[i], "--gateway-port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.gateway_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out.config_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--cluster-open")) {
            out.cluster_open = true;
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
    const io = std.Io.Threaded.global_single_threaded.io();
    var cfg = wormdb.core.config.loadFromFile(args.config_path, allocator) catch |err| {
        std.log.err("failed to load config '{s}': {s}", .{ args.config_path, @errorName(err) });
        std.process.exit(1);
    };
    applyCliOverrides(&cfg, args);
    try validateBackend(cfg.server.backend);
    // Validate before starting background tasks or borrowing stack-owned
    // state into the gateway thread.
    if (cfg.server.max_connections == 0 or cfg.server.timeout_ms == 0 or
        ((args.gateway_port != null or cfg.gateway.enabled) and
            (cfg.gateway.max_connections == 0 or cfg.gateway.timeout_ms == 0)))
        return error.InvalidConnectionLimits;

    // Build runtime org trust once; shared read-only by the cluster (outbound
    // handshake) and the TCP server (inbound handshake + per-frame checks).
    // Lives on this frame, which outlives both.
    var org_trust = wormdb.cluster.OrgTrust.fromConfig(allocator, cfg.org_trust) catch |err| {
        std.log.err("invalid org_trust config in '{s}': {s}", .{ args.config_path, @errorName(err) });
        std.process.exit(1);
    };

    // Deny-by-default gate (#63): a cluster with no org trust serves an
    // unauthenticated replication endpoint. That must be an explicit,
    // acknowledged choice — never a silent default.
    if (cfg.cluster.name != null and !org_trust.enforce) {
        if (!args.cluster_open) {
            std.log.err("cluster replication is OPEN (unauthenticated) — configure org_trust in {s} or pass --cluster-open to acknowledge", .{args.config_path});
            std.process.exit(1);
        }
        std.log.warn("cluster replication is OPEN (unauthenticated) — --cluster-open acknowledged; any peer can replicate arbitrary keys", .{});
    }
    // Replication magic shares the client port even in standalone mode.
    // Never let it bypass SCT enforcement without the explicit open opt-in.
    if (!args.cluster_open) org_trust.enforce = true;
    if (org_trust.enforce and cfg.cluster.name != null and org_trust.node_cert == null) {
        std.log.warn("org_trust enforced but no node_cert_path set — this node cannot authenticate its own outbound replication (enforcing peers will reject it)", .{});
    }

    // Preserve every store option. Relative filenames are rooted in cfg.data;
    // absolute filenames keep their configured location.
    const store_cfg = try resolveStoreConfig(allocator, cfg);
    defer allocator.free(store_cfg.wal_path);
    defer allocator.free(store_cfg.snapshot_path);
    try checkLegacyStorage(allocator, args, cfg, store_cfg);
    try std.Io.Dir.cwd().createDirPath(io, cfg.data);
    if (store_cfg.persistence == .full) {
        if (std.fs.path.dirname(store_cfg.wal_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    }
    if (store_cfg.persistence != .none) {
        if (std.fs.path.dirname(store_cfg.snapshot_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    var vector_registry = NamespaceRegistry.init(allocator, .{});
    defer vector_registry.deinit();

    var store = try Store.initWithRegistry(allocator, store_cfg, &vector_registry);
    defer store.deinit();

    if (cfg.store.persistence == .full) try store.startBackgroundTasks();

    // Dynamic delegated-org authorization (#66): only when enforcement is on
    // AND this node has a cert (so "our org" is known). Folds this org's own
    // trust log ("trust:<our_org_hex>") to authorize DELEGATED orgs' writes
    // on granted prefixes; cached ≤5s + invalidated by local trust_revoke.
    // Lives on this frame (outlives the server); deregistered before store
    // teardown by defer ordering.
    var dynamic_trust: wormdb.cluster.org_trust.DynamicTrust = undefined;
    if (org_trust.enforce) {
        if (org_trust.node_cert) |cert| {
            dynamic_trust = wormdb.cluster.org_trust.DynamicTrust.init(allocator, &store, cert.org_pubkey);
            org_trust.dynamic = &dynamic_trust;
            std.log.info("Org trust: dynamic delegation fold active (trust:<our-org> log, cache ttl {d} ms)", .{dynamic_trust.ttl_ms});
        }
    }
    defer if (org_trust.dynamic) |dynamic| dynamic.deinit();

    var event_bus = EventBus.init(allocator);
    defer event_bus.deinit();
    var metrics = wormdb.server.ServerMetrics.init();

    // Enforcement is independent of key availability. A keyless protected
    // listener stays locked until the operator supplies verification keys.
    const srv_auth = wormdb.server.auth;
    const auth_keys = try allocator.alloc(srv_auth.PublicKey, cfg.auth.public_keys.len);
    defer allocator.free(auth_keys);
    for (cfg.auth.public_keys, auth_keys) |b64, *pk| {
        pk.* = srv_auth.decodePublicKey(b64) catch {
            std.log.err("invalid auth.public_keys entry in '{s}': {s}", .{ args.config_path, b64 });
            std.process.exit(1);
        };
    }
    const auth_enforce = cfg.auth.require_auth;
    if (!auth_enforce or !cfg.server.auth_enabled) {
        std.log.warn("TCP authentication is disabled on {s}:{d}", .{ cfg.server.bind_address, cfg.server.port });
    }
    if (cfg.auth.require_auth and auth_keys.len == 0) {
        std.log.warn("auth.require_auth is set but auth.public_keys is empty — protected commands remain LOCKED on auth-enabled listeners", .{});
    }

    var mint_secret: [64]u8 = undefined;
    var auth_mint: ?wormdb.procedures.context.AuthMintConfig = null;
    if (cfg.auth.mint_secret_key) |b64| {
        mint_secret = srv_auth.decodeSecretKey(b64) catch {
            std.log.err("invalid auth.mint_secret_key in '{s}'", .{args.config_path});
            std.process.exit(1);
        };
        auth_mint = .{
            .secret_key = &mint_secret,
            .default_ttl_s = cfg.auth.namespace_token_ttl_s,
            .max_ttl_s = cfg.auth.token_max_age_s,
        };
    }

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
                .org_trust = &org_trust,
            });
            cluster.?.attachVectorRegistry(&vector_registry);
        } else {
            std.log.warn("cluster '{s}' requested, but clustering is Linux-only; running single-node", .{cfg.cluster.name.?});
        }
    }
    defer if (cluster != null) cluster.?.deinit();

    var server = Server.init(allocator, &store, &event_bus, .{
        .bind_address = cfg.server.bind_address,
        .port = cfg.server.port,
        .max_connections = cfg.server.max_connections,
        .timeout_ms = cfg.server.timeout_ms,
        .cluster = if (cluster) |*c| c else null,
        .vector_registry = &vector_registry,
        .org_trust = &org_trust,
        .metrics = &metrics,
        .auth_enforce = auth_enforce and cfg.server.auth_enabled,
        .auth_public_keys = auth_keys,
        .auth_max_token_age = cfg.auth.token_max_age_s,
        .auth_mint = auth_mint,
    });

    if (cluster) |*c| c.start();

    // WebSocket gateway: --gateway-port enables it (and overrides the file's
    // port); `gateway.enabled` in the config file works too. Lives on this
    // frame — the accept-loop thread borrows it for the process lifetime.
    var gateway: wormdb.server.Gateway = undefined;
    if (args.gateway_port != null or cfg.gateway.enabled) {
        const gw_port = args.gateway_port orelse cfg.gateway.port;
        gateway = wormdb.server.Gateway.initWithMetrics(
            allocator,
            &store,
            &event_bus,
            if (cluster) |*c| c else null,
            gw_port,
            &metrics,
        );
        gateway.public_keys = auth_keys;
        gateway.max_token_age = cfg.auth.token_max_age_s;
        gateway.auth_required = auth_enforce and cfg.gateway.auth_enabled;
        gateway.auth_mint = auth_mint;
        gateway.max_connections = cfg.gateway.max_connections;
        gateway.timeout_ms = cfg.gateway.timeout_ms;
        gateway.setPerIpLimit(
            cfg.gateway.max_connections_per_ip,
            cfg.gateway.per_ip_exempt_loopback,
        );
        const gw_thread = try gateway.start();
        gw_thread.detach();
        std.log.info("Gateway: WebSocket on port {d} (auth: {s})", .{
            gw_port,
            if (gateway.auth_required) @as([]const u8, "required") else @as([]const u8, "disabled"),
        });
    }

    std.log.info("WormDB starting on port {d}", .{cfg.server.port});
    std.log.info("Data directory: {s}", .{cfg.data});
    std.log.info("Persistence: {s}", .{@tagName(cfg.store.persistence)});
    if (cfg.cluster.name) |name| {
        std.log.info("Cluster: {s} (replication: {d})", .{ name, cfg.cluster.replication_factor });
        if (org_trust.enforce) {
            std.log.info("Org trust: ENFORCED ({d} grant(s), node cert: {s})", .{
                org_trust.grants.len,
                if (org_trust.node_cert != null) "yes" else "no",
            });
        }
    }

    try server.run();
}

fn applyCliOverrides(cfg: *WormDBConfig, args: Args) void {
    if (args.port) |v| cfg.server.port = v;
    if (args.bind_address) |v| cfg.server.bind_address = v;
    if (args.backend) |v| cfg.server.backend = v;
    if (args.data) |v| cfg.data = v;
    if (args.persistence) |v| cfg.store.persistence = v;
    if (args.no_sync) cfg.store.sync_writes = false;
    if (args.cluster_name) |v| cfg.cluster.name = v;
    if (args.seed) |v| cfg.cluster.seed = v;
    if (args.replicas) |v| cfg.cluster.replication_factor = v;
    if (args.gossip_port) |v| cfg.cluster.gossip_port = v;
    if (args.wg_port) |v| cfg.cluster.wg_port = v;
    if (args.require_auth) |v| cfg.auth.require_auth = v;
    if (args.server_auth_enabled) |v| cfg.server.auth_enabled = v;
}

fn validateBackend(backend: Backend) !void {
    if (backend != .threadpool) {
        std.log.err("standalone server supports only --backend threadpool; {s} is available through the engine API without SCT authentication", .{@tagName(backend)});
        return error.UnsupportedBackend;
    }
}

fn resolveStoreConfig(allocator: std.mem.Allocator, cfg: WormDBConfig) !wormdb.core.config.Config {
    var store_cfg = cfg.store;
    store_cfg.wal_path = try resolveStoragePath(allocator, cfg.data, cfg.store.wal_path);
    errdefer allocator.free(store_cfg.wal_path);
    store_cfg.snapshot_path = try resolveStoragePath(allocator, cfg.data, cfg.store.snapshot_path);
    return store_cfg;
}

fn resolveStoragePath(allocator: std.mem.Allocator, data: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ data, path });
}

// Older standalone binaries ignored configured paths and cfg.data. Refuse to
// silently skip durable data when the effective storage location changes.
fn checkLegacyStorage(allocator: std.mem.Allocator, args: Args, cfg: WormDBConfig, store_cfg: wormdb.core.config.Config) !void {
    if (cfg.store.persistence != .none) {
        try checkLegacyPath(allocator, "wormdb.snapshot", store_cfg.snapshot_path, "snapshot_path", error.LegacySnapshotPath);
    }
    // The old executable used only the CLI/default mode. A newly honored
    // snapshot/none config must not discard a WAL that the old full mode wrote.
    if ((args.persistence orelse .full) == .full) {
        const legacy_wal = try std.fs.path.join(allocator, &.{ args.data orelse "./data", "wormdb.wal" });
        defer allocator.free(legacy_wal);
        if (cfg.store.persistence != .full) {
            const io = std.Io.Threaded.global_single_threaded.io();
            const legacy = std.Io.Dir.cwd().openFile(io, legacy_wal, .{}) catch |err| switch (err) {
                error.FileNotFound => return,
                else => return err,
            };
            legacy.close(io);
            std.log.err("legacy full-mode WAL exists at {s}; recover in full mode and migrate or archive it before selecting {s}", .{ legacy_wal, @tagName(cfg.store.persistence) });
            return error.LegacyWalMode;
        }
        try checkLegacyPath(allocator, legacy_wal, store_cfg.wal_path, "wal_path", error.LegacyWalPath);
    }
}

fn checkLegacyPath(allocator: std.mem.Allocator, previous: []const u8, desired: []const u8, setting: []const u8, migration_error: anyerror) !void {
    const cwd_path = try wormdb.core.compat.Dir.realPathAlloc(std.Io.Dir.cwd(), allocator, ".");
    defer allocator.free(cwd_path);
    const old_path = try std.fs.path.resolve(allocator, &.{ cwd_path, previous });
    defer allocator.free(old_path);
    const new_path = try std.fs.path.resolve(allocator, &.{ cwd_path, desired });
    defer allocator.free(new_path);
    if (std.mem.eql(u8, old_path, new_path)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    const legacy = std.Io.Dir.cwd().openFile(io, old_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    legacy.close(io);
    std.log.err("legacy storage exists at {s}; migrate it to {s} or set store.{s} to its absolute path before starting", .{ old_path, new_path, setting });
    return migration_error;
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
        \\  --bind <addr>             TCP bind address (default: 0.0.0.0)
        \\  --backend <type>          Standalone backend: threadpool (default)
        \\  --data <path>             Data directory for WAL/snapshots (default: ./data)
        \\  --persistence <mode>      Persistence mode: full (default), snapshot, none
        \\  --no-sync                 Disable fsync per write
        \\  --cluster <name>          Cluster name for mesh discovery (Linux-only)
        \\  --seed <host:port>        Seed node gossip address for joining cluster
        \\  --replicas <n>            Replication factor (default: 0 = all peers)
        \\  --gossip-port <port>      SWIM gossip UDP port (default: 51821)
        \\  --wg-port <port>          WireGuard listen port (default: 51830)
        \\  --gateway-port <port>     Enable the WebSocket gateway on this port
        \\                            (config file: gateway.enabled/gateway.port)
        \\  --config <path>           JSON config file (default: ./wormdb.json;
        \\                            explicit CLI flags override file values)
        \\  --require-auth            Require auth globally (default)
        \\  --no-auth                 Disable auth globally (trusted networks only)
        \\  --tcp-auth                Enable TCP auth enforcement (default)
        \\  --no-tcp-auth             Disable TCP auth (trusted networks only)
        \\  --cluster-open            Acknowledge running cluster replication OPEN
        \\                            (unauthenticated). Required to start a cluster
        \\                            without org_trust configured.
        \\  --help, -h                Show this help
        \\
        \\Examples:
        \\  wormdb --port 6389 --data ./data
        \\  wormdb --port 6389 --gateway-port 6390
        \\  wormdb --cluster myapp --port 6389
        \\  wormdb --cluster myapp --seed 10.0.0.1:51821 --port 6390
        \\
    );
}

test "CLI preserves loaded settings unless explicitly overridden" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = try wormdb.core.config.loadFromJson(
        \\{"data":"configured-data","server":{"port":7777,"backend":"epoll"},
        \\ "store":{"wal_path":"logs/custom.wal","snapshot_path":"snapshots/custom.snap",
        \\ "max_wal_size":12345,"compaction_threshold":0.7,"sync_writes":false,"persistence":"snapshot"},
        \\ "cluster":{"replication_factor":3,"gossip_port":51900,"wg_port":51901},
        \\ "gateway":{"enabled":true,"port":9001}}
    , arena.allocator());
    applyCliOverrides(&cfg, try parseArgs(&.{"wormdb"}));
    try std.testing.expectEqual(@as(u16, 7777), cfg.server.port);
    try std.testing.expectEqualStrings("configured-data", cfg.data);
    try std.testing.expectEqual(PersistenceMode.snapshot, cfg.store.persistence);
    try std.testing.expect(!cfg.store.sync_writes);
    try std.testing.expectEqual(@as(usize, 3), cfg.cluster.replication_factor);
    try std.testing.expect(cfg.gateway.enabled);
    try std.testing.expect(cfg.auth.require_auth and cfg.server.auth_enabled);

    const args = try parseArgs(&.{ "wormdb", "--config", "secure.json", "--port", "8888", "--bind", "127.0.0.1", "--backend", "threadpool", "--data", "override-data", "--persistence", "full", "--replicas", "0", "--gossip-port", "52000", "--wg-port", "52001", "--no-auth", "--no-tcp-auth", "--gateway-port", "9002", "--cluster-open" });
    applyCliOverrides(&cfg, args);
    try std.testing.expectEqualStrings("secure.json", args.config_path);
    try std.testing.expectEqual(@as(u16, 8888), cfg.server.port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.server.bind_address);
    try std.testing.expectEqual(Backend.threadpool, cfg.server.backend);
    try std.testing.expectEqualStrings("override-data", cfg.data);
    try std.testing.expectEqual(PersistenceMode.full, cfg.store.persistence);
    try std.testing.expectEqual(@as(usize, 0), cfg.cluster.replication_factor);
    try std.testing.expectEqual(@as(u16, 52000), cfg.cluster.gossip_port);
    try std.testing.expectEqual(@as(u16, 52001), cfg.cluster.wg_port);
    try std.testing.expect(!cfg.auth.require_auth and !cfg.server.auth_enabled);
    try std.testing.expectEqual(@as(u16, 9002), args.gateway_port.?);
    try std.testing.expect(args.cluster_open);
    const resolved = try resolveStoreConfig(arena.allocator(), cfg);
    const expected_wal = try std.fs.path.join(arena.allocator(), &.{ "override-data", "logs/custom.wal" });
    const expected_snapshot = try std.fs.path.join(arena.allocator(), &.{ "override-data", "snapshots/custom.snap" });
    try std.testing.expectEqualStrings(expected_wal, resolved.wal_path);
    try std.testing.expectEqualStrings(expected_snapshot, resolved.snapshot_path);
    try std.testing.expectEqual(@as(usize, 12345), resolved.max_wal_size);
    try std.testing.expectEqual(@as(f32, 0.7), resolved.compaction_threshold);
    try std.testing.expect(!resolved.sync_writes);
    applyCliOverrides(&cfg, try parseArgs(&.{ "wormdb", "--require-auth", "--tcp-auth" }));
    try std.testing.expect(cfg.auth.require_auth and cfg.server.auth_enabled);
}

test "absolute storage paths remain unchanged and defaults use data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd_path = try wormdb.core.compat.Dir.realPathAlloc(std.Io.Dir.cwd(), a, ".");
    const path = try std.fs.path.resolve(a, &.{ cwd_path, "custom", "store.snapshot" });
    const cfg = try resolveStoreConfig(a, .{ .data = "elsewhere", .store = .{ .wal_path = path, .snapshot_path = path } });
    try std.testing.expectEqualStrings(path, cfg.wal_path);
    try std.testing.expectEqualStrings(path, cfg.snapshot_path);
    const defaults = try resolveStoreConfig(a, .{});
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ "./data", "wormdb.wal" }), defaults.wal_path);
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ "./data", "wormdb.snapshot" }), defaults.snapshot_path);
}

test "backend and argument validation rejects unsupported choices" {
    try validateBackend(.threadpool);
    // Logging expected errors increments Zig's test log counter; check the
    // startup errors in the live suite, and parsing/precedence here.
    for ([_][]const u8{ "epoll", "uring" }) |name| {
        const args = try parseArgs(&.{ "wormdb", "--backend", name });
        try std.testing.expect(args.backend.? != .threadpool);
    }
    try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "wormdb", "--backend", "unknown" }));
    for ([_][]const u8{ "--config", "--port", "--bind", "--backend", "--data" }) |flag| {
        try std.testing.expectError(error.InvalidArgs, parseArgs(&.{ "wormdb", flag }));
    }
}
