//! Shared transport/liveness counters surfaced by STATUS.

const std = @import("std");
const core = @import("../core/mod.zig");

pub const ServerMetrics = struct {
    started_ms: std.atomic.Value(u64),

    tcp_connections_active: std.atomic.Value(u64),
    tcp_commands_in_flight: std.atomic.Value(u64),
    tcp_commands_completed: std.atomic.Value(u64),
    tcp_commands_succeeded: std.atomic.Value(u64),
    tcp_last_successful_command_completed_ms: std.atomic.Value(u64),
    tcp_connection_queue_depth: std.atomic.Value(u64),

    gateway_connections_active: std.atomic.Value(u64),
    gateway_websocket_connections_active: std.atomic.Value(u64),
    gateway_threads_active: std.atomic.Value(u64),
    gateway_commands_in_flight: std.atomic.Value(u64),
    gateway_commands_completed: std.atomic.Value(u64),
    gateway_commands_succeeded: std.atomic.Value(u64),
    gateway_last_successful_command_completed_ms: std.atomic.Value(u64),

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
    };

    pub fn init() ServerMetrics {
        const now_ms: u64 = @intCast(core.compat.nowMs());
        return .{
            .started_ms = std.atomic.Value(u64).init(now_ms),
            .tcp_connections_active = std.atomic.Value(u64).init(0),
            .tcp_commands_in_flight = std.atomic.Value(u64).init(0),
            .tcp_commands_completed = std.atomic.Value(u64).init(0),
            .tcp_commands_succeeded = std.atomic.Value(u64).init(0),
            .tcp_last_successful_command_completed_ms = std.atomic.Value(u64).init(0),
            .tcp_connection_queue_depth = std.atomic.Value(u64).init(0),
            .gateway_connections_active = std.atomic.Value(u64).init(0),
            .gateway_websocket_connections_active = std.atomic.Value(u64).init(0),
            .gateway_threads_active = std.atomic.Value(u64).init(0),
            .gateway_commands_in_flight = std.atomic.Value(u64).init(0),
            .gateway_commands_completed = std.atomic.Value(u64).init(0),
            .gateway_commands_succeeded = std.atomic.Value(u64).init(0),
            .gateway_last_successful_command_completed_ms = std.atomic.Value(u64).init(0),
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
        };
    }

    pub fn snapshot(self: *const ServerMetrics) Snapshot {
        return .{
            .started_ms = self.started_ms.load(.monotonic),
            .status_generated_ms = @intCast(core.compat.nowMs()),
            .tcp_connections_active = self.tcp_connections_active.load(.monotonic),
            .tcp_commands_in_flight = self.tcp_commands_in_flight.load(.monotonic),
            .tcp_commands_completed = self.tcp_commands_completed.load(.monotonic),
            .tcp_commands_succeeded = self.tcp_commands_succeeded.load(.monotonic),
            .tcp_last_successful_command_completed_ms = self.tcp_last_successful_command_completed_ms.load(.monotonic),
            .tcp_connection_queue_depth = self.tcp_connection_queue_depth.load(.monotonic),
            .gateway_connections_active = self.gateway_connections_active.load(.monotonic),
            .gateway_websocket_connections_active = self.gateway_websocket_connections_active.load(.monotonic),
            .gateway_threads_active = self.gateway_threads_active.load(.monotonic),
            .gateway_commands_in_flight = self.gateway_commands_in_flight.load(.monotonic),
            .gateway_commands_completed = self.gateway_commands_completed.load(.monotonic),
            .gateway_commands_succeeded = self.gateway_commands_succeeded.load(.monotonic),
            .gateway_last_successful_command_completed_ms = self.gateway_last_successful_command_completed_ms.load(.monotonic),
        };
    }

    pub fn beginTcpConnection(self: *ServerMetrics) void {
        _ = self.tcp_connections_active.fetchAdd(1, .monotonic);
    }

    pub fn endTcpConnection(self: *ServerMetrics) void {
        _ = self.tcp_connections_active.fetchSub(1, .monotonic);
    }

    pub fn beginTcpCommand(self: *ServerMetrics) void {
        _ = self.tcp_commands_in_flight.fetchAdd(1, .monotonic);
    }

    pub fn endTcpCommand(self: *ServerMetrics, succeeded: bool) void {
        _ = self.tcp_commands_in_flight.fetchSub(1, .monotonic);
        _ = self.tcp_commands_completed.fetchAdd(1, .monotonic);
        if (succeeded) {
            _ = self.tcp_commands_succeeded.fetchAdd(1, .monotonic);
            self.tcp_last_successful_command_completed_ms.store(@intCast(core.compat.nowMs()), .monotonic);
        }
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

    pub fn endGatewayCommand(self: *ServerMetrics, succeeded: bool) void {
        _ = self.gateway_commands_in_flight.fetchSub(1, .monotonic);
        _ = self.gateway_commands_completed.fetchAdd(1, .monotonic);
        if (succeeded) {
            _ = self.gateway_commands_succeeded.fetchAdd(1, .monotonic);
            self.gateway_last_successful_command_completed_ms.store(@intCast(core.compat.nowMs()), .monotonic);
        }
    }
};
