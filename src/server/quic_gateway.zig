//! QUIC/WebTransport Gateway — browser-direct access to WormDB over QUIC
//!
//! Uses libwtf (WebTransport over MsQuic) to accept WebTransport connections.
//! Each bidirectional stream carries one WormWire request/response exchange.
//!
//! Architecture:
//!   Browser → WebTransport (QUIC/UDP) → stream read → WormWire decode
//!           → executor.execute() → WormWire encode → stream write
//!
//! Mirrors gateway.zig but replaces WebSocket framing with WebTransport streams.

const std = @import("std");
const core = @import("../core/mod.zig");
const storage = @import("../storage/mod.zig");
const protocol = @import("../protocol/mod.zig");
const wire = protocol.wire;
const event_mod = @import("../event/mod.zig");
const cluster_mod = @import("../cluster/mod.zig");
const executor = @import("executor.zig");
const config = core.config;
const auth = @import("auth.zig");

const Store = storage.Store;
const EventBus = event_mod.EventBus;
const Command = core.types.Command;
const Response = core.types.Response;
const Cluster = cluster_mod.Cluster;

// libwtf C bindings
const wtf = @cImport({
    @cInclude("wtf.h");
});

/// Per-session state — allocated on CONNECTED, freed on DISCONNECTED.
const SessionContext = struct {
    gateway: *QuicGateway,
    session: ?*wtf.wtf_session_t,
    auth_state: ?auth.TokenState,
};

/// Per-stream state — allocated on STREAM_OPENED, freed on CLOSED.
const StreamContext = struct {
    session_ctx: *SessionContext,
    recv_buf: std.ArrayListUnmanaged(u8),
};

