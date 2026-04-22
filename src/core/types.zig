//! Core types and data structures
//!
//! This module defines the fundamental types used throughout WormDB:
//! - Entry: Key-value entry with metadata
//! - Command: Client commands
//! - Response: Server responses

const std = @import("std");
const compat = @import("compat.zig");

/// Timestamp type (milliseconds since epoch)
pub const Timestamp = u64;

/// Flags for a key-value entry
pub const EntryFlags = packed struct(u8) {
    is_worm: bool, // Write-once-read-many: cannot be modified
    is_deleted: bool, // Tombstone for deletions
    _: u6 = 0,
};

/// A single key-value entry in the store
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    timestamp: Timestamp,
    flags: EntryFlags,

    pub fn init(allocator: std.mem.Allocator, key: []const u8, value: []const u8, is_worm: bool) !Entry {
        return .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
            .timestamp = @intCast(compat.nowMs()),
            .flags = .{ .is_worm = is_worm, .is_deleted = false },
        };
    }

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

/// Command types from clients
pub const Command = union(enum) {
    get: []const u8, // GET <key>
    set: SetParams, // SET <key> <value> [WORM]
    delete: []const u8, // DEL <key>
    status: void, // STATUS
    cluster_status: void, // CLUSTER STATUS
    cluster_peers: void, // CLUSTER PEERS
    subscribe: []const u8, // SUB <channel>
    unsubscribe: []const u8, // UNSUB <channel>
    publish: PublishParams, // PUB <channel> <message>
    exec: ExecParams, // EXEC <procedure> <args...>
    save: void, // SAVE (manual snapshot)
    auth: []const u8, // AUTH <token> (binary SCT)
    vinsert: VinsertParams, // VINSERT <key> <vec> <flags> <ns> <metric> <timestamp>
    vdelete: VdeleteParams, // VDELETE <key> <namespace>

    pub const SetParams = struct {
        key: []const u8,
        value: []const u8,
        worm: bool = false,
    };

    pub const PublishParams = struct {
        channel: []const u8,
        message: []const u8,
    };

    pub const ExecParams = struct {
        procedure: []const u8,
        args: []const []const u8,
    };

    /// Parameters for the VINSERT wire command. The timestamp is carried
    /// explicitly (unlike SET, which re-times on each peer) so HNSW
    /// side-table entries stay consistent across the cluster.
    pub const VinsertParams = struct {
        key: []const u8,
        vector: []const u8, // raw f32 bytes — length validated by the applier
        worm: bool = true,
        namespace: []const u8,
        metric: []const u8, // "cosine" | "dot" | "l2"
        timestamp: Timestamp,
    };

    pub const VdeleteParams = struct {
        key: []const u8,
        namespace: []const u8,
    };
};

/// WormWire command IDs (binary protocol)
pub const CommandId = enum(u8) {
    get = 0x01,
    set = 0x02,
    delete = 0x03,
    status = 0x04,
    cluster_status = 0x05,
    subscribe = 0x06,
    unsubscribe = 0x07,
    publish = 0x08,
    exec = 0x09,
    cluster_peers = 0x0A,
    save = 0x0B,
    auth = 0x0C,
    vinsert = 0x0D,
    vdelete = 0x0E,
};

/// Maximum accepted binary payload length (16 MiB)
pub const MAX_PAYLOAD_LENGTH: u32 = 16 * 1024 * 1024;

/// Response to clients
pub const Response = union(enum) {
    value: ?[]const u8, // For GET: value or null
    ok: void, // For SET/DEL success
    err: []const u8, // Error message
    event: EventMessage, // For subscription callbacks

    pub const EventMessage = struct {
        channel: []const u8,
        message: []const u8,
    };
};

/// Error types for the store
pub const StoreError = error{
    KeyNotFound,
    WormViolation, // Attempt to modify WORM key
    OutOfMemory,
    IoError,
    Corruption,
};

/// WAL record types
pub const WalRecordType = enum(u8) {
    set = 0x01,
    delete = 0x02,
};

test {
    @import("std").testing.refAllDecls(@This());
}
