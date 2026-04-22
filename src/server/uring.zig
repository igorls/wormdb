//! io_uring event loop server — single-threaded, zero-syscall I/O for sub-50μs latency.
//!
//! Uses multishot accept, batched CQE processing, and per-connection state machines.
//! Binary protocol (WormWire) only — text protocol clients fall back to the thread-pool server.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const core = @import("../core/mod.zig");
const storage = @import("../storage/mod.zig");
const protocol = @import("../protocol/mod.zig");
const wire = protocol.wire;
const event = @import("../event/mod.zig");
const cluster_mod = @import("../cluster/mod.zig");
const executor = @import("executor.zig");

const Store = storage.Store;
const EventBus = event.EventBus;
const Command = core.types.Command;
const Response = core.types.Response;
const Cluster = cluster_mod.Cluster;

const IoUring = linux.IoUring;

// ── user_data encoding: pack slot index + op type into u64 ──

const OpType = enum(u8) {
    accept = 0,
    recv = 1,
    send = 2,
    close = 3,
};

fn encodeUserData(slot: u16, op: OpType) u64 {
    return @as(u64, slot) | (@as(u64, @intFromEnum(op)) << 16);
}

fn decodeSlot(user_data: u64) u16 {
    return @truncate(user_data & 0xFFFF);
}

fn decodeOp(user_data: u64) OpType {
    return @enumFromInt(@as(u8, @truncate((user_data >> 16) & 0xFF)));
}

// ── Per-connection state ──

const RECV_BUF_SIZE = 65536;

const ConnState = struct {
    fd: posix.fd_t = -1,
    recv_buf: [RECV_BUF_SIZE]u8 = undefined,
    recv_len: usize = 0,
    send_buf: std.ArrayListUnmanaged(u8) = .empty,
    active: bool = false,
    /// Set to true once the full WormWire handshake (2 bytes) is validated.
    handshake_done: bool = false,

    fn reset(self: *ConnState) void {
        self.fd = -1;
        self.recv_len = 0;
        self.send_buf.clearRetainingCapacity();
        self.active = false;
        self.handshake_done = false;
    }
};

// ── UringServer ──

