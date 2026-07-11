//! WormDB configuration
//!
//! Unified configuration system supporting JSON config files and CLI overrides.
//! All configuration sections are optional and use sensible defaults.

const std = @import("std");

/// Persistence mode for the store.
pub const PersistenceMode = enum {
    /// Full durability: WAL on every write + snapshots.
    full,
    /// Snapshot-only: load on startup, save on shutdown + manual SAVE.
    /// No per-write IO — maximum write throughput.
    snapshot,
    /// Pure in-memory: no disk IO at all. Data lost on exit.
    none,
};

/// Configuration for the store
pub const Config = struct {
    /// Path to the Write-Ahead Log file
    wal_path: []const u8 = "wormdb.wal",

    /// Path to snapshot files
    snapshot_path: []const u8 = "wormdb.snapshot",

    /// Sync writes to disk after each write operation
    sync_writes: bool = true,

    /// Maximum WAL file size before rotation
    max_wal_size: usize = 1024 * 1024 * 1024, // 1GB

    /// Compaction threshold (ratio of live vs total entries)
    compaction_threshold: f32 = 0.3,

    /// Persistence mode: full (WAL+snapshot), snapshot (load/save only), none (pure RAM).
    persistence: PersistenceMode = .full,
};

/// Server configuration
pub const ServerConfig = struct {
    /// TCP port to listen on
    port: u16 = 6389,

    /// Bind address
    bind_address: []const u8 = "0.0.0.0",

    /// Maximum concurrent connections
    max_connections: usize = 1024,

    /// Connection timeout in milliseconds
    timeout_ms: usize = 30000,

    /// Server backend
    backend: Backend = .threadpool,

    /// Per-transport auth opt-out for the binary TCP / io_uring / epoll listener. Secure by
    /// default (true): when `auth.require_auth` is set, this listener rejects unauthenticated
    /// protected commands. Set false ONLY on a trusted network / for maximum throughput — it
    /// disables capability checks on this transport (logged loudly at startup).
    auth_enabled: bool = true,
};

pub const Backend = enum {
    threadpool,
    uring,
    epoll,
};

/// Cluster configuration
pub const ClusterConfig = struct {
    /// Cluster name for mesh discovery
    name: ?[]const u8 = null,

    /// Seed node address (format: "host:port")
    seed: ?[]const u8 = null,

    /// Replication factor (0 = all peers)
    replication_factor: usize = 0,

    /// Gossip interval in milliseconds
    gossip_interval_ms: usize = 1000,

    /// Node timeout in milliseconds
    node_timeout_ms: usize = 5000,

    /// SWIM gossip UDP port
    gossip_port: u16 = 51821,

    /// WireGuard listen port
    wg_port: u16 = 51830,
};

/// Gateway configuration (WebSocket endpoint for browser-direct access)
pub const GatewayConfig = struct {
    /// Enable the WebSocket gateway
    enabled: bool = false,

    /// WebSocket port to listen on
    port: u16 = 6390,

    /// Public endpoint URL advertised to browsers (e.g. "wss://us-east.myapp.com")
    /// If null, this node is hidden from browser discovery.
    public_endpoint: ?[]const u8 = null,

    /// Enable the QUIC/WebTransport gateway (requires TLS cert/key)
    quic_enabled: bool = false,

    /// QUIC/WebTransport UDP port to listen on
    quic_port: u16 = 6393,

    /// Path to TLS certificate file (PEM). Required for QUIC.
    tls_cert_path: ?[]const u8 = null,

    /// Path to TLS private key file (PEM). Required for QUIC.
    tls_key_path: ?[]const u8 = null,

    /// Per-transport auth opt-out for the WebSocket gateway. Secure by default (true); set
    /// false only on a trusted network to disable capability checks on the WS listener.
    auth_enabled: bool = true,

    /// Max concurrent WebSocket-gateway connections per client IP. 0 (default) = unlimited.
    /// NEVER default this to a small number: players behind one NAT and localhost capacity
    /// benches share a single address (#89). Enforced only when the peer address is
    /// resolvable on the accept path; rejections are logged and counted in STATUS
    /// (`gateway_per_ip_rejections`).
    max_connections_per_ip: u32 = 0,

    /// Exempt loopback peers (127.0.0.0/8, ::1) from `max_connections_per_ip` so local
    /// benches can open hundreds of sockets from one address (#89).
    per_ip_exempt_loopback: bool = true,

    /// Per-transport auth opt-out for the QUIC/WebTransport gateway. Secure by default (true).
    quic_auth_enabled: bool = true,
};

