//! Hybrid logical clock (HLC) — 64-bit packed timestamps.
//!
//! Layout: [48 bits physical wall-clock ms][16 bits logical counter].
//! `now` generates a locally-monotone timestamp even when the wall clock
//! stalls or regresses (the logical counter absorbs the difference).
//! `observe` merges a remote HLC on receive, with a bounded-drift clamp so
//! a forged far-future remote clock cannot poison the local clock (mirrors
//! meshguard's forged-clock clamp, #121).
//!
//! The whole clock is a single atomic u64 advanced by a CAS loop, so one
//! shared instance is safe under concurrent procedure execution.

const std = @import("std");

/// Maximum tolerated remote-vs-local physical drift on `observe` (ms).
pub const MAX_DRIFT_MS: u64 = 60_000;

/// Number of low bits used for the logical counter.
pub const LOGICAL_BITS: u6 = 16;

/// Mask of the logical-counter bits.
pub const LOGICAL_MASK: u64 = (1 << LOGICAL_BITS) - 1;

/// Physical part is truncated to 48 bits (good until the year ~10889).
pub const PHYSICAL_MAX: u64 = (1 << 48) - 1;

pub const Unpacked = struct {
    physical_ms: u64,
    logical: u16,
};

/// Pack a (physical ms, logical) pair into a 64-bit HLC value.
pub fn pack(physical_ms: u64, logical: u16) u64 {
    return ((physical_ms & PHYSICAL_MAX) << LOGICAL_BITS) | logical;
}

/// Unpack a 64-bit HLC value into its physical/logical parts.
pub fn unpack(v: u64) Unpacked {
    return .{
        .physical_ms = v >> LOGICAL_BITS,
        .logical = @truncate(v & LOGICAL_MASK),
    };
}

pub const Hlc = struct {
    /// Last issued/observed HLC value. Single atomic word — all updates go
    /// through a CAS loop, so concurrent callers never regress the clock.
    last: std.atomic.Value(u64),

    pub fn init() Hlc {
        return .{ .last = std.atomic.Value(u64).init(0) };
    }

    /// Issue the next local timestamp: `max(wall_ms << 16, last + 1)`.
    /// When the wall clock advances past the last physical part, the result
    /// carries the new wall time with logical = 0; otherwise the logical
    /// counter increments (rolling into physical +1ms on u16 overflow, which
    /// the `last + 1` arithmetic handles naturally).
    pub fn now(self: *Hlc, wall_ms: u64) u64 {
        const wall_part = pack(wall_ms, 0);
        while (true) {
            const prev = self.last.load(.monotonic);
            const candidate = @max(wall_part, prev + 1);
            if (self.last.cmpxchgWeak(prev, candidate, .monotonic, .monotonic) == null) {
                return candidate;
            }
        }
    }

    /// Merge a remote HLC value on receive and issue the next local
    /// timestamp: `max(wall_ms << 16, last + 1, clamped_remote + 1)`.
    ///
    /// Forged-clock guard: if the remote physical part is more than
    /// MAX_DRIFT_MS ahead of our wall clock, it is clamped to
    /// `wall_ms + MAX_DRIFT_MS` (logical part preserved) so a malicious or
    /// broken peer cannot jump the local clock arbitrarily far into the
    /// future.
    pub fn observe(self: *Hlc, remote: u64, wall_ms: u64) u64 {
        var remote_v = remote;
        const remote_parts = unpack(remote);
        if (remote_parts.physical_ms > wall_ms + MAX_DRIFT_MS) {
            remote_v = pack(wall_ms + MAX_DRIFT_MS, remote_parts.logical);
        }
        const wall_part = pack(wall_ms, 0);
        while (true) {
            const prev = self.last.load(.monotonic);
            const candidate = @max(wall_part, @max(prev, remote_v) + 1);
            if (self.last.cmpxchgWeak(prev, candidate, .monotonic, .monotonic) == null) {
                return candidate;
            }
        }
    }
};

test "hlc pack/unpack round trip" {
    const testing = std.testing;
    const v = pack(1_700_000_000_123, 42);
    const u = unpack(v);
    try testing.expectEqual(@as(u64, 1_700_000_000_123), u.physical_ms);
    try testing.expectEqual(@as(u16, 42), u.logical);
    // Physical truncates to 48 bits.
    const big = pack(std.math.maxInt(u64), 7);
    try testing.expectEqual(PHYSICAL_MAX, unpack(big).physical_ms);
}

test "hlc now is strictly monotone when the wall clock stalls" {
    const testing = std.testing;
    var clock = Hlc.init();
    const wall: u64 = 1000;
    var prev = clock.now(wall);
    try testing.expectEqual(@as(u64, 1000), unpack(prev).physical_ms);
    try testing.expectEqual(@as(u16, 0), unpack(prev).logical);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const next = clock.now(wall); // same millisecond, repeatedly
        try testing.expect(next > prev);
        try testing.expectEqual(@as(u64, 1000), unpack(next).physical_ms);
        prev = next;
    }
    try testing.expectEqual(@as(u16, 100), unpack(prev).logical);
}

test "hlc now tolerates wall-clock regression" {
    const testing = std.testing;
    var clock = Hlc.init();
    const a = clock.now(5000);
    const b = clock.now(4000); // wall regressed by a second
    const c = clock.now(4001);
    try testing.expect(b > a);
    try testing.expect(c > b);
    // Physical part never regresses.
    try testing.expectEqual(@as(u64, 5000), unpack(b).physical_ms);
    // Wall catching up past the physical part resumes normal ticking.
    const d = clock.now(6000);
    try testing.expect(d > c);
    try testing.expectEqual(@as(u64, 6000), unpack(d).physical_ms);
    try testing.expectEqual(@as(u16, 0), unpack(d).logical);
}

test "hlc observe advances past both local and remote" {
    const testing = std.testing;
    var clock = Hlc.init();
    const local = clock.now(1000);
    const remote = pack(1500, 3); // remote slightly ahead, within drift
    const merged = clock.observe(remote, 1000);
    try testing.expect(merged > local);
    try testing.expect(merged > remote);
    try testing.expectEqual(@as(u64, 1500), unpack(merged).physical_ms);
    try testing.expectEqual(@as(u16, 4), unpack(merged).logical);
}

test "hlc observe clamps forged far-future remote clocks" {
    const testing = std.testing;
    var clock = Hlc.init();
    const wall: u64 = 1_000_000;
    const forged = pack(wall + 10 * 24 * 3600 * 1000, 0); // 10 days ahead
    const merged = clock.observe(forged, wall);
    // Result physical part is bounded by wall + MAX_DRIFT_MS.
    try testing.expect(unpack(merged).physical_ms <= wall + MAX_DRIFT_MS);
    try testing.expect(merged > pack(wall, 0));
    // Subsequent local ticks stay monotone and near the clamp, not the forgery.
    const next = clock.now(wall);
    try testing.expect(next > merged);
    try testing.expect(unpack(next).physical_ms <= wall + MAX_DRIFT_MS);
}

test "hlc ordering is transitive across generate and observe" {
    const testing = std.testing;
    var a = Hlc.init();
    var b = Hlc.init();
    var c = Hlc.init();
    // a -> b -> c message chain: each hop observes the previous timestamp.
    const ta = a.now(2000);
    const tb = b.observe(ta, 1990); // b's wall clock is behind
    const tc = c.observe(tb, 1980); // c's wall clock is further behind
    try testing.expect(ta < tb);
    try testing.expect(tb < tc);
    try testing.expect(ta < tc);
}
