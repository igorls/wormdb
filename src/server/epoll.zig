//! epoll event loop server — single-threaded, Redis-style architecture.
//!
//! Classic non-blocking I/O with epoll_wait. This is the same approach Redis uses.
//! Binary protocol (WormWire) only.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const core = @import("../core/mod.zig");
const storage = @import("../storage/mod.zig");
const protocol = @import("../protocol/mod.zig");
const wire = protocol.wire;
const event_mod = @import("../event/mod.zig");
const cluster_mod = @import("../cluster/mod.zig");
const executor = @import("executor.zig");
const ServerMetrics = @import("metrics.zig").ServerMetrics;

const Store = storage.Store;
const EventBus = event_mod.EventBus;
const Command = core.types.Command;
const Response = core.types.Response;
const Cluster = cluster_mod.Cluster;

const RECV_BUF_SIZE = 65536;
const MAX_EVENTS = 256;
const MAX_CONNS = 4096;

// ── 0.16 compatibility shims for epoll ────────────────────────────────
// `posix.epoll_*` was removed in 0.16; fall back to the raw linux
// syscalls (which return usize — errno encoded in the top half).

fn epollCreate1(flags: u32) !posix.fd_t {
    const rc = linux.epoll_create1(flags);
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => return error.EpollCreateFailed,
    }
}

fn epollCtl(epfd: posix.fd_t, op: u32, fd: posix.fd_t, ev: ?*linux.epoll_event) !void {
    const rc = linux.epoll_ctl(epfd, op, fd, ev);
    switch (posix.errno(rc)) {
        .SUCCESS => return,
        else => return error.EpollCtlFailed,
    }
}

fn epollWait(epfd: posix.fd_t, events: []linux.epoll_event, timeout: i32) usize {
    while (true) {
        const rc = linux.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout);
        switch (posix.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => return 0,
        }
    }
}

/// Replacement for `posix.write` (removed in 0.16). Uses raw libc write().
fn posixWrite(fd: posix.fd_t, data: []const u8) !usize {
    while (true) {
        const rc = std.c.write(fd, data.ptr, data.len);
        if (rc < 0) {
            switch (posix.errno(rc)) {
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .PIPE => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                else => return error.Unexpected,
            }
        }
        return @intCast(rc);
    }
}

/// Adapter so `wire.writeResponse` (which takes any writer with `.writeAll`)
/// can push into an ArrayListUnmanaged (ArrayList.writer() was removed in 0.16).
const RespBufWriter = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *RespBufWriter, data: []const u8) !void {
        try self.buf.appendSlice(self.allocator, data);
    }
};

const ConnState = struct {
    fd: posix.fd_t = -1,
    recv_buf: [RECV_BUF_SIZE]u8 = undefined,
    recv_len: usize = 0,
    send_buf: []u8 = &.{},
    send_pos: usize = 0,
    resp_buf: std.ArrayListUnmanaged(u8) = .empty,
    active: bool = false,
    handshake_done: bool = false,
    /// True when we have data queued to send and are waiting for EPOLLOUT.
    write_ready: bool = false,

    fn reset(self: *ConnState) void {
        self.fd = -1;
        self.recv_len = 0;
        self.send_buf = &.{};
        self.send_pos = 0;
        self.resp_buf.clearRetainingCapacity();
        self.active = false;
        self.handshake_done = false;
        self.write_ready = false;
    }
};

