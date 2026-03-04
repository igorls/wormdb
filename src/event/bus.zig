//! Event bus for pub/sub streaming
//!
//! Supports channels with multiple subscribers.
//! Thread-safe with atomic operations for subscriber counts.

const std = @import("std");

pub const Subscriber = struct {
    id: u64,
    write_fn: *const fn (ctx: *anyopaque, data: []const u8) void,
    ctx: *anyopaque,
};

pub const Channel = struct {
    name: []const u8,
    subscribers: std.AutoHashMap(u64, Subscriber),
    mutex: std.Thread.Mutex,
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
        self.subscribers.deinit();
    }
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    channels: std.StringHashMap(*Channel),
    mutex: std.Thread.RwLock,
    stats: Stats,

    pub const Stats = struct {
        publish_count: std.atomic.Value(u64),
        subscriber_count: std.atomic.Value(u64),
    };

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .channels = std.StringHashMap(*Channel).init(allocator),
            .mutex = .{},
            .stats = .{
                .publish_count = std.atomic.Value(u64).init(0),
                .subscriber_count = std.atomic.Value(u64).init(0),
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
        write_fn: *const fn (ctx: *anyopaque, data: []const u8) void,
        ctx: *anyopaque,
    ) !u64 {
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
        });

        _ = self.stats.subscriber_count.fetchAdd(1, .monotonic);
        return sub_id;
    }

    pub fn unsubscribe(self: *EventBus, channel_name: []const u8, sub_id: u64) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        if (self.channels.get(channel_name)) |channel| {
            channel.mutex.lock();
            defer channel.mutex.unlock();

            if (channel.subscribers.fetchRemove(sub_id)) |_| {
                _ = self.stats.subscriber_count.fetchSub(1, .monotonic);
            }
        }
    }

    pub fn publish(self: *EventBus, channel_name: []const u8, message: []const u8) !void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const channel = self.channels.get(channel_name) orelse return;
        const event_msg = try std.fmt.allocPrint(self.allocator, ">EVENT {s}\r\n{s}\r\n", .{ channel_name, message });
        defer self.allocator.free(event_msg);

        channel.mutex.lock();
        defer channel.mutex.unlock();

        var iter = channel.subscribers.iterator();
        while (iter.next()) |entry| {
            const sub = entry.value_ptr.*;
            sub.write_fn(sub.ctx, event_msg);
        }

        _ = self.stats.publish_count.fetchAdd(1, .monotonic);
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
};

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