/// QUIC/WebTransport gateway server.
pub const QuicGateway = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    event_bus: *EventBus,
    cluster: ?*Cluster,
    port: u16,
    cert_path: [:0]const u8,
    key_path: [:0]const u8,
    running: std.atomic.Value(bool),
    /// Ed25519 public keys for SCT verification
    public_keys: []const auth.PublicKey,
    max_token_age: u64,
    auth_required: bool,

    // libwtf handles
    context: ?*wtf.wtf_context_t,
    server: ?*wtf.wtf_server_t,

    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        event_bus: *EventBus,
        cluster: ?*Cluster,
        port: u16,
        cert_path: [:0]const u8,
        key_path: [:0]const u8,
    ) QuicGateway {
        return .{
            .allocator = allocator,
            .store = store,
            .event_bus = event_bus,
            .cluster = cluster,
            .port = port,
            .cert_path = cert_path,
            .key_path = key_path,
            .running = std.atomic.Value(bool).init(false),
            .public_keys = &.{},
            .max_token_age = 0,
            .auth_required = false,
            .context = null,
            .server = null,
        };
    }

    /// Start the QUIC gateway. Returns the listener thread.
    pub fn start(self: *QuicGateway) !std.Thread {
        return try std.Thread.spawn(.{}, runLoop, .{self});
    }

    fn runLoop(self: *QuicGateway) void {
        self.running.store(true, .release);

        // Step 1: Create libwtf context
        var ctx_config = std.mem.zeroes(wtf.wtf_context_config_t);
        ctx_config.log_level = wtf.WTF_LOG_LEVEL_INFO;

        var context: ?*wtf.wtf_context_t = null;
        const ctx_result = wtf.wtf_context_create(&ctx_config, &context);
        if (ctx_result != wtf.WTF_SUCCESS) {
            std.log.err("QUIC Gateway: failed to create context, error: {d}", .{@as(u32, ctx_result)});
            return;
        }
        self.context = context;
        defer {
            if (self.context) |ctx| {
                wtf.wtf_context_destroy(ctx);
                self.context = null;
            }
        }

        // Step 2: Set up TLS certificate config
        var cert_config = std.mem.zeroes(wtf.wtf_certificate_config_t);
        cert_config.cert_type = wtf.WTF_CERT_TYPE_FILE;
        cert_config.cert_data.file.cert_path = self.cert_path.ptr;
        cert_config.cert_data.file.key_path = self.key_path.ptr;

        // Step 3: Configure the server
        var server_config = std.mem.zeroes(wtf.wtf_server_config_t);
        server_config.port = self.port;
        server_config.cert_config = &cert_config;
        server_config.session_callback = sessionCallback;
        server_config.connection_validator = connectionValidator;
        server_config.user_context = @ptrCast(self);
        server_config.idle_timeout_ms = 30000;
        server_config.handshake_timeout_ms = 5000;

        var server: ?*wtf.wtf_server_t = null;
        const srv_result = wtf.wtf_server_create(context.?, &server_config, &server);
        if (srv_result != wtf.WTF_SUCCESS) {
            std.log.err("QUIC Gateway: failed to create server, error: {d}", .{@as(u32, srv_result)});
            return;
        }
        self.server = server;
        defer {
            if (self.server) |srv| {
                _ = wtf.wtf_server_stop(srv);
                wtf.wtf_server_destroy(srv);
                self.server = null;
            }
        }

        const start_result = wtf.wtf_server_start(server.?);
        if (start_result != wtf.WTF_SUCCESS) {
            std.log.err("QUIC Gateway: failed to start server, error: {d}", .{@as(u32, start_result)});
            return;
        }

        std.log.info("QUIC Gateway: listening on UDP port {d} (WebTransport)", .{self.port});

        // Block this thread until shutdown
        while (self.running.load(.acquire)) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    pub fn stop(self: *QuicGateway) void {
        self.running.store(false, .release);
    }

    // --- libwtf Callbacks (C calling convention) ---

    /// Validate incoming WebTransport connections. Accept all.
    fn connectionValidator(_: [*c]const wtf.wtf_connection_request_t, _: ?*anyopaque) callconv(.c) wtf.wtf_connection_decision_t {
        return wtf.WTF_CONNECTION_ACCEPT;
    }

    /// Handle WebTransport session events.
    /// libwtf calls this with (event) only — gateway pointer comes from server user_context
    /// threaded through the session's user context.
    fn sessionCallback(event: [*c]const wtf.wtf_session_event_t) callconv(.c) void {
        const ev = event.*;

        switch (ev.type) {
            wtf.WTF_SESSION_EVENT_CONNECTED => {
                // The session's server has our gateway pointer in user_context.
                // We store it by convention in session context.
                // But the session callback doesn't give us user_context directly...
                // We need to find the gateway pointer from a global or thread-local.
                // WORKAROUND: use a module-level global (only one QUIC gateway per process)
                const gw = global_gateway orelse return;

                std.log.info("QUIC Gateway: new WebTransport session", .{});

                // Allocate per-session state
                const session_ctx = gw.allocator.create(SessionContext) catch {
                    std.log.err("QUIC Gateway: failed to allocate session context", .{});
                    return;
                };
                session_ctx.* = SessionContext{
                    .gateway = gw,
                    .session = ev.session,
                    .auth_state = null,
                };
                wtf.wtf_session_set_context(ev.session, @ptrCast(session_ctx));
            },
            wtf.WTF_SESSION_EVENT_STREAM_OPENED => {
                const ctx_ptr = wtf.wtf_session_get_context(ev.session);
                if (ctx_ptr == null) return;
                const session_ctx: *SessionContext = @ptrCast(@alignCast(ctx_ptr));
                const gw = session_ctx.gateway;

                const stream = ev.unnamed_0.stream_opened.stream;

                // Allocate per-stream state
                const stream_ctx = gw.allocator.create(StreamContext) catch {
                    std.log.err("QUIC Gateway: failed to allocate stream context", .{});
                    return;
                };
                stream_ctx.* = StreamContext{
                    .session_ctx = session_ctx,
                    .recv_buf = .{},
                };

                wtf.wtf_stream_set_callback(stream, streamCallback);
                wtf.wtf_stream_set_context(stream, @ptrCast(stream_ctx));
            },
            wtf.WTF_SESSION_EVENT_DISCONNECTED => {
                const ctx_ptr = wtf.wtf_session_get_context(ev.session);
                if (ctx_ptr) |ptr| {
                    const session_ctx: *SessionContext = @ptrCast(@alignCast(ptr));
                    const gw = session_ctx.gateway;
                    if (session_ctx.auth_state) |*state| {
                        gw.allocator.free(state.capabilities);
                    }
                    gw.allocator.destroy(session_ctx);
                }
                std.log.info("QUIC Gateway: session disconnected", .{});
            },
            else => {},
        }
    }

    /// Handle WebTransport stream events — the WormWire command loop.
    fn streamCallback(event: [*c]const wtf.wtf_stream_event_t) callconv(.c) void {
        const stream_user_ctx = wtf.wtf_stream_get_context(event.*.stream);
        if (stream_user_ctx == null) return;
        const stream_ctx: *StreamContext = @ptrCast(@alignCast(stream_user_ctx));
        const session_ctx = stream_ctx.session_ctx;
        const gw = session_ctx.gateway;

        const ev = event.*;

        switch (ev.type) {
            wtf.WTF_STREAM_EVENT_DATA_RECEIVED => {
                // Accumulate received data
                const data = ev.unnamed_0.data_received;
                var i: u32 = 0;
                while (i < data.buffer_count) : (i += 1) {
                    const buf = data.buffers[i];
                    stream_ctx.recv_buf.appendSlice(gw.allocator, @as([*]const u8, @ptrCast(buf.data))[0..buf.length]) catch return;
                }

                // Process complete WormWire frames: [1B cmd][4B len][payload]
                while (true) {
                    const items = stream_ctx.recv_buf.items;
                    if (items.len < 5) break;

                    const cmd_id_raw = items[0];
                    const payload_len = std.mem.readInt(u32, items[1..5], .big);

                    if (items.len < 5 + payload_len) break;

                    const payload = items[5 .. 5 + payload_len];

                    // Parse & execute
                    processCommand(gw, session_ctx, ev.stream, cmd_id_raw, payload);

                    // Drain processed bytes
                    const consumed = 5 + payload_len;
                    const remaining = items.len - consumed;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, items[0..remaining], items[consumed..]);
                    }
                    stream_ctx.recv_buf.shrinkRetainingCapacity(remaining);
                }
            },
            wtf.WTF_STREAM_EVENT_SEND_COMPLETE => {
                // Free the C-malloc'd response data. The buffer struct array
                // (send_ctx->buffers) is freed by libwtf after this callback returns.
                const send_data = ev.unnamed_0.send_complete;
                var j: u32 = 0;
                while (j < send_data.buffer_count) : (j += 1) {
                    const buf = send_data.buffers[j];
                    if (buf.data != null) {
                        std.c.free(buf.data);
                    }
                }
            },
            wtf.WTF_STREAM_EVENT_PEER_CLOSED => {
                // Peer closed their send side — no cleanup yet, wait for CLOSED
            },
            wtf.WTF_STREAM_EVENT_CLOSED => {
                // Terminal event — clean up stream context
                stream_ctx.recv_buf.deinit(gw.allocator);
                gw.allocator.destroy(stream_ctx);
                // Null the context to prevent stale pointer access
                wtf.wtf_stream_set_context(ev.stream, null);
            },
            else => {},
        }
    }

    /// Process a single WormWire command from the stream.
    fn processCommand(
        gw: *QuicGateway,
        session_ctx: *SessionContext,
        stream: ?*wtf.wtf_stream_t,
        cmd_id_raw: u8,
        payload: []const u8,
    ) void {
        var arena = std.heap.ArenaAllocator.init(gw.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const cmd_id = std.meta.intToEnum(core.types.CommandId, cmd_id_raw) catch {
            sendResponse(stream, Response{ .err = "unknown command" });
            return;
        };

        const cmd = wire.parseCommandPayloadZeroCopy(cmd_id, payload, arena_alloc) catch {
            sendResponse(stream, Response{ .err = "malformed command" });
            return;
        };

        const resp = switch (cmd) {
            .auth => |token| blk: {
                if (gw.public_keys.len == 0) {
                    break :blk Response{ .err = "auth not configured" };
                }
                const state = auth.verifyAndParse(
                    token,
                    gw.public_keys,
                    gw.allocator,
                    gw.max_token_age,
                ) catch {
                    break :blk Response{ .err = "invalid token" };
                };
                if (session_ctx.auth_state) |*old| {
                    gw.allocator.free(old.capabilities);
                }
                session_ctx.auth_state = state;
                break :blk Response.ok;
            },
            else => blk: {
                // Capability enforcement
                if (gw.auth_required) {
                    if (session_ctx.auth_state) |*state| {
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
                        break :blk Response{ .err = "auth required" };
                    }
                }

                // Execute
                break :blk executor.execute(.{
                    .allocator = arena_alloc,
                    .store = gw.store,
                    .event_bus = gw.event_bus,
                    .cluster = gw.cluster,
                    .identity = if (session_ctx.auth_state) |*s| s.subject else null,
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

        sendResponse(stream, resp);
    }

    fn sendResponse(stream: ?*wtf.wtf_stream_t, resp: Response) void {
        // Serialize response to a temporary stack buffer, then copy to C heap.
        // CRITICAL MEMORY CONTRACT with libwtf:
        //   - wtf_stream_send stores the wtf_buffer_t* pointer
        //   - On SEND_COMPLETE, libwtf calls our callback (to free data),
        //     then free(send_ctx->buffers) and free(send_ctx)
        //   - All allocations must use C malloc/free (not Zig allocator)
        var tmp_buf: [65536]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&tmp_buf);
        wire.writeResponse(fbs.writer(), resp) catch {
            // Fallback: send a small error response
            var err_tmp: [256]u8 = undefined;
            var err_fbs = std.io.fixedBufferStream(&err_tmp);
            wire.writeResponse(err_fbs.writer(), Response{ .err = "response too large" }) catch return;
            const err_data = err_fbs.getWritten();
            sendRawResponse(stream, err_data);
            return;
        };
        const written = fbs.getWritten();
        sendRawResponse(stream, written);
    }

    fn sendRawResponse(stream: ?*wtf.wtf_stream_t, data: []const u8) void {
        // Allocate buffer struct with C malloc (libwtf will free() it)
        const buf_ptr = std.c.malloc(@sizeOf(wtf.wtf_buffer_t)) orelse return;
        const heap_buf: [*c]wtf.wtf_buffer_t = @ptrCast(@alignCast(buf_ptr));

        // Allocate data with C malloc (we free in SEND_COMPLETE callback)
        const data_ptr = std.c.malloc(data.len) orelse {
            std.c.free(buf_ptr);
            return;
        };
        @memcpy(@as([*]u8, @ptrCast(data_ptr))[0..data.len], data);

        heap_buf[0] = wtf.wtf_buffer_t{
            .length = @intCast(data.len),
            .data = @ptrCast(data_ptr),
        };
        _ = wtf.wtf_stream_send(stream, heap_buf, 1, false);
    }

    /// Register this gateway as the global instance (required for session callback).
    /// Only one QUIC gateway per process is supported.
    pub fn setGlobal(self: *QuicGateway) void {
        global_gateway = self;
    }
};

/// Module-level gateway pointer for use in session callbacks.
/// libwtf's session_callback doesn't pass user_context, so we need this.
var global_gateway: ?*QuicGateway = null;