/// Authentication configuration (Signed Capability Tokens)
pub const AuthConfig = struct {
    /// Ed25519 public keys for SCT verification (base64-encoded)
    public_keys: []const []const u8 = &.{},

    /// Require authentication for gateway connections
    require_auth: bool = true,

    /// Maximum token age in seconds. Tokens older than this are rejected.
    token_max_age_s: u64 = 3600,

    /// Optional base64 Ed25519 secret key used by auth_mint_scoped.
    /// When null, server-side minting is disabled and offline token minting still works.
    mint_secret_key: ?[]const u8 = null,

    /// Default namespace token lifetime for auth_mint_scoped.
    namespace_token_ttl_s: u64 = 3600,
};

/// One org → namespace grant (JSON form). `org_pubkey` is the org's Ed25519
/// public key, base64 (standard alphabet, 44 chars). Nodes presenting a valid
/// certificate from that org may replicate keys matching any prefix.
pub const OrgGrantConfig = struct {
    org_pubkey: []const u8,
    name: []const u8 = "",
    prefixes: []const []const u8 = &.{},
};

/// Org-trust configuration for the replication channel (issue #63).
/// Deny-by-default: configuring any grant turns enforcement on regardless of
/// the `enforce` flag — trust that is configured but not enforced is a trap.
pub const OrgTrustConfig = struct {
    /// Force enforcement even with an empty grant list (rejects everything).
    enforce: bool = false,
    /// Path to this node's org-signed certificate (binary, 186 bytes,
    /// as written by meshguard `Org.saveCertificate`). Required for this node
    /// to authenticate its own outbound replication connections.
    node_cert_path: ?[]const u8 = null,
    /// Orgs whose certified nodes may replicate into the listed key prefixes.
    grants: []const OrgGrantConfig = &.{},
};

/// One frozen segment mount: a `.wseg` file mmap'd at startup and attached to the
/// store under `name`. The engine is domain-agnostic — `name` is an opaque string
/// a serving layer looks up; core assigns it no meaning.
pub const SegmentMount = struct {
    name: []const u8,
    path: []const u8,
};

/// Top-level WormDB configuration.
/// Maps directly to the JSON config file structure.
pub const WormDBConfig = struct {
    /// Data directory for WAL and snapshots
    data: []const u8 = "./data",

    /// Frozen read-only segments (.wseg) to mmap at startup. Each is attached to
    /// the store under its opaque `name`; a serving layer looks it up by that name.
    /// The engine assigns no domain meaning to the name.
    segments: []const SegmentMount = &.{},

    /// Store / persistence settings
    store: Config = .{},

    /// TCP server settings
    server: ServerConfig = .{},

    /// Cluster settings (null = standalone mode)
    cluster: ClusterConfig = .{},

    /// WebSocket gateway settings
    gateway: GatewayConfig = .{},

    /// Authentication settings
    auth: AuthConfig = .{},

    /// Org trust for cluster replication (empty = open/legacy replication;
    /// the composition root refuses to start a cluster without either this
    /// or an explicit --cluster-open acknowledgement).
    org_trust: OrgTrustConfig = .{},
};

/// Load configuration from a JSON file.
/// Returns default config if the file doesn't exist.
/// The file content is kept alive for the process lifetime since
/// parsed string values reference the input buffer directly.
pub fn loadFromFile(path: []const u8, allocator: std.mem.Allocator) !WormDBConfig {
    return loadTyped(WormDBConfig, path, allocator);
}

/// Load any config struct `T` from the JSON file at `path`, or `T{}` (all defaults)
/// if the file is missing. Generic so a domain serving layer can parse its OWN config
/// section from the same file without core knowing the domain type — keeping core free
/// of any domain config struct. Content is NOT freed: parsed string slices point into
/// it for the process lifetime, and `ignore_unknown_fields` lets each caller see only
/// its own section.
pub fn loadTyped(comptime T: type, path: []const u8, allocator: std.mem.Allocator) !T {
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return T{};
        return err;
    };
    return std.json.parseFromSliceLeaky(T, allocator, content, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidConfig;
}

