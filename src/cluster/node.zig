//! Cluster node management — embedded meshguard mesh networking
//!
//! Uses meshguard library directly for:
//!   - Ed25519 identity and deterministic mesh IPs
//!   - SWIM protocol for peer discovery and liveness
//!   - WireGuard interface management (kernel netlink)
//!   - WormWire replication over mesh tunnels

const std = @import("std");
const builtin = @import("builtin");
const meshguard = @import("meshguard");
const storage = @import("../storage/mod.zig");
const event = @import("../event/mod.zig");
const wire = @import("../protocol/wire.zig");
const core = @import("../core/mod.zig");
const Command = core.types.Command;

const Store = storage.Store;
const EventBus = event.EventBus;

const Keys = meshguard.identity.Keys;
const Membership = meshguard.discovery.Membership;
const Swim = meshguard.discovery.Swim;
const Seed = meshguard.discovery.Seed;
const Udp = meshguard.net.Udp;
const WgConfig = meshguard.wireguard.Config;
const WgIp = meshguard.wireguard.Ip;
const messages = meshguard.protocol.Messages;

pub const ClusterNode = struct {
    pubkey: [32]u8,
    mesh_ip: [4]u8,
    last_seen_ns: i128,
    state: NodeState,
    name: []const u8,

    pub const NodeState = enum {
        alive,
        suspected,
        dead,
    };
};

pub const ClusterConfig = struct {
    /// Seed node addresses (host:port strings)
    seed_addrs: []const []const u8 = &.{},
    /// Replication factor (0 = replicate to all peers)
    replication_factor: usize = 0,
    /// WormDB port on peer mesh IPs (peers use same port)
    peer_port: u16 = 6389,
    /// Config directory for identity persistence
    config_dir: []const u8 = "/tmp/wormdb",
    /// Use open mode (no trust enforcement)
    open_mode: bool = true,
    /// SWIM gossip port
    gossip_port: u16 = 51821,
    /// WireGuard listen port
    wg_port: u16 = 51830,
};

pub const ClusterStatus = struct {
    total_nodes: usize,
    alive_nodes: usize,
    suspected_nodes: usize,
    dead_nodes: usize,
    replication_factor: usize,
    connected_peers: usize,
    mesh_ip: [4]u8,
    enabled: bool,
    proof_checkpoint_records: usize,
    proof_witness_records: usize,
    proof_last_verified_ms: u64,
    anti_entropy_mode: []const u8,
};

/// A persistent WormWire TCP connection to a peer WormDB node.
const PeerConnection = struct {
    mesh_ip: [4]u8,
    /// Real network IP of the peer (from SWIM endpoint exchange).
    /// Used for replication connections instead of mesh IP when available,
    /// since WireGuard tunnels may not be functional (e.g. Docker).
    real_addr: ?[4]u8,
    stream: ?core.compat.net.Stream,
    last_connect_attempt_ns: i128,
    /// Set to true when a new connection is established.
    /// Consumed by replicateWrite to trigger a full-state anti-entropy sync.
    needs_sync: bool,
    /// Set by onPeerDead, cleared by onPeerJoin. Prevents blocking TCP connect
    /// attempts to unreachable peers.
    is_dead: bool,

    fn connect(self: *PeerConnection, port: u16) void {
        if (self.stream != null) return;
        if (self.is_dead) return;

        const now = core.compat.nowNs();
        if (now - self.last_connect_attempt_ns < 2_000_000_000) return;
        self.last_connect_attempt_ns = now;

        // Use real network IP (Docker bridge / LAN) if available,
        // fall back to mesh IP (requires WireGuard tunnel).
        const ip = self.real_addr orelse self.mesh_ip;
        const addr = core.compat.net.Address.initIp4(ip, port);
        const stream = core.compat.net.tcpConnectToAddress(addr) catch return;

        // Set send timeout so writeAll to dead peers times out in 2s
        // instead of blocking for 30+ seconds (Linux TCP keepalive default).
        // POSIX-only (std.posix.setsockopt is a compile-error on Windows); the
        // cluster path only runs on Linux, so this is gated rather than ported.
        if (comptime builtin.os.tag == .linux) {
            const timeval = std.posix.timeval{ .sec = 2, .usec = 0 };
            std.posix.setsockopt(stream.getHandle(), std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeval)) catch {};
        }

        var stream_mut = stream;
        stream_mut.writeAll(&.{ 0x57, 0x52 }) catch {
            stream_mut.close();
            return;
        };

        self.stream = stream_mut;
        self.needs_sync = true;
        std.log.info("cluster: connected to peer {d}.{d}.{d}.{d}:{d}", .{
            ip[0], ip[1], ip[2], ip[3], port,
        });
    }

    fn disconnect(self: *PeerConnection) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    fn sendCommand(self: *PeerConnection, cmd: Command) bool {
        if (self.stream == null) return false;
        // wire.writeCommand takes an anytype writer with a `.writeAll` method;
        // core.compat.net.Stream.writeAll requires `*Stream`, so pass by pointer.
        wire.writeCommand(&self.stream.?, cmd) catch {
            self.disconnect();
            return false;
        };
        return true;
    }
};

