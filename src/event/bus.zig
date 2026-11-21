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
const build_options = @import("build_options");
const core = @import("../core/mod.zig");
const compat = core.compat;
const predicate = core.predicate;

pub const WriteFn = *const fn (ctx: *anyopaque, data: []const u8) void;
pub const EventFn = *const fn (ctx: *anyopaque, channel: []const u8, message: []const u8) void;
pub const LifetimeFn = *const fn (ctx: *anyopaque) void;

pub const Subscriber = struct {
    id: u64,
    write_fn: ?WriteFn,
    event_fn: ?EventFn = null,
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
    /// Structured delivery preserves arbitrary binary channel/message bytes.
    /// When absent, the legacy text event envelope is passed to write_fn.
    event_fn: ?EventFn = null,
};

const Delivery = struct {
    write_fn: ?WriteFn,
    event_fn: ?EventFn,
    ctx: *anyopaque,
    release_fn: ?LifetimeFn,
};

pub const Channel = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    subscribers: std.AutoArrayHashMapUnmanaged(u64, Subscriber),
    mutex: compat.Mutex,
    next_sub_id: compat.AtomicU64,
    /// Number of subscribers on this channel with an active predicate filter (under `mutex`).
    filtered_count: usize = 0,
    /// Number of subscribers on this channel using legacy text `write_fn` (under `mutex`).
    text_sub_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Channel {
        return .{
            .allocator = allocator,
            .name = name,
            .subscribers = .empty,
            .mutex = .{},
            .next_sub_id = compat.AtomicU64.init(1),
            .filtered_count = 0,
            .text_sub_count = 0,
        };
    }

    pub fn deinit(self: *Channel) void {
        for (self.subscribers.values()) |*sub| {
            sub.deinit();
        }
        self.subscribers.deinit(self.allocator);
    }
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    channels: std.StringHashMap(*Channel),
    /// Subset of `channels` whose names end in `:` or `*` (prefix/wildcard patterns).
    /// Borrowed pointers owned by `channels`; guarded by `mutex`. Keeping these separate
    /// lets `publish()` do an O(1) exact hash lookup in the common no-wildcard case.
    prefix_channels: std.ArrayListUnmanaged(*Channel) = .empty,
    mutex: compat.RwLock,
    stats: Stats,

    pub const Stats = struct {
        // A wasm32 build has no 64-bit atomics, and a single-threaded build has nothing to
        // synchronise with, so the counter is a plain u64 there and an atomic elsewhere.
        publish_count: if (build_options.single_threaded) u64 else compat.AtomicU64,
        subscriber_count: compat.AtomicU64,
        /// Events dropped because a subscriber's write path was busy (tryLock fail).
        drop_count: compat.AtomicU64 = compat.AtomicU64.init(0),
        /// Subscribers evicted because their socket could not take an event frame
        /// within the transport's send deadline (stalled consumer).
        evict_count: compat.AtomicU64 = compat.AtomicU64.init(0),
    };

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return .{
            .allocator = allocator,
            .channels = std.StringHashMap(*Channel).init(allocator),
            .prefix_channels = .empty,
            .mutex = .{},
            .stats = .{
                .publish_count = if (build_options.single_threaded) @as(u64, 0) else compat.AtomicU64.init(0),
                .subscriber_count = compat.AtomicU64.init(0),
                .drop_count = compat.AtomicU64.init(0),
                .evict_count = compat.AtomicU64.init(0),
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
        self.prefix_channels.deinit(self.allocator);
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

    fn isPrefixPattern(name: []const u8) bool {
        if (name.len == 0) return false;
        const last = name[name.len - 1];
        return last == ':' or last == '*';
    }

    /// True if prefix/wildcard pattern `sub_pattern` (guaranteed to end in `:` or `*`)
    /// matches `channel_name`.
    fn prefixMatches(channel_name: []const u8, sub_pattern: []const u8) bool {
        const last = sub_pattern[sub_pattern.len - 1];
        if (last == ':') {
            return std.mem.startsWith(u8, channel_name, sub_pattern);
        }
        return std.mem.startsWith(u8, channel_name, sub_pattern[0 .. sub_pattern.len - 1]);
    }

    pub fn subscribeFilteredHooks(
        self: *EventBus,
        channel_name: []const u8,
        filter_raw: ?[]const u8,
        write_fn: ?WriteFn,
        ctx: *anyopaque,
        hooks: LifetimeHooks,
    ) !u64 {
        std.debug.assert(write_fn != null or hooks.event_fn != null);
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

        const is_prefix = isPrefixPattern(channel_name);
        if (is_prefix) {
            try self.prefix_channels.ensureUnusedCapacity(self.allocator, 1);
        }

        const gop = try self.channels.getOrPut(channel_name);
        if (!gop.found_existing) {
            errdefer _ = self.channels.remove(channel_name);
            const name_copy = try self.allocator.dupe(u8, channel_name);
            errdefer self.allocator.free(name_copy);
            const channel = try self.allocator.create(Channel);
            channel.* = Channel.init(self.allocator, name_copy);
            gop.key_ptr.* = name_copy;
            gop.value_ptr.* = channel;
            if (is_prefix) {
                self.prefix_channels.appendAssumeCapacity(channel);
            }
        }

        const channel = gop.value_ptr.*;
        channel.mutex.lock();
        defer channel.mutex.unlock();

        const sub_id = channel.next_sub_id.fetchAdd(1, .monotonic);
        const has_filter = parsed_filter != null;
        const is_text = hooks.event_fn == null;
        try channel.subscribers.put(self.allocator, sub_id, .{
            .id = sub_id,
            .write_fn = write_fn,
            .event_fn = hooks.event_fn,
            .ctx = ctx,
            .filter = parsed_filter,
            .filter_src = filter_src,
            .filter_allocator = self.allocator,
            .retain_fn = hooks.retain_fn,
            .release_fn = hooks.release_fn,
        });
        parsed_filter = null;
        filter_src = null;
        if (has_filter) channel.filtered_count += 1;
        if (is_text) channel.text_sub_count += 1;

        _ = self.stats.subscriber_count.fetchAdd(1, .monotonic);
        return sub_id;
    }

    pub fn unsubscribe(self: *EventBus, channel_name: []const u8, sub_id: u64) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        if (self.channels.get(channel_name)) |channel| {
            channel.mutex.lock();
            defer channel.mutex.unlock();

            if (channel.subscribers.fetchSwapRemove(sub_id)) |removed| {
                var sub = removed.value;
                if (sub.filter != null) channel.filtered_count -= 1;
                if (sub.event_fn == null) channel.text_sub_count -= 1;
                sub.deinit();
                _ = self.stats.subscriber_count.fetchSub(1, .monotonic);
            }
        }
    }

    /// Publish `message` to all subscribers of `channel_name` (exact and prefix matches).
    ///
    /// Filter matching runs under `channel.mutex`. Delivery (`write_fn`) runs
    /// **after both** the bus map lock and the channel lock are released so
    /// slow socket I/O cannot stall other publishers, block subscribe
    /// (exclusive bus lock), or wedge unsubscribe. Callers that free `ctx`
    /// on disconnect must provide retain/release hooks.
    ///
    /// Throughput notes:
    /// - Exact channel lookup is O(1); prefix/wildcard matching only iterates
    ///   `prefix_channels` (empty in the common no-wildcard case).
    /// - Stack buffers cover up to 32 deliveries and 1 KiB text frames with zero
    ///   heap allocation; larger fanouts/messages fall back cleanly to the heap.
    /// - Full JSON parse for `ts` is skipped when `channel.filtered_count == 0`.
    ///
    /// Channel pointers remain valid for the process lifetime of the bus
    /// (channels are only destroyed in `EventBus.deinit`).
    pub fn publish(self: *EventBus, channel_name: []const u8, message: []const u8) !void {
        var matched_stack: [16]*Channel = undefined;
        var matched_len: usize = 0;
        var matched_heap: std.ArrayListUnmanaged(*Channel) = .empty;
        defer matched_heap.deinit(self.allocator);

        {
            self.mutex.lockShared();
            defer self.mutex.unlockShared();

            const exact_ch = self.channels.get(channel_name);
            if (exact_ch) |ch| {
                matched_stack[0] = ch;
                matched_len = 1;
            }

            if (self.prefix_channels.items.len > 0) {
                for (self.prefix_channels.items) |ch| {
                    if (exact_ch != null and ch == exact_ch.?) continue;
                    if (!prefixMatches(channel_name, ch.name)) continue;
                    if (matched_len < matched_stack.len) {
                        matched_stack[matched_len] = ch;
                        matched_len += 1;
                    } else {
                        try matched_heap.append(self.allocator, ch);
                    }
                }
            }
        }

        // Count every publish call even when zero subscribers match.
        self.bumpPublishCount();

        const total_matched = matched_len + matched_heap.items.len;
        if (total_matched == 0) return;

        var deliveries_stack: [32]Delivery = undefined;
        var deliveries_stack_len: usize = 0;
        var deliveries_heap: std.ArrayListUnmanaged(Delivery) = .empty;
        var delivered_count: usize = 0;
        defer {
            // Releases any retained deliveries that were not yet handed off to the
            // delivery loop (e.g., on OOM while growing overflow/frame buffers).
            const total_del = deliveries_stack_len + deliveries_heap.items.len;
            var rem = delivered_count;
            while (rem < total_del) : (rem += 1) {
                const d = if (rem < deliveries_stack_len)
                    deliveries_stack[rem]
                else
                    deliveries_heap.items[rem - deliveries_stack_len];
                if (d.release_fn) |rel| rel(d.ctx);
            }
            deliveries_heap.deinit(self.allocator);
        }

        var ts_computed = false;
        var ts_ms: u64 = 0;
        var need_text_frame = false;

        var ch_idx: usize = 0;
        while (ch_idx < total_matched) : (ch_idx += 1) {
            const channel = if (ch_idx < matched_len) matched_stack[ch_idx] else matched_heap.items[ch_idx - matched_len];

            channel.mutex.lock();
            defer channel.mutex.unlock();

            const subs = channel.subscribers.values();
            if (subs.len == 0) continue;

            // Pre-reserve heap overflow capacity once per channel if this channel
            // could spill past the 32-slot stack buffer.
            const current_total = deliveries_stack_len + deliveries_heap.items.len;
            if (current_total + subs.len > deliveries_stack.len) {
                const needed_heap = (current_total + subs.len) - deliveries_stack.len;
                try deliveries_heap.ensureTotalCapacity(self.allocator, needed_heap);
            }

            const has_filters = channel.filtered_count > 0;
            if (has_filters and !ts_computed) {
                ts_ms = eventTimestamp(message);
                ts_computed = true;
            }

            if (!has_filters and total_matched == 1) {
                // Fast path: single channel, no predicate filters, no dedup needed.
                if (channel.text_sub_count > 0) need_text_frame = true;
                for (subs) |sub| {
                    if (sub.retain_fn) |retain| retain(sub.ctx);
                    const d = Delivery{
                        .write_fn = sub.write_fn,
                        .event_fn = sub.event_fn,
                        .ctx = sub.ctx,
                        .release_fn = sub.release_fn,
                    };
                    if (deliveries_stack_len < deliveries_stack.len) {
                        deliveries_stack[deliveries_stack_len] = d;
                        deliveries_stack_len += 1;
                    } else {
                        deliveries_heap.appendAssumeCapacity(d);
                    }
                }
                continue;
            }

            for (subs) |sub| {
                if (has_filters) {
                    if (sub.filter) |filter| {
                        if (!filter.matches(message, ts_ms)) continue;
                    }
                }

                // When multiple prefix/exact patterns match the same publish, avoid
                // delivering duplicate frames to the exact same subscriber target.
                if (total_matched > 1) {
                    var dup = false;
                    for (deliveries_stack[0..deliveries_stack_len]) |existing| {
                        if (existing.ctx == sub.ctx and existing.write_fn == sub.write_fn and existing.event_fn == sub.event_fn) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) {
                        for (deliveries_heap.items) |existing| {
                            if (existing.ctx == sub.ctx and existing.write_fn == sub.write_fn and existing.event_fn == sub.event_fn) {
                                dup = true;
                                break;
                            }
                        }
                    }
                    if (dup) continue;
                }

                if (sub.event_fn == null) need_text_frame = true;
                // Retain before leaving the lock so deinit cannot free ctx.
                if (sub.retain_fn) |retain| retain(sub.ctx);

                const d = Delivery{
                    .write_fn = sub.write_fn,
                    .event_fn = sub.event_fn,
                    .ctx = sub.ctx,
                    .release_fn = sub.release_fn,
                };
                if (deliveries_stack_len < deliveries_stack.len) {
                    deliveries_stack[deliveries_stack_len] = d;
                    deliveries_stack_len += 1;
                } else {
                    deliveries_heap.appendAssumeCapacity(d);
                }
            }
        }

        const total_deliveries = deliveries_stack_len + deliveries_heap.items.len;
        if (total_deliveries == 0) return;

        // Format wire text frame only when at least one subscriber uses write_fn.
        // Stack buffer avoids heap allocation and std.fmt overhead for typical frames.
        var event_stack: [1024]u8 = undefined;
        var event_heap: ?[]u8 = null;
        defer if (event_heap) |m| self.allocator.free(m);
        var event_msg: []const u8 = "";
        if (need_text_frame) {
            const prefix = ">EVENT ";
            const frame_len = prefix.len + channel_name.len + 2 + message.len + 2;
            const dst: []u8 = if (frame_len <= event_stack.len)
                event_stack[0..frame_len]
            else blk: {
                const buf = try self.allocator.alloc(u8, frame_len);
                event_heap = buf;
                break :blk buf;
            };
            var pos: usize = 0;
            @memcpy(dst[pos..][0..prefix.len], prefix);
            pos += prefix.len;
            @memcpy(dst[pos..][0..channel_name.len], channel_name);
            pos += channel_name.len;
            dst[pos] = '\r';
            dst[pos + 1] = '\n';
            pos += 2;
            @memcpy(dst[pos..][0..message.len], message);
            pos += message.len;
            dst[pos] = '\r';
            dst[pos + 1] = '\n';
            event_msg = dst;
        }

        // Deliver outside all bus/channel locks — head-of-line socket I/O must
        // not serialize all publishers or block subscribe/unsubscribe.
        var i: usize = 0;
        while (i < total_deliveries) : (i += 1) {
            const d = if (i < deliveries_stack_len)
                deliveries_stack[i]
            else
                deliveries_heap.items[i - deliveries_stack_len];
            // Mark ownership transferred before invoking callback; defer only cleans up
            // items at index >= delivered_count.
            delivered_count = i + 1;
            if (d.event_fn) |deliver_event| {
                deliver_event(d.ctx, channel_name, message);
            } else {
                d.write_fn.?(d.ctx, event_msg);
            }
            if (d.release_fn) |rel| rel(d.ctx);
        }
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
        return if (build_options.single_threaded) self.stats.publish_count else self.stats.publish_count.load(.monotonic);
    }

    /// One place for the counter bump: wasm32 has no 64-bit atomics without the threads
    /// proposal, and a single-threaded build has nothing to synchronise with, so the plain
    /// field is used there. Keeping both call sites on this helper stops them drifting apart.
    fn bumpPublishCount(self: *EventBus) void {
        if (build_options.single_threaded) self.stats.publish_count += 1 else _ = self.stats.publish_count.fetchAdd(1, .monotonic);
    }

    pub fn dropCount(self: *EventBus) u64 {
        return self.stats.drop_count.load(.monotonic);
    }

    /// Record a dropped event delivery (busy write path). Called from transports.
    pub fn recordDrop(self: *EventBus) void {
        _ = self.stats.drop_count.fetchAdd(1, .monotonic);
    }

    pub fn evictionCount(self: *EventBus) u64 {
        return self.stats.evict_count.load(.monotonic);
    }

    /// Record a stalled-subscriber eviction. Called from transports when a send
    /// deadline expires on the publish path and the connection is shut down.
    pub fn recordEviction(self: *EventBus) void {
        _ = self.stats.evict_count.fetchAdd(1, .monotonic);
    }
};

