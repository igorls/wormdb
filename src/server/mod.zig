//! Server module — TCP server, io_uring event loop, WebSocket and QUIC gateways.
//!
//! Thread-pool TCP server, io_uring/epoll event loops, and the WebSocket/QUIC
//! gateways for browser-direct access, all sharing the command executor.

const std = @import("std");
const build_options = @import("build_options");

pub const tcp = @import("tcp.zig");
pub const executor = @import("executor.zig");
pub const uring = @import("uring.zig");
pub const epoll = @import("epoll.zig");
pub const gateway = @import("gateway.zig");
pub const quic_gateway = if (build_options.quic) @import("quic_gateway.zig") else struct {};
pub const auth = @import("auth.zig");

pub const Server = tcp.Server;
pub const ServerConfig = tcp.ServerConfig;
pub const Gateway = gateway.Gateway;
pub const QuicGateway = if (build_options.quic) quic_gateway.QuicGateway else void;

test {
    @import("std").testing.refAllDecls(@This());
}