pub const Cluster = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    event_bus: *EventBus,
    config: ClusterConfig,
    /// Optional HNSW registry back-reference. When set, the anti-entropy
    /// sync emits VINSERT frames for keys belonging to a registered
    /// namespace (so the peer reconstructs both KV + HNSW in one shot);
    /// other keys still go out as SET. Attached via attachVectorRegistry
    /// after construction — same shape as Store.attachVectorRegistry.
    vector_registry: ?*@import("../vector/index.zig").NamespaceRegistry = null,

    // meshguard components (embedded)
    identity: Keys.KeyPair,
    mesh_ip: [4]u8,
    membership: Membership.MembershipTable,
    swim: ?Swim.SwimProtocol,
    gossip_socket: ?Udp.UdpSocket,

    // Active WormWire replication connections (keyed by mesh IP)
    peers: std.AutoHashMap([4]u8, PeerConnection),
    mutex: core.compat.Mutex,

    // Discovery thread
    discovery_thread: ?std.Thread,
    running: std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        event_bus: *EventBus,
        config: ClusterConfig,
    ) Cluster {
        // Generate or load identity
        const kp = Keys.load(allocator, config.config_dir) catch blk: {
            const new_kp = Keys.generate();
            Keys.save(allocator, config.config_dir, new_kp) catch |err| {
                std.log.warn("cluster: failed to save identity: {s}", .{@errorName(err)});
            };
            std.log.info("cluster: generated new identity", .{});
            break :blk new_kp;
        };

        // Derive deterministic mesh IP from public key
        const pub_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(kp.public_key.toBytes()) catch unreachable;
        const mesh_ip = WgIp.deriveFromPubkey(pub_key);
        var ip_buf: [15]u8 = undefined;
        const ip_str = WgIp.formatIp(mesh_ip, &ip_buf);
        std.log.info("cluster: mesh IP {s}", .{ip_str});

        return .{
            .allocator = allocator,
            .store = store,
            .event_bus = event_bus,
            .config = config,
            .identity = kp,
            .mesh_ip = mesh_ip,
            .membership = Membership.MembershipTable.init(allocator, 5000),
            .swim = null,
            .gossip_socket = null,
            .peers = std.AutoHashMap([4]u8, PeerConnection).init(allocator),
            .mutex = .{},
            .discovery_thread = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Cluster) void {
        self.stop();
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.disconnect();
        }
        self.peers.deinit();
        self.membership.deinit();
        if (self.gossip_socket) |*s| s.close();
    }

    pub fn attachVectorRegistry(
        self: *Cluster,
        registry: *@import("../vector/index.zig").NamespaceRegistry,
    ) void {
        self.vector_registry = registry;
    }

    pub fn identityPublicKey(self: *const Cluster) [32]u8 {
        return self.identity.public_key.toBytes();
    }

    pub fn signWithIdentity(self: *const Cluster, message: []const u8) ![64]u8 {
        return try Keys.sign(message, self.identity.secret_key);
    }

    /// Start the mesh network: bind gossip socket, init SWIM, seed peers, start discovery thread.
    pub fn start(self: *Cluster) void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);

        // Bind gossip UDP socket
        self.gossip_socket = Udp.UdpSocket.bind(self.config.gossip_port) catch |err| {
            std.log.err("cluster: failed to bind gossip port {d}: {s}", .{ self.config.gossip_port, @errorName(err) });
            self.running.store(false, .release);
            return;
        };

        // Derive WireGuard X25519 key from Ed25519 identity
        const sk_seed = self.identity.secret_key.seed();
        var hash: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(&sk_seed, &hash, .{});
        var wg_private: [32]u8 = hash[0..32].*;
        wg_private[0] &= 248;
        wg_private[31] &= 127;
        wg_private[31] |= 64;

        const wg_public = std.crypto.dh.X25519.recoverPublicKey(wg_private) catch {
            std.log.err("cluster: failed to derive WG public key", .{});
            self.running.store(false, .release);
            return;
        };

        // Setup WireGuard kernel interface (Linux-only: meshguard manages the
        // interface via netlink, which has no Windows/macOS equivalent here).
        // Off Linux the mesh runs over real peer addresses (same fallback used
        // when WG tunnels are unavailable, e.g. Docker).
        if (comptime builtin.os.tag == .linux) {
            WgConfig.setup(.{
                .private_key = wg_private,
                .listen_port = self.config.wg_port,
                .mesh_ip = self.mesh_ip,
            }) catch |err| {
                std.log.warn("cluster: WG interface setup failed: {s} (continuing without WG)", .{@errorName(err)});
            };
        } else {
            std.log.warn("cluster: WireGuard interface management is Linux-only; running mesh over real peer addresses", .{});
        }

        // Initialize SWIM protocol
        self.swim = Swim.SwimProtocol.init(
            &self.membership,
            self.gossip_socket.?,
            .{ .gossip_port = self.config.gossip_port },
            self.identity.public_key.toBytes(),
            wg_public,
            self.mesh_ip,
            self.config.wg_port,
            .{
                .ctx = @ptrCast(self),
                .onPeerJoin = &onPeerJoin,
                .onPeerDead = &onPeerDead,
                .onPeerPunched = &onPeerPunched,
            },
        );

        // Resolve and seed peers (uses libc getaddrinfo for Docker DNS compatibility)
        var seed_buf: [16]messages.Endpoint = undefined;
        var seed_count: usize = 0;
        for (self.config.seed_addrs) |seed_str| {
            if (resolveSeedEndpoint(seed_str)) |ep| {
                if (seed_count < seed_buf.len) {
                    seed_buf[seed_count] = ep;
                    seed_count += 1;
                }
            } else {
                std.log.warn("cluster: failed to resolve seed '{s}'", .{seed_str});
            }
        }

        if (seed_count > 0) {
            std.log.info("cluster: seeding {d} peer(s)", .{seed_count});
            self.swim.?.seedPeers(seed_buf[0..seed_count]);
        }

        std.log.info("cluster: mesh started (gossip:{d}, wg:{d})", .{
            self.config.gossip_port, self.config.wg_port,
        });

        // Start discovery thread (runs SWIM tick loop)
        self.discovery_thread = std.Thread.spawn(.{}, discoveryLoop, .{self}) catch |err| {
            std.log.err("cluster: failed to start discovery thread: {s}", .{@errorName(err)});
            self.running.store(false, .release);
            return;
        };
    }

    pub fn stop(self: *Cluster) void {
        if (!self.running.load(.acquire)) return;

        // Broadcast leave to peers before shutdown
        if (self.swim) |*s| s.broadcastLeave();

        self.running.store(false, .release);
        if (self.discovery_thread) |t| {
            t.join();
            self.discovery_thread = null;
        }

        // Teardown WireGuard interface (Linux-only; see start()).
        if (comptime builtin.os.tag == .linux) {
            WgConfig.teardown(WgConfig.DEFAULT_IFNAME) catch {};
        }
    }

    /// Reconcile the peer map from SWIM membership, then for every peer
    /// (alive or newly resurrected): connect + run anti-entropy if needed.
    /// Caller must hold `self.mutex`.
    ///
    /// Shared by `replicateWrite`, `replicateVinsert`, and `replicateVdelete`
    /// so any replicable event can wake a dormant peer and trigger sync.
    fn ensurePeersConnectedLocked(self: *Cluster) void {
        // ── Reconcile peer map from SWIM ──
        var swim_iter = self.membership.peers.iterator();
        while (swim_iter.next()) |swim_entry| {
            const swim_peer = swim_entry.value_ptr;
            if (swim_peer.state != .alive) continue;

            const real_addr: ?[4]u8 = if (swim_peer.gossip_endpoint) |ep| ep.addr else null;

            if (self.peers.getPtr(swim_peer.mesh_ip)) |pc| {
                if (pc.is_dead) {
                    pc.is_dead = false;
                    pc.needs_sync = true;
                    if (real_addr != null) pc.real_addr = real_addr;
                    var ip_buf: [15]u8 = undefined;
                    const ip_str = WgIp.formatIp(swim_peer.mesh_ip, &ip_buf);
                    std.log.info("cluster: peer alive again {s}", .{ip_str});
                }
            } else {
                self.peers.put(swim_peer.mesh_ip, PeerConnection{
                    .mesh_ip = swim_peer.mesh_ip,
                    .real_addr = real_addr,
                    .stream = null,
                    .last_connect_attempt_ns = 0,
                    .needs_sync = true,
                    .is_dead = false,
                }) catch {};
                var ip_buf: [15]u8 = undefined;
                const ip_str = WgIp.formatIp(swim_peer.mesh_ip, &ip_buf);
                std.log.info("cluster: discovered peer from SWIM {s}", .{ip_str});
            }
        }

        // ── Connect + anti-entropy sync per peer ──
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            var peer = entry.value_ptr;
            peer.connect(self.config.peer_port);

            if (peer.needs_sync and peer.stream != null) {
                peer.needs_sync = false;
                var ip_buf: [15]u8 = undefined;
                const ip_str = WgIp.formatIp(peer.mesh_ip, &ip_buf);
                std.log.info("cluster: anti-entropy sync starting for {s}", .{ip_str});

                // Snapshot the registry's namespaces once so the per-key
                // callback can do cheap prefix checks. The registry's own
                // read-lock stays brief; NamespaceIndex pointers remain
                // valid because nothing removes namespaces during this sync.
                const RegSnap = struct {
                    prefix: []const u8,
                    idx: *@import("../vector/index.zig").NamespaceIndex,
                };
                var reg_snap: std.ArrayListUnmanaged(RegSnap) = .empty;
                defer reg_snap.deinit(self.allocator);
                if (self.vector_registry) |reg| {
                    reg.lock.lockShared();
                    defer reg.lock.unlockShared();
                    var ri = reg.map.iterator();
                    while (ri.next()) |e| {
                        reg_snap.append(self.allocator, .{
                            .prefix = e.key_ptr.*,
                            .idx = e.value_ptr.*,
                        }) catch break;
                    }
                }

                const SyncCtx = struct {
                    p: *PeerConnection,
                    synced_set: usize = 0,
                    synced_vinsert: usize = 0,
                    skipped_bq: usize = 0,
                    reg_snap: []const RegSnap,
                    /// Find which registered namespace (if any) owns this key.
                    fn matchNamespace(ctx: @This(), key: []const u8) ?*RegSnap {
                        for (ctx.reg_snap) |*r| {
                            if (std.mem.startsWith(u8, key, r.prefix)) return @constCast(r);
                        }
                        return null;
                    }
                };
                var sync_ctx = SyncCtx{ .p = peer, .reg_snap = reg_snap.items };

                self.store.iterateAll(@ptrCast(&sync_ctx), &struct {
                    fn cb(raw_ctx: *anyopaque, k: []const u8, v: []const u8, w: bool) void {
                        const sctx: *SyncCtx = @ptrCast(@alignCast(raw_ctx));

                        // `bq:<ns><id>` companions: skip when the namespace
                        // is registered — the peer regenerates them from
                        // VINSERT. Otherwise, SET replicates them.
                        const BQ_PREFIX = "bq:";
                        if (std.mem.startsWith(u8, k, BQ_PREFIX)) {
                            const stripped = k[BQ_PREFIX.len..];
                            if (sctx.matchNamespace(stripped) != null) {
                                sctx.skipped_bq += 1;
                                return;
                            }
                        }

                        // Registered-namespace vector keys: emit VINSERT.
                        if (sctx.matchNamespace(k)) |r| {
                            r.idx.lock.lockShared();
                            defer r.idx.lock.unlockShared();

                            if (r.idx.nodeIdFor(k)) |node_id| {
                                const ts = r.idx.timestamps.items[node_id];
                                if (sctx.p.sendCommand(.{ .vinsert = .{
                                    .key = k,
                                    .vector = v,
                                    .worm = w,
                                    .namespace = r.prefix,
                                    .metric = r.idx.metric.name(),
                                    .timestamp = ts,
                                } })) {
                                    sctx.synced_vinsert += 1;
                                }
                                return;
                            }
                            // Registered namespace but no HNSW node — this
                            // key was SET directly. Fall through to SET.
                        }

                        // Default path: replicate as a raw SET.
                        if (sctx.p.sendCommand(.{ .set = .{
                            .key = k,
                            .value = v,
                            .worm = w,
                        } })) {
                            sctx.synced_set += 1;
                        }
                    }
                }.cb);

                std.log.info("cluster: sync to {s} — {d} SET, {d} VINSERT, {d} bq-skipped", .{
                    ip_str,
                    sync_ctx.synced_set,
                    sync_ctx.synced_vinsert,
                    sync_ctx.skipped_bq,
                });
            }
        }
    }

    /// Replicate a SET to all alive peers via WormWire.
    /// Also triggers anti-entropy full-state sync on newly connected peers.
    pub fn replicateWrite(self: *Cluster, key: []const u8, value: []const u8, is_worm: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ensurePeersConnectedLocked();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            var peer = entry.value_ptr;
            _ = peer.sendCommand(.{ .set = .{
                .key = key,
                .value = value,
                .worm = is_worm,
            } });
        }
    }

    /// Replicate a VINSERT to all alive peers. Carries vector bytes +
    /// metric + origin timestamp so peers update store + BQ + HNSW as a
    /// single unit. Triggers anti-entropy sync if a peer needs it.
    pub fn replicateVinsert(
        self: *Cluster,
        params: Command.VinsertParams,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ensurePeersConnectedLocked();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            var peer = entry.value_ptr;
            _ = peer.sendCommand(.{ .vinsert = params });
        }
    }

    /// Replicate a VBULKINSERT to all alive peers. Best-effort — individual
    /// peer failures are swallowed so one stuck peer can't block writes.
    pub fn replicateVbulkinsert(
        self: *Cluster,
        params: Command.VbulkinsertParams,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ensurePeersConnectedLocked();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            var peer = entry.value_ptr;
            _ = peer.sendCommand(.{ .vbulkinsert = params });
        }
    }

    /// Replicate a VDELETE to all alive peers.
    pub fn replicateVdelete(
        self: *Cluster,
        key: []const u8,
        namespace: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ensurePeersConnectedLocked();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            var peer = entry.value_ptr;
            _ = peer.sendCommand(.{ .vdelete = .{ .key = key, .namespace = namespace } });
        }
    }

    /// Ask currently connected/alive peers to countersign an append-log
    /// checkpoint using their local cluster identity. The peer-side TCP
    /// replication handler only accepts this one EXEC over REPL_MAGIC.
    pub fn requestCheckpointWitnesses(
        self: *Cluster,
        log_id: []const u8,
        checkpoint_hash_hex: []const u8,
    ) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ensurePeersConnectedLocked();

        var requested: usize = 0;
        var args = [_][]const u8{ log_id, checkpoint_hash_hex };
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            var peer = entry.value_ptr;
            if (peer.sendCommand(.{ .exec = .{
                .procedure = "append_log_witness",
                .args = args[0..],
            } })) {
                requested += 1;
            }
        }
        return requested;
    }

    /// Replicate a RaBitQ params install (centroid + rotation) to all
    /// alive peers. Issued by `EXEC vrabitq` *before* its re-encode pass
    /// streams the per-vector bq:* SETs, so peers have the params in
    /// hand when the encoded entries arrive on the same connection (TCP
    /// preserves ordering per peer).
    ///
    /// The frame is large (d=128: 64 KiB; d=1536: ~9 MiB) but one-shot
    /// per namespace per `vrabitq` invocation. The same anti-entropy
    /// reconnect logic that other replicate paths rely on covers peers
    /// that drop mid-broadcast — the next vrabitq run will resend.
    pub fn replicateVrabitqInstall(
        self: *Cluster,
        params: Command.VrabitqInstallParams,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.ensurePeersConnectedLocked();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            var peer = entry.value_ptr;
            _ = peer.sendCommand(.{ .vrabitq_install = params });
        }
    }

    /// Replicate a DEL to all alive peers via WormWire.
    pub fn replicateDelete(self: *Cluster, key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            var peer = entry.value_ptr;
            peer.connect(self.config.peer_port);
            _ = peer.sendCommand(.{ .delete = key });
        }
    }

    pub fn handleReplicatedWrite(self: *Cluster, key: []const u8, value: []const u8, is_worm: bool) !void {
        _ = self;
        _ = key;
        _ = value;
        _ = is_worm;
    }

    pub fn status(self: *Cluster) ClusterStatus {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .total_nodes = self.membership.count(),
            .alive_nodes = self.membership.countByState(.alive),
            .suspected_nodes = self.membership.countByState(.suspected),
            .dead_nodes = self.membership.countByState(.dead),
            .replication_factor = self.config.replication_factor,
            .connected_peers = self.peers.count(),
            .mesh_ip = self.mesh_ip,
            .enabled = true,
            .proof_checkpoint_records = self.store.countPrefix("proof:append-log-checkpoint:v1:"),
            .proof_witness_records = self.store.countPrefix("proof:append-log-witness:v1:"),
            .proof_last_verified_ms = 0,
            .anti_entropy_mode = "full",
        };
    }

    /// Return peer list with per-peer details for monitoring/failover.
    /// Format: one line per field, peers separated by blank lines.
    ///   self_mesh_ip=10.99.x.x
    ///   self_port=6389
    ///   ---
    ///   mesh_ip=10.99.x.x
    ///   state=alive|suspected|dead|left
    ///   gossip_endpoint=1.2.3.4:51821
    ///   wormwire=connected|disconnected
    ///   ---
    pub fn peerList(self: *Cluster, allocator: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        // Self identity
        try buf.print(allocator, "self_mesh_ip={d}.{d}.{d}.{d}\n", .{
            self.mesh_ip[0], self.mesh_ip[1], self.mesh_ip[2], self.mesh_ip[3],
        });
        try buf.print(allocator, "self_port={d}\n", .{self.config.peer_port});
        try buf.appendSlice(allocator, "---\n");

        // Iterate SWIM membership table
        var iter = self.membership.peers.iterator();
        while (iter.next()) |entry| {
            const peer = entry.value_ptr;

            try buf.print(allocator, "mesh_ip={d}.{d}.{d}.{d}\n", .{
                peer.mesh_ip[0], peer.mesh_ip[1], peer.mesh_ip[2], peer.mesh_ip[3],
            });

            const state_str: []const u8 = switch (peer.state) {
                .alive => "alive",
                .suspected => "suspected",
                .dead => "dead",
                .left => "left",
            };
            try buf.print(allocator, "state={s}\n", .{state_str});

            if (peer.gossip_endpoint) |ep| {
                var ep_buf: [32]u8 = undefined;
                const ep_str = ep.format(&ep_buf);
                try buf.print(allocator, "gossip_endpoint={s}\n", .{ep_str});
            }

            // Check if we have an active WormWire TCP connection to this peer
            const has_conn = if (self.peers.getPtr(peer.mesh_ip)) |pc|
                pc.stream != null
            else
                false;
            try buf.print(allocator, "wormwire={s}\n", .{if (has_conn) "connected" else "disconnected"});
            try buf.appendSlice(allocator, "root_sync=unknown\n");
            try buf.appendSlice(allocator, "root_sync_last_ms=0\n");
            try buf.appendSlice(allocator, "root_sync_missing_ranges=0\n");

            try buf.appendSlice(allocator, "---\n");
        }

        return buf.toOwnedSlice(allocator);
    }

    // ── SWIM event callbacks ──

    fn onPeerJoin(ctx: *anyopaque, peer: *const Membership.Peer) void {
        const self: *Cluster = @ptrCast(@alignCast(ctx));

        // Derive mesh IP for this peer
        const pub_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(peer.pubkey) catch return;
        const peer_mesh_ip = WgIp.deriveFromPubkey(pub_key);

        var ip_buf: [15]u8 = undefined;
        const ip_str = WgIp.formatIp(peer_mesh_ip, &ip_buf);
        std.log.info("cluster: peer joined {s}", .{ip_str});

        // Add WormWire replication connection
        self.mutex.lock();
        defer self.mutex.unlock();

        // Extract real network IP from SWIM gossip endpoint (e.g. Docker bridge IP).
        // This is the address SWIM actually received messages from — the real route.
        const real_addr: ?[4]u8 = if (peer.gossip_endpoint) |ep| ep.addr else null;

        if (!self.peers.contains(peer_mesh_ip)) {
            self.peers.put(peer_mesh_ip, PeerConnection{
                .mesh_ip = peer_mesh_ip,
                .real_addr = real_addr,
                .stream = null,
                .last_connect_attempt_ns = 0,
                .needs_sync = true,
                .is_dead = false,
            }) catch {};
        } else {
            // Peer returning after death — clear dead flag and update address
            if (self.peers.getPtr(peer_mesh_ip)) |conn| {
                conn.is_dead = false;
                conn.needs_sync = true;
                if (real_addr != null) conn.real_addr = real_addr;
            }
        }

        if (real_addr) |ra| {
            var ra_buf: [15]u8 = undefined;
            const ra_str = WgIp.formatIp(ra, &ra_buf);
            std.log.info("cluster: peer real addr = {s}", .{ra_str});
        }
    }

    fn onPeerDead(ctx: *anyopaque, pubkey: [32]u8) void {
        const self: *Cluster = @ptrCast(@alignCast(ctx));

        const pub_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(pubkey) catch return;
        const peer_mesh_ip = WgIp.deriveFromPubkey(pub_key);

        var ip_buf: [15]u8 = undefined;
        const ip_str = WgIp.formatIp(peer_mesh_ip, &ip_buf);
        std.log.info("cluster: peer dead {s}", .{ip_str});

        self.mutex.lock();
        defer self.mutex.unlock();

        // Disconnect but keep in the map — when replicateWrite attempts
        // reconnect and succeeds, needs_sync will trigger anti-entropy.
        if (self.peers.getPtr(peer_mesh_ip)) |p| {
            p.disconnect();
            p.is_dead = true;
            // Reset connect backoff so we retry promptly when peer returns
            p.last_connect_attempt_ns = 0;
        }
    }

    fn onPeerPunched(ctx: *anyopaque, peer: *const Membership.Peer, endpoint: messages.Endpoint) void {
        const self: *Cluster = @ptrCast(@alignCast(ctx));

        // Derive mesh IP to look up the peer connection
        const pub_key = std.crypto.sign.Ed25519.PublicKey.fromBytes(peer.pubkey) catch return;
        const peer_mesh_ip = WgIp.deriveFromPubkey(pub_key);

        // Store the peer's real network IP so replication can connect
        // without requiring a functional WireGuard tunnel.
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.peers.getPtr(peer_mesh_ip)) |conn| {
            conn.real_addr = endpoint.addr;
            var ip_buf: [15]u8 = undefined;
            const ip_str = WgIp.formatIp(endpoint.addr, &ip_buf);
            std.log.info("cluster: peer punched, real IP = {s}:{d}", .{ ip_str, endpoint.port });
        }
    }

    // ── Discovery loop (background thread) ──

    fn discoveryLoop(self: *Cluster) void {
        while (self.running.load(.acquire)) {
            if (self.swim) |*s| {
                s.tick() catch |err| {
                    std.log.warn("cluster: swim tick error: {s}", .{@errorName(err)});
                };
            }
        }
    }
};