pub const EpollServer = struct {
    epoll_fd: posix.fd_t,
    listener_fd: posix.fd_t,
    conns: []ConnState,
    free_slots: std.ArrayListUnmanaged(u16),
    allocator: std.mem.Allocator,
    exec_ctx: executor.ExecContext,
    running: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        event_bus: *EventBus,
        cluster: ?*Cluster,
        /// Whether this binary listener enforces auth (set by the composition root from
        /// `cfg.auth.require_auth && cfg.server.auth_enabled`). Phase 1 has no AUTH-frame handling
        /// here, so enforce ⇒ every protected command fails closed at the executor gate.
        auth_enforce: bool,
        bind_address: []const u8,
        port: u16,
    ) !EpollServer {
        return initWithMetrics(allocator, store, event_bus, cluster, auth_enforce, bind_address, port, null);
    }

    pub fn initWithMetrics(
        allocator: std.mem.Allocator,
        store: *Store,
        event_bus: *EventBus,
        cluster: ?*Cluster,
        /// Whether this binary listener enforces auth (set by the composition root from
        /// `cfg.auth.require_auth && cfg.server.auth_enabled`). Phase 1 has no AUTH-frame handling
        /// here, so enforce ⇒ every protected command fails closed at the executor gate.
        auth_enforce: bool,
        bind_address: []const u8,
        port: u16,
        metrics: ?*ServerMetrics,
    ) !EpollServer {
        // Create listening socket (non-blocking). std.net and posix.socket
        // were removed in 0.16; parse IP via std.Io.net and build the
        // sockaddr_in directly, then use the libc wrappers in core.compat.
        const parsed = try std.Io.net.IpAddress.parse(bind_address, port);
        const sin_bytes: [4]u8 = switch (parsed) {
            .ip4 => |ip4| ip4.bytes,
            .ip6 => return error.Ipv6BindNotSupportedInEpollServer,
        };
        const sockaddr_in = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(sin_bytes),
            .zero = @splat(0),
        };

        const listener_fd = try core.compat.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            posix.IPPROTO.TCP,
        );
        errdefer core.compat.close(listener_fd);

        try posix.setsockopt(listener_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try core.compat.bind(listener_fd, @ptrCast(&sockaddr_in), @sizeOf(posix.sockaddr.in));
        try core.compat.listen(listener_fd, 128);

        // Create epoll instance
        const epoll_fd = try epollCreate1(linux.EPOLL.CLOEXEC);
        errdefer core.compat.close(epoll_fd);

        // Register listener
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = listener_fd },
        };
        try epollCtl(epoll_fd, linux.EPOLL.CTL_ADD, listener_fd, &ev);

        // Pre-allocate connection pool
        const conns = try allocator.alloc(ConnState, MAX_CONNS);
        for (conns) |*c| c.* = .{};

        var free_slots: std.ArrayListUnmanaged(u16) = .empty;
        try free_slots.ensureTotalCapacity(allocator, MAX_CONNS);
        var i: u16 = 0;
        while (i < MAX_CONNS) : (i += 1) {
            free_slots.appendAssumeCapacity(i);
        }

        return .{
            .epoll_fd = epoll_fd,
            .listener_fd = listener_fd,
            .conns = conns,
            .free_slots = free_slots,
            .allocator = allocator,
            .exec_ctx = .{
                .allocator = allocator,
                .store = store,
                .event_bus = event_bus,
                .cluster = cluster,
                .auth = if (auth_enforce) .{ .enforce = null } else .disabled,
                .metrics = metrics,
            },
            .running = false,
        };
    }

    pub fn attachMetrics(self: *EpollServer, metrics: *ServerMetrics) void {
        self.exec_ctx.metrics = metrics;
    }

    pub fn deinit(self: *EpollServer) void {
        core.compat.close(self.epoll_fd);
        core.compat.close(self.listener_fd);
        for (self.conns) |*c| {
            if (c.active) core.compat.close(c.fd);
            if (c.send_buf.len > 0) self.allocator.free(c.send_buf);
        }
        self.allocator.free(self.conns);
        self.free_slots.deinit(self.allocator);
    }

    fn allocSlot(self: *EpollServer) ?u16 {
        if (self.free_slots.items.len == 0) return null;
        return self.free_slots.pop();
    }

    fn freeSlotAndClose(self: *EpollServer, slot: u16) void {
        const conn = &self.conns[slot];
        if (conn.active) {
            // Remove from epoll (ignore errors — fd may already be removed)
            epollCtl(self.epoll_fd, linux.EPOLL.CTL_DEL, conn.fd, null) catch {};
            core.compat.close(conn.fd);
            if (conn.send_buf.len > 0) self.allocator.free(conn.send_buf);
            if (self.exec_ctx.metrics) |metrics| metrics.endTcpConnection();
            conn.reset();
        }
        self.free_slots.appendAssumeCapacity(slot);
    }

    fn handleAccept(self: *EpollServer) void {
        // Accept as many connections as possible (edge-triggered style)
        while (true) {
            const client_fd = core.compat.accept4(self.listener_fd, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch break;

            // TCP_NODELAY
            posix.setsockopt(client_fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

            if (self.allocSlot()) |slot| {
                const conn = &self.conns[slot];
                conn.fd = client_fd;
                conn.active = true;
                if (self.exec_ctx.metrics) |metrics| metrics.beginTcpConnection();

                // Register for read events; store slot index in data
                var ev = linux.epoll_event{
                    .events = linux.EPOLL.IN,
                    .data = .{ .u32 = slot },
                };
                epollCtl(self.epoll_fd, linux.EPOLL.CTL_ADD, client_fd, &ev) catch {
                    self.freeSlotAndClose(slot);
                };
            } else {
                core.compat.close(client_fd);
            }
        }
    }

    fn handleRead(self: *EpollServer, slot: u16) void {
        const conn = &self.conns[slot];
        if (!conn.active) return;

        // Read as much as possible
        const space = conn.recv_buf[conn.recv_len..];
        if (space.len == 0) {
            // Buffer full — close connection
            self.freeSlotAndClose(slot);
            return;
        }

        const nbytes = posix.read(conn.fd, space) catch {
            self.freeSlotAndClose(slot);
            return;
        };
        if (nbytes == 0) {
            // EOF
            self.freeSlotAndClose(slot);
            return;
        }
        conn.recv_len += nbytes;

        // Handle handshake
        if (!conn.handshake_done) {
            if (conn.recv_len < 2) return; // need more data
            if (!std.mem.eql(u8, conn.recv_buf[0..2], &wire.WIRE_MAGIC)) {
                self.freeSlotAndClose(slot);
                return;
            }
            conn.handshake_done = true;
            const remaining = conn.recv_len - 2;
            if (remaining > 0) {
                std.mem.copyForwards(u8, conn.recv_buf[0..remaining], conn.recv_buf[2..conn.recv_len]);
            }
            conn.recv_len = remaining;
        }

        // Process frames
        self.processFrames(slot);
    }

    fn processFrames(self: *EpollServer, slot: u16) void {
        const conn = &self.conns[slot];

        // Reuse per-connection response buffer (avoids malloc/free per batch)
        conn.resp_buf.clearRetainingCapacity();

        var consumed: usize = 0;

        while (conn.recv_len - consumed >= 5) {
            const hdr = conn.recv_buf[consumed..];
            const payload_len = std.mem.readInt(u32, hdr[1..5], .big);
            const frame_len = 5 + @as(usize, payload_len);
            if (conn.recv_len - consumed < frame_len) break;

            const cmd_id_byte = hdr[0];
            const cmd_id: wire.CommandId = core.compat.intToEnum(wire.CommandId, cmd_id_byte) catch {
                self.freeSlotAndClose(slot);
                return;
            };

            const payload = hdr[5..frame_len];
            const cmd = wire.parseCommandPayloadZeroCopy(cmd_id, payload, self.allocator) catch {
                self.freeSlotAndClose(slot);
                return;
            };

            if (self.exec_ctx.metrics) |metrics| metrics.beginTcpCommand();
            defer if (self.exec_ctx.metrics) |metrics| metrics.endTcpCommand();

            const response = executor.execute(self.exec_ctx, cmd) catch |err| {
                const err_msg: []const u8 = switch (err) {
                    error.WormViolation => "WORM violation",
                    error.OutOfMemory => "out of memory",
                    error.IoError => "I/O error",
                    error.KeyNotFound => "key not found",
                    error.Corruption => "data corruption",
                };
                var w = RespBufWriter{ .buf = &conn.resp_buf, .allocator = self.allocator };
                wire.writeResponse(&w, .{ .err = err_msg }) catch {
                    consumed += frame_len;
                    continue;
                };
                if (self.exec_ctx.metrics) |metrics| metrics.completeTcpCommand(false);
                consumed += frame_len;
                continue;
            };
            defer protocol.deinitResponse(self.allocator, response);

            var w = RespBufWriter{ .buf = &conn.resp_buf, .allocator = self.allocator };
            wire.writeResponse(&w, response) catch {
                consumed += frame_len;
                continue;
            };
            if (self.exec_ctx.metrics) |metrics| metrics.completeTcpCommand(responseSucceeded(response));
            consumed += frame_len;
        }

        // Shift consumed bytes out of recv buffer
        if (consumed > 0) {
            const remaining = conn.recv_len - consumed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, conn.recv_buf[0..remaining], conn.recv_buf[consumed..conn.recv_len]);
            }
            conn.recv_len = remaining;
        }

        if (conn.resp_buf.items.len > 0) {
            // Try to write immediately (non-blocking)
            const written = posixWrite(conn.fd, conn.resp_buf.items) catch {
                self.freeSlotAndClose(slot);
                return;
            };

            if (written < conn.resp_buf.items.len) {
                // Partial write — buffer the rest and switch to EPOLLOUT
                const remaining_data = conn.resp_buf.items[written..];
                conn.send_buf = self.allocator.dupe(u8, remaining_data) catch {
                    self.freeSlotAndClose(slot);
                    return;
                };
                conn.send_pos = 0;
                conn.write_ready = true;

                var ev = linux.epoll_event{
                    .events = linux.EPOLL.OUT,
                    .data = .{ .u32 = slot },
                };
                epollCtl(self.epoll_fd, linux.EPOLL.CTL_MOD, conn.fd, &ev) catch {
                    self.freeSlotAndClose(slot);
                };
            }
            // else: full write completed, stay on EPOLLIN
        }
    }

    fn handleWrite(self: *EpollServer, slot: u16) void {
        const conn = &self.conns[slot];
        if (!conn.active or !conn.write_ready) return;

        const remaining = conn.send_buf[conn.send_pos..];
        const written = posixWrite(conn.fd, remaining) catch {
            self.freeSlotAndClose(slot);
            return;
        };
        conn.send_pos += written;

        if (conn.send_pos >= conn.send_buf.len) {
            // All data sent — switch back to EPOLLIN
            self.allocator.free(conn.send_buf);
            conn.send_buf = &.{};
            conn.send_pos = 0;
            conn.write_ready = false;

            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN,
                .data = .{ .u32 = slot },
            };
            epollCtl(self.epoll_fd, linux.EPOLL.CTL_MOD, conn.fd, &ev) catch {
                self.freeSlotAndClose(slot);
            };
        }
    }

    pub fn run(self: *EpollServer) !void {
        self.running = true;
        std.log.info("WormDB epoll listening on fd={d}", .{self.listener_fd});

        var events: [MAX_EVENTS]linux.epoll_event = undefined;

        while (self.running) {
            const nfds = epollWait(self.epoll_fd, &events, -1);
            if (nfds == 0) continue;

            for (events[0..nfds]) |ev| {
                if (ev.data.fd == self.listener_fd) {
                    self.handleAccept();
                } else {
                    const slot: u16 = @truncate(ev.data.u32);
                    if (ev.events & linux.EPOLL.IN != 0) {
                        self.handleRead(slot);
                    }
                    if (ev.events & linux.EPOLL.OUT != 0) {
                        self.handleWrite(slot);
                    }
                    if (ev.events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
                        self.freeSlotAndClose(slot);
                    }
                }
            }
        }
    }

    pub fn stop(self: *EpollServer) void {
        self.running = false;
    }
};

fn responseSucceeded(response: Response) bool {
    return switch (response) {
        .err => false,
        else => true,
    };
}
