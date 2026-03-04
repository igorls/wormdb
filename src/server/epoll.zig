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

const Store = storage.Store;
const EventBus = event_mod.EventBus;
const Command = core.types.Command;
const Response = core.types.Response;
const Cluster = cluster_mod.Cluster;

const RECV_BUF_SIZE = 65536;
const MAX_EVENTS = 256;
const MAX_CONNS = 4096;

const ConnState = struct {
    fd: posix.fd_t = -1,
    recv_buf: [RECV_BUF_SIZE]u8 = undefined,
    recv_len: usize = 0,
    send_buf: []u8 = &.{},
    send_pos: usize = 0,
    resp_buf: std.ArrayListUnmanaged(u8) = .{},
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
        bind_address: []const u8,
        port: u16,
    ) !EpollServer {
        // Create listening socket (non-blocking)
        const addr = try std.net.Address.parseIp(bind_address, port);
        const listener_fd = try posix.socket(
            addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            posix.IPPROTO.TCP,
        );
        errdefer posix.close(listener_fd);

        try posix.setsockopt(listener_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener_fd, &addr.any, addr.getOsSockLen());
        try posix.listen(listener_fd, 128);

        // Create epoll instance
        const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        errdefer posix.close(epoll_fd);

        // Register listener
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = listener_fd },
        };
        try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listener_fd, &ev);

        // Pre-allocate connection pool
        const conns = try allocator.alloc(ConnState, MAX_CONNS);
        for (conns) |*c| c.* = .{};

        var free_slots = std.ArrayListUnmanaged(u16){};
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
            },
            .running = false,
        };
    }

    pub fn deinit(self: *EpollServer) void {
        posix.close(self.epoll_fd);
        posix.close(self.listener_fd);
        for (self.conns) |*c| {
            if (c.active) posix.close(c.fd);
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
            posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, conn.fd, null) catch {};
            posix.close(conn.fd);
            if (conn.send_buf.len > 0) self.allocator.free(conn.send_buf);
            conn.reset();
        }
        self.free_slots.appendAssumeCapacity(slot);
    }

    fn handleAccept(self: *EpollServer) void {
        // Accept as many connections as possible (edge-triggered style)
        while (true) {
            const client_fd = posix.accept(self.listener_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch break;

            // TCP_NODELAY
            posix.setsockopt(client_fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

            if (self.allocSlot()) |slot| {
                const conn = &self.conns[slot];
                conn.fd = client_fd;
                conn.active = true;

                // Register for read events; store slot index in data
                var ev = linux.epoll_event{
                    .events = linux.EPOLL.IN,
                    .data = .{ .u32 = slot },
                };
                posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, client_fd, &ev) catch {
                    posix.close(client_fd);
                    conn.reset();
                    self.free_slots.appendAssumeCapacity(slot);
                };
            } else {
                posix.close(client_fd);
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
            const cmd_id: wire.CommandId = std.meta.intToEnum(wire.CommandId, cmd_id_byte) catch {
                self.freeSlotAndClose(slot);
                return;
            };

            const payload = hdr[5..frame_len];
            const cmd = wire.parseCommandPayloadZeroCopy(cmd_id, payload, self.allocator) catch {
                self.freeSlotAndClose(slot);
                return;
            };

            const response = executor.execute(self.exec_ctx, cmd) catch |err| {
                const err_msg: []const u8 = switch (err) {
                    error.WormViolation => "WORM violation",
                    error.OutOfMemory => "out of memory",
                    error.IoError => "I/O error",
                    error.KeyNotFound => "key not found",
                    error.Corruption => "data corruption",
                };
                var w = conn.resp_buf.writer(self.allocator);
                wire.writeResponse(&w, .{ .err = err_msg }) catch {};
                consumed += frame_len;
                continue;
            };
            defer protocol.deinitResponse(self.allocator, response);

            var w = conn.resp_buf.writer(self.allocator);
            wire.writeResponse(&w, response) catch {};
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
            const written = posix.write(conn.fd, conn.resp_buf.items) catch {
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
                posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, conn.fd, &ev) catch {
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
        const written = posix.write(conn.fd, remaining) catch {
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
            posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, conn.fd, &ev) catch {
                self.freeSlotAndClose(slot);
            };
        }
    }

    pub fn run(self: *EpollServer) !void {
        self.running = true;
        std.log.info("WormDB epoll listening on fd={d}", .{self.listener_fd});

        var events: [MAX_EVENTS]linux.epoll_event = undefined;

        while (self.running) {
            const nfds = posix.epoll_wait(self.epoll_fd, &events, -1);
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