pub const UringServer = struct {
    ring: IoUring,
    listener_fd: posix.fd_t,
    conns: []ConnState,
    free_slots: std.ArrayListUnmanaged(u16),
    allocator: std.mem.Allocator,
    exec_ctx: executor.ExecContext,
    running: bool,

    const RING_ENTRIES = 256;
    const MAX_CONNS = 4096;
    const CQE_BATCH = 256;

    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        event_bus: *EventBus,
        cluster: ?*Cluster,
        bind_address: []const u8,
        port: u16,
    ) !UringServer {
        // Create listening socket.
        // We parse the bind IP using std.Io.net.IpAddress (0.16) and manually
        // populate a posix sockaddr_in so the remainder of this module can
        // stay on the raw-socket path.
        const parsed = try std.Io.net.IpAddress.parse(bind_address, port);
        const sin_bytes: [4]u8 = switch (parsed) {
            .ip4 => |ip4| ip4.bytes,
            .ip6 => return error.Ipv6BindNotSupportedInUringServer,
        };

        const sockaddr_in = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(sin_bytes),
            .zero = @splat(0),
        };

        // posix.socket / bind / listen / close were removed in Zig 0.16.
        // core.compat wraps the libc externs.
        const listener_fd = try core.compat.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            posix.IPPROTO.TCP,
        );
        errdefer core.compat.close(listener_fd);

        // SO_REUSEADDR
        try posix.setsockopt(listener_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        try core.compat.bind(listener_fd, @ptrCast(&sockaddr_in), @sizeOf(posix.sockaddr.in));
        try core.compat.listen(listener_fd, 128);

        // Initialize io_uring
        var params = std.mem.zeroes(linux.io_uring_params);
        var ring = try IoUring.init_params(RING_ENTRIES, &params);
        errdefer ring.deinit();

        // Pre-allocate connection pool
        const conns = try allocator.alloc(ConnState, MAX_CONNS);
        for (conns) |*c| c.* = .{};

        // Free list (all slots initially free)
        var free_slots: std.ArrayListUnmanaged(u16) = .empty;
        try free_slots.ensureTotalCapacity(allocator, MAX_CONNS);
        var i: u16 = 0;
        while (i < MAX_CONNS) : (i += 1) {
            free_slots.appendAssumeCapacity(i);
        }

        return .{
            .ring = ring,
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

    pub fn deinit(self: *UringServer) void {
        self.ring.deinit();
        core.compat.close(self.listener_fd);
        for (self.conns) |*c| {
            if (c.active) {
                core.compat.close(c.fd);
            }
            c.send_buf.deinit(self.allocator);
        }
        self.allocator.free(self.conns);
        self.free_slots.deinit(self.allocator);
    }

    /// Submit an accept SQE for the listening socket.
    fn queueAccept(self: *UringServer) !void {
        _ = try self.ring.accept(
            encodeUserData(0, .accept),
            self.listener_fd,
            null,
            null,
            posix.SOCK.CLOEXEC,
        );
    }

    /// Submit a recv SQE for a connection slot.
    fn queueRecv(self: *UringServer, slot: u16) !void {
        const conn = &self.conns[slot];
        // Recv into the buffer starting after any existing data
        _ = try self.ring.recv(
            encodeUserData(slot, .recv),
            conn.fd,
            .{ .buffer = conn.recv_buf[conn.recv_len..] },
            0,
        );
    }

    /// Submit a send SQE for a connection slot.
    fn queueSend(self: *UringServer, slot: u16) !void {
        const conn = &self.conns[slot];
        _ = try self.ring.send(
            encodeUserData(slot, .send),
            conn.fd,
            conn.send_buf.items,
            0,
        );
    }

    /// Submit a close SQE for a connection slot.
    fn queueClose(self: *UringServer, slot: u16) !void {
        const conn = &self.conns[slot];
        _ = try self.ring.close(encodeUserData(slot, .close), conn.fd);
    }

    /// Allocate a connection slot, returns null if pool is exhausted.
    fn allocSlot(self: *UringServer) ?u16 {
        if (self.free_slots.items.len == 0) return null;
        return self.free_slots.pop();
    }

    /// Free a connection slot back to the pool.
    fn freeSlot(self: *UringServer, slot: u16) void {
        self.conns[slot].reset();
        self.free_slots.appendAssumeCapacity(slot);
    }

    /// Process a completed recv — parse + execute + queue send.
    fn handleRecvComplete(self: *UringServer, slot: u16, nbytes: usize) void {
        const conn = &self.conns[slot];
        conn.recv_len += nbytes;

        // Check handshake (first 2 bytes = WormWire magic)
        if (!conn.handshake_done) {
            if (conn.recv_len < 2) {
                // Need more data
                self.queueRecv(slot) catch {
                    self.queueClose(slot) catch {};
                };
                return;
            }
            if (!std.mem.eql(u8, conn.recv_buf[0..2], &wire.WIRE_MAGIC)) {
                // Not binary protocol — reject
                self.queueClose(slot) catch {};
                return;
            }
            conn.handshake_done = true;
            // Remove handshake bytes from buffer
            const remaining = conn.recv_len - 2;
            if (remaining > 0) {
                std.mem.copyForwards(u8, conn.recv_buf[0..remaining], conn.recv_buf[2..conn.recv_len]);
            }
            conn.recv_len = remaining;
        }

        // Process as many complete frames as possible from the buffer
        self.processFrames(slot);
    }

    /// Parse and execute complete WormWire frames from the recv buffer.
    fn processFrames(self: *UringServer, slot: u16) void {
        const conn = &self.conns[slot];

        while (conn.recv_len >= 5) {
            // WormWire frame: 1 byte cmd + 4 byte payload_len + payload
            const payload_len = std.mem.readInt(u32, conn.recv_buf[1..5], .big);
            const frame_len = 5 + @as(usize, payload_len);

            if (conn.recv_len < frame_len) break; // incomplete frame

            // Parse command from the buffer (zero-copy — slices into recv_buf)
            const cmd_id_byte = conn.recv_buf[0];
            const cmd_id: wire.CommandId = core.compat.intToEnum(wire.CommandId, cmd_id_byte) catch {
                // Unknown command — send error, close
                self.writeError(slot, "unknown command");
                self.flushAndClose(slot);
                return;
            };

            const payload = conn.recv_buf[5..frame_len];
            const cmd = wire.parseCommandPayloadZeroCopy(cmd_id, payload, self.allocator) catch {
                self.writeError(slot, "malformed frame");
                self.flushAndClose(slot);
                return;
            };

            // Execute
            const response = executor.execute(self.exec_ctx, cmd) catch |err| {
                const err_msg: []const u8 = switch (err) {
                    error.WormViolation => "WORM violation",
                    error.OutOfMemory => "out of memory",
                    error.IoError => "I/O error",
                    error.KeyNotFound => "key not found",
                    error.Corruption => "data corruption",
                };
                self.writeError(slot, err_msg);
                // Shift buffer, continue processing
                self.shiftBuffer(slot, frame_len);
                continue;
            };
            defer protocol.deinitResponse(self.allocator, response);

            // Serialize response into send buffer
            self.writeResponse(slot, response);

            // Shift consumed bytes out of recv buffer
            self.shiftBuffer(slot, frame_len);
        }

        // If we have data to send, queue a send; otherwise queue another recv
        if (conn.send_buf.items.len > 0) {
            self.queueSend(slot) catch {
                self.queueClose(slot) catch {};
            };
        } else {
            self.queueRecv(slot) catch {
                self.queueClose(slot) catch {};
            };
        }
    }

    fn shiftBuffer(self: *UringServer, slot: u16, consumed: usize) void {
        const conn = &self.conns[slot];
        const remaining = conn.recv_len - consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, conn.recv_buf[0..remaining], conn.recv_buf[consumed..conn.recv_len]);
        }
        conn.recv_len = remaining;
    }

    /// Adapter so `wire.writeResponse` (which takes any writer with
    /// `writeAll`) can push into our ArrayListUnmanaged-backed send buffer.
    /// ArrayList.writer() was removed in Zig 0.16.
    const SendBufWriter = struct {
        buf: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,

        pub fn writeAll(self: *SendBufWriter, data: []const u8) !void {
            try self.buf.appendSlice(self.allocator, data);
        }
    };

    fn writeResponse(self: *UringServer, slot: u16, response: Response) void {
        const conn = &self.conns[slot];
        var writer = SendBufWriter{ .buf = &conn.send_buf, .allocator = self.allocator };
        wire.writeResponse(&writer, response) catch {};
    }

    fn writeError(self: *UringServer, slot: u16, msg: []const u8) void {
        self.writeResponse(slot, .{ .err = msg });
    }

    fn flushAndClose(self: *UringServer, slot: u16) void {
        const conn = &self.conns[slot];
        if (conn.send_buf.items.len > 0) {
            // Send response first, then close on completion
            self.queueSend(slot) catch {
                self.queueClose(slot) catch {};
            };
        } else {
            self.queueClose(slot) catch {};
        }
    }

    /// Main event loop.
    pub fn run(self: *UringServer) !void {
        self.running = true;

        // Queue initial accept
        try self.queueAccept();
        _ = try self.ring.submit();

        std.log.info("WormDB io_uring listening on fd={d}", .{self.listener_fd});

        var cqes: [CQE_BATCH]linux.io_uring_cqe = undefined;

        while (self.running) {
            // Wait for at least 1 CQE, harvest up to CQE_BATCH
            const count = try self.ring.copy_cqes(&cqes, 1);

            for (cqes[0..count]) |cqe| {
                const op = decodeOp(cqe.user_data);
                const slot = decodeSlot(cqe.user_data);
                const res = cqe.res;

                switch (op) {
                    .accept => {
                        // Always re-queue accept for next connection
                        self.queueAccept() catch {};

                        if (res < 0) {
                            // Accept failed — just retry
                            continue;
                        }

                        const client_fd: posix.fd_t = @intCast(res);

                        // Set TCP_NODELAY
                        posix.setsockopt(client_fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

                        // Allocate connection slot
                        if (self.allocSlot()) |new_slot| {
                            const conn = &self.conns[new_slot];
                            conn.fd = client_fd;
                            conn.active = true;
                            self.queueRecv(new_slot) catch {
                                core.compat.close(client_fd);
                                self.freeSlot(new_slot);
                            };
                        } else {
                            // Pool exhausted — reject
                            core.compat.close(client_fd);
                        }
                    },
                    .recv => {
                        if (res <= 0) {
                            // EOF or error — close connection
                            self.queueClose(slot) catch {
                                core.compat.close(self.conns[slot].fd);
                                self.freeSlot(slot);
                            };
                            continue;
                        }
                        self.handleRecvComplete(slot, @intCast(res));
                    },
                    .send => {
                        const conn = &self.conns[slot];
                        conn.send_buf.clearRetainingCapacity();

                        if (res < 0) {
                            // Send error — close
                            self.queueClose(slot) catch {
                                core.compat.close(conn.fd);
                                self.freeSlot(slot);
                            };
                            continue;
                        }

                        // Check if there's more data to receive
                        self.queueRecv(slot) catch {
                            self.queueClose(slot) catch {};
                        };
                    },
                    .close => {
                        self.freeSlot(slot);
                    },
                }
            }

            // Submit all queued SQEs from this batch
            _ = try self.ring.submit();
        }
    }

    pub fn stop(self: *UringServer) void {
        self.running = false;
    }
};
