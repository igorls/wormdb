//! TCP server implementation

const std = @import("std");
const core = @import("../core/mod.zig");
const storage = @import("../storage/mod.zig");
const protocol = @import("../protocol/mod.zig");
const wire = protocol.wire;
const event = @import("../event/mod.zig");
const cluster_mod = @import("../cluster/mod.zig");
const procedures = @import("../procedures/mod.zig");
const executor = @import("executor.zig");

const Store = storage.Store;
const EventBus = event.EventBus;
const Command = core.types.Command;
const Response = core.types.Response;
const Cluster = cluster_mod.Cluster;
const vector_ops = @import("../procedures/vector_ops.zig");
const Metric = @import("../vector/metric.zig").Metric;

pub const ServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0",
    port: u16 = 6389,
    max_connections: usize = 1024,
    cluster: ?*Cluster = null,
    vector_registry: ?*@import("../vector/index.zig").NamespaceRegistry = null,
    /// Number of worker threads. 0 = auto (cpu_count * 2, capped at 64).
    worker_count: usize = 0,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    event_bus: *EventBus,
    cluster: ?*Cluster,
    config: ServerConfig,
    running: std.atomic.Value(bool),

    // Thread pool infrastructure
    conn_queue: ConnQueue,
    workers: []std.Thread,

    const CONN_QUEUE_CAP = 1024;

    /// Bounded queue for accepted connections awaiting worker pickup.
    const ConnQueue = struct {
        items: [CONN_QUEUE_CAP]core.compat.net.ServerCompat.Connection = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        mutex: core.compat.Mutex = .{},
        futex: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn push(self: *ConnQueue, conn: core.compat.net.ServerCompat.Connection) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count >= CONN_QUEUE_CAP) return false;
            self.items[self.tail] = conn;
            self.tail = (self.tail + 1) % CONN_QUEUE_CAP;
            self.count += 1;
            // Wake one worker
            _ = self.futex.fetchAdd(1, .release);
            core.compat.Futex.wake(&self.futex, 1);
            return true;
        }

        fn pop(self: *ConnQueue) ?core.compat.net.ServerCompat.Connection {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == 0) return null;
            const conn = self.items[self.head];
            self.head = (self.head + 1) % CONN_QUEUE_CAP;
            self.count -= 1;
            return conn;
        }
    };

    const TEXT_READ_BUF_SIZE = 16384;

    const ConnectionContext = struct {
        allocator: std.mem.Allocator,
        event_bus: *EventBus,
        stream: ?*core.compat.net.Stream,
        write_capture: ?*std.ArrayListUnmanaged(u8),
        write_mutex: core.compat.Mutex,
        subscriptions: std.StringHashMap(u64),
        binary_mode: bool,

        fn init(allocator: std.mem.Allocator, event_bus: *EventBus, stream: ?*core.compat.net.Stream) ConnectionContext {
            return .{
                .allocator = allocator,
                .event_bus = event_bus,
                .stream = stream,
                .write_capture = null,
                .write_mutex = .{},
                .subscriptions = std.StringHashMap(u64).init(allocator),
                .binary_mode = false,
            };
        }

        fn initWithCapture(
            allocator: std.mem.Allocator,
            event_bus: *EventBus,
            stream: ?*core.compat.net.Stream,
            write_capture: *std.ArrayListUnmanaged(u8),
        ) ConnectionContext {
            return .{
                .allocator = allocator,
                .event_bus = event_bus,
                .stream = stream,
                .write_capture = write_capture,
                .write_mutex = .{},
                .subscriptions = std.StringHashMap(u64).init(allocator),
                .binary_mode = false,
            };
        }

        fn deinit(self: *ConnectionContext) void {
            var iter = self.subscriptions.iterator();
            while (iter.next()) |entry| {
                const channel = entry.key_ptr.*;
                const sub_id = entry.value_ptr.*;
                self.event_bus.unsubscribe(channel, sub_id);
                self.allocator.free(channel);
            }
            self.subscriptions.deinit();
        }

        fn subscribe(self: *ConnectionContext, channel: []const u8) !void {
            if (self.subscriptions.contains(channel)) {
                return;
            }

            const channel_copy = try self.allocator.dupe(u8, channel);
            errdefer self.allocator.free(channel_copy);

            const sub_id = try self.event_bus.subscribe(channel_copy, ConnectionContext.writeEvent, @ptrCast(self));
            errdefer self.event_bus.unsubscribe(channel_copy, sub_id);

            try self.subscriptions.put(channel_copy, sub_id);
        }

        fn unsubscribe(self: *ConnectionContext, channel: []const u8) void {
            if (self.subscriptions.fetchRemove(channel)) |removed| {
                self.event_bus.unsubscribe(removed.key, removed.value);
                self.allocator.free(removed.key);
            }
        }

        fn writeAllLocked(self: *ConnectionContext, data: []const u8) void {
            self.write_mutex.lock();
            defer self.write_mutex.unlock();

            if (self.write_capture) |capture| {
                capture.appendSlice(self.allocator, data) catch {};
            }

            if (self.stream) |stream| {
                stream.writeAll(data) catch {};
            }
        }

        fn writeEvent(ctx: *anyopaque, data: []const u8) void {
            const self: *ConnectionContext = @ptrCast(@alignCast(ctx));

            if (self.binary_mode) {
                const parsed = parseTextEventPayload(data) orelse return;

                self.write_mutex.lock();
                defer self.write_mutex.unlock();

                if (self.write_capture) |capture| {
                    capture.appendSlice(self.allocator, data) catch {};
                }

                if (self.stream) |stream| {
                    wire.writeResponse(stream, .{ .event = .{
                        .channel = parsed.channel,
                        .message = parsed.message,
                    } }) catch {};
                }
                return;
            }

            self.writeAllLocked(data);
        }

        const ParsedTextEvent = struct {
            channel: []const u8,
            message: []const u8,
        };

        fn parseTextEventPayload(data: []const u8) ?ParsedTextEvent {
            const prefix = ">EVENT ";
            if (!std.mem.startsWith(u8, data, prefix)) return null;

            const channel_start = prefix.len;
            const channel_end_rel = std.mem.indexOf(u8, data[channel_start..], "\r\n") orelse return null;
            const channel_end = channel_start + channel_end_rel;

            const message_start = channel_end + 2;
            if (message_start > data.len) return null;

            if (data.len < message_start + 2) return null;
            if (!std.mem.endsWith(u8, data, "\r\n")) return null;

            const message_end = data.len - 2;
            if (message_end < message_start) return null;

            return .{
                .channel = data[channel_start..channel_end],
                .message = data[message_start..message_end],
            };
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        event_bus: *EventBus,
        config: ServerConfig,
    ) Server {
        return .{
            .allocator = allocator,
            .store = store,
            .event_bus = event_bus,
            .cluster = config.cluster,
            .config = config,
            .running = std.atomic.Value(bool).init(false),
            .conn_queue = .{},
            .workers = &.{},
        };
    }

    pub fn run(self: *Server) !void {
        self.running.store(true, .release);

        const addr = try core.compat.net.Address.parseIp(self.config.bind_address, self.config.port);
        var listener = try addr.listen(.{ .reuse_address = true });
        defer listener.deinit();

        // Start worker pool
        const cpu_count = std.Thread.getCpuCount() catch 4;
        const num_workers = if (self.config.worker_count > 0)
            self.config.worker_count
        else
            @min(cpu_count * 2, 64);

        self.workers = try self.allocator.alloc(std.Thread, num_workers);
        for (self.workers) |*w| {
            w.* = try std.Thread.spawn(.{}, workerLoop, .{self});
        }

        std.log.info("WormDB listening on {s}:{d} ({d} workers)", .{ self.config.bind_address, self.config.port, num_workers });

        while (self.running.load(.acquire)) {
            const conn = listener.accept() catch |err| {
                std.log.err("Accept error: {}", .{err});
                continue;
            };

            if (!self.conn_queue.push(conn)) {
                // Queue full — reject connection
                std.log.warn("Connection queue full, rejecting", .{});
                conn.stream.close();
            }
        }

        // Shutdown: wake all workers so they exit
        for (self.workers) |*w| {
            _ = self.conn_queue.futex.fetchAdd(1, .release);
            core.compat.Futex.wake(&self.conn_queue.futex, 1);
            w.join();
        }
        self.allocator.free(self.workers);
        self.workers = &.{};
    }

    fn workerLoop(self: *Server) void {
        while (self.running.load(.acquire)) {
            if (self.conn_queue.pop()) |conn| {
                self.handleConnection(conn);
            } else {
                // Wait for new connections
                core.compat.Futex.timedWait(&self.conn_queue.futex, self.conn_queue.futex.load(.acquire), 10_000_000);
            }
        }
        // Drain remaining connections on shutdown
        while (self.conn_queue.pop()) |conn| {
            self.handleConnection(conn);
        }
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }

    fn handleConnection(self: *Server, conn: core.compat.net.ServerCompat.Connection) void {
        var stream = conn.stream;

        // Disable Nagle's algorithm — critical for low-latency request/response.
        // Without this, small response packets get buffered for up to 40ms.
        const fd = stream.getHandle();
        std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        var conn_ctx = ConnectionContext.init(self.allocator, self.event_bus, &stream);
        defer conn_ctx.deinit();
        defer conn.stream.close();

        var handshake: [2]u8 = undefined;
        var handshake_read: usize = 0;
        while (handshake_read < handshake.len) {
            const n = stream.read(handshake[handshake_read..]) catch |err| {
                std.log.debug("Handshake read error: {}", .{err});
                return;
            };
            if (n == 0) return;
            handshake_read += n;
        }

        if (std.mem.eql(u8, &handshake, &wire.WIRE_MAGIC)) {
            conn_ctx.binary_mode = true;
            self.handleBinaryConnection(&stream, &conn_ctx);
            return;
        }

        // Replication connections: same binary protocol but skip re-replication (anti-echo)
        if (std.mem.eql(u8, &handshake, &wire.REPL_MAGIC)) {
            conn_ctx.binary_mode = true;
            self.handleReplicationConnection(&stream);
            return;
        }

        conn_ctx.writeAllLocked("-ERR binary protocol required\r\n");
    }

    fn handleBinaryConnection(self: *Server, stream: *core.compat.net.Stream, conn_ctx: *ConnectionContext) void {
        const ReadAdapter = struct {
            stream: *core.compat.net.Stream,

            pub fn read(adapter: *@This(), dest: []u8) !usize {
                return adapter.stream.read(dest);
            }
        };

        var reader = ReadAdapter{ .stream = stream };
        // Buffered write adapter: coalesces small writes (frame header + length
        // prefix + data) into a single sendmsg syscall per response.
        const WriteAdapter = struct {
            s: *core.compat.net.Stream,
            buf: [4096]u8 = undefined,
            end: usize = 0,

            pub fn writeAll(wa: *@This(), data: []const u8) !void {
                var remaining = data;
                while (remaining.len > 0) {
                    const space = wa.buf.len - wa.end;
                    if (remaining.len >= space) {
                        @memcpy(wa.buf[wa.end..][0..space], remaining[0..space]);
                        wa.end = wa.buf.len;
                        try wa.flush();
                        remaining = remaining[space..];
                    } else {
                        @memcpy(wa.buf[wa.end..][0..remaining.len], remaining);
                        wa.end += remaining.len;
                        break;
                    }
                }
            }

            pub fn flush(wa: *@This()) !void {
                if (wa.end > 0) {
                    try wa.s.writeAll(wa.buf[0..wa.end]);
                    wa.end = 0;
                }
            }
        };

        var w = WriteAdapter{ .s = stream };

        // Per-command arena: avoids per-field malloc/free pairs.
        // Reset after each command instead of O(n) individual frees.
        var cmd_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer cmd_arena.deinit();

        while (true) {
            // Reset arena for this command cycle (key/value/args)
            _ = cmd_arena.reset(.retain_capacity);
            const arena_alloc = cmd_arena.allocator();

            const cmd = wire.readFrameZeroCopy(&reader, arena_alloc) catch |err| {
                switch (err) {
                    error.EndOfStream => return,
                    error.PayloadTooLarge => {
                        wire.writeResponse(&w, .{ .err = "request too large" }) catch {};
                        w.flush() catch {};
                        return;
                    },
                    else => {
                        wire.writeResponse(&w, .{ .err = "malformed frame" }) catch {};
                        w.flush() catch {};
                        return;
                    },
                }
            };
            // No need for deinitCommand — arena reset handles cleanup

            const response = self.executeForConnectionWithAlloc(cmd, conn_ctx, arena_alloc) catch |err| {
                const err_msg: []const u8 = switch (err) {
                    error.WormViolation => "WORM violation",
                    error.OutOfMemory => "out of memory",
                    error.IoError => "I/O error",
                    error.KeyNotFound => "key not found",
                    error.Corruption => "data corruption",
                };
                wire.writeResponse(&w, .{ .err = err_msg }) catch {};
                w.flush() catch {};
                continue;
            };
            // No defer deinitResponse needed — arena reset handles cleanup

            wire.writeResponse(&w, response) catch return;
            w.flush() catch return;
        }
    }

    /// Handle a replication connection from another WormDB node.
    /// Applies SET/DEL directly to the store without re-replicating (anti-echo).
    /// Emits local PUB/SUB events for replicated writes so local subscribers
    /// (e.g. WebSocket-connected clients) get real-time notifications.
    fn handleReplicationConnection(self: *Server, stream: *core.compat.net.Stream) void {
        const ReadAdapter = struct {
            stream: *core.compat.net.Stream,

            pub fn read(adapter: *@This(), dest: []u8) !usize {
                return adapter.stream.read(dest);
            }
        };

        var reader = ReadAdapter{ .stream = stream };

        while (true) {
            const cmd = wire.readFrameAlloc(&reader, self.allocator) catch return;
            defer protocol.deinitCommand(self.allocator, cmd);

            switch (cmd) {
                .set => |params| {
                    self.store.set(params.key, params.value, params.worm) catch {};
                    // No replication — this IS the replication

                    // Emit local PUB/SUB event for note changes so browser clients
                    // connected to this node get real-time updates via WebSocket.
                    if (std.mem.startsWith(u8, params.key, "note:") and
                        !std.mem.eql(u8, params.key, "notes:index"))
                    {
                        // Extract note id (strip "note:" prefix)
                        const note_id = params.key["note:".len..];
                        // Decode the note JSON from base64 to extract title/author
                        const decoded = std.base64.standard.Decoder.calcSizeForSlice(params.value) catch null;
                        if (decoded) |decoded_len| {
                            const buf = self.allocator.alloc(u8, decoded_len) catch null;
                            if (buf) |json_buf| {
                                defer self.allocator.free(json_buf);
                                if (std.base64.standard.Decoder.decode(json_buf, params.value)) |_| {
                                    // Parse title and author from note JSON
                                    const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_buf, .{}) catch null;
                                    var title: []const u8 = "Untitled";
                                    var author: []const u8 = "peer";
                                    if (parsed) |p| {
                                        defer p.deinit();
                                        if (p.value.object.get("title")) |t| {
                                            if (t == .string) title = t.string;
                                        }
                                        if (p.value.object.get("author")) |a| {
                                            if (a == .string) author = a.string;
                                        }
                                        // Build PUB event inside this block while parsed strings are alive
                                        const event_msg = std.fmt.allocPrint(
                                            self.allocator,
                                            "{{\"type\":\"note:updated\",\"id\":\"{s}\",\"author\":\"{s}\",\"title\":\"{s}\"}}",
                                            .{ note_id, author, title },
                                        ) catch null;
                                        if (event_msg) |msg| {
                                            defer self.allocator.free(msg);
                                            self.event_bus.publish("notes", msg) catch {};
                                        }
                                    }
                                } else |_| {}
                            }
                        }
                    }

                    wire.writeResponse(stream, .ok) catch return;
                },
                .delete => |key| {
                    self.store.delete(key) catch {};

                    // Emit local PUB/SUB event for note deletions
                    if (std.mem.startsWith(u8, key, "note:") and
                        !std.mem.eql(u8, key, "notes:index"))
                    {
                        const note_id = key["note:".len..];
                        const event_msg = std.fmt.allocPrint(
                            self.allocator,
                            "{{\"type\":\"note:deleted\",\"id\":\"{s}\"}}",
                            .{note_id},
                        ) catch null;
                        if (event_msg) |msg| {
                            defer self.allocator.free(msg);
                            self.event_bus.publish("notes", msg) catch {};
                        }
                    }

                    wire.writeResponse(stream, .ok) catch return;
                },
                .vinsert => |params| {
                    const metric_enum = Metric.fromStr(params.metric) orelse {
                        wire.writeResponse(stream, .{ .err = "vinsert: unknown metric" }) catch return;
                        continue;
                    };
                    vector_ops.applyVinsert(
                        self.store,
                        null, // don't re-replicate — this IS the replication
                        self.event_bus,
                        self.config.vector_registry,
                        self.allocator,
                        .{
                            .key = params.key,
                            .vector = params.vector,
                            .worm = params.worm,
                            .namespace = params.namespace,
                            .metric = metric_enum,
                            .timestamp = params.timestamp,
                            .replicate = false, // anti-echo boundary
                            .is_async = params.is_async,
                        },
                    ) catch |e| {
                        std.log.warn("replication: applyVinsert failed: {s}", .{@errorName(e)});
                    };
                    wire.writeResponse(stream, .ok) catch return;
                },
                .vdelete => |params| {
                    vector_ops.applyVdelete(
                        self.store,
                        null,
                        self.event_bus,
                        self.config.vector_registry,
                        self.allocator,
                        params.key,
                        params.namespace,
                        false,
                    ) catch |e| {
                        std.log.warn("replication: applyVdelete failed: {s}", .{@errorName(e)});
                    };
                    wire.writeResponse(stream, .ok) catch return;
                },
                .vbulkinsert => |params| {
                    const metric_enum = Metric.fromStr(params.metric) orelse {
                        wire.writeResponse(stream, .{ .err = "vbulkinsert: unknown metric" }) catch return;
                        continue;
                    };
                    vector_ops.applyVbulkinsert(
                        self.store,
                        null, // don't re-replicate
                        self.event_bus,
                        self.config.vector_registry,
                        self.allocator,
                        params.namespace,
                        metric_enum,
                        params.worm,
                        params.is_async,
                        params.items,
                        false, // anti-echo boundary
                    ) catch |e| {
                        std.log.warn("replication: applyVbulkinsert failed: {s}", .{@errorName(e)});
                    };
                    wire.writeResponse(stream, .ok) catch return;
                },
                else => {
                    wire.writeResponse(stream, .{ .err = "unsupported replication command" }) catch return;
                },
            }
        }
    }

    fn handleTextConnection(self: *Server, stream: *core.compat.net.Stream, conn_ctx: *ConnectionContext, initial: [2]u8) void {
        var read_buf: [TEXT_READ_BUF_SIZE]u8 = undefined;
        read_buf[0] = initial[0];
        read_buf[1] = initial[1];

        var buffered_len: usize = 2;
        var discarding_oversized_line = false;

        // Process any complete line already in the handshake-prefixed buffer.
        self.processReadBuffer(conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, 0);

        while (true) {
            if (buffered_len == read_buf.len and !discarding_oversized_line) {
                buffered_len = 0;
                discarding_oversized_line = true;
                conn_ctx.writeAllLocked("-ERR request too large\r\n");
            }

            const bytes_read = stream.read(read_buf[buffered_len..]) catch |err| {
                std.log.debug("Read error: {}", .{err});
                return;
            };
            if (bytes_read == 0) return;

            self.processReadBuffer(conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, bytes_read);
        }
    }

    fn processReadBuffer(
        self: *Server,
        conn_ctx: *ConnectionContext,
        read_buf: *[TEXT_READ_BUF_SIZE]u8,
        buffered_len: *usize,
        discarding_oversized_line: *bool,
        bytes_read: usize,
    ) void {
        const end = buffered_len.* + bytes_read;

        var start: usize = 0;
        if (discarding_oversized_line.*) {
            for (read_buf[0..end], 0..) |c, i| {
                if (c == '\n') {
                    discarding_oversized_line.* = false;
                    start = i + 1;
                    break;
                }
            }

            if (discarding_oversized_line.*) {
                buffered_len.* = 0;
                return;
            }
        }

        for (read_buf[0..end], 0..) |c, i| {
            if (i < start) continue;

            if (c == '\n') {
                const line = read_buf[start..i];
                const trimmed = std.mem.trim(u8, line, "\r\n");
                if (trimmed.len > 0) {
                    self.processLine(trimmed, conn_ctx) catch {};
                }
                start = i + 1;
            }
        }

        if (start < end) {
            const remaining = end - start;
            std.mem.copyForwards(u8, read_buf[0..remaining], read_buf[start..end]);
            buffered_len.* = remaining;
        } else {
            buffered_len.* = 0;
        }

        if (buffered_len.* == read_buf.len) {
            buffered_len.* = 0;
            discarding_oversized_line.* = true;
            conn_ctx.writeAllLocked("-ERR request too large\r\n");
        }
    }

    fn processLine(self: *Server, line: []const u8, conn_ctx: *ConnectionContext) !void {
        const cmd = protocol.parseCommand(self.allocator, line) catch |err| {
            var buf: [256]u8 = undefined;
            const err_msg = switch (err) {
                error.MalformedCommand => "malformed command",
                error.InvalidArgs => "invalid arguments",
                error.UnknownCommand => "unknown command",
                error.OutOfMemory => "out of memory",
                error.TooLarge => "request too large",
            };
            const msg = std.fmt.bufPrint(&buf, "-ERR {s}\r\n", .{err_msg}) catch "-ERR internal\r\n";
            conn_ctx.writeAllLocked(msg);
            return;
        };
        defer protocol.deinitCommand(self.allocator, cmd);

        switch (cmd) {
            .subscribe => |channel| {
                conn_ctx.subscribe(channel) catch {
                    conn_ctx.writeAllLocked("-ERR out of memory\r\n");
                    return;
                };
                conn_ctx.writeAllLocked("+OK\r\n");
                return;
            },
            .unsubscribe => |channel| {
                conn_ctx.unsubscribe(channel);
                conn_ctx.writeAllLocked("+OK\r\n");
                return;
            },
            else => {},
        }

        const response = self.executeForConnection(cmd, conn_ctx) catch |err| {
            var buf: [256]u8 = undefined;
            const err_msg = switch (err) {
                error.WormViolation => "WORM violation",
                error.OutOfMemory => "out of memory",
                error.IoError => "I/O error",
                error.KeyNotFound => "key not found",
                error.Corruption => "data corruption",
            };
            const msg = std.fmt.bufPrint(&buf, "-ERR {s}\r\n", .{err_msg}) catch "-ERR internal\r\n";
            conn_ctx.writeAllLocked(msg);
            return;
        };
        defer protocol.deinitResponse(self.allocator, response);

        var resp_buf: [4096]u8 = undefined;
        const resp_str = switch (response) {
            .value => |val| if (val) |v|
                std.fmt.bufPrint(&resp_buf, "${d}\r\n{s}\r\n", .{ v.len, v }) catch "$-1\r\n"
            else
                "$-1\r\n",
            .ok => "+OK\r\n",
            .err => |msg| std.fmt.bufPrint(&resp_buf, "-ERR {s}\r\n", .{msg}) catch "-ERR internal\r\n",
            .event => |evt| std.fmt.bufPrint(&resp_buf, ">EVENT {s}\r\n{s}\r\n", .{ evt.channel, evt.message }) catch ">EVENT error\r\n",
        };

        conn_ctx.writeAllLocked(resp_str);
    }

    fn executeForConnection(self: *Server, cmd: Command, conn_ctx: *ConnectionContext) !Response {
        return self.executeForConnectionWithAlloc(cmd, conn_ctx, self.allocator);
    }

    fn executeForConnectionWithAlloc(self: *Server, cmd: Command, conn_ctx: *ConnectionContext, alloc: std.mem.Allocator) !Response {
        return switch (cmd) {
            .subscribe => |channel| blk: {
                try conn_ctx.subscribe(channel);
                break :blk .ok;
            },
            .unsubscribe => |channel| blk: {
                conn_ctx.unsubscribe(channel);
                break :blk .ok;
            },
            else => try executor.execute(.{
                .allocator = alloc,
                .store = self.store,
                .event_bus = self.event_bus,
                .cluster = self.cluster,
                .vector_registry = self.config.vector_registry,
            }, cmd),
        };
    }
};

