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
const domain = @import("../procedures/domain.zig");

/// Domain HTTP routes, registered at startup by the composition root from the domain manifests
/// (each domain package contributes its routes). Read-only during serving; the gateway holds no
/// domain URLs of its own.
var domain_routes: []const domain.Route = &.{};

/// Register the composed domains' HTTP routes. Call once at startup, before serving.
pub fn registerRoutes(routes: []const domain.Route) void {
    domain_routes = routes;
}

/// Domain WebSocket JSON-RPC methods, registered at startup from the manifests. The gateway owns the
/// WS framing + the executor; the cc32d9 dialect (method names, param shapes, row JSON) lives in the
/// domains. Read-only during serving.
var domain_ws_methods: []const domain.WsMethod = &.{};

/// Register the composed domains' WS JSON-RPC methods. Call once at startup, before serving.
pub fn registerWsMethods(methods: []const domain.WsMethod) void {
    domain_ws_methods = methods;
}

const auth = @import("auth.zig");
const AuthMintConfig = @import("../procedures/context.zig").AuthMintConfig;

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
    /// Ed25519 public keys for SCT verification. Empty means AUTH cannot succeed; it does NOT
    /// disable auth — commands are still rejected when `auth_required` is true (fail closed).
    public_keys: []const auth.PublicKey,
    /// Maximum token lifetime in seconds (0 = no limit).
    max_token_age: u64,
    /// Whether this listener enforces auth (= `cfg.auth.require_auth && cfg.gateway.auth_enabled`).
    /// True ⇒ executor rejects unauthenticated protected commands; false ⇒ listener opted out.
    auth_required: bool,
    /// Optional server-side SCT minting config.
    auth_mint: ?AuthMintConfig,

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
            .auth_mint = null,
        };
    }

    /// Run the gateway on a dedicated thread. Call from main after server start.
    pub fn start(self: *Gateway) !std.Thread {
        return try std.Thread.spawn(.{}, runLoop, .{self});
    }

    fn runLoop(self: *Gateway) void {
        self.running.store(true, .release);

        const addr = core.compat.net.Address.parseIp("0.0.0.0", self.port) catch |err| {
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

    fn handleConnection(self: *Gateway, conn: core.compat.net.ServerCompat.Connection) void {
        var stream = conn.stream;
        defer stream.close();

        // Disable Nagle for low-latency request/response
        core.compat.setNoDelay(stream.getHandle());

        // Step 1: WebSocket handshake
        var request_buf: [4096]u8 = undefined;
        const request = readHttpRequest(&stream, &request_buf) orelse return;

        const ws_key = extractWebSocketKey(request) orelse {
            // Not a WebSocket upgrade — serve the plain-HTTP Light-API drop-in (GET /api/...),
            // so HTTP clients consume the same contract as cc32d9 / Hyperion with no app tier.
            self.serveHttp(&stream, &request_buf, request);
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
                0x01 => {
                    // Text frame — the cc32d9 Light-API WebSocket dialect (JSON-RPC 2.0). Reuses the
                    // same store/segment; streams notifications back as text frames.
                    _ = cmd_arena.reset(.retain_capacity);
                    self.handleJsonRpc(&stream, cmd_arena.allocator(), ws_frame.payload);
                    continue;
                },
                else => {
                    // Other opcodes — reject
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
            const cmd_id = core.compat.intToEnum(core.types.CommandId, cmd_id_raw) catch {
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
                .subscribe => |params| blk: {
                    // Check capability for subscribe
                    if (self.auth_required) {
                        if (auth_state) |*state| {
                            if (!state.permits(.subscribe, params.channel)) {
                                break :blk Response{ .err = "permission denied" };
                            }
                        } else {
                            break :blk Response{ .err = "auth required" };
                        }
                    }
                    conn_ctx.subscribe(params.channel, params.filter) catch |err| {
                        break :blk Response{ .err = switch (err) {
                            error.InvalidPredicate => "invalid filter",
                            else => "subscription failed",
                        } };
                    };
                    break :blk Response.ok;
                },
                .unsubscribe => |channel| blk: {
                    conn_ctx.unsubscribe(channel);
                    break :blk Response.ok;
                },
                else => blk: {
                    // Authorization is enforced once, in executor.execute (the unified
                    // chokepoint). This listener only supplies the decision: enforce with the
                    // connection's token when auth is on for this listener, else .disabled.
                    break :blk executor.execute(.{
                        .allocator = arena_alloc,
                        .store = self.store,
                        .event_bus = self.event_bus,
                        .cluster = self.cluster,
                        .auth = if (self.auth_required)
                            .{ .enforce = if (auth_state) |*s| s else null }
                        else
                            .disabled,
                        .auth_mint = self.auth_mint,
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
            sendWireResponseFrame(&stream, self.allocator, resp) catch return;
        }
    }

    // --- Plain HTTP (Light-API drop-in) ---
    //
    // Answers `GET /api/...` directly over HTTP/1.1 by routing to an EXEC procedure and returning its
    // JSON value — the SAME executor pipeline as WormWire/WS clients, no application tier. Keep-alive
    // loop so HTTP clients (and reverse proxies) get connection reuse. The DB *is* the API server.

    fn serveHttp(self: *Gateway, stream: *core.compat.net.Stream, request_buf: *[4096]u8, first: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var current = first;
        while (self.running.load(.acquire)) {
            _ = arena.reset(.retain_capacity);
            if (!self.handleHttpRequest(stream, arena.allocator(), current)) return;
            current = readHttpRequest(stream, request_buf) orelse return;
        }
    }

    /// Handle one HTTP request. Returns true to keep the connection alive.
    fn handleHttpRequest(self: *Gateway, stream: *core.compat.net.Stream, alloc: std.mem.Allocator, request: []const u8) bool {
        const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return false;
        const line = request[0..line_end];
        if (!std.mem.startsWith(u8, line, "GET ")) {
            return writeHttp(stream, 405, "text/plain", "method not allowed");
        }
        const after = line[4..];
        const sp = std.mem.indexOfScalar(u8, after, ' ') orelse return false;
        var path = after[0..sp];
        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, path, '?')) |q| {
            query = path[q + 1 ..]; // AtomicAssets endpoints take filter/sort/page params here
            path = path[0..q];
        }

        if (self.route(alloc, path, query)) |r| {
            return writeHttp(stream, r.status, r.content_type, r.body);
        }
        return writeHttp(stream, 404, "text/plain", "not found");
    }

    const RouteResult = struct {
        body: []const u8,
        content_type: []const u8,
        status: u16 = 200,
    };

    /// Match the request path against the registered domain routes (manifest-contributed). The first
    /// route whose `prefix` segments match wins; its builder maps the remaining path segments + query
    /// to an EXEC call. No domain URLs are hard-coded here — they live in each domain package's manifest.
    fn route(self: *Gateway, alloc: std.mem.Allocator, path: []const u8, query: []const u8) ?RouteResult {
        var segbuf: [16][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |s| {
            if (n >= segbuf.len) return null;
            segbuf[n] = s;
            n += 1;
        }
        const segs = segbuf[0..n];

        for (domain_routes) |r| {
            if (r.prefix.len > segs.len) continue;
            if (!segPrefixEql(r.prefix, segs[0..r.prefix.len])) continue;
            const caps = domain.Captures{ .segs = segs[r.prefix.len..], .query = query };
            const call = r.build(alloc, &caps) orelse return null;
            const body = self.execProc(alloc, call.proc, call.args) orelse return null;
            const status = if (call.status_from_body) |f| f(body) else call.status;
            return .{
                .body = body,
                .content_type = call.content_type orelse "application/json",
                .status = status,
            };
        }
        return null;
    }

    fn segPrefixEql(prefix: []const []const u8, segs: []const []const u8) bool {
        for (prefix, segs) |pseg, s| {
            if (!std.mem.eql(u8, pseg, s)) return false;
        }
        return true;
    }

    /// Run a procedure through the shared executor; return its `value` payload (or null on error).
    /// HTTP-GET and JSON-RPC EXEC reach here with no per-connection token (Phase 1), so when this
    /// listener enforces auth the call passes `.enforce(null)` and the executor rejects it
    /// (fail-closed). Disable auth on the WS listener to expose a public read-only HTTP/JSON-RPC API.
    fn execProc(self: *Gateway, alloc: std.mem.Allocator, proc: []const u8, args: []const []const u8) ?[]const u8 {
        const resp = executor.execute(.{
            .allocator = alloc,
            .store = self.store,
            .event_bus = self.event_bus,
            .cluster = self.cluster,
            .auth = if (self.auth_required) .{ .enforce = null } else .disabled,
            .auth_mint = self.auth_mint,
        }, .{ .exec = .{ .procedure = proc, .args = args } }) catch return null;
        return switch (resp) {
            .value => |v| v orelse "null",
            else => null,
        };
    }

    fn writeHttp(stream: *core.compat.net.Stream, status: u16, content_type: []const u8, body: []const u8) bool {
        const reason: []const u8 = switch (status) {
            200 => "OK",
            404 => "Not Found",
            405 => "Method Not Allowed",
            503 => "Service Unavailable",
            else => "OK",
        };
        var hdr: [256]u8 = undefined;
        const h = std.fmt.bufPrint(
            &hdr,
            "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n",
            .{ status, reason, content_type, body.len },
        ) catch return false;
        stream.writeAll(h) catch return false;
        stream.writeAll(body) catch return false;
        return true;
    }

    // --- cc32d9 WebSocket JSON-RPC API (jsonrpc2-ws dialect) ---
    //
    // A text WS frame carries a JSON-RPC 2.0 request {method, params:{reqid, …}}. We stream results
    // back as `reqdata` notifications — one per row `{method, reqid, data}` — terminated by
    // `{method, reqid, end:true, status:200, error:null}`. Mirrors cc32d9's wsapi/lightapi_wsapi.js.

    // Per-WS-request state the trampolines below dereference — the gateway side of the WsCtx vtable.
    const WsImpl = struct {
        gw: *Gateway,
        stream: *core.compat.net.Stream,
        a: std.mem.Allocator,
        method: []const u8,
        reqid: []const u8,
    };
    fn wsEmitTramp(impl: *anyopaque, data_json: []const u8) void {
        const w: *WsImpl = @ptrCast(@alignCast(impl));
        w.gw.wsData(w.stream, w.a, w.method, w.reqid, data_json);
    }
    fn wsEndTramp(impl: *anyopaque) void {
        const w: *WsImpl = @ptrCast(@alignCast(impl));
        w.gw.wsEnd(w.stream, w.a, w.method, w.reqid);
    }
    fn wsErrTramp(impl: *anyopaque, msg: []const u8) void {
        const w: *WsImpl = @ptrCast(@alignCast(impl));
        w.gw.wsErr(w.stream, w.a, w.method, w.reqid, msg);
    }
    fn wsExecTramp(impl: *anyopaque, proc: []const u8, args: []const []const u8) ?[]const u8 {
        const w: *WsImpl = @ptrCast(@alignCast(impl));
        return w.gw.execProc(w.a, proc, args);
    }

    fn handleJsonRpc(self: *Gateway, stream: *core.compat.net.Stream, a: std.mem.Allocator, text: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;
        const method = root.get("method") orelse return;
        if (method != .string) return;
        const m = method.string;
        const params: ?std.json.ObjectMap = if (root.get("params")) |p| (if (p == .object) p.object else null) else null;

        var reqid_buf: [80]u8 = undefined;
        const reqid = reqidStr(params, &reqid_buf);

        // Dispatch to the registered domain WS method; the handler streams via the WsCtx vtable.
        for (domain_ws_methods) |wm| {
            if (std.mem.eql(u8, wm.name, m)) {
                var impl = WsImpl{ .gw = self, .stream = stream, .a = a, .method = m, .reqid = reqid };
                const ctx = domain.WsCtx{
                    .impl = &impl,
                    .allocator = a,
                    .params = params,
                    .emitFn = wsEmitTramp,
                    .endFn = wsEndTramp,
                    .errFn = wsErrTramp,
                    .execFn = wsExecTramp,
                };
                wm.handler(&ctx);
                return;
            }
        }
        self.wsErr(stream, a, m, reqid, "unknown method");
    }

    /// reqid re-emitted verbatim (number or JSON string); defaults to null.
    fn reqidStr(params: ?std.json.ObjectMap, buf: []u8) []const u8 {
        const p = params orelse return "null";
        const v = p.get("reqid") orelse return "null";
        return switch (v) {
            .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch "null",
            .string => |s| std.fmt.bufPrint(buf, "\"{s}\"", .{s}) catch "null",
            else => "null",
        };
    }

    fn wsData(_: *Gateway, stream: *core.compat.net.Stream, a: std.mem.Allocator, method: []const u8, reqid: []const u8, data_json: []const u8) void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"reqdata\",\"params\":{\"method\":\"") catch return;
        buf.appendSlice(a, method) catch return;
        buf.appendSlice(a, "\",\"reqid\":") catch return;
        buf.appendSlice(a, reqid) catch return;
        buf.appendSlice(a, ",\"data\":") catch return;
        buf.appendSlice(a, data_json) catch return;
        buf.appendSlice(a, "}}") catch return;
        sendWsFrame(stream, 0x01, buf.items) catch {};
    }

    fn wsEnd(_: *Gateway, stream: *core.compat.net.Stream, a: std.mem.Allocator, method: []const u8, reqid: []const u8) void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"reqdata\",\"params\":{\"method\":\"") catch return;
        buf.appendSlice(a, method) catch return;
        buf.appendSlice(a, "\",\"reqid\":") catch return;
        buf.appendSlice(a, reqid) catch return;
        buf.appendSlice(a, ",\"end\":true,\"status\":200,\"error\":null}}") catch return;
        sendWsFrame(stream, 0x01, buf.items) catch {};
    }

    fn wsErr(_: *Gateway, stream: *core.compat.net.Stream, a: std.mem.Allocator, method: []const u8, reqid: []const u8, msg: []const u8) void {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(a);
        buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"reqdata\",\"params\":{\"method\":\"") catch return;
        buf.appendSlice(a, method) catch return;
        buf.appendSlice(a, "\",\"reqid\":") catch return;
        buf.appendSlice(a, reqid) catch return;
        buf.appendSlice(a, ",\"end\":true,\"status\":500,\"error\":\"") catch return;
        buf.appendSlice(a, msg) catch return;
        buf.appendSlice(a, "\"}}") catch return;
        sendWsFrame(stream, 0x01, buf.items) catch {};
    }

    // --- WebSocket Protocol Implementation ---

    const WsFrame = struct {
        opcode: u4,
        payload: []const u8,
        allocated: bool, // true if payload was heap-allocated (needs free)
    };

    fn readWsFrame(stream: *core.compat.net.Stream, allocator: std.mem.Allocator) ?WsFrame {
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

    fn sendWsFrame(stream: *core.compat.net.Stream, opcode: u8, payload: []const u8) !void {
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

    const WireListWriter = struct {
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,

        pub fn writeAll(self: *WireListWriter, data: []const u8) !void {
            try self.list.appendSlice(self.allocator, data);
        }
    };

    fn encodeWireResponseAlloc(allocator: std.mem.Allocator, response: Response) ![]u8 {
        var encoded: std.ArrayListUnmanaged(u8) = .empty;
        errdefer encoded.deinit(allocator);

        var writer = WireListWriter{ .list = &encoded, .allocator = allocator };
        try wire.writeResponse(&writer, response);
        return try encoded.toOwnedSlice(allocator);
    }

    fn sendWireResponseFrame(stream: *core.compat.net.Stream, allocator: std.mem.Allocator, response: Response) !void {
        var resp_buf: [65536]u8 = undefined;
        var fbw = wire.FixedBufWriter.init(&resp_buf);
        wire.writeResponse(&fbw, response) catch |err| {
            if (err != error.NoSpaceLeft) return err;
            const encoded = try encodeWireResponseAlloc(allocator, response);
            defer allocator.free(encoded);
            try sendWsFrame(stream, 0x02, encoded);
            return;
        };
        try sendWsFrame(stream, 0x02, fbw.getWritten());
    }

    fn sendWsCloseWithCode(stream: *core.compat.net.Stream, code: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, code, .big);
        try sendWsFrame(stream, 0x08, &buf);
    }

    fn readExact(stream: *core.compat.net.Stream, dest: []u8) ?void {
        var offset: usize = 0;
        while (offset < dest.len) {
            const n = stream.read(dest[offset..]) catch return null;
            if (n == 0) return null;
            offset += n;
        }
    }

    // --- HTTP/WebSocket Handshake ---

    fn readHttpRequest(stream: *core.compat.net.Stream, buf: *[4096]u8) ?[]const u8 {
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
        stream: *core.compat.net.Stream,
        subscriptions: std.StringHashMap(u64),
        write_mutex: core.compat.Mutex,

        fn init(allocator: std.mem.Allocator, event_bus: *EventBus, stream: *core.compat.net.Stream) ConnContext {
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

        fn subscribe(self: *ConnContext, channel: []const u8, filter: ?[]const u8) !void {
            if (self.subscriptions.contains(channel)) return;

            const channel_copy = try self.allocator.dupe(u8, channel);
            errdefer self.allocator.free(channel_copy);

            const sub_id = try self.event_bus.subscribeFiltered(
                channel_copy,
                filter,
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

            self.write_mutex.lock();
            defer self.write_mutex.unlock();
            sendWireResponseFrame(self.stream, self.allocator, .{ .event = .{
                .channel = parsed.channel,
                .message = parsed.message,
            } }) catch {};
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

test "gateway allocator-backed response encoder handles payloads over 64 KiB" {
    const testing = std.testing;

    const payload = try testing.allocator.alloc(u8, 70 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 'x');

    const encoded = try Gateway.encodeWireResponseAlloc(testing.allocator, .{ .value = payload });
    defer testing.allocator.free(encoded);

    try testing.expectEqual(@as(usize, payload.len + 5), encoded.len);
    try testing.expectEqual(@as(u8, @intFromEnum(wire.ResponseCode.value)), encoded[0]);
    try testing.expectEqual(@as(u32, @intCast(payload.len)), std.mem.readInt(u32, encoded[1..5], .big));
    try testing.expectEqualSlices(u8, payload, encoded[5..]);
}
