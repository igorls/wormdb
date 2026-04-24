//! Vector distance functions — SIMD-optimized via Zig @Vector
//!
//! Supports four distance metrics, all operating on raw f32 slices:
//!   - Cosine similarity  (most common for embeddings)
//!   - Dot product         (equivalent to cosine when vectors are normalized)
//!   - Euclidean (L2)      (distance, not similarity — lower is closer)
//!   - Hamming             (for binary-quantized vectors, via popCount)
//!
//! All functions are safe to call with mismatched lengths — they use the
//! minimum of the two input lengths. Degenerate cases (zero-length, zero-norm)
//! return 0.0 rather than NaN.

const std = @import("std");
const math = std.math;

/// SIMD lane width — 8 × f32 = 256 bits (AVX2 baseline).
/// On AVX-512 hardware, LLVM may further auto-widen.
const LANES: usize = 8;
const F32xN = @Vector(LANES, f32);
const ZERO: F32xN = @splat(0.0);

// ╔═══════════════════════════════════════════════════╗
// ║  Cosine Similarity                                 ║
// ╚═══════════════════════════════════════════════════╝

/// Cosine similarity: dot(a,b) / (‖a‖ × ‖b‖)
/// Returns value in [-1.0, 1.0]. Returns 0.0 for zero-length or zero-norm inputs.
///
/// Accepts align(1) slices — vectors recovered from raw byte storage have
/// no guaranteed alignment beyond 1. On x86 the compiler lowers the SIMD
/// loads to `vmovups` (unaligned), which is 0–5% slower than `vmovaps`;
/// on ARM NEON there's no aligned/unaligned distinction.
pub fn cosine(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const len = @min(a.len, b.len);
    if (len == 0) return 0.0;

    var dot_acc: F32xN = ZERO;
    var norm_a_acc: F32xN = ZERO;
    var norm_b_acc: F32xN = ZERO;

    // Vectorized main loop
    const vec_len = len - (len % LANES);
    var i: usize = 0;
    while (i < vec_len) : (i += LANES) {
        const va: F32xN = a[i..][0..LANES].*;
        const vb: F32xN = b[i..][0..LANES].*;
        dot_acc = @mulAdd(F32xN, va, vb, dot_acc);
        norm_a_acc = @mulAdd(F32xN, va, va, norm_a_acc);
        norm_b_acc = @mulAdd(F32xN, vb, vb, norm_b_acc);
    }

    // Horizontal reduce
    var dot_sum = @reduce(.Add, dot_acc);
    var norm_a_sum = @reduce(.Add, norm_a_acc);
    var norm_b_sum = @reduce(.Add, norm_b_acc);

    // Scalar tail
    while (i < len) : (i += 1) {
        dot_sum += a[i] * b[i];
        norm_a_sum += a[i] * a[i];
        norm_b_sum += b[i] * b[i];
    }

    const denom = @sqrt(norm_a_sum) * @sqrt(norm_b_sum);
    if (denom == 0.0) return 0.0;
    return dot_sum / denom;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Dot Product                                       ║
// ╚═══════════════════════════════════════════════════╝

/// Inner (dot) product: Σ a[i] × b[i]
/// Equivalent to cosine similarity when both vectors are L2-normalized.
pub fn dot(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const len = @min(a.len, b.len);
    if (len == 0) return 0.0;

    var acc: F32xN = ZERO;

    const vec_len = len - (len % LANES);
    var i: usize = 0;
    while (i < vec_len) : (i += LANES) {
        const va: F32xN = a[i..][0..LANES].*;
        const vb: F32xN = b[i..][0..LANES].*;
        acc = @mulAdd(F32xN, va, vb, acc);
    }

    var sum = @reduce(.Add, acc);

    while (i < len) : (i += 1) {
        sum += a[i] * b[i];
    }

    return sum;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Euclidean (L2) Distance                           ║
// ╚═══════════════════════════════════════════════════╝

/// Squared Euclidean distance: Σ (a[i] - b[i])²
/// Returns the squared distance (avoids sqrt for ranking — monotonic).
pub fn l2Squared(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const len = @min(a.len, b.len);
    if (len == 0) return 0.0;

    var acc: F32xN = ZERO;

    const vec_len = len - (len % LANES);
    var i: usize = 0;
    while (i < vec_len) : (i += LANES) {
        const va: F32xN = a[i..][0..LANES].*;
        const vb: F32xN = b[i..][0..LANES].*;
        const diff = va - vb;
        acc = @mulAdd(F32xN, diff, diff, acc);
    }

    var sum = @reduce(.Add, acc);

    while (i < len) : (i += 1) {
        const d = a[i] - b[i];
        sum += d * d;
    }

    return sum;
}

/// Euclidean (L2) distance: √(Σ (a[i] - b[i])²)
pub fn l2(a: []align(1) const f32, b: []align(1) const f32) f32 {
    return @sqrt(l2Squared(a, b));
}

// ╔═══════════════════════════════════════════════════╗
// ║  Binary Hamming Distance                           ║
// ╚═══════════════════════════════════════════════════╝

/// Hamming distance between binary-quantized vectors stored as byte arrays.
/// Each bit represents one dimension (sign bit of the original float).
/// Result is the number of differing bits — lower is more similar.
pub fn hamming(a: []const u8, b: []const u8) u32 {
    const len = @min(a.len, b.len);
    var dist: u32 = 0;

    // Process 8 bytes at a time (64 bits) using popCount
    const bulk_len = len - (len % 8);
    var i: usize = 0;
    while (i < bulk_len) : (i += 8) {
        const wa: u64 = @bitCast(a[i..][0..8].*);
        const wb: u64 = @bitCast(b[i..][0..8].*);
        dist += @popCount(wa ^ wb);
    }

    // Byte-level tail
    while (i < len) : (i += 1) {
        dist += @popCount(@as(u8, a[i] ^ b[i]));
    }

    return dist;
}

/// Normalized Hamming similarity: 1.0 - (hamming_distance / total_bits)
/// Returns value in [0.0, 1.0] where 1.0 = identical.
pub fn hammingSimilarity(a: []const u8, b: []const u8) f32 {
    const len = @min(a.len, b.len);
    if (len == 0) return 0.0;
    const total_bits: f32 = @floatFromInt(len * 8);
    const dist: f32 = @floatFromInt(hamming(a, b));
    return 1.0 - (dist / total_bits);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Binary Quantization                               ║
// ╚═══════════════════════════════════════════════════╝

/// Quantize an f32 vector to binary (1 bit per dimension).
/// Each bit is 1 if the corresponding float is >= 0, else 0.
/// Output length: ceil(input.len / 8) bytes.
///
/// Limitation: this is "naive" sign quantization — it only produces a
/// useful signal when the input distribution has components on both sides
/// of zero. Unsigned data (SIFT, TF-IDF, pixel intensities) will collapse
/// to a single hash per value range, making Hamming distance useless as
/// a similarity proxy. For those use cases, see `binaryQuantizeCentered`
/// which subtracts a dataset centroid first (RaBitQ phase 1).
pub fn binaryQuantize(vec: []align(1) const f32, out: []u8) void {
    const byte_count = (vec.len + 7) / 8;
    const actual = @min(byte_count, out.len);

    for (0..actual) |byte_idx| {
        var byte: u8 = 0;
        const base = byte_idx * 8;
        inline for (0..8) |bit| {
            const dim = base + bit;
            if (dim < vec.len and vec[dim] >= 0.0) {
                byte |= (@as(u8, 1) << @intCast(7 - bit));
            }
        }
        out[byte_idx] = byte;
    }
}

/// Centroid-subtracted binary quantization (RaBitQ without rotation).
/// For each dimension: bit = sign(vec[i] - centroid[i]). This ensures
/// the output has a meaningful bit distribution even when `vec` has
/// uniformly-signed components. A fair prefilter for non-centered data
/// like SIFT features.
///
/// `centroid` must be the same length as `vec`. Callers pass the
/// namespace's frozen centroid — see `NamespaceIndex.centroid`.
pub fn binaryQuantizeCentered(
    vec: []align(1) const f32,
    centroid: []align(1) const f32,
    out: []u8,
) void {
    std.debug.assert(centroid.len == vec.len);
    const byte_count = (vec.len + 7) / 8;
    const actual = @min(byte_count, out.len);

    for (0..actual) |byte_idx| {
        var byte: u8 = 0;
        const base = byte_idx * 8;
        inline for (0..8) |bit| {
            const dim = base + bit;
            if (dim < vec.len and (vec[dim] - centroid[dim]) >= 0.0) {
                byte |= (@as(u8, 1) << @intCast(7 - bit));
            }
        }
        out[byte_idx] = byte;
    }
}

/// Returns the number of bytes needed to store a binary-quantized vector.
pub fn binaryQuantizedSize(dimensions: usize) usize {
    return (dimensions + 7) / 8;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Helpers                                           ║
// ╚═══════════════════════════════════════════════════╝

/// Interpret raw bytes (from WormDB value) as an f32 slice.
/// Returns an align(1) slice — the input byte buffer has no alignment
/// guarantee, and the SIMD loads in the distance functions handle
/// unaligned data fine. Returns null if the byte length is 0 or not a
/// multiple of 4.
pub fn bytesToF32(bytes: []const u8) ?[]align(1) const f32 {
    if (bytes.len == 0) return null;
    if (bytes.len % 4 != 0) return null;
    const ptr: [*]align(1) const f32 = @ptrCast(bytes.ptr);
    return ptr[0 .. bytes.len / 4];
}

/// Interpret an f32 slice as raw bytes (for storing in WormDB).
pub fn f32ToBytes(vec: []align(1) const f32) []const u8 {
    const ptr: [*]const u8 = @ptrCast(vec.ptr);
    return ptr[0 .. vec.len * 4];
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

test "cosine: identical vectors" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const result = cosine(&a, &a);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 1e-6);
}

test "cosine: orthogonal vectors" {
    const a = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0, 0.0 };
    const result = cosine(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result, 1e-6);
}

test "cosine: opposite vectors" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ -1.0, -2.0, -3.0 };
    const result = cosine(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), result, 1e-6);
}

