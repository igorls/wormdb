//! Event bus for pub/sub streaming
//!
//! Supports channels with multiple subscribers.
//! Thread-safe with atomic operations for subscriber counts.
//!
//! Fanout contract (#84): `publish` never holds `channel.mutex` across
//! `write_fn` (socket I/O). Subscribers that may outlive the deliver window
//! must supply retain/release hooks so connection teardown cannot free
//! `ctx` while a publisher is still delivering.

const std = @import("std");
const core = @import("../core/mod.zig");
const compat = core.compat;
const predicate = core.predicate;

pub const WriteFn = *const fn (ctx: *anyopaque, data: []const u8) void;
pub const LifetimeFn = *const fn (ctx: *anyopaque) void;

pub const Subscriber = struct {
    id: u64,
    write_fn: WriteFn,
    ctx: *anyopaque,
    filter: ?predicate.Predicate = null,
    // Owned copy of the raw filter bytes. The parsed `filter` predicate stores
    // slices into this buffer (it does not copy field/literal strings), so the
    // buffer must outlive the predicate and is freed together with it. Without
    // this the predicate would dangle into the transient per-command buffer.
    filter_src: ?[]u8 = null,
    filter_allocator: ?std.mem.Allocator = null,
    /// Incremented under channel.mutex before unlock-for-deliver; pairs with release.
    retain_fn: ?LifetimeFn = null,
    /// Called after write_fn returns (or if snapshot assembly fails mid-way).
    release_fn: ?LifetimeFn = null,

    fn deinit(self: *Subscriber) void {
        if (self.filter) |*filter| filter.deinit();
        if (self.filter_src) |src| {
            if (self.filter_allocator) |a| a.free(src);
        }
    }
};

/// Optional lifetime hooks for connection-backed subscribers (gateway/TCP).
pub const LifetimeHooks = struct {
    retain_fn: ?LifetimeFn = null,
    release_fn: ?LifetimeFn = null,
};

const Delivery = struct {
    write_fn: WriteFn,
    ctx: *anyopaque,
    release_fn: ?LifetimeFn,
};