/// Resolve a "host:port" seed string into a meshguard Endpoint.
/// Tries IP parsing first, then falls back to libc getaddrinfo for hostname resolution.
fn resolveSeedEndpoint(seed_str: []const u8) ?messages.Endpoint {
    // Split host:port
    const colon_idx = std.mem.lastIndexOfScalar(u8, seed_str, ':') orelse return null;
    const host = seed_str[0..colon_idx];
    const port_str = seed_str[colon_idx + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;

    // Try direct IP parsing first
    if (parseIpv4(host)) |addr| {
        return .{ .addr = addr, .port = port };
    }

    // Hostname: resolve via libc getaddrinfo (works with Docker DNS). The
    // @cImport of netdb.h/arpa/inet.h is POSIX-only; clustering is disabled off
    // Linux, so an unresolved hostname seed simply fails there.
    if (comptime builtin.os.tag == .linux) {
        const c = @cImport({
            @cInclude("netdb.h");
            @cInclude("arpa/inet.h");
        });

        // Null-terminate the hostname for C
        var host_buf: [256]u8 = undefined;
        if (host.len >= host_buf.len) return null;
        @memcpy(host_buf[0..host.len], host);
        host_buf[host.len] = 0;

        var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
        hints.ai_family = c.AF_INET; // IPv4 only
        hints.ai_socktype = c.SOCK_DGRAM;

        var result: ?*c.struct_addrinfo = null;
        const rc = c.getaddrinfo(&host_buf, null, &hints, &result);
        if (rc != 0 or result == null) return null;
        defer c.freeaddrinfo(result.?);

        // Extract IPv4 address from the first result
        const sa: *const c.struct_sockaddr_in = @ptrCast(@alignCast(result.?.ai_addr));
        const addr_bytes: [4]u8 = @bitCast(sa.sin_addr.s_addr);

        var ip_buf: [15]u8 = undefined;
        const ip_str = std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3] }) catch return null;
        std.log.info("cluster: resolved seed '{s}' → {s}:{d}", .{ host, ip_str, port });

        return .{ .addr = addr_bytes, .port = port };
    }

    return null;
}

fn parseIpv4(ip_str: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var dot_count: usize = 0;
    var current: u16 = 0;
    var octet_idx: usize = 0;

    for (ip_str) |c| {
        if (c == '.') {
            if (current > 255 or octet_idx >= 4) return null;
            result[octet_idx] = @intCast(current);
            octet_idx += 1;
            dot_count += 1;
            current = 0;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
        } else return null;
    }

    if (dot_count != 3 or octet_idx != 3 or current > 255) return null;
    result[3] = @intCast(current);
    return result;
}
