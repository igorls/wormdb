//! Distance-metric selector shared by HNSW, NamespaceIndex, and the
//! procedure layer.
//!
//! HNSW is algorithmically defined over a "distance" — smaller is closer.
//! Cosine and dot are similarities (higher = closer), so this module
//! exposes them pre-negated/inverted so the HNSW graph traversal logic
//! stays metric-agnostic:
//!
//!   cosine_dist(a, b) = 1 − cos_sim(a, b)        range [0, 2]
//!   dot_dist(a, b)    = −dot(a, b)                range [−∞, +∞]
//!   l2_dist(a, b)     = ‖a − b‖²                  range [0, +∞]
//!
//! L2-squared is used (not L2) because ranking is monotonic in squared
//! distance and avoids a sqrt per comparison.
//!
//! Note on theory: HNSW's recall guarantees assume a proper metric
//! (triangle inequality). Cosine-distance on L2-normalized vectors and
//! plain L2 both satisfy this. Negated dot product doesn't in general —
//! it works empirically for embedding workloads but offers no theoretical
//! bound. This matches the behavior of industry HNSW implementations
//! (Qdrant, Milvus, etc. all ship dot-product HNSW with the same caveat).

const std = @import("std");
const distance = @import("distance.zig");

/// A distance function — smaller values mean closer. Accepts align(1)
/// slices so callers can pass `distance.bytesToF32` output directly.
pub const DistFn = *const fn (a: []align(1) const f32, b: []align(1) const f32) f32;

pub const Metric = enum {
    cosine,
    dot,
    l2,

    /// Parse a metric name. Returns null for unknown names; callers
    /// typically fall back to `.cosine` for missing/unknown.
    pub fn fromStr(s: []const u8) ?Metric {
        if (std.mem.eql(u8, s, "cosine")) return .cosine;
        if (std.mem.eql(u8, s, "dot")) return .dot;
        if (std.mem.eql(u8, s, "l2")) return .l2;
        return null;
    }

    pub fn name(self: Metric) []const u8 {
        return switch (self) {
            .cosine => "cosine",
            .dot => "dot",
            .l2 => "l2",
        };
    }

    /// Return the distance function for this metric, suitable for use by
    /// the HNSW graph (smaller = closer).
    pub fn distFn(self: Metric) DistFn {
        return switch (self) {
            .cosine => cosine_dist,
            .dot => dot_dist,
            .l2 => l2_dist,
        };
    }

    /// Inline tag-dispatched single-pair distance (smaller = closer).
    /// Avoids indirect function-pointer overhead when the caller switches
    /// once outside a hot loop.
    pub inline fn distSingle(self: Metric, a: []align(1) const f32, b: []align(1) const f32) f32 {
        return switch (self) {
            .cosine => 1.0 - distance.cosine(a, b),
            .dot => -distance.dot(a, b),
            .l2 => distance.l2Squared(a, b),
        };
    }

    /// Inline tag-dispatched single-pair distance assuming inputs are
    /// pre-normalized unit vectors when `self == .cosine` (zero-norm vectors
    /// stored as all-zeros yield `dot = 0` → `dist = 1.0`).
    pub inline fn distSingleUnit(self: Metric, a: []align(1) const f32, b: []align(1) const f32) f32 {
        return switch (self) {
            .cosine => 1.0 - distance.dot(a, b),
            .dot => -distance.dot(a, b),
            .l2 => distance.l2Squared(a, b),
        };
    }

    /// Inline tag-dispatched 4-way batched distance for unaligned slices (smaller = closer).
    pub inline fn distBatch4(self: Metric, q: []align(1) const f32, b: [4][]align(1) const f32) [4]f32 {
        return switch (self) {
            .cosine => blk: {
                const sims = distance.cosineBatch4(q, b);
                break :blk .{ 1.0 - sims[0], 1.0 - sims[1], 1.0 - sims[2], 1.0 - sims[3] };
            },
            .dot => blk: {
                const dots = distance.dotBatch4(q, b);
                break :blk .{ -dots[0], -dots[1], -dots[2], -dots[3] };
            },
            .l2 => distance.l2SquaredBatch4(q, b),
        };
    }

    /// Inline tag-dispatched 4-way batched distance on 32B-aligned, 16-padded
    /// slabs assuming unit-normalized vectors when `self == .cosine`.
    pub inline fn distBatch4AlignedUnit(
        self: Metric,
        q: [*]align(32) const f32,
        b: [4][*]align(32) const f32,
        padded_len: usize,
    ) [4]f32 {
        return switch (self) {
            .cosine => blk: {
                const dots = distance.dotBatch4Aligned(q, b, padded_len);
                break :blk .{ 1.0 - dots[0], 1.0 - dots[1], 1.0 - dots[2], 1.0 - dots[3] };
            },
            .dot => blk: {
                const dots = distance.dotBatch4Aligned(q, b, padded_len);
                break :blk .{ -dots[0], -dots[1], -dots[2], -dots[3] };
            },
            .l2 => distance.l2SquaredBatch4Aligned(q, b, padded_len),
        };
    }

    /// Convert an HNSW distance (smaller = closer) back to a similarity score
    /// (higher = closer), matching `vsearch`'s score convention.
    pub fn distToScore(self: Metric, dist: f32) f32 {
        return switch (self) {
            .cosine => 1.0 - dist,
            .dot => -dist,
            .l2 => 1.0 / (1.0 + @max(@as(f32, 0.0), dist)),
        };
    }
};

pub const cosine_dist: DistFn = cosineDistImpl;
pub const dot_dist: DistFn = dotDistImpl;
pub const l2_dist: DistFn = l2DistImpl;

