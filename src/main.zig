//! WormDB - Distributed Key-Value Store with WORM and Event Streaming
//!
//! Usage:
//!   wormdb [options]
//!
//! Configuration is loaded from a JSON file (default: ./wormdb.json) and
//! CLI flags override any values from the config file.

const std = @import("std");
// Import the engine via the named module (not @import("lib.zig")) so main and the domain
// packages share ONE wormdb module instance — otherwise a file-import copy and the named-module
// copy are distinct modules and their types (Domain/Entry/Ctx) don't match.
const wormdb = @import("wormdb");
// AtomicAssets domain package — its own repo, wired in at src/atomicassets (a symlink to the
// package's src/, like deps/meshguard). Imported as a plain file into the exe module so it
// shares this binary's `wormdb` import (same engine module instance → its manifest types match
// the engine exactly). Composed in via registerDomains() at startup; the engine core (lib.zig)
// imports none of it.
const atomicassets = @import("atomicassets/mod.zig");

const Store = wormdb.storage.Store;
const EventBus = wormdb.event.EventBus;
const Server = wormdb.server.Server;
// io_uring / epoll backends are Linux-only; referenced through
// `wormdb.server.uring`/`.epoll` inside comptime-gated blocks below.
const Gateway = wormdb.server.Gateway;
const build_options = @import("build_options");
const QuicGateway = wormdb.server.QuicGateway;
const auth = wormdb.server.auth;
const Cluster = wormdb.cluster.Cluster;
const NamespaceRegistry = wormdb.vector.NamespaceRegistry;

const PersistenceMode = wormdb.core.config.PersistenceMode;
const Backend = wormdb.core.config.Backend;
const WormDBConfig = wormdb.core.config.WormDBConfig;
const SegmentMount = wormdb.core.config.SegmentMount;
const loadFromFile = wormdb.core.config.loadFromFile;
const LightApiNetwork = wormdb.lightapi.config.LightApiNetwork;