/// Extract a top-level numeric `"ts"` field without allocating a full JSON tree.
/// Used only for filtered subscriptions. Unfiltered feed paths skip this entirely.
fn eventTimestamp(message: []const u8) u64 {
    const needle = "\"ts\":";
    const start = std.mem.indexOf(u8, message, needle) orelse return 0;
    var i = start + needle.len;
    while (i < message.len and (message[i] == ' ' or message[i] == '\t')) : (i += 1) {}
    if (i >= message.len or message[i] == '-') return 0;
    var val: u64 = 0;
    var digits: usize = 0;
    while (i < message.len) : (i += 1) {
        const c = message[i];
        if (c < '0' or c > '9') break;
        // Saturating multiply/add keeps pathological inputs from wrapping oddly.
        val = val *| 10 +| (c - '0');
        digits += 1;
        if (digits > 20) return 0;
    }
    return if (digits > 0) val else 0;
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

test "EventBus prefix subscribe receives matching sub-channels and bumps publishCount" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const Counter = struct {
        count: usize = 0,
        last_len: usize = 0,
        last_buf: [256]u8 = undefined,

        fn write(ctx: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            const n = @min(data.len, self.last_buf.len);
            @memcpy(self.last_buf[0..n], data[0..n]);
            self.last_len = n;
        }
    };

    var prefix_sub = Counter{};
    var exact_sub = Counter{};
    var unrelated_sub = Counter{};

    const s1 = try bus.subscribe("gallery:", Counter.write, @ptrCast(&prefix_sub));
    defer bus.unsubscribe("gallery:", s1);
    const s2 = try bus.subscribe("gallery:progress", Counter.write, @ptrCast(&exact_sub));
    defer bus.unsubscribe("gallery:progress", s2);
    // "gal" does not end in ':' or '*' so it must NOT match "gallery:*"
    const s3 = try bus.subscribe("gal", Counter.write, @ptrCast(&unrelated_sub));
    defer bus.unsubscribe("gal", s3);

    try bus.publish("gallery:progress", "{\"done\":1}");
    try bus.publish("gallery:clusters", "{\"count\":4}");
    try bus.publish("unsubscribed:channel", "noop");

    try testing.expectEqual(@as(usize, 2), prefix_sub.count);
    try testing.expectEqual(@as(usize, 1), exact_sub.count);
    try testing.expectEqual(@as(usize, 0), unrelated_sub.count);
    try testing.expectEqual(@as(u64, 3), bus.publishCount());
    try testing.expect(std.mem.containsAtLeast(u8, prefix_sub.last_buf[0..prefix_sub.last_len], 1, "gallery:clusters"));
}