pub const Channel = struct {
    name: []const u8,
    subscribers: std.AutoHashMap(u64, Subscriber),
    mutex: compat.Mutex,
    next_sub_id: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Channel {
        return .{
            .name = name,
            .subscribers = std.AutoHashMap(u64, Subscriber).init(allocator),
            .mutex = .{},
            .next_sub_id = std.atomic.Value(u64).init(1),
        };
    }

    pub fn deinit(self: *Channel) void {
        var iter = self.subscribers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.subscribers.deinit();
    }
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    channels: std.StringHashMap(*Channel),
    mutex: compat.RwLock,
    stats: Stats,

    pub const Stats = struct {
        publish_count: std.atomic.Value(u64),
        subscriber_count: std.atomic.Value(u64),
        /// Events dropped because a subscriber's write path was busy (tryLock fail).
        drop_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .channels = std.StringHashMap(*Channel).init(allocator),
            .mutex = .{},
            .stats = .{
                .publish_count = std.atomic.Value(u64).init(0),
                .subscriber_count = std.atomic.Value(u64).init(0),
                .drop_count = std.atomic.Value(u64).init(0),
            },
        };
    }

    pub fn deinit(self: *EventBus) void {
        var iter = self.channels.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.channels.deinit();
    }

    pub fn subscribe(
        self: *EventBus,
        channel_name: []const u8,
        write_fn: WriteFn,
        ctx: *anyopaque,
    ) !u64 {
        return self.subscribeFiltered(channel_name, null, write_fn, ctx);
    }

    pub fn subscribeFiltered(
        self: *EventBus,
        channel_name: []const u8,
        filter_raw: ?[]const u8,
        write_fn: WriteFn,
        ctx: *anyopaque,
    ) !u64 {
        return self.subscribeFilteredHooks(channel_name, filter_raw, write_fn, ctx, .{});
    }

    pub fn subscribeFilteredHooks(
        self: *EventBus,
        channel_name: []const u8,
        filter_raw: ?[]const u8,
        write_fn: WriteFn,
        ctx: *anyopaque,
        hooks: LifetimeHooks,
    ) !u64 {
        // Own a copy of the raw filter bytes: the parsed predicate borrows
        // slices from it and the subscription outlives the caller's buffer.
        var filter_src: ?[]u8 = null;
        errdefer if (filter_src) |src| self.allocator.free(src);
        var parsed_filter: ?predicate.Predicate = null;
        errdefer if (parsed_filter) |*filter| filter.deinit();
        if (filter_raw) |raw| {
            const owned = try self.allocator.dupe(u8, raw);
            filter_src = owned;
            parsed_filter = try predicate.parse(self.allocator, owned);
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = try self.channels.getOrPut(channel_name);
        if (!gop.found_existing) {
            const name_copy = try self.allocator.dupe(u8, channel_name);
            const channel = try self.allocator.create(Channel);
            channel.* = Channel.init(self.allocator, name_copy);
            gop.key_ptr.* = name_copy;
            gop.value_ptr.* = channel;
        }

        const channel = gop.value_ptr.*;
        channel.mutex.lock();
        defer channel.mutex.unlock();

        const sub_id = channel.next_sub_id.fetchAdd(1, .monotonic);
        try channel.subscribers.put(sub_id, .{
            .id = sub_id,
            .write_fn = write_fn,
            .ctx = ctx,
            .filter = parsed_filter,
            .filter_src = filter_src,
            .filter_allocator = self.allocator,
            .retain_fn = hooks.retain_fn,
            .release_fn = hooks.release_fn,
        });
        parsed_filter = null;
        filter_src = null;

        _ = self.stats.subscriber_count.fetchAdd(1, .monotonic);
        return sub_id;
    }

    pub fn unsubscribe(self: *EventBus, channel_name: []const u8, sub_id: u64) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        if (self.channels.get(channel_name)) |channel| {
            channel.mutex.lock();
            defer channel.mutex.unlock();

            if (channel.subscribers.fetchRemove(sub_id)) |removed| {
                var sub = removed.value;
                sub.deinit();
                _ = self.stats.subscriber_count.fetchSub(1, .monotonic);
            }
        }
    }

    /// Publish `message` to all subscribers of `channel_name`.
    ///
    /// Filter matching runs under `channel.mutex`. Delivery (`write_fn`) runs
    /// **after both** the bus map lock and the channel lock are released so
    /// slow socket I/O cannot stall other publishers, block subscribe
    /// (exclusive bus lock), or wedge unsubscribe. Callers that free `ctx`
    /// on disconnect must provide retain/release hooks.
    ///
    /// Channel pointers remain valid for the process lifetime of the bus
    /// (channels are only destroyed in `EventBus.deinit`).
    pub fn publish(self: *EventBus, channel_name: []const u8, message: []const u8) !void {
        const channel: *Channel = blk: {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();
            break :blk self.channels.get(channel_name) orelse return;
        };

        const event_msg = try std.fmt.allocPrint(self.allocator, ">EVENT {s}\r\n{s}\r\n", .{ channel_name, message });
        defer self.allocator.free(event_msg);
        const ts_ms = eventTimestamp(self.allocator, message);

        var deliveries: std.ArrayListUnmanaged(Delivery) = .empty;
        defer {
            // Only runs if we abort before the deliver loop takes ownership;
            // after successful assembly the loop clears via release_fn.
            for (deliveries.items) |d| {
                if (d.release_fn) |rel| rel(d.ctx);
            }
            deliveries.deinit(self.allocator);
        }

        {
            channel.mutex.lock();
            defer channel.mutex.unlock();

            var iter = channel.subscribers.iterator();
            while (iter.next()) |entry| {
                const sub = entry.value_ptr.*;
                if (sub.filter) |filter| {
                    if (!filter.matches(message, ts_ms)) continue;
                }
                // Retain before leaving the lock so deinit cannot free ctx.
                if (sub.retain_fn) |retain| retain(sub.ctx);
                errdefer if (sub.release_fn) |rel| rel(sub.ctx);

                try deliveries.append(self.allocator, .{
                    .write_fn = sub.write_fn,
                    .ctx = sub.ctx,
                    .release_fn = sub.release_fn,
                });
            }

            _ = self.stats.publish_count.fetchAdd(1, .monotonic);
        }

        // Deliver outside all bus/channel locks — head-of-line socket I/O must
        // not serialize all publishers or block subscribe/unsubscribe.
        var i: usize = 0;
        while (i < deliveries.items.len) : (i += 1) {
            const d = deliveries.items[i];
            // Clear release from the defer list by nulling so defer doesn't double-release.
            deliveries.items[i].release_fn = null;
            d.write_fn(d.ctx, event_msg);
            if (d.release_fn) |rel| rel(d.ctx);
        }
        deliveries.clearRetainingCapacity();
    }

    pub fn channelCount(self: *EventBus) usize {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        return self.channels.count();
    }

    pub fn subscriberCount(self: *EventBus) u64 {
        return self.stats.subscriber_count.load(.monotonic);
    }

    pub fn publishCount(self: *EventBus) u64 {
        return self.stats.publish_count.load(.monotonic);
    }

    pub fn dropCount(self: *EventBus) u64 {
        return self.stats.drop_count.load(.monotonic);
    }

    /// Record a dropped event delivery (busy write path). Called from transports.
    pub fn recordDrop(self: *EventBus) void {
        _ = self.stats.drop_count.fetchAdd(1, .monotonic);
    }
};