// Zig 0.16: "Juicy Main" — accept std.process.Init for pre-initialized
// allocator, Io, args, and environment.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Get args as a slice via the arena allocator
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // --- Step 1: Pre-scan for --help and --config ---
    var config_path: []const u8 = "wormdb.json";
    {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
                try printHelp(init.io);
                return;
            } else if (std.mem.eql(u8, args[i], "--config")) {
                i += 1;
                if (i >= args.len) {
                    std.log.err("--config requires an argument", .{});
                    return error.InvalidArgs;
                }
                config_path = args[i];
            }
        }
    }

    // --- Step 2: Load config from JSON file (missing file = all defaults) ---
    var cfg = loadFromFile(config_path, allocator) catch |err| {
        std.log.err("Failed to load config from '{s}': {}", .{ config_path, err });
        return err;
    };

    // --- Step 3: Apply CLI overrides ---
    // Segment mounts named on the CLI (generic `--segment name=path`, plus the
    // domain-named back-compat aliases) are collected here, then appended to the
    // config-file `segments` after the loop.
    var cli_segments: std.ArrayListUnmanaged(SegmentMount) = .empty;
    defer cli_segments.deinit(allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--port requires an argument", .{});
                return error.InvalidArgs;
            }
            cfg.server.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--data")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--data requires an argument", .{});
                return error.InvalidArgs;
            }
            cfg.data = args[i];
        } else if (std.mem.eql(u8, args[i], "--cluster")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--cluster requires an argument", .{});
                return error.InvalidArgs;
            }
            cfg.cluster.name = args[i];
        } else if (std.mem.eql(u8, args[i], "--seed")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--seed requires an argument", .{});
                return error.InvalidArgs;
            }
            cfg.cluster.seed = args[i];
        } else if (std.mem.eql(u8, args[i], "--replicas")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--replicas requires an argument", .{});
                return error.InvalidArgs;
            }
            cfg.cluster.replication_factor = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--gossip-port")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--gossip-port requires an argument", .{});
                return error.InvalidArgs;
            }
            cfg.cluster.gossip_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--wg-port")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--wg-port requires an argument", .{});
                return error.InvalidArgs;
            }
            cfg.cluster.wg_port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--no-sync")) {
            cfg.store.sync_writes = false;
        } else if (std.mem.eql(u8, args[i], "--persistence")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--persistence requires an argument (full, snapshot, none)", .{});
                return error.InvalidArgs;
            }
            if (std.mem.eql(u8, args[i], "full")) {
                cfg.store.persistence = .full;
            } else if (std.mem.eql(u8, args[i], "snapshot")) {
                cfg.store.persistence = .snapshot;
            } else if (std.mem.eql(u8, args[i], "none")) {
                cfg.store.persistence = .none;
            } else {
                std.log.err("Invalid persistence mode: {s} (expected: full, snapshot, none)", .{args[i]});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, args[i], "--segment")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--segment requires an argument (name=path)", .{});
                return error.InvalidArgs;
            }
            const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse {
                std.log.err("--segment expects name=path, got '{s}'", .{args[i]});
                return error.InvalidArgs;
            };
            try cli_segments.append(allocator, .{ .name = args[i][0..eq], .path = args[i][eq + 1 ..] });
        } else if (std.mem.eql(u8, args[i], "--lightapi-segment")) {
            // Deprecated alias for `--segment lightapi=<path>` (kept for existing deployments).
            i += 1;
            if (i >= args.len) {
                std.log.err("--lightapi-segment requires an argument", .{});
                return error.InvalidArgs;
            }
            try cli_segments.append(allocator, .{ .name = "lightapi", .path = args[i] });
        } else if (std.mem.eql(u8, args[i], "--atomicassets-segment")) {
            // Deprecated alias for `--segment atomicassets=<path>`.
            i += 1;
            if (i >= args.len) {
                std.log.err("--atomicassets-segment requires an argument", .{});
                return error.InvalidArgs;
            }
            try cli_segments.append(allocator, .{ .name = "atomicassets", .path = args[i] });
        } else if (std.mem.eql(u8, args[i], "--gateway-port")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--gateway-port requires an argument", .{});
                return error.InvalidArgs;
            }
            cfg.gateway.enabled = true;
            cfg.gateway.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--io-uring")) {
            cfg.server.backend = .uring;
        } else if (std.mem.eql(u8, args[i], "--backend")) {
            i += 1;
            if (i >= args.len) {
                std.log.err("--backend requires an argument (threadpool, uring, epoll)", .{});
                return error.InvalidArgs;
            }
            if (std.mem.eql(u8, args[i], "threadpool")) {
                cfg.server.backend = .threadpool;
            } else if (std.mem.eql(u8, args[i], "uring")) {
                cfg.server.backend = .uring;
            } else if (std.mem.eql(u8, args[i], "epoll")) {
                cfg.server.backend = .epoll;
            } else {
                std.log.err("Invalid backend: {s} (expected: threadpool, uring, epoll)", .{args[i]});
                return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, args[i], "--config")) {
            i += 1; // Already handled in pre-scan, skip the value
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try printHelp(init.io);
            return;
        } else {
            std.log.err("Unknown argument: {s}", .{args[i]});
            return error.InvalidArgs;
        }
    }

    // Fold CLI-named segment mounts into the config-file list (CLI appended last).
    if (cli_segments.items.len > 0) {
        var all = try std.ArrayListUnmanaged(SegmentMount).initCapacity(allocator, cfg.segments.len + cli_segments.items.len);
        all.appendSliceAssumeCapacity(cfg.segments);
        all.appendSliceAssumeCapacity(cli_segments.items);
        cfg.segments = try all.toOwnedSlice(allocator);
    }

    // --- Step 4: Start WormDB with resolved config ---
    // Light-API networks are a domain config section parsed by the domain itself,
    // so core stays domain-agnostic. Empty if the file or the section is absent.
    const la_networks = wormdb.lightapi.config.loadNetworks(config_path, allocator) catch |err| blk: {
        std.log.warn("Light-API config load failed: {s}", .{@errorName(err)});
        break :blk &.{};
    };
    try startServer(allocator, &cfg, la_networks);
}

