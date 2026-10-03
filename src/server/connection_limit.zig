//! Allocation-free admission budget, reserved before queuing or spawning.
const std = @import("std");

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
