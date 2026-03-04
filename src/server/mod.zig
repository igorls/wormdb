//! Server module — TCP server, io_uring event loop, and WebSocket gateway.
//!
//! Thread-pool TCP server, io_uring/epoll event loops, and the WebSocket
//! gateway for browser-direct access, all sharing the command executor.

const std = @import("std");
pub const tcp = @import("tcp.zig");
pub const executor = @import("executor.zig");
pub const uring = @import("uring.zig");
pub const epoll = @import("epoll.zig");
pub const gateway = @import("gateway.zig");
pub const auth = @import("auth.zig");

pub const Server = tcp.Server;
pub const ServerConfig = tcp.ServerConfig;
pub const Gateway = gateway.Gateway;

test {
    @import("std").testing.refAllDecls(@This());
}