fn startServer(allocator: std.mem.Allocator, cfg: *const WormDBConfig, la_networks: []const LightApiNetwork) !void {
    const port = cfg.server.port;
    const data_dir = cfg.data;
    const persistence = cfg.store.persistence;

    // Create data directory if it doesn't exist
    // Zig 0.16: use Io.Dir.cwd() + createDirPath with blocking Io
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch |err| {
        logStartupFailure(err, port, data_dir);
        return err;
    };

    // Initialize WAL path
    const wal_path = try std.fmt.allocPrint(allocator, "{s}/wormdb.wal", .{data_dir});
    defer allocator.free(wal_path);

    // Per-namespace HNSW index registry. Constructed BEFORE the store so
    // its init can restore graph state from a v2 snapshot trailer in the
    // same pass as the KV load. Cold namespaces with no inserts cost nothing.
    var vector_registry = NamespaceRegistry.init(allocator, .{});
    defer vector_registry.deinit();

    // Initialize store (restores KV + HNSW trailer if the snapshot is v2)
    std.log.info("Initializing store at {s}", .{data_dir});
    if (!cfg.store.sync_writes) std.log.warn("sync_writes disabled — data may be lost on crash", .{});
    var store = Store.initWithRegistry(allocator, .{
        .wal_path = wal_path,
        .sync_writes = cfg.store.sync_writes,
        .persistence = persistence,
    }, &vector_registry) catch |err| {
        logStartupFailure(err, port, data_dir);
        return err;
    };
    defer store.deinit();

    // Start group-commit background sync thread (safe now that store is at stable address).
    if (persistence == .full) {
        store.startBackgroundTasks() catch |err| {
            logStartupFailure(err, port, data_dir);
            return err;
        };
    }

    // Compose domain packages: register their EXEC procedures into the engine registry.
    // The domains live in their own repos (e.g. wormdb-domain-atomicassets); the engine core
    // imports none of them — main is the composition root that wires their manifests in.
    wormdb.procedures.registry.registerDomains(atomicassets.manifest.procedures);
    std.log.info("Composed domain '{s}': {d} procedures, table ids {d}..={d}", .{
        atomicassets.manifest.name,
        atomicassets.manifest.procedures.len,
        atomicassets.manifest.table_id_lo,
        atomicassets.manifest.table_id_hi,
    });

    // Attach the configured frozen segments: each a read-only mmap addressed by an
    // opaque name a serving layer looks up. The engine assigns the name no meaning;
    // segments stay mapped for the process lifetime (closed on shutdown).
    const opened_segs = try allocator.alloc(?wormdb.storage.Segment, cfg.segments.len);
    defer {
        for (opened_segs) |*os| if (os.*) |*s| s.close(allocator);
        allocator.free(opened_segs);
    }
    for (cfg.segments, 0..) |mount, idx| {
        opened_segs[idx] = wormdb.storage.Segment.open(allocator, mount.path) catch |err| blk: {
            std.log.err("Failed to open segment '{s}' ({s}): {}", .{ mount.name, mount.path, err });
            break :blk null;
        };
        if (opened_segs[idx]) |*s| {
            store.attachSegment(mount.name, s);
            std.log.info(
                "Segment '{s}': {s} ({d} bytes, {s}-backed, {d} tables)",
                .{ mount.name, mount.path, s.bytes.len, @tagName(s.backing), s.tableCount() },
            );
        }
    }

    // Seed the Light-API chain metadata from the domain config (a no-op when no networks
    // are configured), so serving a snapshot segment needs no external loader. The live
    // feed overwrites block_num/sync later.
    wormdb.lightapi.seed.run(&store, allocator, la_networks) catch |err| {
        std.log.warn("Light-API metadata seed failed: {s}", .{@errorName(err)});
    };

    // Initialize event bus
    var event_bus = EventBus.init(allocator);
    defer event_bus.deinit();

    // Initialize cluster if enabled. Clustering depends on meshguard's
    // WireGuard/netlink layer, which is Linux-only; on other platforms we log
    // and run single-node. (See docs/WINDOWS.md and the meshguard port notes.)
    var cluster: ?Cluster = null;
    if (cfg.cluster.name != null) {
        if (comptime wormdb.server.is_linux) {
            std.log.info("Initializing cluster: {s}", .{cfg.cluster.name.?});
            // Pass seed as a single-element slice if provided
            var seed_slice: [1][]const u8 = undefined;
            const seeds: []const []const u8 = if (cfg.cluster.seed) |seed| blk: {
                seed_slice[0] = seed;
                break :blk seed_slice[0..1];
            } else &.{};

            cluster = Cluster.init(allocator, &store, &event_bus, .{
                .seed_addrs = seeds,
                .replication_factor = cfg.cluster.replication_factor,
                .peer_port = port,
                .config_dir = data_dir,
                .gossip_port = cfg.cluster.gossip_port,
                .wg_port = cfg.cluster.wg_port,
            });
            cluster.?.attachVectorRegistry(&vector_registry);
        } else {
            std.log.warn("cluster '{s}' requested, but clustering is Linux-only — running single-node", .{cfg.cluster.name.?});
        }
    }
    defer if (cluster != null) {
        cluster.?.deinit();
    };

    // Initialize server
    var server = Server.init(allocator, &store, &event_bus, .{
        .port = port,
        .cluster = if (cluster) |*c| c else null,
        .vector_registry = &vector_registry,
    });

    // Log startup info
    std.log.info("WormDB starting on port {d}", .{port});
    std.log.info("Data directory: {s}", .{data_dir});
    if (cfg.cluster.name) |name| {
        std.log.info("Cluster: {s} (replication: {d})", .{ name, cfg.cluster.replication_factor });
    }
    std.log.info("Persistence: {s}", .{@tagName(persistence)});
    if (cfg.gateway.enabled) {
        std.log.info("Gateway: port {d}", .{cfg.gateway.port});
        if (cfg.gateway.public_endpoint) |ep| {
            std.log.info("Public endpoint: {s}", .{ep});
        }
    }

    // Start cluster discovery if enabled
    if (cluster) |*c| {
        c.start();
    }

    // Start WebSocket gateway if enabled
    if (cfg.gateway.enabled) {
        var gw = Gateway.init(
            allocator,
            &store,
            &event_bus,
            if (cluster) |*c| c else null,
            cfg.gateway.port,
        );

        // Wire auth config into gateway
        if (cfg.auth.public_keys.len > 0) {
            var pks = allocator.alloc(auth.PublicKey, cfg.auth.public_keys.len) catch {
                std.log.err("Failed to allocate auth public keys", .{});
                return;
            };
            var valid_count: usize = 0;
            for (cfg.auth.public_keys) |b64_key| {
                const pk = auth.decodePublicKey(b64_key) catch {
                    std.log.err("Invalid auth public key: {s}", .{b64_key});
                    continue;
                };
                pks[valid_count] = pk;
                valid_count += 1;
            }
            if (valid_count > 0) {
                gw.public_keys = pks[0..valid_count];
                gw.auth_required = cfg.auth.require_auth;
                gw.max_token_age = cfg.auth.token_max_age_s;
                std.log.info("Auth: {d} public key(s) loaded, require_auth={}", .{ valid_count, cfg.auth.require_auth });
            }
        }

        _ = gw.start() catch |err| {
            std.log.err("Gateway start failed: {}", .{err});
        };
    }

    // Start QUIC/WebTransport gateway if enabled (compile-time gated)
    if (comptime build_options.quic) {
        if (cfg.gateway.quic_enabled) {
            const cert_path_raw = cfg.gateway.tls_cert_path orelse {
                std.log.err("QUIC Gateway: tls_cert_path is required when quic_enabled=true", .{});
                return;
            };
            const key_path_raw = cfg.gateway.tls_key_path orelse {
                std.log.err("QUIC Gateway: tls_key_path is required when quic_enabled=true", .{});
                return;
            };

            // Sentinel-terminate paths for C interop
            const cert_path = allocator.dupeZ(u8, cert_path_raw) catch {
                std.log.err("QUIC Gateway: failed to allocate cert path", .{});
                return;
            };
            const key_path = allocator.dupeZ(u8, key_path_raw) catch {
                std.log.err("QUIC Gateway: failed to allocate key path", .{});
                return;
            };

            std.log.info("QUIC Gateway: port {d}", .{cfg.gateway.quic_port});

            var quic_gw = QuicGateway.init(
                allocator,
                &store,
                &event_bus,
                if (cluster) |*c| c else null,
                cfg.gateway.quic_port,
                cert_path,
                key_path,
            );

            // Wire auth config (same keys as WebSocket gateway)
            if (cfg.auth.public_keys.len > 0) {
                var pks = allocator.alloc(auth.PublicKey, cfg.auth.public_keys.len) catch {
                    std.log.err("QUIC Gateway: failed to allocate auth public keys", .{});
                    return;
                };
                var valid_count: usize = 0;
                for (cfg.auth.public_keys) |b64_key| {
                    const pk = auth.decodePublicKey(b64_key) catch {
                        std.log.err("Invalid auth public key: {s}", .{b64_key});
                        continue;
                    };
                    pks[valid_count] = pk;
                    valid_count += 1;
                }
                if (valid_count > 0) {
                    quic_gw.public_keys = pks[0..valid_count];
                    quic_gw.auth_required = cfg.auth.require_auth;
                    quic_gw.max_token_age = cfg.auth.token_max_age_s;
                }
            }

            // Register as global for session callbacks
            quic_gw.setGlobal();

            _ = quic_gw.start() catch |err| {
                std.log.err("QUIC Gateway start failed: {}", .{err});
            };
        }
    }

    // Run server — selected backend. io_uring and epoll are Linux-only; on
    // other platforms the request transparently falls back to the thread pool.
    const backend = blk: {
        const requested = cfg.server.backend;
        if (!wormdb.server.is_linux and requested != .threadpool) {
            std.log.warn("backend '{s}' is Linux-only; using thread pool on this platform", .{@tagName(requested)});
            break :blk .threadpool;
        }
        break :blk requested;
    };
    std.log.info("Backend: {s}", .{@tagName(backend)});
    switch (backend) {
        .uring => {
            if (comptime wormdb.server.is_linux) {
                var uring_server = wormdb.server.uring.UringServer.init(
                    allocator,
                    &store,
                    &event_bus,
                    if (cluster) |*c| c else null,
                    "0.0.0.0",
                    port,
                ) catch |err| {
                    std.log.err("io_uring init failed: {}, falling back to thread pool", .{err});
                    try server.run();
                    return;
                };
                defer uring_server.deinit();
                uring_server.run() catch |err| {
                    logStartupFailure(err, port, data_dir);
                    return err;
                };
            } else unreachable;
        },
        .epoll => {
            if (comptime wormdb.server.is_linux) {
                var epoll_server = wormdb.server.epoll.EpollServer.init(
                    allocator,
                    &store,
                    &event_bus,
                    if (cluster) |*c| c else null,
                    "0.0.0.0",
                    port,
                ) catch |err| {
                    std.log.err("epoll init failed: {}, falling back to thread pool", .{err});
                    try server.run();
                    return;
                };
                defer epoll_server.deinit();
                epoll_server.run() catch |err| {
                    logStartupFailure(err, port, data_dir);
                    return err;
                };
            } else unreachable;
        },
        .threadpool => {
            server.run() catch |err| {
                logStartupFailure(err, port, data_dir);
                return err;
            };
        },
    }
}