test "Server SUB/UNSUB command wiring updates subscriber count" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_server_sub_unsub.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_server_sub_unsub.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_server_sub_unsub.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});

    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    try server.processLine("SUB updates", &conn_ctx);
    try testing.expectEqual(@as(u64, 1), bus.subscriberCount());

    try server.processLine("SUB updates", &conn_ctx);
    try testing.expectEqual(@as(u64, 1), bus.subscriberCount());

    try server.processLine("UNSUB updates", &conn_ctx);
    try testing.expectEqual(@as(u64, 0), bus.subscriberCount());
}

test "Server connection cleanup auto-unsubscribes remaining subscriptions" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_server_conn_cleanup.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_server_conn_cleanup.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_server_conn_cleanup.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});

    {
        var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
        defer conn_ctx.deinit();

        try server.processLine("SUB alpha", &conn_ctx);
        try server.processLine("SUB beta", &conn_ctx);
        try testing.expectEqual(@as(u64, 2), bus.subscriberCount());
    }

    try testing.expectEqual(@as(u64, 0), bus.subscriberCount());
}

fn feedReadChunk(
    server: *Server,
    conn_ctx: *Server.ConnectionContext,
    read_buf: *[Server.TEXT_READ_BUF_SIZE]u8,
    buffered_len: *usize,
    discarding_oversized_line: *bool,
    chunk: []const u8,
) !void {
    const testing = std.testing;
    try testing.expect(chunk.len <= read_buf.len - buffered_len.*);

    const dest = read_buf[buffered_len.* .. buffered_len.* + chunk.len];
    std.mem.copyForwards(u8, dest, chunk);
    server.processReadBuffer(conn_ctx, read_buf, buffered_len, discarding_oversized_line, chunk.len);
}

