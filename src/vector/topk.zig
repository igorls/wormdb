//! Bounded top-K and fixed-capacity heap primitives for vector search.
//!
//! Provides:
//!   - `TopK(T, scoreOf)` — fixed-capacity min-heap retaining the K highest
//!     scores from a stream (O(N log K), zero per-item allocation).
//!   - `BoundedMaxHeap(T, distOf)` — fixed-capacity max-heap retaining the K
//!     smallest distances (root = furthest kept element), using single-pass
//!     `pushOrReplace` (1 siftDown vs push+pop) for HNSW beam search.
//!
//! Both use hole-sifting (1 element move per tree level instead of 3-move swap).

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
            if (self.count < self.buf.len or self.buf.len == 0) return -std.math.inf(f32);
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

            // Full — replace root only if new item strictly beats current min.
            if (scoreOf(item) <= scoreOf(self.buf[0])) return;
            self.buf[0] = item;
            siftDown(self.buf, 0);
        }

        /// Sort the captured items in descending order of score (best first)
        /// and return the populated prefix. Destroys heap invariant — call
        /// at most once per fill cycle.
        pub fn sortedDesc(self: *Self) []T {
            const slice = self.buf[0..self.count];
            // `slice` is already a valid min-heap; extract minimums to the back
            // to sort descending in-place without an extra build-heap pass.
            var end = self.count;
            while (end > 1) {
                end -= 1;
                const min_item = slice[0];
                slice[0] = slice[end];
                slice[end] = min_item;
                siftDown(slice[0..end], 0);
            }
            return slice;
        }

        fn siftUp(heap: []T, start: usize) void {
            const item = heap[start];
            const item_score = scoreOf(item);
            var i = start;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (item_score >= scoreOf(heap[parent])) break;
                heap[i] = heap[parent];
                i = parent;
            }
            heap[i] = item;
        }

        fn siftDown(heap: []T, start: usize) void {
            const n = heap.len;
            const item = heap[start];
            const item_score = scoreOf(item);
            var i = start;
            while (true) {
                const l = 2 * i + 1;
                if (l >= n) break;
                const r = l + 1;
                var smallest = l;
                var smallest_score = scoreOf(heap[l]);
                if (r < n) {
                    const r_score = scoreOf(heap[r]);
                    if (r_score < smallest_score) {
                        smallest = r;
                        smallest_score = r_score;
                    }
                }
                if (item_score <= smallest_score) break;
                heap[i] = heap[smallest];
                i = smallest;
            }
            heap[i] = item;
        }
    };
}