fn logStartupFailure(err: anyerror, port: u16, data_dir: []const u8) void {
    std.log.err("WormDB startup failed: {}", .{err});

    switch (err) {
        error.AddressInUse => {
            std.log.err("Port {d} is already in use.", .{port});
            std.log.err("Remediation: free the port, or start with --port <other-port> (for example, --port 6390).", .{});
        },
        error.AddressNotAvailable => {
            std.log.err("Bind address is invalid or not available on this host.", .{});
            std.log.err("Remediation: verify the bind interface and host networking configuration.", .{});
        },
        error.AccessDenied, error.PermissionDenied => {
            std.log.err("Permission denied while binding port {d} or accessing data path '{s}'.", .{ port, data_dir });
            std.log.err("Remediation: verify directory/file permissions and run with privileges that can open the selected port and WAL path.", .{});
        },
        error.FileNotFound, error.NotDir => {
            std.log.err("Data path '{s}' is invalid or missing.", .{data_dir});
            std.log.err("Remediation: create/fix the data directory path and retry with --data <path>.", .{});
        },
        else => {
            std.log.err("Remediation: verify --port/--data options, check filesystem permissions for WAL, and retry.", .{});
        },
    }
}

fn printHelp(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\WormDB - Distributed Key-Value Store with WORM and Event Streaming
        \\
        \\Usage:
        \\  wormdb [options]
        \\
        \\Options:
        \\  --config <path>            JSON config file (default: ./wormdb.json)
        \\  --port <port>              TCP port to listen on (default: 6389)
        \\  --data <path>              Data directory for WAL (default: ./data)
        \\  --backend <type>           Server backend: threadpool (default), uring, epoll
        \\  --cluster <name>           Cluster name for mesh discovery
        \\  --seed <addr:port>         Seed node address for joining cluster
        \\  --replicas <n>             Replication factor (default: 0 = all peers)
        \\  --gossip-port <port>       SWIM gossip UDP port (default: 51821)
        \\  --wg-port <port>           WireGuard listen port (default: 51830)
        \\  --no-sync                  Disable fsync per write (faster, less durable)
        \\  --persistence <mode>       Persistence mode: full (default), snapshot, none
        \\  --segment <name=path>      Frozen segment (.wseg) to mmap at startup, attached under <name>
        \\                             (repeatable; e.g. --segment lightapi=la.wseg --segment atomicassets=aa.wseg)
        \\  --lightapi-segment <path>  Deprecated alias for --segment lightapi=<path>
        \\  --atomicassets-segment <path>  Deprecated alias for --segment atomicassets=<path>
        \\  --gateway-port <port>      Enable the HTTP/WebSocket gateway on <port>
        \\  --help, -h                 Show this help
        \\
        \\Config File:
        \\  WormDB loads configuration from a JSON file. CLI flags override file values.
        \\  If no --config is provided, ./wormdb.json is used if present.
        \\
        \\  Example wormdb.json:
        \\    {
        \\      "data": "./data",
        \\      "server": { "port": 6389 },
        \\      "cluster": { "name": "myapp", "seed": "10.0.0.1:51821" },
        \\      "gateway": { "enabled": true, "port": 6390 }
        \\    }
        \\
        \\Protocol:
        \\  WormWire v1 (binary framing) over TCP
        \\  Client magic: 0x57 0x57 ("WW")  Replication magic: 0x57 0x52 ("WR")
        \\
        \\Examples:
        \\  Start standalone:
        \\    wormdb --port 6389 --data ./mydata
        \\
        \\  Start with config file:
        \\    wormdb --config /etc/wormdb/config.json
        \\
        \\  Start cluster node:
        \\    wormdb --cluster myapp --port 6389
        \\
        \\  Join existing cluster:
        \\    wormdb --cluster myapp --seed 10.99.42.1:51821 --port 6389
        \\
    );
}