test "EventBus overlapping prefix and exact subscriptions on same target deduplicate delivery" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const Counter = struct {
        count: usize = 0,
        fn write(ctx: *anyopaque, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
        }
    };

    var shared = Counter{};
    const s1 = try bus.subscribe("vec:", Counter.write, @ptrCast(&shared));
    defer bus.unsubscribe("vec:", s1);
    const s2 = try bus.subscribe("vec:vis:1", Counter.write, @ptrCast(&shared));
    defer bus.unsubscribe("vec:vis:1", s2);

    try bus.publish("vec:vis:1", "payload");
    try testing.expectEqual(@as(usize, 1), shared.count);
}

test "EventBus heap fallback handles >32 subscribers and >1024B frames" {
    const testing = std.testing;

    var bus = EventBus.init(testing.allocator);
    defer bus.deinit();

    const Counter = struct {
        count: usize = 0,
        last_len: usize = 0,
        fn write(ctx: *anyopaque, data: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
            self.last_len = data.len;
        }
    };

    var counters: [48]Counter = @splat(.{});
    var sub_ids: [48]u64 = undefined;
    for (0..48) |i| {
        sub_ids[i] = try bus.subscribe("big:fanout", Counter.write, @ptrCast(&counters[i]));
    }
    defer for (sub_ids) |id| bus.unsubscribe("big:fanout", id);

    const big_payload = &@as([1500]u8, @splat('Z'));
    try bus.publish("big:fanout", big_payload);

    for (counters) |c| {
        try testing.expectEqual(@as(usize, 1), c.count);
        try testing.expectEqual(@as(usize, ">EVENT big:fanout\r\n".len + big_payload.len + 2), c.last_len);
    }
}