/// Fixed-capacity max-heap over items of type T, ranked by `distOf(T) -> f32`
/// (smaller = closer). Retains up to `buf.len` closest items; root (`buf[0]`)
/// is always the furthest kept item.
///
/// Designed for HNSW's result set `W`: when full, `pushOrReplace` replaces
/// root in a single `siftDown` (half the heap work of `push` + `pop` and no
/// capacity doubling).
pub fn BoundedMaxHeap(
    comptime T: type,
    comptime distOf: fn (T) f32,
) type {
    return struct {
        const Self = @This();

        buf: []T,
        count: usize,

        pub fn init(buf: []T) Self {
            return .{ .buf = buf, .count = 0 };
        }

        pub inline fn reset(self: *Self) void {
            self.count = 0;
        }

        pub inline fn capacity(self: *const Self) usize {
            return self.buf.len;
        }

        pub inline fn len(self: *const Self) usize {
            return self.count;
        }

        pub inline fn isFull(self: *const Self) bool {
            return self.count >= self.buf.len;
        }

        pub inline fn peek(self: *const Self) ?T {
            return if (self.count > 0) self.buf[0] else null;
        }

        pub inline fn items(self: *const Self) []const T {
            return self.buf[0..self.count];
        }

        /// Distance threshold a new item must beat (`d < worstDist()`) to improve
        /// the heap. Returns `+inf` while not yet full so any finite distance qualifies.
        pub inline fn worstDist(self: *const Self) f32 {
            if (self.count < self.buf.len or self.count == 0) return std.math.inf(f32);
            return distOf(self.buf[0]);
        }

        /// Admit `item` if the heap is not yet full, or replace the furthest
        /// kept item if `distOf(item) < distOf(root)`. Single sift pass.
        pub inline fn pushOrReplace(self: *Self, item: T) void {
            if (self.buf.len == 0) return;

            if (self.count < self.buf.len) {
                self.buf[self.count] = item;
                self.count += 1;
                siftUpMax(self.buf[0..self.count], self.count - 1);
                return;
            }

            if (distOf(item) >= distOf(self.buf[0])) return;
            self.buf[0] = item;
            siftDownMax(self.buf, 0);
        }

        /// Remove and return the furthest (maximum-distance) item.
        pub inline fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            const top = self.buf[0];
            self.count -= 1;
            if (self.count > 0) {
                self.buf[0] = self.buf[self.count];
                siftDownMax(self.buf[0..self.count], 0);
            }
            return top;
        }

        /// Sort captured items ascending by distance (closest first) in-place
        /// via direct max-heap extraction. Destroys heap invariant.
        pub fn sortedAsc(self: *Self) []T {
            const slice = self.buf[0..self.count];
            var end = self.count;
            while (end > 1) {
                end -= 1;
                const max_item = slice[0];
                slice[0] = slice[end];
                slice[end] = max_item;
                siftDownMax(slice[0..end], 0);
            }
            return slice;
        }

        fn siftUpMax(heap: []T, start: usize) void {
            const item = heap[start];
            const item_dist = distOf(item);
            var i = start;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (item_dist <= distOf(heap[parent])) break;
                heap[i] = heap[parent];
                i = parent;
            }
            heap[i] = item;
        }

        fn siftDownMax(heap: []T, start: usize) void {
            const n = heap.len;
            const item = heap[start];
            const item_dist = distOf(item);
            var i = start;
            while (true) {
                const l = 2 * i + 1;
                if (l >= n) break;
                const r = l + 1;
                var largest = l;
                var largest_dist = distOf(heap[l]);
                if (r < n) {
                    const r_dist = distOf(heap[r]);
                    if (r_dist > largest_dist) {
                        largest = r;
                        largest_dist = r_dist;
                    }
                }
                if (item_dist >= largest_dist) break;
                heap[i] = heap[largest];
                i = largest;
            }
            heap[i] = item;
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
const BoundedDist = BoundedMaxHeap(Scored, scoreOfScored);

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
    try std.testing.expect(std.math.isNegativeInf(tk.thresholdScore()));
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

test "top-k: thresholdScore and negative scores" {
    var buf: [3]Scored = undefined;
    var tk = TopKScored.init(&buf);

    // Unfilled heap returns -inf
    try std.testing.expect(std.math.isNegativeInf(tk.thresholdScore()));
    tk.push(.{ .id = 1, .score = -10.0 });
    try std.testing.expect(std.math.isNegativeInf(tk.thresholdScore()));
    tk.push(.{ .id = 2, .score = -2.5 });
    try std.testing.expect(std.math.isNegativeInf(tk.thresholdScore()));
    tk.push(.{ .id = 3, .score = -7.0 });

    // Full heap exposes minimum surviving score (-10.0)
    try std.testing.expectApproxEqAbs(@as(f32, -10.0), tk.thresholdScore(), 1e-6);

    // Worse negative score is ignored; threshold unchanged
    tk.push(.{ .id = 4, .score = -15.0 });
    try std.testing.expectApproxEqAbs(@as(f32, -10.0), tk.thresholdScore(), 1e-6);

    // Better negative score displaces -10.0; threshold rises to -7.0
    tk.push(.{ .id = 5, .score = -1.0 });
    try std.testing.expectApproxEqAbs(@as(f32, -7.0), tk.thresholdScore(), 1e-6);

    // Another better score displaces -7.0; threshold rises to -2.5
    tk.push(.{ .id = 6, .score = -0.25 });
    try std.testing.expectApproxEqAbs(@as(f32, -2.5), tk.thresholdScore(), 1e-6);

    const out = tk.sortedDesc();
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqual(@as(u32, 6), out[0].id);
    try std.testing.expectEqual(@as(u32, 5), out[1].id);
    try std.testing.expectEqual(@as(u32, 2), out[2].id);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), out[0].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), out[1].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2.5), out[2].score, 1e-6);
}

test "bounded max-heap: retains smallest K distances and sorts ascending" {
    var buf: [4]Scored = undefined;
    var h = BoundedDist.init(&buf);

    try std.testing.expect(std.math.isPositiveInf(h.worstDist()));
    const vals = [_]f32{ 5.0, -1.0, 2.0, 0.5, -3.5, 4.0, 0.0, -2.0, 10.0 };
    for (vals, 0..) |v, i| {
        h.pushOrReplace(.{ .id = @intCast(i), .score = v });
    }
    try std.testing.expectEqual(@as(usize, 4), h.len());
    // Four smallest from vals are {-3.5, -2.0, -1.0, 0.0} -> worst kept is 0.0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), h.worstDist(), 1e-6);

    // Equal or larger than worstDist does not displace
    h.pushOrReplace(.{ .id = 99, .score = 0.0 });
    h.pushOrReplace(.{ .id = 100, .score = 9.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), h.worstDist(), 1e-6);

    const sorted = h.sortedAsc();
    try std.testing.expectEqual(@as(usize, 4), sorted.len);
    try std.testing.expectApproxEqAbs(@as(f32, -3.5), sorted[0].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), sorted[1].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), sorted[2].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sorted[3].score, 1e-6);

    // Also verify pop() yields descending (furthest first)
    h.reset();
    h.pushOrReplace(.{ .id = 1, .score = 2.0 });
    h.pushOrReplace(.{ .id = 2, .score = -1.0 });
    h.pushOrReplace(.{ .id = 3, .score = 0.5 });
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), h.pop().?.score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), h.pop().?.score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), h.pop().?.score, 1e-6);
    try std.testing.expect(h.pop() == null);
}
