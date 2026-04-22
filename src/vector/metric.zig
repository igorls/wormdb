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
