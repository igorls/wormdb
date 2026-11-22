//! Shared transport/liveness counters surfaced by STATUS.

const std = @import("std");
const core = @import("../core/mod.zig");

pub const ServerMetrics = struct {
    /// Number of cache-line-isolated shards for hot TCP command counters so
    /// concurrent worker threads never bounce shared cache lines across cores/CCDs.
    pub const TCP_SHARDS: usize = 64;

    pub const TcpShard = struct {
        in_flight: std.atomic.Value(i64) align(64) = .init(0),
        completed: std.atomic.Value(u64) = .init(0),
        succeeded: std.atomic.Value(u64) = .init(0),
        last_ok_ms: std.atomic.Value(u64) = .init(0),
    };

    started_ms: std.atomic.Value(u64) align(64),

    tcp_connections_active: std.atomic.Value(u64) align(64),
    tcp_connection_queue_depth: std.atomic.Value(u64) align(64),
    tcp_next_shard: std.atomic.Value(usize) align(64),
    tcp_shards: [TCP_SHARDS]TcpShard align(64),

    gateway_connections_active: std.atomic.Value(u64) align(64),
    gateway_websocket_connections_active: std.atomic.Value(u64) align(64),
    gateway_threads_active: std.atomic.Value(u64) align(64),
    gateway_commands_in_flight: std.atomic.Value(u64) align(64),
    gateway_commands_completed: std.atomic.Value(u64) align(64),
    gateway_commands_succeeded: std.atomic.Value(u64) align(64),
    gateway_last_successful_command_completed_ms: std.atomic.Value(u64) align(64),
    gateway_per_ip_rejections: std.atomic.Value(u64) align(64),

    pub const Snapshot = struct {
        started_ms: u64,
        status_generated_ms: u64,

        tcp_connections_active: u64,
        tcp_commands_in_flight: u64,
        tcp_commands_completed: u64,
        tcp_commands_succeeded: u64,
        tcp_last_successful_command_completed_ms: u64,
        tcp_connection_queue_depth: u64,

        gateway_connections_active: u64,
        gateway_websocket_connections_active: u64,
        gateway_threads_active: u64,
        gateway_commands_in_flight: u64,
        gateway_commands_completed: u64,
        gateway_commands_succeeded: u64,
        gateway_last_successful_command_completed_ms: u64,
        gateway_per_ip_rejections: u64,
    };

    fn initTcpShards() [TCP_SHARDS]TcpShard {
        var shards: [TCP_SHARDS]TcpShard = undefined;
        for (&shards) |*s| s.* = .{};
        return shards;
    }

    pub fn init() ServerMetrics {
        const now_ms: u64 = @intCast(core.compat.nowMs());
        return .{
            .started_ms = std.atomic.Value(u64).init(now_ms),
            .tcp_connections_active = std.atomic.Value(u64).init(0),
            .tcp_connection_queue_depth = std.atomic.Value(u64).init(0),
            .tcp_next_shard = std.atomic.Value(usize).init(0),
            .tcp_shards = initTcpShards(),
            .gateway_connections_active = std.atomic.Value(u64).init(0),
            .gateway_websocket_connections_active = std.atomic.Value(u64).init(0),
            .gateway_threads_active = std.atomic.Value(u64).init(0),
            .gateway_commands_in_flight = std.atomic.Value(u64).init(0),
            .gateway_commands_completed = std.atomic.Value(u64).init(0),
            .gateway_commands_succeeded = std.atomic.Value(u64).init(0),
            .gateway_last_successful_command_completed_ms = std.atomic.Value(u64).init(0),
            .gateway_per_ip_rejections = std.atomic.Value(u64).init(0),
        };
    }

    pub fn emptySnapshot() Snapshot {
        const now_ms: u64 = @intCast(core.compat.nowMs());
        return .{
            .started_ms = 0,
            .status_generated_ms = now_ms,
            .tcp_connections_active = 0,
            .tcp_commands_in_flight = 0,
            .tcp_commands_completed = 0,
            .tcp_commands_succeeded = 0,
            .tcp_last_successful_command_completed_ms = 0,
            .tcp_connection_queue_depth = 0,
            .gateway_connections_active = 0,
            .gateway_websocket_connections_active = 0,
            .gateway_threads_active = 0,
            .gateway_commands_in_flight = 0,
            .gateway_commands_completed = 0,
            .gateway_commands_succeeded = 0,
            .gateway_last_successful_command_completed_ms = 0,
            .gateway_per_ip_rejections = 0,
        };
    }

    pub fn snapshot(self: *const ServerMetrics) Snapshot {
        var in_flight: i64 = 0;
        var completed: u64 = 0;
        var succeeded: u64 = 0;
        var last_ok_ms: u64 = 0;
        for (&self.tcp_shards) |*s| {
            in_flight += s.in_flight.load(.monotonic);
            completed += s.completed.load(.monotonic);
            succeeded += s.succeeded.load(.monotonic);
            const ts = s.last_ok_ms.load(.monotonic);
            if (ts > last_ok_ms) last_ok_ms = ts;
        }
        return .{
            .started_ms = self.started_ms.load(.monotonic),
            .status_generated_ms = @intCast(core.compat.nowMs()),
            .tcp_connections_active = self.tcp_connections_active.load(.monotonic),
            .tcp_commands_in_flight = if (in_flight > 0) @intCast(in_flight) else 0,
            .tcp_commands_completed = completed,
            .tcp_commands_succeeded = succeeded,
            .tcp_last_successful_command_completed_ms = last_ok_ms,
            .tcp_connection_queue_depth = self.tcp_connection_queue_depth.load(.monotonic),
            .gateway_connections_active = self.gateway_connections_active.load(.monotonic),
            .gateway_websocket_connections_active = self.gateway_websocket_connections_active.load(.monotonic),
            .gateway_threads_active = self.gateway_threads_active.load(.monotonic),
            .gateway_commands_in_flight = self.gateway_commands_in_flight.load(.monotonic),
            .gateway_commands_completed = self.gateway_commands_completed.load(.monotonic),
            .gateway_commands_succeeded = self.gateway_commands_succeeded.load(.monotonic),
            .gateway_last_successful_command_completed_ms = self.gateway_last_successful_command_completed_ms.load(.monotonic),
            .gateway_per_ip_rejections = self.gateway_per_ip_rejections.load(.monotonic),
        };
    }

    /// Assign a connection its own metrics shard slot (called once on accept).
    pub fn assignTcpShard(self: *ServerMetrics) usize {
        return self.tcp_next_shard.fetchAdd(1, .monotonic) & (TCP_SHARDS - 1);
    }

    pub fn beginTcpConnection(self: *ServerMetrics) void {
        _ = self.tcp_connections_active.fetchAdd(1, .monotonic);
    }

    pub fn endTcpConnection(self: *ServerMetrics) void {
        _ = self.tcp_connections_active.fetchSub(1, .monotonic);
    }

    pub fn beginTcpCommand(self: *ServerMetrics) void {
        self.beginTcpCommandShard(0);
    }

    pub fn endTcpCommand(self: *ServerMetrics) void {
        self.endTcpCommandShard(0);
    }

    pub fn completeTcpCommand(self: *ServerMetrics, succeeded: bool) void {
        self.completeTcpCommandShard(0, succeeded, true);
    }

    pub inline fn beginTcpCommandShard(self: *ServerMetrics, shard_idx: usize) void {
        _ = self.tcp_shards[shard_idx].in_flight.fetchAdd(1, .monotonic);
    }

    pub inline fn endTcpCommandShard(self: *ServerMetrics, shard_idx: usize) void {
        _ = self.tcp_shards[shard_idx].in_flight.fetchSub(1, .monotonic);
    }

    pub inline fn completeTcpCommandShard(self: *ServerMetrics, shard_idx: usize, succeeded: bool, record_ts: bool) void {
        const s = &self.tcp_shards[shard_idx];
        _ = s.completed.fetchAdd(1, .monotonic);
        if (succeeded) {
            _ = s.succeeded.fetchAdd(1, .monotonic);
            if (record_ts) {
                s.last_ok_ms.store(@intCast(core.compat.nowMs()), .monotonic);
            }
        }
    }

    pub inline fn touchTcpSuccessMsShard(self: *ServerMetrics, shard_idx: usize) void {
        self.tcp_shards[shard_idx].last_ok_ms.store(@intCast(core.compat.nowMs()), .monotonic);
    }

    pub fn setTcpConnectionQueueDepth(self: *ServerMetrics, depth: usize) void {
        self.tcp_connection_queue_depth.store(@intCast(depth), .monotonic);
    }

    pub fn beginGatewayThread(self: *ServerMetrics) void {
        _ = self.gateway_threads_active.fetchAdd(1, .monotonic);
        _ = self.gateway_connections_active.fetchAdd(1, .monotonic);
    }

    pub fn endGatewayThread(self: *ServerMetrics) void {
        _ = self.gateway_connections_active.fetchSub(1, .monotonic);
        _ = self.gateway_threads_active.fetchSub(1, .monotonic);
    }

    pub fn beginGatewayWebSocket(self: *ServerMetrics) void {
        _ = self.gateway_websocket_connections_active.fetchAdd(1, .monotonic);
    }

    pub fn endGatewayWebSocket(self: *ServerMetrics) void {
        _ = self.gateway_websocket_connections_active.fetchSub(1, .monotonic);
    }

    pub fn beginGatewayCommand(self: *ServerMetrics) void {
        _ = self.gateway_commands_in_flight.fetchAdd(1, .monotonic);
    }

    pub fn endGatewayCommand(self: *ServerMetrics) void {
        _ = self.gateway_commands_in_flight.fetchSub(1, .monotonic);
    }

    pub fn recordGatewayPerIpRejection(self: *ServerMetrics) void {
        _ = self.gateway_per_ip_rejections.fetchAdd(1, .monotonic);
    }

    pub fn completeGatewayCommand(self: *ServerMetrics, succeeded: bool) void {
        _ = self.gateway_commands_completed.fetchAdd(1, .monotonic);
        if (succeeded) {
            _ = self.gateway_commands_succeeded.fetchAdd(1, .monotonic);
            self.gateway_last_successful_command_completed_ms.store(@intCast(core.compat.nowMs()), .monotonic);
        }
    }
};
