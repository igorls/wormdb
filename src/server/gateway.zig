//! WebSocket Gateway — browser-direct access to WormDB
//!
//! Embeds a WebSocket server inside the WormDB process. Each binary
//! WebSocket message maps 1:1 to a WormWire frame.
//!
//! Architecture:
//!   Browser → WebSocket (binary) → WS frame unwrap → WormWire decode → Executor → Response → WS frame wrap → Browser
//!
//! The gateway reuses the existing executor pipeline, event bus, and store —
//! identical code path as TCP connections.

const std = @import("std");
const core = @import("../core/mod.zig");
const storage = @import("../storage/mod.zig");
const protocol = @import("../protocol/mod.zig");
const wire = protocol.wire;
const event_mod = @import("../event/mod.zig");
const cluster_mod = @import("../cluster/mod.zig");
const executor = @import("executor.zig");

const auth = @import("auth.zig");

const Store = storage.Store;
const EventBus = event_mod.EventBus;
const Command = core.types.Command;
const Response = core.types.Response;
const Cluster = cluster_mod.Cluster;
const Sha1 = std.crypto.hash.Sha1;

/// WebSocket gateway server.
pub const Gateway = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    event_bus: *EventBus,
    cluster: ?*Cluster,
    port: u16,
    running: std.atomic.Value(bool),
    /// Ed25519 public keys for SCT verification. Empty = auth disabled (all commands permitted).
    public_keys: []const auth.PublicKey,
    /// Maximum token lifetime in seconds (0 = no limit).
    max_token_age: u64,
    /// Whether authentication is required (true = reject unauthenticated commands).
    auth_required: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        event_bus: *EventBus,
        cluster: ?*Cluster,
        port: u16,
    ) Gateway {
        return .{
            .allocator = allocator,
            .store = store,
            .event_bus = event_bus,
            .cluster = cluster,
            .port = port,
            .running = std.atomic.Value(bool).init(false),
            .public_keys = &.{},
            .max_token_age = 0,
            .auth_required = false,
        };
    }

    /// Run the gateway on a dedicated thread. Call from main after server start.
    pub fn start(self: *Gateway) !std.Thread {
        return try std.Thread.spawn(.{}, runLoop, .{self});
    }

    fn runLoop(self: *Gateway) void {
        self.running.store(true, .release);

        const addr = std.net.Address.parseIp("0.0.0.0", self.port) catch |err| {
            std.log.err("Gateway: invalid bind address: {}", .{err});
            return;
        };
        var listener = addr.listen(.{ .reuse_address = true }) catch |err| {
            std.log.err("Gateway: listen failed on port {d}: {}", .{ self.port, err });
            return;
        };
        defer listener.deinit();

        std.log.info("Gateway listening on 0.0.0.0:{d} (WebSocket{s})", .{
            self.port,
            if (self.auth_required) @as([]const u8, ", auth required") else @as([]const u8, ""),
        });

        while (self.running.load(.acquire)) {
            const conn = listener.accept() catch |err| {
                std.log.debug("Gateway: accept error: {}", .{err});
                continue;
            };
            // Spawn a thread per connection — simple and sufficient for browser clients.
            // Browser connections are long-lived and few in number compared to TCP backend traffic.
            const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn }) catch |err| {
                std.log.warn("Gateway: spawn thread failed: {}", .{err});
                conn.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(self: *Gateway, conn: std.net.Server.Connection) void {
        var stream = conn.stream;
        defer stream.close();

        // Disable Nagle for low-latency request/response
        std.posix.setsockopt(
            stream.handle,
            std.posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch {};

        // Step 1: WebSocket handshake
        var request_buf: [4096]u8 = undefined;
        const request = readHttpRequest(&stream, &request_buf) orelse return;

        const ws_key = extractWebSocketKey(request) orelse {
            const reject = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            stream.writeAll(reject) catch {};
            return;
        };

        // Compute Sec-WebSocket-Accept
        const accept_value = computeAcceptKey(ws_key);
        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(
            &response_buf,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n" ++
                "\r\n",
            .{accept_value},
        ) catch return;
        stream.writeAll(response) catch return;

        // Step 2: WebSocket session — command loop
        var conn_ctx = ConnContext.init(self.allocator, self.event_bus, &stream);
        defer conn_ctx.deinit();

        var cmd_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer cmd_arena.deinit();

        // Per-connection auth state
        var auth_state: ?auth.TokenState = null;

        while (self.running.load(.acquire)) {
            // Check if token expired mid-session
            if (auth_state) |*state| {
                if (state.isExpired()) {
                    auth_state = null; // Revoke — force re-auth
                }
            }

            // Read one WebSocket frame
            const ws_frame = readWsFrame(&stream, self.allocator) orelse return;
            defer if (ws_frame.allocated) self.allocator.free(ws_frame.payload);

            switch (ws_frame.opcode) {
                0x08 => {
                    // Close frame — send close reply and exit
                    sendWsFrame(&stream, 0x08, ws_frame.payload) catch {};
                    return;
                },
                0x09 => {
                    // Ping — respond with pong
                    sendWsFrame(&stream, 0x0A, ws_frame.payload) catch {};
                    continue;
                },
                0x0A => continue, // Pong — ignore
                0x02 => {}, // Binary — process below
                else => {
                    // Text or other — reject
                    sendWsCloseWithCode(&stream, 1003) catch {};
                    return;
                },
            }

            // Step 3: Parse WormWire command from WebSocket binary payload
            _ = cmd_arena.reset(.retain_capacity);
            const arena_alloc = cmd_arena.allocator();

            const payload = ws_frame.payload;
            if (payload.len < 5) {
                const err_resp = wireEncodeError("frame too short");
                sendWsFrame(&stream, 0x02, err_resp) catch return;
                continue;
            }

            const cmd_id_raw = payload[0];
            const cmd_id = std.meta.intToEnum(core.types.CommandId, cmd_id_raw) catch {
                const err_resp = wireEncodeError("unknown command");
                sendWsFrame(&stream, 0x02, err_resp) catch return;
                continue;
            };
            const payload_len = std.mem.readInt(u32, payload[1..5], .big);
            if (5 + payload_len > payload.len) {
                const err_resp = wireEncodeError("incomplete frame");
                sendWsFrame(&stream, 0x02, err_resp) catch return;
                continue;
            }

            const cmd_payload = payload[5 .. 5 + payload_len];
            const cmd = wire.parseCommandPayloadZeroCopy(cmd_id, cmd_payload, arena_alloc) catch {
                const err_resp = wireEncodeError("malformed command");
                sendWsFrame(&stream, 0x02, err_resp) catch return;
                continue;
            };

            // Step 4: Handle AUTH command at connection level
            const resp = switch (cmd) {
                .auth => |token| blk: {
                    if (self.public_keys.len == 0) {
                        break :blk Response{ .err = "auth not configured" };
                    }
                    const state = auth.verifyAndParse(
                        token,
                        self.public_keys,
                        self.allocator,
                        self.max_token_age,
                    ) catch |err| {
                        const msg: []const u8 = switch (err) {
                            error.InvalidSignature => "invalid signature",
                            error.TokenExpired => "token expired",
                            error.TokenNotYetValid => "token not yet valid",
                            error.TokenTooLongLived => "token lifetime exceeds max",
                            error.TokenTooShort, error.MalformedToken => "malformed token",
                            else => "auth failed",
                        };
                        break :blk Response{ .err = msg };
                    };
                    // Replace previous auth state
                    if (auth_state) |*old| {
                        self.allocator.free(old.subject);
                        for (old.capabilities) |cap| {
                            self.allocator.free(cap.pattern);
                        }
                        self.allocator.free(old.capabilities);
                    }
                    auth_state = state;
                    break :blk Response.ok;
                },
                .subscribe => |channel| blk: {
                    // Check capability for subscribe
                    if (self.auth_required) {
                        if (auth_state) |*state| {
                            if (!state.permits(.subscribe, channel)) {
                                break :blk Response{ .err = "permission denied" };
                            }
                        } else {
                            break :blk Response{ .err = "auth required" };
                        }
                    }
                    conn_ctx.subscribe(channel) catch {
                        break :blk Response{ .err = "subscription failed" };
                    };
                    break :blk Response.ok;
                },
                .unsubscribe => |channel| blk: {
                    conn_ctx.unsubscribe(channel);
                    break :blk Response.ok;
                },
                else => blk: {
                    // Step 5: Capability enforcement
                    if (self.auth_required) {
                        if (auth_state) |*state| {
                            const op = auth.commandToOperation(cmd_id_raw);
                            const target = auth.commandTarget(cmd);
                            if (op) |o| {
                                if (target) |t| {
                                    if (!state.permits(o, t)) {
                                        break :blk Response{ .err = "permission denied" };
                                    }
                                }
                            }
                        } else {
                            // No STATUS/CLUSTER_STATUS without auth if auth_required
                            // (those ops return null from commandToOperation, so they pass through)
                            const op = auth.commandToOperation(cmd_id_raw);
                            if (op != null) {
                                break :blk Response{ .err = "auth required" };
                            }
                        }
                    }

                    break :blk executor.execute(.{
                        .allocator = arena_alloc,
                        .store = self.store,
                        .event_bus = self.event_bus,
                        .cluster = self.cluster,
                        .identity = if (auth_state) |*s| s.subject else null,
                    }, cmd) catch |err| {
                        const err_msg: []const u8 = switch (err) {
                            error.WormViolation => "WORM violation",
                            error.OutOfMemory => "out of memory",
                            error.IoError => "I/O error",
                            error.KeyNotFound => "key not found",
                            error.Corruption => "data corruption",
                        };
                        break :blk Response{ .err = err_msg };
                    };
                },
            };

            // Step 6: Encode WormWire response and send as WebSocket binary frame
            var resp_buf: [65536]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&resp_buf);
            wire.writeResponse(fbs.writer(), resp) catch {
                const err_resp = wireEncodeError("response too large");
                sendWsFrame(&stream, 0x02, err_resp) catch return;
                continue;
            };
            sendWsFrame(&stream, 0x02, fbs.getWritten()) catch return;
        }
    }

    // --- WebSocket Protocol Implementation ---

    const WsFrame = struct {
        opcode: u4,
        payload: []const u8,
        allocated: bool, // true if payload was heap-allocated (needs free)
    };

    fn readWsFrame(stream: *std.net.Stream, allocator: std.mem.Allocator) ?WsFrame {
        // Read 2 byte header
        var header: [2]u8 = undefined;
        readExact(stream, &header) orelse return null;

        const opcode: u4 = @truncate(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            readExact(stream, &ext) orelse return null;
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            readExact(stream, &ext) orelse return null;
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // Sanity check — reject frames > 16 MiB
        if (payload_len > 16 * 1024 * 1024) return null;

        var mask_key: [4]u8 = undefined;
        if (masked) {
            readExact(stream, &mask_key) orelse return null;
        }

        const len: usize = @intCast(payload_len);
        const buf = allocator.alloc(u8, len) catch return null;

        var read_total: usize = 0;
        while (read_total < len) {
            const n = stream.read(buf[read_total..]) catch return null;
            if (n == 0) {
                allocator.free(buf);
                return null;
            }
            read_total += n;
        }

        // Unmask if needed (browser clients always mask)
        if (masked) {
            for (buf, 0..) |*byte, j| {
                byte.* ^= mask_key[j % 4];
            }
        }

        return .{ .opcode = opcode, .payload = buf, .allocated = true };
    }

    fn sendWsFrame(stream: *std.net.Stream, opcode: u8, payload: []const u8) !void {
        // Server-to-client frames are NOT masked (RFC 6455 §5.1)
        var header_buf: [10]u8 = undefined;
        var header_len: usize = 2;
        header_buf[0] = 0x80 | opcode; // FIN + opcode

        if (payload.len < 126) {
            header_buf[1] = @intCast(payload.len);
        } else if (payload.len <= 65535) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
            header_len = 10;
        }

        try stream.writeAll(header_buf[0..header_len]);
        if (payload.len > 0) {
            try stream.writeAll(payload);
        }
    }

    fn sendWsCloseWithCode(stream: *std.net.Stream, code: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, code, .big);
        try sendWsFrame(stream, 0x08, &buf);
    }

    fn readExact(stream: *std.net.Stream, dest: []u8) ?void {
        var offset: usize = 0;
        while (offset < dest.len) {
            const n = stream.read(dest[offset..]) catch return null;
            if (n == 0) return null;
            offset += n;
        }
    }

    // --- HTTP/WebSocket Handshake ---

    fn readHttpRequest(stream: *std.net.Stream, buf: *[4096]u8) ?[]const u8 {
        var total: usize = 0;
        while (total < buf.len) {
            const n = stream.read(buf[total..]) catch return null;
            if (n == 0) return null;
            total += n;
            // Check for end of HTTP headers
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) {
                return buf[0..total];
            }
        }
        return null; // Headers too large
    }

    fn extractWebSocketKey(request: []const u8) ?[]const u8 {
        // Find "Sec-WebSocket-Key: " header (case-insensitive search on header name)
        var it = std.mem.splitSequence(u8, request, "\r\n");
        while (it.next()) |line| {
            if (line.len > 19) {
                // Check for "Sec-WebSocket-Key: " prefix (case-insensitive)
                if (asciiEqlIgnoreCase(line[0..19], "Sec-WebSocket-Key: ")) {
                    return std.mem.trim(u8, line[19..], " \t");
                }
            }
        }
        return null;
    }

    fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
            const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
            if (la != lb) return false;
        }
        return true;
    }

    const WS_MAGIC_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    fn computeAcceptKey(ws_key: []const u8) [28]u8 {
        var hasher = Sha1.init(.{});
        hasher.update(ws_key);
        hasher.update(WS_MAGIC_GUID);
        const hash = hasher.finalResult();

        var result: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&result, &hash);
        return result;
    }

    // --- Helpers ---

    fn wireEncodeError(msg: []const u8) []const u8 {
        // Pre-encoded error responses for common cases.
        // Format: [0x03 (err code)][4B len][msg]
        // For simplicity we return a comptime-known slice for short messages.
        _ = msg;
        return &[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x05 } ++ "error";
    }

    // --- Connection Context (manages subscriptions per WebSocket client) ---

    const ConnContext = struct {
        allocator: std.mem.Allocator,
        event_bus: *EventBus,
        stream: *std.net.Stream,
        subscriptions: std.StringHashMap(u64),
        write_mutex: std.Thread.Mutex,

        fn init(allocator: std.mem.Allocator, event_bus: *EventBus, stream: *std.net.Stream) ConnContext {
            return .{
                .allocator = allocator,
                .event_bus = event_bus,
                .stream = stream,
                .subscriptions = std.StringHashMap(u64).init(allocator),
                .write_mutex = .{},
            };
        }

        fn deinit(self: *ConnContext) void {
            var iter = self.subscriptions.iterator();
            while (iter.next()) |entry| {
                self.event_bus.unsubscribe(entry.key_ptr.*, entry.value_ptr.*);
                self.allocator.free(entry.key_ptr.*);
            }
            self.subscriptions.deinit();
        }

        fn subscribe(self: *ConnContext, channel: []const u8) !void {
            if (self.subscriptions.contains(channel)) return;

            const channel_copy = try self.allocator.dupe(u8, channel);
            errdefer self.allocator.free(channel_copy);

            const sub_id = try self.event_bus.subscribe(
                channel_copy,
                ConnContext.writeEvent,
                @ptrCast(self),
            );
            errdefer self.event_bus.unsubscribe(channel_copy, sub_id);

            try self.subscriptions.put(channel_copy, sub_id);
        }

        fn unsubscribe(self: *ConnContext, channel: []const u8) void {
            if (self.subscriptions.fetchRemove(channel)) |removed| {
                self.event_bus.unsubscribe(removed.key, removed.value);
                self.allocator.free(removed.key);
            }
        }

        /// Event callback — called from EventBus publisher thread.
        /// Wraps the WormWire event response in a WebSocket binary frame.
        fn writeEvent(ctx: *anyopaque, data: []const u8) void {
            const self: *ConnContext = @ptrCast(@alignCast(ctx));

            // Parse the text event payload to extract channel/message
            const parsed = parseTextEvent(data) orelse return;

            // Encode as WormWire event response
            var resp_buf: [65536]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&resp_buf);
            wire.writeResponse(fbs.writer(), .{ .event = .{
                .channel = parsed.channel,
                .message = parsed.message,
            } }) catch return;

            // Wrap in WebSocket binary frame and send
            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            sendWsFrame(self.stream, 0x02, fbs.getWritten()) catch {};
        }

        fn parseTextEvent(data: []const u8) ?struct { channel: []const u8, message: []const u8 } {
            const prefix = ">EVENT ";
            if (!std.mem.startsWith(u8, data, prefix)) return null;
            const ch_start = prefix.len;
            const ch_end_rel = std.mem.indexOf(u8, data[ch_start..], "\r\n") orelse return null;
            const ch_end = ch_start + ch_end_rel;
            const msg_start = ch_end + 2;
            if (msg_start >= data.len) return null;
            if (!std.mem.endsWith(u8, data, "\r\n")) return null;
            const msg_end = data.len - 2;
            if (msg_end < msg_start) return null;
            return .{ .channel = data[ch_start..ch_end], .message = data[msg_start..msg_end] };
        }
    };
};