/// Parse a WormDBConfig from a JSON string.
/// Uses parseFromSliceLeaky so all string values are duplicated into the
/// provided allocator, surviving after the JSON input buffer is freed.
pub fn loadFromJson(json: []const u8, allocator: std.mem.Allocator) !WormDBConfig {
    return std.json.parseFromSliceLeaky(WormDBConfig, allocator, json, .{
        .ignore_unknown_fields = true,
    }) catch {
        return error.InvalidConfig;
    };
}

test "loadFromJson: empty object uses defaults" {
    const cfg = try loadFromJson("{}", std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 6389), cfg.server.port);
    try std.testing.expectEqual(PersistenceMode.full, cfg.store.persistence);
    try std.testing.expectEqual(false, cfg.gateway.enabled);
    try std.testing.expectEqual(true, cfg.auth.require_auth);
    // Per-transport auth is secure by default on every listener.
    try std.testing.expectEqual(true, cfg.server.auth_enabled);
    try std.testing.expectEqual(true, cfg.gateway.auth_enabled);
    try std.testing.expectEqual(true, cfg.gateway.quic_auth_enabled);
    // Per-IP cap ships OFF (#89): a default cap breaks NAT'd players and localhost benches.
    try std.testing.expectEqual(@as(u32, 0), cfg.gateway.max_connections_per_ip);
    try std.testing.expectEqual(true, cfg.gateway.per_ip_exempt_loopback);
}

test "loadFromJson: gateway per-IP cap overrides" {
    const cfg = try loadFromJson(
        \\{
        \\  "gateway": {
        \\    "enabled": true,
        \\    "max_connections_per_ip": 256,
        \\    "per_ip_exempt_loopback": false
        \\  }
        \\}
    , std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 256), cfg.gateway.max_connections_per_ip);
    try std.testing.expectEqual(false, cfg.gateway.per_ip_exempt_loopback);
}

test "loadFromJson: override specific fields" {
    const cfg = try loadFromJson(
        \\{
        \\  "data": "/var/lib/wormdb",
        \\  "server": { "port": 7000 },
        \\  "gateway": { "enabled": true, "port": 7001 },
        \\  "cluster": { "name": "prod" }
        \\}
    , std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 7000), cfg.server.port);
    try std.testing.expectEqual(true, cfg.gateway.enabled);
    try std.testing.expectEqual(@as(u16, 7001), cfg.gateway.port);
    try std.testing.expectEqualStrings("/var/lib/wormdb", cfg.data);
    try std.testing.expectEqualStrings("prod", cfg.cluster.name.?);
}

test "loadFromJson: org_trust section round-trips" {
    // Defaults: no org trust configured.
    const bare = try loadFromJson("{}", std.testing.allocator);
    try std.testing.expectEqual(false, bare.org_trust.enforce);
    try std.testing.expectEqual(@as(usize, 0), bare.org_trust.grants.len);
    try std.testing.expect(bare.org_trust.node_cert_path == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try loadFromJson(
        \\{
        \\  "org_trust": {
        \\    "enforce": true,
        \\    "node_cert_path": "/etc/wormdb/node.cert",
        \\    "grants": [
        \\      {
        \\        "org_pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        \\        "name": "acme",
        \\        "prefixes": ["acme:", "vec:acme:"]
        \\      }
        \\    ]
        \\  }
        \\}
    , arena.allocator());
    try std.testing.expectEqual(true, cfg.org_trust.enforce);
    try std.testing.expectEqualStrings("/etc/wormdb/node.cert", cfg.org_trust.node_cert_path.?);
    try std.testing.expectEqual(@as(usize, 1), cfg.org_trust.grants.len);
    try std.testing.expectEqualStrings("acme", cfg.org_trust.grants[0].name);
    try std.testing.expectEqual(@as(usize, 2), cfg.org_trust.grants[0].prefixes.len);
    try std.testing.expectEqualStrings("acme:", cfg.org_trust.grants[0].prefixes[0]);
    try std.testing.expectEqualStrings("vec:acme:", cfg.org_trust.grants[0].prefixes[1]);
}

test "loadFromJson: unknown fields ignored" {
    const cfg = try loadFromJson(
        \\{ "future_feature": true, "server": { "port": 8000 } }
    , std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 8000), cfg.server.port);
}

test {
    @import("std").testing.refAllDecls(@This());
}