fn cosineDistImpl(a: []align(1) const f32, b: []align(1) const f32) f32 {
    return 1.0 - distance.cosine(a, b);
}

fn dotDistImpl(a: []align(1) const f32, b: []align(1) const f32) f32 {
    return -distance.dot(a, b);
}

fn l2DistImpl(a: []align(1) const f32, b: []align(1) const f32) f32 {
    return distance.l2Squared(a, b);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

const testing = std.testing;

test "metric: fromStr / name roundtrip" {
    try testing.expectEqual(Metric.cosine, Metric.fromStr("cosine").?);
    try testing.expectEqual(Metric.dot, Metric.fromStr("dot").?);
    try testing.expectEqual(Metric.l2, Metric.fromStr("l2").?);
    try testing.expect(Metric.fromStr("nope") == null);

    try testing.expectEqualStrings("cosine", Metric.cosine.name());
    try testing.expectEqualStrings("dot", Metric.dot.name());
    try testing.expectEqualStrings("l2", Metric.l2.name());
}

test "metric: distFn semantics — lower is closer for identical vectors" {
    const a = [_]f32{ 1, 2, 3 };
    const aa: []align(1) const f32 = @ptrCast(&a);

    const cd = Metric.cosine.distFn()(aa, aa);
    try testing.expectApproxEqAbs(@as(f32, 0), cd, 1e-5);

    const ld = Metric.l2.distFn()(aa, aa);
    try testing.expectApproxEqAbs(@as(f32, 0), ld, 1e-5);

    // Dot product of [1,2,3] with itself is 14 → negated dist = -14.
    const dd = Metric.dot.distFn()(aa, aa);
    try testing.expectApproxEqAbs(@as(f32, -14), dd, 1e-5);
}

test "metric: orthogonal vectors have cosine_dist ≈ 1" {
    const a = [_]f32{ 1, 0, 0 };
    const b = [_]f32{ 0, 1, 0 };
    const aa: []align(1) const f32 = @ptrCast(&a);
    const bb: []align(1) const f32 = @ptrCast(&b);
    try testing.expectApproxEqAbs(@as(f32, 1.0), Metric.cosine.distFn()(aa, bb), 1e-5);
}

test "metric: distToScore conversions and clamping" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), Metric.cosine.distToScore(0.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), Metric.cosine.distToScore(1.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1.0), Metric.cosine.distToScore(2.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 14.0), Metric.dot.distToScore(-14.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), Metric.l2.distToScore(0.0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), Metric.l2.distToScore(-0.5), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.2), Metric.l2.distToScore(4.0), 1e-6);
}

test "metric: distSingle / distBatch4 / distBatch4AlignedUnit parity with distFn" {
    const alloc = testing.allocator;
    const dim: usize = 37;
    const padded = std.mem.alignForward(usize, dim, 16);
    var prng = std.Random.DefaultPrng.init(0x3E72_1C00);
    const rand = prng.random();

    const q = try alloc.alignedAlloc(f32, .@"32", padded);
    defer alloc.free(q);
    @memset(q, 0.0);
    for (0..dim) |i| q[i] = rand.floatNorm(f32);

    const q_unit = try alloc.alignedAlloc(f32, .@"32", padded);
    defer alloc.free(q_unit);
    @memset(q_unit, 0.0);
    _ = distance.normalizeInto(q[0..dim], q_unit[0..dim]);

    var bs: [4][]align(32) f32 = undefined;
    var bs_unit: [4][]align(32) f32 = undefined;
    for (0..4) |k| {
        bs[k] = try alloc.alignedAlloc(f32, .@"32", padded);
        bs_unit[k] = try alloc.alignedAlloc(f32, .@"32", padded);
        @memset(bs[k], 0.0);
        @memset(bs_unit[k], 0.0);
        for (0..dim) |i| bs[k][i] = rand.floatNorm(f32);
        _ = distance.normalizeInto(bs[k][0..dim], bs_unit[k][0..dim]);
    }
    defer for (0..4) |k| {
        alloc.free(bs[k]);
        alloc.free(bs_unit[k]);
    };

    const qa: []align(1) const f32 = @ptrCast(q[0..dim]);
    const b_slices: [4][]align(1) const f32 = .{
        @ptrCast(bs[0][0..dim]),
        @ptrCast(bs[1][0..dim]),
        @ptrCast(bs[2][0..dim]),
        @ptrCast(bs[3][0..dim]),
    };

    inline for ([_]Metric{ .cosine, .dot, .l2 }) |m| {
        const batch = m.distBatch4(qa, b_slices);
        const aligned_batch = if (m == .cosine)
            m.distBatch4AlignedUnit(q_unit.ptr, .{ bs_unit[0].ptr, bs_unit[1].ptr, bs_unit[2].ptr, bs_unit[3].ptr }, padded)
        else
            m.distBatch4AlignedUnit(q.ptr, .{ bs[0].ptr, bs[1].ptr, bs[2].ptr, bs[3].ptr }, padded);

        for (0..4) |k| {
            const ref = m.distFn()(qa, b_slices[k]);
            const tol: f32 = @max(@as(f32, 1e-4), @abs(ref) * 1e-5);
            try testing.expectApproxEqAbs(ref, m.distSingle(qa, b_slices[k]), tol);
            try testing.expectApproxEqAbs(ref, batch[k], tol);
            try testing.expectApproxEqAbs(ref, aligned_batch[k], tol);
            if (m == .cosine) {
                try testing.expectApproxEqAbs(ref, m.distSingleUnit(@ptrCast(q_unit[0..dim]), @ptrCast(bs_unit[k][0..dim])), tol);
            } else {
                try testing.expectApproxEqAbs(ref, m.distSingleUnit(qa, b_slices[k]), tol);
            }
        }
    }
}
