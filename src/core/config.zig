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
};

/// Authentication configuration (Signed Capability Tokens)
pub const AuthConfig = struct {
    /// Ed25519 public keys for SCT verification (base64-encoded)
    public_keys: []const []const u8 = &.{},

    /// Require authentication for gateway connections
    require_auth: bool = true,

    /// Maximum token age in seconds. Tokens older than this are rejected.
    token_max_age_s: u64 = 3600,
};

/// Top-level WormDB configuration.
/// Maps directly to the JSON config file structure.
pub const WormDBConfig = struct {
    /// Data directory for WAL and snapshots
    data: []const u8 = "./data",

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
};

/// Load configuration from a JSON file.
/// Returns default config if the file doesn't exist.
/// The file content is kept alive for the process lifetime since
/// parsed string values reference the input buffer directly.
pub fn loadFromFile(path: []const u8, allocator: std.mem.Allocator) !WormDBConfig {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) return WormDBConfig{};
        return err;
    };
    defer file.close();

    // Content is intentionally NOT freed — string slices in the parsed
    // config point into this buffer for the process lifetime.
    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max

    return loadFromJson(content, allocator);
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

test "loadFromJson: unknown fields ignored" {
    const cfg = try loadFromJson(
        \\{ "future_feature": true, "server": { "port": 8000 } }
    , std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 8000), cfg.server.port);
}

test {
    @import("std").testing.refAllDecls(@This());
}
