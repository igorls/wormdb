//! Admission and request budgets shared by the client transports: the global
//! connection budget, the per-IP connection cap, and the per-connection
//! command rate limit.
const std = @import("std");
const core = @import("../core/mod.zig");

pub const ConnectionLimit = struct {
    active: std.atomic.Value(usize) = .init(0),

    pub fn acquire(self: *ConnectionLimit, max: usize) bool {
        var n = self.active.load(.monotonic);
        while (n < max) {
            n = self.active.cmpxchgWeak(n, n + 1, .acq_rel, .monotonic) orelse return true;
        }
        return false;
    }

    pub fn release(self: *ConnectionLimit) void {
        const previous = self.active.fetchSub(1, .release);
        std.debug.assert(previous > 0);
    }
};

test "admission rejects at capacity and recovers after release" {
    var limit = ConnectionLimit{};
    try std.testing.expect(!limit.acquire(0));
    try std.testing.expect(limit.acquire(2));
    try std.testing.expect(limit.acquire(2));
    try std.testing.expect(!limit.acquire(2));
    limit.release();
    try std.testing.expect(limit.acquire(2));
    limit.release();
    limit.release();
    try std.testing.expectEqual(@as(usize, 0), limit.active.load(.acquire));
}

/// Per-IP concurrent-connection accounting for an accept path (#89).
/// Keys are peer IPs normalized to 16 bytes (IPv4 mapped to ::ffff:a.b.c.d) so a
/// v4 peer and the same peer seen as v4-mapped-v6 share one bucket. Guarded by
/// `core.compat.Mutex` (NOT `std.Thread.Mutex`, which is gone in Zig 0.16).
/// Fails open: an OOM while tracking admits the connection uncounted — the cap
/// is a brake against address-sharing floods, not a security boundary.
pub const IpLimiter = struct {
    allocator: std.mem.Allocator,
    mutex: core.compat.Mutex = .{},
    counts: std.AutoHashMapUnmanaged(Key, u32) = .empty,

    pub const Key = [16]u8;

    const v4_mapped_prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

    pub fn init(allocator: std.mem.Allocator) IpLimiter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *IpLimiter) void {
        self.counts.deinit(self.allocator);
    }

    pub fn keyFromAddress(addr: std.Io.net.IpAddress) Key {
        return std.Io.net.Ip6Address.fromAny(addr).bytes;
    }

    /// ::1 or ::ffff:127.0.0.0/8.
    pub fn isLoopback(key: Key) bool {
        const v6_loopback = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        if (std.mem.eql(u8, &key, &v6_loopback)) return true;
        return std.mem.eql(u8, key[0..12], &v4_mapped_prefix) and key[12] == 127;
    }

    /// Reserve one connection slot for `key`. Returns false when the peer
    /// already holds `max` slots (caller rejects the connection).
    pub fn acquire(self: *IpLimiter, key: Key, max: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.counts.getOrPut(self.allocator, key) catch return true; // fail open
        if (!gop.found_existing) gop.value_ptr.* = 0;
        if (gop.value_ptr.* >= max) return false;
        gop.value_ptr.* += 1;
        return true;
    }

    /// Return a slot taken by `acquire`. Tolerates keys it never counted
    /// (fail-open admissions) so a stray release cannot underflow.
    pub fn release(self: *IpLimiter, key: Key) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.counts.getPtr(key) orelse return;
        if (entry.* > 0) entry.* -= 1;
        if (entry.* == 0) _ = self.counts.remove(key);
    }

    /// Current active count for `key` (tests/diagnostics).
    pub fn activeCount(self: *IpLimiter, key: Key) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.counts.get(key) orelse 0;
    }
};

/// Per-connection command token bucket: `per_sec` tokens refill per second and
/// the bucket holds one second's worth, so a client may burst up to `per_sec`
/// commands and then sustain `per_sec`/s. A rejected command is answered with
/// `ERR rate limited` and not executed; the connection stays open. One bucket
/// per connection keeps a single chatty token from monopolizing the worker
/// pool (the pool is shared by every tenant on the node).
pub const CommandRateLimiter = struct {
    capacity: f64,
    tokens: f64,
    per_ns: f64,
    last_ns: i128,

    /// Null when `per_sec` is 0 (unlimited), so callers can store `?CommandRateLimiter`.
    pub fn init(per_sec: u32, now_ns: i128) ?CommandRateLimiter {
        if (per_sec == 0) return null;
        const cap: f64 = @floatFromInt(per_sec);
        return .{ .capacity = cap, .tokens = cap, .per_ns = cap / 1_000_000_000.0, .last_ns = now_ns };
    }

    /// Consume one token if available.
    pub fn allow(self: *CommandRateLimiter, now_ns: i128) bool {
        if (now_ns > self.last_ns) {
            const elapsed: f64 = @floatFromInt(now_ns - self.last_ns);
            self.tokens = @min(self.capacity, self.tokens + elapsed * self.per_ns);
            self.last_ns = now_ns;
        }
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }
};

test "CommandRateLimiter: burst, refusal, refill; zero means unlimited" {
    try std.testing.expect(CommandRateLimiter.init(0, 0) == null);
    var limiter = CommandRateLimiter.init(10, 0).?;
    var i: usize = 0;
    while (i < 10) : (i += 1) try std.testing.expect(limiter.allow(0));
    try std.testing.expect(!limiter.allow(0));
    // 100 ms later one token has refilled; 1 s later the bucket is full again.
    try std.testing.expect(limiter.allow(100 * 1_000_000));
    try std.testing.expect(!limiter.allow(100 * 1_000_000));
    i = 0;
    while (i < 10) : (i += 1) try std.testing.expect(limiter.allow(2 * 1_000_000_000));
    try std.testing.expect(!limiter.allow(2 * 1_000_000_000));
    // A clock that does not advance never refills.
    try std.testing.expect(!limiter.allow(1 * 1_000_000_000));
}