test "TCP framing handles partial command split across reads" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_partial_reads.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_partial_reads.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_partial_reads.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});
    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    var read_buf: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    var buffered_len: usize = 0;
    var discarding_oversized_line = false;

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "SET alpha va");
    try testing.expectEqual(@as(usize, "SET alpha va".len), buffered_len);
    try testing.expect(store.get("alpha") == null);

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "lue\n");
    try testing.expectEqual(@as(usize, 0), buffered_len);

    const entry = store.get("alpha") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("value", entry.value);
}

test "TCP framing handles multiple commands in one read" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_multi_commands.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_multi_commands.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_multi_commands.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});
    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    var read_buf: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    var buffered_len: usize = 0;
    var discarding_oversized_line = false;

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "SET k1 v1\nSET k2 v2\n");
    try testing.expectEqual(@as(usize, 0), buffered_len);

    const e1 = store.get("k1") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("v1", e1.value);

    const e2 = store.get("k2") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("v2", e2.value);
}

test "TCP framing preserves buffered tail across mixed full and partial reads" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_mixed_reads.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_mixed_reads.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_mixed_reads.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});
    var conn_ctx = Server.ConnectionContext.init(testing.allocator, &bus, null);
    defer conn_ctx.deinit();

    var read_buf: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    var buffered_len: usize = 0;
    var discarding_oversized_line = false;

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "SET k3 v3\nSET k4 ");

    const e3 = store.get("k3") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("v3", e3.value);
    try testing.expectEqual(@as(usize, "SET k4 ".len), buffered_len);
    try testing.expectEqualStrings("SET k4 ", read_buf[0..buffered_len]);
    try testing.expect(store.get("k4") == null);

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "v4\n");
    try testing.expectEqual(@as(usize, 0), buffered_len);

    const e4 = store.get("k4") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("v4", e4.value);
}

