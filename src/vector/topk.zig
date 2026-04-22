//! Bounded top-K via fixed-capacity min-heap.
//!
//! Tracks the K highest-scoring items from an unknown-length stream without
//! allocating per-item or sorting the whole stream. Standard pattern:
//! maintain a min-heap of size K; a new item is kept only if it beats the
//! current minimum (root).
//!
//! For N candidates this is O(N log K) vs O(N log N) for append+sort — the
//! difference matters when N = millions of vectors and K = 10.
//!
//! Usage:
//!   var buf: [10]Candidate = undefined;
//!   var topk = TopK(Candidate, scoreOf).init(&buf);
//!   // stream items:
//!   topk.push(.{ .key = k, .score = s });
//!   // drain sorted (best first):
//!   const results = topk.sortedDesc();

const std = @import("std");

/// Min-heap of capacity K over items of type T, ranked by a user-supplied
/// `scoreOf(T) -> f32`. Items with the largest scores survive.
pub fn TopK(
    comptime T: type,
    comptime scoreOf: fn (T) f32,
) type {
    return struct {
        const Self = @This();

        buf: []T,
        count: usize,

        /// Initialize over a caller-owned buffer. `buf.len` is the K bound.
        pub fn init(buf: []T) Self {
            return .{ .buf = buf, .count = 0 };
        }

        pub fn capacity(self: *const Self) usize {
            return self.buf.len;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// The score a new candidate must strictly exceed to be admitted.
        /// Returns `-inf` while the heap isn't yet full (any finite score
        /// qualifies). Callers can use this to skip expensive work (e.g.
        /// duping a key into the arena) for candidates that would be
        /// rejected anyway.
        pub fn thresholdScore(self: *const Self) f32 {
            if (self.count < self.buf.len) return -std.math.inf(f32);
            return scoreOf(self.buf[0]);
        }

        /// Offer a candidate. Kept iff the buffer isn't full, or the item's
        /// score exceeds the current minimum. O(log K).
        pub fn push(self: *Self, item: T) void {
            if (self.buf.len == 0) return;

            if (self.count < self.buf.len) {
                self.buf[self.count] = item;
                self.count += 1;
                siftUp(self.buf[0..self.count], self.count - 1);
                return;
            }

            // Full — replace root only if new item beats current min.
            if (scoreOf(item) <= scoreOf(self.buf[0])) return;
            self.buf[0] = item;
            siftDown(self.buf, 0);
        }

        /// Sort the captured items in descending order of score (best first)
        /// and return the populated prefix. Destroys heap invariant — call
        /// at most once per fill cycle.
        pub fn sortedDesc(self: *Self) []T {
            const slice = self.buf[0..self.count];
            std.sort.heap(T, slice, {}, struct {
                fn greater(_: void, a: T, b: T) bool {
                    return scoreOf(a) > scoreOf(b);
                }
            }.greater);
            return slice;
        }

        fn siftUp(heap: []T, start: usize) void {
            var i = start;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (scoreOf(heap[i]) >= scoreOf(heap[parent])) break;
                std.mem.swap(T, &heap[i], &heap[parent]);
                i = parent;
            }
        }

        fn siftDown(heap: []T, start: usize) void {
            const n = heap.len;
            var i = start;
            while (true) {
                const l = 2 * i + 1;
                const r = 2 * i + 2;
                var smallest = i;
                if (l < n and scoreOf(heap[l]) < scoreOf(heap[smallest])) smallest = l;
                if (r < n and scoreOf(heap[r]) < scoreOf(heap[smallest])) smallest = r;
                if (smallest == i) break;
                std.mem.swap(T, &heap[i], &heap[smallest]);
                i = smallest;
            }
        }
    };
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

const Scored = struct { id: u32, score: f32 };
fn scoreOfScored(s: Scored) f32 {
    return s.score;
}
const TopKScored = TopK(Scored, scoreOfScored);

test "top-k: fewer items than capacity" {
    var buf: [5]Scored = undefined;
    var tk = TopKScored.init(&buf);
    tk.push(.{ .id = 1, .score = 0.3 });
    tk.push(.{ .id = 2, .score = 0.9 });
    tk.push(.{ .id = 3, .score = 0.5 });
    const out = tk.sortedDesc();
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqual(@as(u32, 2), out[0].id); // 0.9
    try std.testing.expectEqual(@as(u32, 3), out[1].id); // 0.5
    try std.testing.expectEqual(@as(u32, 1), out[2].id); // 0.3
}

test "top-k: more items than capacity keeps top K" {
    var buf: [3]Scored = undefined;
    var tk = TopKScored.init(&buf);
    const scores = [_]f32{ 0.1, 0.8, 0.3, 0.95, 0.5, 0.2, 0.7, 0.6 };
    for (scores, 0..) |s, i| {
        tk.push(.{ .id = @intCast(i), .score = s });
    }
    const out = tk.sortedDesc();
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), out[0].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), out[1].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), out[2].score, 1e-6);
}

test "top-k: zero capacity is a no-op" {
    var buf: [0]Scored = undefined;
    var tk = TopKScored.init(&buf);
    tk.push(.{ .id = 1, .score = 1.0 });
    try std.testing.expectEqual(@as(usize, 0), tk.len());
    try std.testing.expectEqual(@as(usize, 0), tk.sortedDesc().len);
}

test "top-k: ties preserve heap invariant" {
    var buf: [3]Scored = undefined;
    var tk = TopKScored.init(&buf);
    for (0..10) |i| tk.push(.{ .id = @intCast(i), .score = 0.5 });
    const out = tk.sortedDesc();
    try std.testing.expectEqual(@as(usize, 3), out.len);
    for (out) |r| try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.score, 1e-6);
}

test "top-k: equal score does not displace (strict >)" {
    var buf: [2]Scored = undefined;
    var tk = TopKScored.init(&buf);
    tk.push(.{ .id = 1, .score = 0.5 });
    tk.push(.{ .id = 2, .score = 0.5 });
    tk.push(.{ .id = 3, .score = 0.5 }); // should NOT displace — ties keep earliest
    const out = tk.sortedDesc();
    try std.testing.expectEqual(@as(usize, 2), out.len);
    // Both surviving ids come from {1, 2}; id=3 was rejected
    for (out) |r| try std.testing.expect(r.id == 1 or r.id == 2);
}