fn eventTimestamp(allocator: std.mem.Allocator, message: []const u8) u64 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, message, .{}) catch return 0;
    defer parsed.deinit();

    if (parsed.value != .object) return 0;
    const ts = parsed.value.object.get("ts") orelse return 0;
    return switch (ts) {
        .integer => |n| if (n >= 0) @intCast(n) else 0,
        .float => |n| if (n >= 0) @intFromFloat(n) else 0,
        .number_string => |s| std.fmt.parseUnsigned(u64, s, 10) catch 0,
        else => 0,
    };
}

test "EventBus subscribe and publish" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var received_len: usize = 0;

    const TestContext = struct {
        data: []u8,
        len: *usize,

        fn write(ctx: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.data[0..data.len], data);
            self.len.* = data.len;
        }
    };

    var ctx = TestContext{
        .data = try testing.allocator.alloc(u8, 1024),
        .len = &received_len,
    };
    defer testing.allocator.free(ctx.data);

    const sub_id = try bus.subscribe("test_channel", TestContext.write, @ptrCast(&ctx));
    try testing.expectEqual(@as(u64, 1), bus.subscriberCount());

    try bus.publish("test_channel", "hello world");
    try testing.expect(received_len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, ctx.data[0..received_len], 1, "hello world"));

    bus.unsubscribe("test_channel", sub_id);
    try testing.expectEqual(@as(u64, 0), bus.subscriberCount());
}

test "EventBus filtered subscribe drops non-matching messages" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    var received_len: usize = 0;
    var received_count: usize = 0;

    const TestContext = struct {
        data: []u8,
        len: *usize,
        count: *usize,

        fn write(ctx: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.data[0..data.len], data);
            self.len.* = data.len;
            self.count.* += 1;
        }
    };

    var ctx = TestContext{
        .data = try testing.allocator.alloc(u8, 1024),
        .len = &received_len,
        .count = &received_count,
    };
    defer testing.allocator.free(ctx.data);

    const sub_id = try bus.subscribeFiltered("memory", "filter='meta.about=\"user-x\"'", TestContext.write, @ptrCast(&ctx));
    defer bus.unsubscribe("memory", sub_id);

    try bus.publish("memory", "{\"id\":\"a\",\"ts\":1,\"about\":\"user-y\"}");
    try bus.publish("memory", "{\"id\":\"b\",\"ts\":2,\"about\":\"user-x\"}");

    try testing.expectEqual(@as(usize, 1), received_count);
    try testing.expect(std.mem.containsAtLeast(u8, ctx.data[0..received_len], 1, "user-x"));
    try testing.expect(!std.mem.containsAtLeast(u8, ctx.data[0..received_len], 1, "user-y"));
}