test "cosine: empty vectors" {
    const result = cosine(&[_]f32{}, &[_]f32{});
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), result, 1e-6);
}

test "cosine: large vector (exercises SIMD path)" {
    var a: [256]f32 = undefined;
    var b: [256]f32 = undefined;
    for (0..256) |i| {
        a[i] = @floatFromInt(i);
        b[i] = @floatFromInt(i);
    }
    const result = cosine(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result, 1e-5);
}

test "dot: known values" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 5.0, 6.0 };
    const result = dot(&a, &b);
    // 1*4 + 2*5 + 3*6 = 32
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), result, 1e-6);
}

test "l2Squared: known values" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 5.0, 6.0 };
    const result = l2Squared(&a, &b);
    // (3)² + (3)² + (3)² = 27
    try std.testing.expectApproxEqAbs(@as(f32, 27.0), result, 1e-6);
}

test "l2: known values" {
    const a = [_]f32{ 0.0, 0.0 };
    const b = [_]f32{ 3.0, 4.0 };
    const result = l2(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), result, 1e-6);
}

test "binary quantize and hamming" {
    const a = [_]f32{ 1.0, -1.0, 0.5, -0.5, 0.0, 1.0, -1.0, 1.0 };
    const b = [_]f32{ 1.0, 1.0, 0.5, -0.5, 0.0, -1.0, -1.0, 1.0 };

    var qa: [1]u8 = undefined;
    var qb: [1]u8 = undefined;
    binaryQuantize(&a, &qa);
    binaryQuantize(&b, &qb);

    // a bits: 1 0 1 0 1 1 0 1 = 0xAD
    // b bits: 1 1 1 0 1 0 0 1 = 0xE9
    // XOR:    0 1 0 0 0 1 0 0 = 2 bits different
    const dist = hamming(&qa, &qb);
    try std.testing.expectEqual(@as(u32, 2), dist);
}

test "hamming similarity" {
    const a = [_]u8{0xFF};
    const b = [_]u8{0xFF};
    const sim = hammingSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sim, 1e-6);
}

test "bytesToF32 roundtrip" {
    const vec = [_]f32{ 1.0, 2.0, 3.0 };
    const bytes = f32ToBytes(&vec);
    const back = bytesToF32(bytes).?;
    try std.testing.expectEqual(@as(usize, 3), back.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), back[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), back[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), back[2], 1e-6);
}

test "bytesToF32 rejects non-aligned length" {
    const bytes = [_]u8{ 0, 0, 0 }; // 3 bytes — not a multiple of 4
    try std.testing.expect(bytesToF32(&bytes) == null);
}