test "TCP framing rejects oversized line and recovers for next valid command" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_oversized_line.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);

    const wal_file = try core.compat.Dir.createFile(tmp_dir.dir, "test_tcp_oversized_line.wal", .{});
    core.compat.File.close(wal_file);

    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_tcp_oversized_line.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    var store = try Store.init(testing.allocator, .{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
    });
    defer store.deinit();

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var server = Server.init(testing.allocator, &store, &bus, .{});

    var writes: std.ArrayListUnmanaged(u8) = .empty;
    defer writes.deinit(testing.allocator);

    var conn_ctx = Server.ConnectionContext.initWithCapture(testing.allocator, &bus, null, &writes);
    defer conn_ctx.deinit();

    var read_buf: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    var buffered_len: usize = 0;
    var discarding_oversized_line = false;

    var oversized: [Server.TEXT_READ_BUF_SIZE]u8 = undefined;
    @memset(&oversized, 'x');

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, oversized[0..]);
    try testing.expectEqual(@as(usize, 0), buffered_len);
    try testing.expect(discarding_oversized_line);
    try testing.expect(std.mem.indexOf(u8, writes.items, "-ERR request too large\r\n") != null);

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "tail-without-newline");
    try testing.expectEqual(@as(usize, 0), buffered_len);
    try testing.expect(discarding_oversized_line);
    try testing.expect(store.get("ok") == null);

    try feedReadChunk(&server, &conn_ctx, &read_buf, &buffered_len, &discarding_oversized_line, "\nSET ok value\n");
    try testing.expectEqual(@as(usize, 0), buffered_len);
    try testing.expect(!discarding_oversized_line);

    const ok_entry = store.get("ok") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("value", ok_entry.value);
}