test "EventBus rejects malformed subscription filter" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const TestContext = struct {
        fn write(_: *anyopaque, _: []const u8) void {}
    };

    var ctx: u8 = 0;
    try testing.expectError(
        error.InvalidPredicate,
        bus.subscribeFiltered("memory", "filter='meta.user.name=\"x\"'", TestContext.write, @ptrCast(&ctx)),
    );
}

test "EventBus publish does not hold channel mutex across write_fn" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const State = struct {
        bus: *EventBus,
        nested_publish_ok: bool = false,
        nested_sub_ok: bool = false,

        fn write(ctx: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // Must not deadlock: channel.mutex is released before write_fn.
            self.bus.publish("other", "nested") catch return;
            self.nested_publish_ok = true;

            const Dummy = struct {
                fn w(_: *anyopaque, _: []const u8) void {}
            };
            var dummy: u8 = 0;
            const id = self.bus.subscribe("other", Dummy.w, @ptrCast(&dummy)) catch return;
            self.bus.unsubscribe("other", id);
            self.nested_sub_ok = true;
        }
    };

    var state = State{ .bus = &bus };
    _ = try bus.subscribe("ch", State.write, @ptrCast(&state));
    try bus.publish("ch", "ping");
    try testing.expect(state.nested_publish_ok);
    try testing.expect(state.nested_sub_ok);
}

test "EventBus write_fn can unsubscribe self without deadlock" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const State = struct {
        bus: *EventBus,
        channel: []const u8,
        sub_id: u64 = 0,
        calls: usize = 0,

        fn write(ctx: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.bus.unsubscribe(self.channel, self.sub_id);
        }
    };

    var state = State{ .bus = &bus, .channel = "self-unsub" };
    state.sub_id = try bus.subscribe("self-unsub", State.write, @ptrCast(&state));
    try bus.publish("self-unsub", "bye");
    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expectEqual(@as(u64, 0), bus.subscriberCount());

    // Second publish has no subscribers — must not call write or hang.
    try bus.publish("self-unsub", "again");
    try testing.expectEqual(@as(usize, 1), state.calls);
}

test "EventBus retain/release keeps ctx alive across concurrent unsub" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const State = struct {
        alive: std.atomic.Value(bool) = .init(true),
        in_flight: std.atomic.Value(u32) = .init(0),
        writes: std.atomic.Value(u32) = .init(0),
        gate: std.atomic.Value(bool) = .init(false),
        bus: *EventBus,
        channel: []const u8 = "life",
        sub_id: u64 = 0,

        fn retain(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.in_flight.fetchAdd(1, .acquire);
        }
        fn release(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.in_flight.fetchSub(1, .release);
        }
        fn write(ctx: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // Hold until main thread has unsubscribed (slow-consumer race).
            while (!self.gate.load(.acquire)) {
                std.Thread.yield() catch {};
            }
            if (!self.alive.load(.acquire)) return;
            _ = data;
            _ = self.writes.fetchAdd(1, .monotonic);
        }
    };

    var state = State{ .bus = &bus };
    state.sub_id = try bus.subscribeFilteredHooks(
        "life",
        null,
        State.write,
        @ptrCast(&state),
        .{ .retain_fn = State.retain, .release_fn = State.release },
    );

    const Pub = struct {
        fn run(b: *EventBus) void {
            b.publish("life", "payload") catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, Pub.run, .{&bus});

    // Wait until publisher has retained us, then unsubscribe under race.
    while (state.in_flight.load(.acquire) == 0) {
        std.Thread.yield() catch {};
    }
    bus.unsubscribe("life", state.sub_id);
    state.alive.store(false, .release);
    state.gate.store(true, .release);

    thread.join();

    // Drain in-flight: publisher must have released.
    try testing.expectEqual(@as(u32, 0), state.in_flight.load(.acquire));
    // Write either completed (1) or saw closed (0) — never UAF crash.
    try testing.expect(state.writes.load(.acquire) <= 1);
}
