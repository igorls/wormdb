//! Server module — TCP server, io_uring event loop, WebSocket and QUIC gateways.
//!
//! Thread-pool TCP server, io_uring/epoll event loops, and the WebSocket/QUIC
//! gateways for browser-direct access, all sharing the command executor.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// The io_uring and epoll event loops are Linux-only (they call directly into
/// `std.os.linux`). On other platforms they collapse to empty namespaces and
/// the thread-pool backend is used instead — see the backend switch in main.zig.
pub const is_linux = builtin.os.tag == .linux;

pub const tcp = @import("tcp.zig");
pub const executor = @import("executor.zig");
pub const metrics = @import("metrics.zig");
pub const uring = if (is_linux) @import("uring.zig") else struct {};
pub const epoll = if (is_linux) @import("epoll.zig") else struct {};
pub const gateway = @import("gateway.zig");
pub const quic_gateway = if (build_options.quic) @import("quic_gateway.zig") else struct {};
pub const auth = @import("auth.zig");

pub const Server = tcp.Server;
pub const ServerConfig = tcp.ServerConfig;
pub const ServerMetrics = metrics.ServerMetrics;
pub const Gateway = gateway.Gateway;
pub const QuicGateway = if (build_options.quic) quic_gateway.QuicGateway else void;

test {
    @import("std").testing.refAllDecls(@This());
}
