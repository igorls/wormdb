//! Vector distance functions — target-adaptive SIMD via Zig @Vector
//!
//! Supports four distance metrics, all operating on raw f32 slices:
//!   - Cosine similarity  (most common for embeddings)
//!   - Dot product        (equivalent to cosine when vectors are normalized)
//!   - Euclidean (L2)     (distance, not similarity — lower is closer)
//!   - Hamming            (for binary-quantized vectors, via popCount)
//!
//! Target-adaptive lane selection:
//!   - x86_64 AVX-512F:          16 × f32 (512-bit ZMM) + VPOPCNTDQ 64B Hamming
//!   - x86_64 AVX/AVX2:           8 × f32 (256-bit YMM)
//!   - aarch64 NEON / x86 SSE2 /
//!     wasm32+simd128:            4 × f32 (128-bit) + NEON 16B cnt Hamming
//!   - wasm32 scalar:             1 × f32 (zero software-fmaf libcalls)
//!
//! All unaligned functions are safe to call with mismatched lengths — they use
//! the minimum of the two input lengths. Degenerate cases (zero-length,
//! zero-norm) return 0.0 rather than NaN.

const std = @import("std");
const builtin = @import("builtin");
const math = std.math;

/// Target-adaptive f32 SIMD lane width.
pub const SIMD_LANES: usize = blk: {
    const arch = builtin.cpu.arch;
    if (arch == .x86_64 or arch == .x86) {
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f)) break :blk 16;
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx)) break :blk 8;
        break :blk 4;
    }
    if (arch == .aarch64 or arch == .aarch64_be) break :blk 4;
    if (arch.isWasm()) {
        break :blk if (std.Target.wasm.featureSetHas(builtin.cpu.features, .simd128)) 4 else 1;
    }
    break :blk std.simd.suggestVectorLength(f32) orelse 4;
};

const has_hw_fma: bool = switch (builtin.cpu.arch) {
    .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
    .aarch64, .aarch64_be => true,
    else => false,
};

const has_avx512f: bool = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f);

const has_avx512_vpopcntdq: bool = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vpopcntdq);

const has_avx512vl: bool = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vl);

const is_aarch64: bool = (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .aarch64_be);

const F32xN = @Vector(SIMD_LANES, f32);
const ZERO: F32xN = @splat(0.0);

/// Fused multiply-add gated on hardware FMA availability.
/// Avoids LLVM lowering `@mulAdd` on vector types to per-lane libc `fmaf` calls
/// on x86_64 baseline (SSE2) and wasm32-wasi.
pub inline fn fmaddVec(
    comptime N: usize,
    a: @Vector(N, f32),
    b: @Vector(N, f32),
    c: @Vector(N, f32),
) @Vector(N, f32) {
    return if (comptime has_hw_fma) @mulAdd(@Vector(N, f32), a, b, c) else a * b + c;
}

inline fn fmadd(a: F32xN, b: F32xN, c: F32xN) F32xN {
    return fmaddVec(SIMD_LANES, a, b, c);
}

inline fn clampUnit(v: f32) f32 {
    return @max(@as(f32, -1.0), @min(@as(f32, 1.0), v));
}

/// Comptime 256-entry bit-reversal LUT for MSB-first binary quantization packing.
/// Eliminates LLVM's AVX-512 mask-register ↔ YMM shuffle round-trip on `@bitReverse`.
pub const BITREV_LUT: [256]u8 = blk: {
    var table: [256]u8 = undefined;
    for (0..256) |i| {
        table[i] = @bitReverse(@as(u8, @intCast(i)));
    }
    break :blk table;
};

// ╔═══════════════════════════════════════════════════╗
// ║  Norm & Unit Normalization                         ║
// ╚═══════════════════════════════════════════════════╝

/// Euclidean (L2) norm: √(Σ v[i]²). Returns 0.0 for empty input.
pub fn l2Norm(v: []align(1) const f32) f32 {
    const len = v.len;
    if (len == 0) return 0.0;

    var acc0: F32xN = ZERO;
    var acc1: F32xN = ZERO;
    var acc2: F32xN = ZERO;
    var acc3: F32xN = ZERO;

    var i: usize = 0;
    const step4 = SIMD_LANES * 4;
    const vec4_len = len - (len % step4);
    while (i < vec4_len) : (i += step4) {
        const v0: F32xN = v[i..][0..SIMD_LANES].*;
        const v1: F32xN = v[i + SIMD_LANES ..][0..SIMD_LANES].*;
        const v2: F32xN = v[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*;
        const v3: F32xN = v[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*;
        acc0 = fmadd(v0, v0, acc0);
        acc1 = fmadd(v1, v1, acc1);
        acc2 = fmadd(v2, v2, acc2);
        acc3 = fmadd(v3, v3, acc3);
    }

    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        const vx: F32xN = v[i..][0..SIMD_LANES].*;
        acc0 = fmadd(vx, vx, acc0);
    }

    var sum_sq = @reduce(.Add, (acc0 + acc1) + (acc2 + acc3));

    if (comptime SIMD_LANES > 4) {
        var sub_acc: @Vector(4, f32) = @splat(0.0);
        while (i + 4 <= len) : (i += 4) {
            const vs: @Vector(4, f32) = v[i..][0..4].*;
            sub_acc = fmaddVec(4, vs, vs, sub_acc);
        }
        sum_sq += @reduce(.Add, sub_acc);
    }

    while (i < len) : (i += 1) {
        const x = v[i];
        sum_sq += x * x;
    }

    return @sqrt(sum_sq);
}

/// L2-normalize `src` into `dst` (same length).
/// Returns the original L2 norm. If `src` is zero-norm (or subnormal such that
/// `1/norm` is non-finite), zero-fills `dst` and returns 0.0 (never produces NaN/Inf).
pub fn normalizeInto(src: []align(1) const f32, dst: []f32) f32 {
    std.debug.assert(src.len == dst.len);
    const len = src.len;
    if (len == 0) return 0.0;

    const norm = l2Norm(src);
    if (!(norm > 0.0)) {
        @memset(dst, 0.0);
        return 0.0;
    }
    const inv = 1.0 / norm;
    if (!math.isFinite(inv)) {
        @memset(dst, 0.0);
        return 0.0;
    }

    const inv_v: F32xN = @splat(inv);
    var i: usize = 0;
    const step4 = SIMD_LANES * 4;
    const vec4_len = len - (len % step4);
    while (i < vec4_len) : (i += step4) {
        dst[i..][0..SIMD_LANES].* = @as(F32xN, src[i..][0..SIMD_LANES].*) * inv_v;
        dst[i + SIMD_LANES ..][0..SIMD_LANES].* = @as(F32xN, src[i + SIMD_LANES ..][0..SIMD_LANES].*) * inv_v;
        dst[i + SIMD_LANES * 2 ..][0..SIMD_LANES].* = @as(F32xN, src[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*) * inv_v;
        dst[i + SIMD_LANES * 3 ..][0..SIMD_LANES].* = @as(F32xN, src[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*) * inv_v;
    }
    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        dst[i..][0..SIMD_LANES].* = @as(F32xN, src[i..][0..SIMD_LANES].*) * inv_v;
    }
    while (i < len) : (i += 1) {
        dst[i] = src[i] * inv;
    }
    return norm;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Cosine Similarity                                 ║
// ╚═══════════════════════════════════════════════════╝

/// Cosine similarity: dot(a,b) / (‖a‖ × ‖b‖)
/// Returns value in [-1.0, 1.0]. Returns 0.0 for zero-length or zero-norm inputs.
///
/// Accepts align(1) slices — vectors recovered from raw byte storage have
/// no guaranteed alignment beyond 1.
pub fn cosine(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const len = @min(a.len, b.len);
    if (len == 0) return 0.0;

    var dot0: F32xN = ZERO;
    var dot1: F32xN = ZERO;
    var na0: F32xN = ZERO;
    var na1: F32xN = ZERO;
    var nb0: F32xN = ZERO;
    var nb1: F32xN = ZERO;

    var i: usize = 0;
    const step2 = SIMD_LANES * 2;
    const vec2_len = len - (len % step2);
    while (i < vec2_len) : (i += step2) {
        const va0: F32xN = a[i..][0..SIMD_LANES].*;
        const vb0: F32xN = b[i..][0..SIMD_LANES].*;
        const va1: F32xN = a[i + SIMD_LANES ..][0..SIMD_LANES].*;
        const vb1: F32xN = b[i + SIMD_LANES ..][0..SIMD_LANES].*;
        dot0 = fmadd(va0, vb0, dot0);
        dot1 = fmadd(va1, vb1, dot1);
        na0 = fmadd(va0, va0, na0);
        na1 = fmadd(va1, va1, na1);
        nb0 = fmadd(vb0, vb0, nb0);
        nb1 = fmadd(vb1, vb1, nb1);
    }

    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        const va: F32xN = a[i..][0..SIMD_LANES].*;
        const vb: F32xN = b[i..][0..SIMD_LANES].*;
        dot0 = fmadd(va, vb, dot0);
        na0 = fmadd(va, va, na0);
        nb0 = fmadd(vb, vb, nb0);
    }

    var dot_sum = @reduce(.Add, dot0 + dot1);
    var norm_a_sum = @reduce(.Add, na0 + na1);
    var norm_b_sum = @reduce(.Add, nb0 + nb1);

    if (comptime SIMD_LANES > 4) {
        var sd: @Vector(4, f32) = @splat(0.0);
        var sna: @Vector(4, f32) = @splat(0.0);
        var snb: @Vector(4, f32) = @splat(0.0);
        while (i + 4 <= len) : (i += 4) {
            const va: @Vector(4, f32) = a[i..][0..4].*;
            const vb: @Vector(4, f32) = b[i..][0..4].*;
            sd = fmaddVec(4, va, vb, sd);
            sna = fmaddVec(4, va, va, sna);
            snb = fmaddVec(4, vb, vb, snb);
        }
        dot_sum += @reduce(.Add, sd);
        norm_a_sum += @reduce(.Add, sna);
        norm_b_sum += @reduce(.Add, snb);
    }

    while (i < len) : (i += 1) {
        const xa = a[i];
        const xb = b[i];
        dot_sum += xa * xb;
        norm_a_sum += xa * xa;
        norm_b_sum += xb * xb;
    }

    const denom = @sqrt(norm_a_sum) * @sqrt(norm_b_sum);
    if (!(denom > 0.0)) return 0.0;
    return clampUnit(dot_sum / denom);
}

/// Cosine similarity when `inv_q_norm = 1.0 / l2Norm(q)` is already computed once
/// per query. Eliminates query norm accumulation and one `@sqrt` per candidate.
/// Pass `inv_q_norm = 0.0` for a zero-norm query (returns 0.0).
pub fn cosineWithQueryNorm(q: []align(1) const f32, inv_q_norm: f32, b: []align(1) const f32) f32 {
    const len = @min(q.len, b.len);
    if (len == 0 or !(inv_q_norm > 0.0)) return 0.0;

    var dot0: F32xN = ZERO;
    var dot1: F32xN = ZERO;
    var nb0: F32xN = ZERO;
    var nb1: F32xN = ZERO;

    var i: usize = 0;
    const step2 = SIMD_LANES * 2;
    const vec2_len = len - (len % step2);
    while (i < vec2_len) : (i += step2) {
        const vq0: F32xN = q[i..][0..SIMD_LANES].*;
        const vb0: F32xN = b[i..][0..SIMD_LANES].*;
        const vq1: F32xN = q[i + SIMD_LANES ..][0..SIMD_LANES].*;
        const vb1: F32xN = b[i + SIMD_LANES ..][0..SIMD_LANES].*;
        dot0 = fmadd(vq0, vb0, dot0);
        dot1 = fmadd(vq1, vb1, dot1);
        nb0 = fmadd(vb0, vb0, nb0);
        nb1 = fmadd(vb1, vb1, nb1);
    }

    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        const vq: F32xN = q[i..][0..SIMD_LANES].*;
        const vb: F32xN = b[i..][0..SIMD_LANES].*;
        dot0 = fmadd(vq, vb, dot0);
        nb0 = fmadd(vb, vb, nb0);
    }

    var dot_sum = @reduce(.Add, dot0 + dot1);
    var norm_b_sum = @reduce(.Add, nb0 + nb1);

    if (comptime SIMD_LANES > 4) {
        var sd: @Vector(4, f32) = @splat(0.0);
        var snb: @Vector(4, f32) = @splat(0.0);
        while (i + 4 <= len) : (i += 4) {
            const vq: @Vector(4, f32) = q[i..][0..4].*;
            const vb: @Vector(4, f32) = b[i..][0..4].*;
            sd = fmaddVec(4, vq, vb, sd);
            snb = fmaddVec(4, vb, vb, snb);
        }
        dot_sum += @reduce(.Add, sd);
        norm_b_sum += @reduce(.Add, snb);
    }

    while (i < len) : (i += 1) {
        const xb = b[i];
        dot_sum += q[i] * xb;
        norm_b_sum += xb * xb;
    }

    const norm_b = @sqrt(norm_b_sum);
    if (!(norm_b > 0.0)) return 0.0;
    return clampUnit((dot_sum * inv_q_norm) / norm_b);
}

/// Alias matching index-vsearch-scout naming ergonomics.
pub const cosineWithPrecomputedNorm = cosineWithQueryNorm;

/// 4-way batched cosine similarity with precomputed `inv_q_norm = 1.0 / l2Norm(q)`.
/// Loads `q` once across all 4 candidates. Safe for mismatched lengths.
pub fn cosineWithQueryNormBatch4(
    q: []align(1) const f32,
    inv_q_norm: f32,
    b: [4][]align(1) const f32,
) [4]f32 {
    const len = q.len;
    if (len == 0 or !(inv_q_norm > 0.0)) return .{ 0.0, 0.0, 0.0, 0.0 };

    if (b[0].len != len or b[1].len != len or b[2].len != len or b[3].len != len) {
        return .{
            cosineWithQueryNorm(q, inv_q_norm, b[0]),
            cosineWithQueryNorm(q, inv_q_norm, b[1]),
            cosineWithQueryNorm(q, inv_q_norm, b[2]),
            cosineWithQueryNorm(q, inv_q_norm, b[3]),
        };
    }

    const b0 = b[0];
    const b1 = b[1];
    const b2 = b[2];
    const b3 = b[3];

    var d0: F32xN = ZERO;
    var d1: F32xN = ZERO;
    var d2: F32xN = ZERO;
    var d3: F32xN = ZERO;
    var n0: F32xN = ZERO;
    var n1: F32xN = ZERO;
    var n2: F32xN = ZERO;
    var n3: F32xN = ZERO;

    var i: usize = 0;
    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        const vq: F32xN = q[i..][0..SIMD_LANES].*;
        const vb0: F32xN = b0[i..][0..SIMD_LANES].*;
        const vb1: F32xN = b1[i..][0..SIMD_LANES].*;
        const vb2: F32xN = b2[i..][0..SIMD_LANES].*;
        const vb3: F32xN = b3[i..][0..SIMD_LANES].*;
        d0 = fmadd(vq, vb0, d0);
        d1 = fmadd(vq, vb1, d1);
        d2 = fmadd(vq, vb2, d2);
        d3 = fmadd(vq, vb3, d3);
        n0 = fmadd(vb0, vb0, n0);
        n1 = fmadd(vb1, vb1, n1);
        n2 = fmadd(vb2, vb2, n2);
        n3 = fmadd(vb3, vb3, n3);
    }

    var ds: [4]f32 = .{
        @reduce(.Add, d0),
        @reduce(.Add, d1),
        @reduce(.Add, d2),
        @reduce(.Add, d3),
    };
    var ns: [4]f32 = .{
        @reduce(.Add, n0),
        @reduce(.Add, n1),
        @reduce(.Add, n2),
        @reduce(.Add, n3),
    };

    while (i < len) : (i += 1) {
        const xq = q[i];
        const x0 = b0[i];
        const x1 = b1[i];
        const x2 = b2[i];
        const x3 = b3[i];
        ds[0] += xq * x0;
        ds[1] += xq * x1;
        ds[2] += xq * x2;
        ds[3] += xq * x3;
        ns[0] += x0 * x0;
        ns[1] += x1 * x1;
        ns[2] += x2 * x2;
        ns[3] += x3 * x3;
    }

    var out: [4]f32 = undefined;
    inline for (0..4) |k| {
        const nb = @sqrt(ns[k]);
        out[k] = if (nb > 0.0) clampUnit((ds[k] * inv_q_norm) / nb) else 0.0;
    }
    return out;
}

/// 4-way batched cosine similarity (computes query norm once for all 4 candidates).
pub fn cosineBatch4(q: []align(1) const f32, b: [4][]align(1) const f32) [4]f32 {
    if (q.len == 0) return .{ 0.0, 0.0, 0.0, 0.0 };
    if (b[0].len != q.len or b[1].len != q.len or b[2].len != q.len or b[3].len != q.len) {
        return .{
            cosine(q, b[0]),
            cosine(q, b[1]),
            cosine(q, b[2]),
            cosine(q, b[3]),
        };
    }
    const qn = l2Norm(q);
    if (!(qn > 0.0)) return .{ 0.0, 0.0, 0.0, 0.0 };
    const inv_q = 1.0 / qn;
    if (!math.isFinite(inv_q)) return .{ 0.0, 0.0, 0.0, 0.0 };
    return cosineWithQueryNormBatch4(q, inv_q, b);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Dot Product                                       ║
// ╚═══════════════════════════════════════════════════╝

/// Inner (dot) product: Σ a[i] × b[i]
/// Equivalent to cosine similarity when both vectors are L2-normalized.
pub fn dot(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const len = @min(a.len, b.len);
    if (len == 0) return 0.0;

    var acc0: F32xN = ZERO;
    var acc1: F32xN = ZERO;
    var acc2: F32xN = ZERO;
    var acc3: F32xN = ZERO;

    var i: usize = 0;
    const step4 = SIMD_LANES * 4;
    const vec4_len = len - (len % step4);
    while (i < vec4_len) : (i += step4) {
        const va0: F32xN = a[i..][0..SIMD_LANES].*;
        const vb0: F32xN = b[i..][0..SIMD_LANES].*;
        const va1: F32xN = a[i + SIMD_LANES ..][0..SIMD_LANES].*;
        const vb1: F32xN = b[i + SIMD_LANES ..][0..SIMD_LANES].*;
        const va2: F32xN = a[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*;
        const vb2: F32xN = b[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*;
        const va3: F32xN = a[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*;
        const vb3: F32xN = b[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*;
        acc0 = fmadd(va0, vb0, acc0);
        acc1 = fmadd(va1, vb1, acc1);
        acc2 = fmadd(va2, vb2, acc2);
        acc3 = fmadd(va3, vb3, acc3);
    }

    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        const va: F32xN = a[i..][0..SIMD_LANES].*;
        const vb: F32xN = b[i..][0..SIMD_LANES].*;
        acc0 = fmadd(va, vb, acc0);
    }

    var sum = @reduce(.Add, (acc0 + acc1) + (acc2 + acc3));

    if (comptime SIMD_LANES > 4) {
        var sub_acc: @Vector(4, f32) = @splat(0.0);
        while (i + 4 <= len) : (i += 4) {
            const va: @Vector(4, f32) = a[i..][0..4].*;
            const vb: @Vector(4, f32) = b[i..][0..4].*;
            sub_acc = fmaddVec(4, va, vb, sub_acc);
        }
        sum += @reduce(.Add, sub_acc);
    }

    while (i < len) : (i += 1) {
        sum += a[i] * b[i];
    }

    return sum;
}

/// Padded-aligned single-pair dot product for flat vector slabs.
/// Precondition: `padded_len % 16 == 0`, tail `[dim..padded_len]` is zero-filled.
pub fn dotAligned(
    a: [*]align(32) const f32,
    b: [*]align(32) const f32,
    padded_len: usize,
) f32 {
    std.debug.assert(padded_len % 16 == 0);
    if (padded_len == 0) return 0.0;

    var acc0: F32xN = ZERO;
    var acc1: F32xN = ZERO;
    var acc2: F32xN = ZERO;
    var acc3: F32xN = ZERO;

    var i: usize = 0;
    const step4 = SIMD_LANES * 4;
    const vec4_len = padded_len - (padded_len % step4);
    while (i < vec4_len) : (i += step4) {
        acc0 = fmadd(a[i..][0..SIMD_LANES].*, b[i..][0..SIMD_LANES].*, acc0);
        acc1 = fmadd(a[i + SIMD_LANES ..][0..SIMD_LANES].*, b[i + SIMD_LANES ..][0..SIMD_LANES].*, acc1);
        acc2 = fmadd(a[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*, b[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*, acc2);
        acc3 = fmadd(a[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*, b[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*, acc3);
    }

    if (comptime SIMD_LANES > 4) {
        while (i < padded_len) : (i += SIMD_LANES) {
            acc0 = fmadd(a[i..][0..SIMD_LANES].*, b[i..][0..SIMD_LANES].*, acc0);
        }
    }

    return @reduce(.Add, (acc0 + acc1) + (acc2 + acc3));
}

/// 4-way batched dot product on 32B-aligned, 16-padded vector slabs.
/// Loads `q` once per 4 candidates and runs 8 independent FMA chains (2× unrolled)
/// to saturate dual FMA ports while overlapping 4 cache-miss streams.
pub fn dotBatch4Aligned(
    q: [*]align(32) const f32,
    b: [4][*]align(32) const f32,
    padded_len: usize,
) [4]f32 {
    std.debug.assert(padded_len % 16 == 0);
    if (padded_len == 0) return .{ 0.0, 0.0, 0.0, 0.0 };

    const b0 = b[0];
    const b1 = b[1];
    const b2 = b[2];
    const b3 = b[3];

    var a0: F32xN = ZERO;
    var a1: F32xN = ZERO;
    var a2: F32xN = ZERO;
    var a3: F32xN = ZERO;
    var c0: F32xN = ZERO;
    var c1: F32xN = ZERO;
    var c2: F32xN = ZERO;
    var c3: F32xN = ZERO;

    var i: usize = 0;
    const step2 = SIMD_LANES * 2;
    const vec2_len = padded_len - (padded_len % step2);
    while (i < vec2_len) : (i += step2) {
        const q0: F32xN = q[i..][0..SIMD_LANES].*;
        a0 = fmadd(q0, b0[i..][0..SIMD_LANES].*, a0);
        a1 = fmadd(q0, b1[i..][0..SIMD_LANES].*, a1);
        a2 = fmadd(q0, b2[i..][0..SIMD_LANES].*, a2);
        a3 = fmadd(q0, b3[i..][0..SIMD_LANES].*, a3);

        const q1: F32xN = q[i + SIMD_LANES ..][0..SIMD_LANES].*;
        c0 = fmadd(q1, b0[i + SIMD_LANES ..][0..SIMD_LANES].*, c0);
        c1 = fmadd(q1, b1[i + SIMD_LANES ..][0..SIMD_LANES].*, c1);
        c2 = fmadd(q1, b2[i + SIMD_LANES ..][0..SIMD_LANES].*, c2);
        c3 = fmadd(q1, b3[i + SIMD_LANES ..][0..SIMD_LANES].*, c3);
    }

    if (comptime SIMD_LANES == 16) {
        if (i < padded_len) {
            const q0: F32xN = q[i..][0..SIMD_LANES].*;
            a0 = fmadd(q0, b0[i..][0..SIMD_LANES].*, a0);
            a1 = fmadd(q0, b1[i..][0..SIMD_LANES].*, a1);
            a2 = fmadd(q0, b2[i..][0..SIMD_LANES].*, a2);
            a3 = fmadd(q0, b3[i..][0..SIMD_LANES].*, a3);
        }
    }

    return .{
        @reduce(.Add, a0 + c0),
        @reduce(.Add, a1 + c1),
        @reduce(.Add, a2 + c2),
        @reduce(.Add, a3 + c3),
    };
}

/// 4-way batched dot product for unaligned slices. Safe for mismatched lengths.
pub fn dotBatch4(q: []align(1) const f32, b: [4][]align(1) const f32) [4]f32 {
    const len = q.len;
    if (len == 0) return .{ 0.0, 0.0, 0.0, 0.0 };

    if (b[0].len != len or b[1].len != len or b[2].len != len or b[3].len != len) {
        return .{
            dot(q, b[0]),
            dot(q, b[1]),
            dot(q, b[2]),
            dot(q, b[3]),
        };
    }

    const b0 = b[0];
    const b1 = b[1];
    const b2 = b[2];
    const b3 = b[3];

    var a0: F32xN = ZERO;
    var a1: F32xN = ZERO;
    var a2: F32xN = ZERO;
    var a3: F32xN = ZERO;
    var c0: F32xN = ZERO;
    var c1: F32xN = ZERO;
    var c2: F32xN = ZERO;
    var c3: F32xN = ZERO;

    var i: usize = 0;
    const step2 = SIMD_LANES * 2;
    const vec2_len = len - (len % step2);
    while (i < vec2_len) : (i += step2) {
        const q0: F32xN = q[i..][0..SIMD_LANES].*;
        a0 = fmadd(q0, b0[i..][0..SIMD_LANES].*, a0);
        a1 = fmadd(q0, b1[i..][0..SIMD_LANES].*, a1);
        a2 = fmadd(q0, b2[i..][0..SIMD_LANES].*, a2);
        a3 = fmadd(q0, b3[i..][0..SIMD_LANES].*, a3);

        const q1: F32xN = q[i + SIMD_LANES ..][0..SIMD_LANES].*;
        c0 = fmadd(q1, b0[i + SIMD_LANES ..][0..SIMD_LANES].*, c0);
        c1 = fmadd(q1, b1[i + SIMD_LANES ..][0..SIMD_LANES].*, c1);
        c2 = fmadd(q1, b2[i + SIMD_LANES ..][0..SIMD_LANES].*, c2);
        c3 = fmadd(q1, b3[i + SIMD_LANES ..][0..SIMD_LANES].*, c3);
    }

    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        const q0: F32xN = q[i..][0..SIMD_LANES].*;
        a0 = fmadd(q0, b0[i..][0..SIMD_LANES].*, a0);
        a1 = fmadd(q0, b1[i..][0..SIMD_LANES].*, a1);
        a2 = fmadd(q0, b2[i..][0..SIMD_LANES].*, a2);
        a3 = fmadd(q0, b3[i..][0..SIMD_LANES].*, a3);
    }

    var out: [4]f32 = .{
        @reduce(.Add, a0 + c0),
        @reduce(.Add, a1 + c1),
        @reduce(.Add, a2 + c2),
        @reduce(.Add, a3 + c3),
    };

    while (i < len) : (i += 1) {
        const xq = q[i];
        out[0] += xq * b0[i];
        out[1] += xq * b1[i];
        out[2] += xq * b2[i];
        out[3] += xq * b3[i];
    }

    return out;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Euclidean (L2) Distance                           ║
// ╚═══════════════════════════════════════════════════╝

/// Squared Euclidean distance: Σ (a[i] - b[i])²
/// Returns the squared distance (avoids sqrt for ranking — monotonic, immune
/// to catastrophic cancellation when a ≈ b).
pub fn l2Squared(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const len = @min(a.len, b.len);
    if (len == 0) return 0.0;

    var acc0: F32xN = ZERO;
    var acc1: F32xN = ZERO;
    var acc2: F32xN = ZERO;
    var acc3: F32xN = ZERO;

    var i: usize = 0;
    const step4 = SIMD_LANES * 4;
    const vec4_len = len - (len % step4);
    while (i < vec4_len) : (i += step4) {
        const d0 = @as(F32xN, a[i..][0..SIMD_LANES].*) - @as(F32xN, b[i..][0..SIMD_LANES].*);
        const d1 = @as(F32xN, a[i + SIMD_LANES ..][0..SIMD_LANES].*) - @as(F32xN, b[i + SIMD_LANES ..][0..SIMD_LANES].*);
        const d2 = @as(F32xN, a[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*) - @as(F32xN, b[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*);
        const d3 = @as(F32xN, a[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*) - @as(F32xN, b[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*);
        acc0 = fmadd(d0, d0, acc0);
        acc1 = fmadd(d1, d1, acc1);
        acc2 = fmadd(d2, d2, acc2);
        acc3 = fmadd(d3, d3, acc3);
    }

    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        const diff = @as(F32xN, a[i..][0..SIMD_LANES].*) - @as(F32xN, b[i..][0..SIMD_LANES].*);
        acc0 = fmadd(diff, diff, acc0);
    }

    var sum = @reduce(.Add, (acc0 + acc1) + (acc2 + acc3));

    if (comptime SIMD_LANES > 4) {
        var sub_acc: @Vector(4, f32) = @splat(0.0);
        while (i + 4 <= len) : (i += 4) {
            const ds = @as(@Vector(4, f32), a[i..][0..4].*) - @as(@Vector(4, f32), b[i..][0..4].*);
            sub_acc = fmaddVec(4, ds, ds, sub_acc);
        }
        sum += @reduce(.Add, sub_acc);
    }

    while (i < len) : (i += 1) {
        const d = a[i] - b[i];
        sum += d * d;
    }

    return sum;
}

/// Padded-aligned single-pair squared L2 distance for flat vector slabs.
/// Precondition: `padded_len % 16 == 0`, tail `[dim..padded_len]` is zero-filled.
pub fn l2SquaredAligned(
    a: [*]align(32) const f32,
    b: [*]align(32) const f32,
    padded_len: usize,
) f32 {
    std.debug.assert(padded_len % 16 == 0);
    if (padded_len == 0) return 0.0;

    var acc0: F32xN = ZERO;
    var acc1: F32xN = ZERO;
    var acc2: F32xN = ZERO;
    var acc3: F32xN = ZERO;

    var i: usize = 0;
    const step4 = SIMD_LANES * 4;
    const vec4_len = padded_len - (padded_len % step4);
    while (i < vec4_len) : (i += step4) {
        const d0 = @as(F32xN, a[i..][0..SIMD_LANES].*) - @as(F32xN, b[i..][0..SIMD_LANES].*);
        const d1 = @as(F32xN, a[i + SIMD_LANES ..][0..SIMD_LANES].*) - @as(F32xN, b[i + SIMD_LANES ..][0..SIMD_LANES].*);
        const d2 = @as(F32xN, a[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*) - @as(F32xN, b[i + SIMD_LANES * 2 ..][0..SIMD_LANES].*);
        const d3 = @as(F32xN, a[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*) - @as(F32xN, b[i + SIMD_LANES * 3 ..][0..SIMD_LANES].*);
        acc0 = fmadd(d0, d0, acc0);
        acc1 = fmadd(d1, d1, acc1);
        acc2 = fmadd(d2, d2, acc2);
        acc3 = fmadd(d3, d3, acc3);
    }

    if (comptime SIMD_LANES > 4) {
        while (i < padded_len) : (i += SIMD_LANES) {
            const diff = @as(F32xN, a[i..][0..SIMD_LANES].*) - @as(F32xN, b[i..][0..SIMD_LANES].*);
            acc0 = fmadd(diff, diff, acc0);
        }
    }

    return @reduce(.Add, (acc0 + acc1) + (acc2 + acc3));
}

/// 4-way batched squared L2 distance on 32B-aligned, 16-padded vector slabs.
/// Uses exact `(q - b)²` per coordinate (zero cancellation when `q ≈ b`).
pub fn l2SquaredBatch4Aligned(
    q: [*]align(32) const f32,
    b: [4][*]align(32) const f32,
    padded_len: usize,
) [4]f32 {
    std.debug.assert(padded_len % 16 == 0);
    if (padded_len == 0) return .{ 0.0, 0.0, 0.0, 0.0 };

    const b0 = b[0];
    const b1 = b[1];
    const b2 = b[2];
    const b3 = b[3];

    var a0: F32xN = ZERO;
    var a1: F32xN = ZERO;
    var a2: F32xN = ZERO;
    var a3: F32xN = ZERO;
    var c0: F32xN = ZERO;
    var c1: F32xN = ZERO;
    var c2: F32xN = ZERO;
    var c3: F32xN = ZERO;

    var i: usize = 0;
    const step2 = SIMD_LANES * 2;
    const vec2_len = padded_len - (padded_len % step2);
    while (i < vec2_len) : (i += step2) {
        const q0: F32xN = q[i..][0..SIMD_LANES].*;
        const d0 = q0 - @as(F32xN, b0[i..][0..SIMD_LANES].*);
        const d1 = q0 - @as(F32xN, b1[i..][0..SIMD_LANES].*);
        const d2 = q0 - @as(F32xN, b2[i..][0..SIMD_LANES].*);
        const d3 = q0 - @as(F32xN, b3[i..][0..SIMD_LANES].*);
        a0 = fmadd(d0, d0, a0);
        a1 = fmadd(d1, d1, a1);
        a2 = fmadd(d2, d2, a2);
        a3 = fmadd(d3, d3, a3);

        const q1: F32xN = q[i + SIMD_LANES ..][0..SIMD_LANES].*;
        const e0 = q1 - @as(F32xN, b0[i + SIMD_LANES ..][0..SIMD_LANES].*);
        const e1 = q1 - @as(F32xN, b1[i + SIMD_LANES ..][0..SIMD_LANES].*);
        const e2 = q1 - @as(F32xN, b2[i + SIMD_LANES ..][0..SIMD_LANES].*);
        const e3 = q1 - @as(F32xN, b3[i + SIMD_LANES ..][0..SIMD_LANES].*);
        c0 = fmadd(e0, e0, c0);
        c1 = fmadd(e1, e1, c1);
        c2 = fmadd(e2, e2, c2);
        c3 = fmadd(e3, e3, c3);
    }

    if (comptime SIMD_LANES == 16) {
        if (i < padded_len) {
            const q0: F32xN = q[i..][0..SIMD_LANES].*;
            const d0 = q0 - @as(F32xN, b0[i..][0..SIMD_LANES].*);
            const d1 = q0 - @as(F32xN, b1[i..][0..SIMD_LANES].*);
            const d2 = q0 - @as(F32xN, b2[i..][0..SIMD_LANES].*);
            const d3 = q0 - @as(F32xN, b3[i..][0..SIMD_LANES].*);
            a0 = fmadd(d0, d0, a0);
            a1 = fmadd(d1, d1, a1);
            a2 = fmadd(d2, d2, a2);
            a3 = fmadd(d3, d3, a3);
        }
    }

    return .{
        @reduce(.Add, a0 + c0),
        @reduce(.Add, a1 + c1),
        @reduce(.Add, a2 + c2),
        @reduce(.Add, a3 + c3),
    };
}

/// 4-way batched squared L2 distance for unaligned slices. Safe for mismatched lengths.
pub fn l2SquaredBatch4(q: []align(1) const f32, b: [4][]align(1) const f32) [4]f32 {
    const len = q.len;
    if (len == 0) return .{ 0.0, 0.0, 0.0, 0.0 };

    if (b[0].len != len or b[1].len != len or b[2].len != len or b[3].len != len) {
        return .{
            l2Squared(q, b[0]),
            l2Squared(q, b[1]),
            l2Squared(q, b[2]),
            l2Squared(q, b[3]),
        };
    }

    const b0 = b[0];
    const b1 = b[1];
    const b2 = b[2];
    const b3 = b[3];

    var a0: F32xN = ZERO;
    var a1: F32xN = ZERO;
    var a2: F32xN = ZERO;
    var a3: F32xN = ZERO;
    var c0: F32xN = ZERO;
    var c1: F32xN = ZERO;
    var c2: F32xN = ZERO;
    var c3: F32xN = ZERO;

    var i: usize = 0;
    const step2 = SIMD_LANES * 2;
    const vec2_len = len - (len % step2);
    while (i < vec2_len) : (i += step2) {
        const q0: F32xN = q[i..][0..SIMD_LANES].*;
        const d0 = q0 - @as(F32xN, b0[i..][0..SIMD_LANES].*);
        const d1 = q0 - @as(F32xN, b1[i..][0..SIMD_LANES].*);
        const d2 = q0 - @as(F32xN, b2[i..][0..SIMD_LANES].*);
        const d3 = q0 - @as(F32xN, b3[i..][0..SIMD_LANES].*);
        a0 = fmadd(d0, d0, a0);
        a1 = fmadd(d1, d1, a1);
        a2 = fmadd(d2, d2, a2);
        a3 = fmadd(d3, d3, a3);

        const q1: F32xN = q[i + SIMD_LANES ..][0..SIMD_LANES].*;
        const e0 = q1 - @as(F32xN, b0[i + SIMD_LANES ..][0..SIMD_LANES].*);
        const e1 = q1 - @as(F32xN, b1[i + SIMD_LANES ..][0..SIMD_LANES].*);
        const e2 = q1 - @as(F32xN, b2[i + SIMD_LANES ..][0..SIMD_LANES].*);
        const e3 = q1 - @as(F32xN, b3[i + SIMD_LANES ..][0..SIMD_LANES].*);
        c0 = fmadd(e0, e0, c0);
        c1 = fmadd(e1, e1, c1);
        c2 = fmadd(e2, e2, c2);
        c3 = fmadd(e3, e3, c3);
    }

    const vec_len = len - (len % SIMD_LANES);
    while (i < vec_len) : (i += SIMD_LANES) {
        const q0: F32xN = q[i..][0..SIMD_LANES].*;
        const d0 = q0 - @as(F32xN, b0[i..][0..SIMD_LANES].*);
        const d1 = q0 - @as(F32xN, b1[i..][0..SIMD_LANES].*);
        const d2 = q0 - @as(F32xN, b2[i..][0..SIMD_LANES].*);
        const d3 = q0 - @as(F32xN, b3[i..][0..SIMD_LANES].*);
        a0 = fmadd(d0, d0, a0);
        a1 = fmadd(d1, d1, a1);
        a2 = fmadd(d2, d2, a2);
        a3 = fmadd(d3, d3, a3);
    }

    var out: [4]f32 = .{
        @reduce(.Add, a0 + c0),
        @reduce(.Add, a1 + c1),
        @reduce(.Add, a2 + c2),
        @reduce(.Add, a3 + c3),
    };

    while (i < len) : (i += 1) {
        const xq = q[i];
        const s0 = xq - b0[i];
        const s1 = xq - b1[i];
        const s2 = xq - b2[i];
        const s3 = xq - b3[i];
        out[0] += s0 * s0;
        out[1] += s1 * s1;
        out[2] += s2 * s2;
        out[3] += s3 * s3;
    }

    return out;
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
    var i: usize = 0;

    if (comptime has_avx512_vpopcntdq) {
        if (len >= 64) {
            var acc: @Vector(8, u64) = @splat(0);
            const end64 = len - (len % 64);
            while (i < end64) : (i += 64) {
                const va: @Vector(8, u64) = @bitCast(a[i..][0..64].*);
                const vb: @Vector(8, u64) = @bitCast(b[i..][0..64].*);
                acc += @popCount(va ^ vb);
            }
            dist += @truncate(@reduce(.Add, acc));
        }
        if (comptime has_avx512vl) {
            if (i + 32 <= len) {
                const va: @Vector(4, u64) = @bitCast(a[i..][0..32].*);
                const vb: @Vector(4, u64) = @bitCast(b[i..][0..32].*);
                dist += @reduce(.Add, @as(@Vector(4, u32), @popCount(va ^ vb)));
                i += 32;
            }
            if (i + 16 <= len) {
                const va: @Vector(2, u64) = @bitCast(a[i..][0..16].*);
                const vb: @Vector(2, u64) = @bitCast(b[i..][0..16].*);
                dist += @reduce(.Add, @as(@Vector(2, u32), @popCount(va ^ vb)));
                i += 16;
            }
        }
    } else if (comptime is_aarch64) {
        // NEON cnt v.16b + uaddw accumulation (flush before u16 could overflow).
        while (i + 16 <= len) {
            var acc: @Vector(16, u16) = @splat(0);
            var chunk_iters: usize = 0;
            while (i + 16 <= len and chunk_iters < 4096) : ({
                i += 16;
                chunk_iters += 1;
            }) {
                const va: @Vector(16, u8) = a[i..][0..16].*;
                const vb: @Vector(16, u8) = b[i..][0..16].*;
                acc += @as(@Vector(16, u16), @popCount(va ^ vb));
            }
            dist += @reduce(.Add, @as(@Vector(16, u32), acc));
        }
    } else {
        // Explicit 4× u64 unroll with independent accumulators (AVX2/SSE2/wasm).
        var c0: u32 = 0;
        var c1: u32 = 0;
        var c2: u32 = 0;
        var c3: u32 = 0;
        const end32 = len - (len % 32);
        while (i < end32) : (i += 32) {
            const a0: u64 = @bitCast(a[i..][0..8].*);
            const b0: u64 = @bitCast(b[i..][0..8].*);
            const a1: u64 = @bitCast(a[i + 8 ..][0..8].*);
            const b1: u64 = @bitCast(b[i + 8 ..][0..8].*);
            const a2: u64 = @bitCast(a[i + 16 ..][0..8].*);
            const b2: u64 = @bitCast(b[i + 16 ..][0..8].*);
            const a3: u64 = @bitCast(a[i + 24 ..][0..8].*);
            const b3: u64 = @bitCast(b[i + 24 ..][0..8].*);
            c0 += @popCount(a0 ^ b0);
            c1 += @popCount(a1 ^ b1);
            c2 += @popCount(a2 ^ b2);
            c3 += @popCount(a3 ^ b3);
        }
        dist += (c0 + c1) + (c2 + c3);
    }

    // 8-byte remainder
    while (i + 8 <= len) : (i += 8) {
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

/// 4-way batched Hamming distance. Amortizes loading `q` across 4 candidate codes.
/// Safe for mismatched lengths.
pub fn hammingBatch4(q: []const u8, b: [4][]const u8) [4]u32 {
    const len = q.len;
    if (len == 0) return .{ 0, 0, 0, 0 };

    if (b[0].len != len or b[1].len != len or b[2].len != len or b[3].len != len) {
        return .{
            hamming(q, b[0]),
            hamming(q, b[1]),
            hamming(q, b[2]),
            hamming(q, b[3]),
        };
    }

    const b0 = b[0];
    const b1 = b[1];
    const b2 = b[2];
    const b3 = b[3];

    var d0: u32 = 0;
    var d1: u32 = 0;
    var d2: u32 = 0;
    var d3: u32 = 0;
    var i: usize = 0;

    if (comptime has_avx512_vpopcntdq) {
        if (len >= 64) {
            var acc0: @Vector(8, u64) = @splat(0);
            var acc1: @Vector(8, u64) = @splat(0);
            var acc2: @Vector(8, u64) = @splat(0);
            var acc3: @Vector(8, u64) = @splat(0);
            const end64 = len - (len % 64);
            while (i < end64) : (i += 64) {
                const vq: @Vector(8, u64) = @bitCast(q[i..][0..64].*);
                acc0 += @popCount(vq ^ @as(@Vector(8, u64), @bitCast(b0[i..][0..64].*)));
                acc1 += @popCount(vq ^ @as(@Vector(8, u64), @bitCast(b1[i..][0..64].*)));
                acc2 += @popCount(vq ^ @as(@Vector(8, u64), @bitCast(b2[i..][0..64].*)));
                acc3 += @popCount(vq ^ @as(@Vector(8, u64), @bitCast(b3[i..][0..64].*)));
            }
            d0 += @truncate(@reduce(.Add, acc0));
            d1 += @truncate(@reduce(.Add, acc1));
            d2 += @truncate(@reduce(.Add, acc2));
            d3 += @truncate(@reduce(.Add, acc3));
        }
        if (comptime has_avx512vl) {
            if (i + 32 <= len) {
                const vq: @Vector(4, u64) = @bitCast(q[i..][0..32].*);
                d0 += @reduce(.Add, @as(@Vector(4, u32), @popCount(vq ^ @as(@Vector(4, u64), @bitCast(b0[i..][0..32].*)))));
                d1 += @reduce(.Add, @as(@Vector(4, u32), @popCount(vq ^ @as(@Vector(4, u64), @bitCast(b1[i..][0..32].*)))));
                d2 += @reduce(.Add, @as(@Vector(4, u32), @popCount(vq ^ @as(@Vector(4, u64), @bitCast(b2[i..][0..32].*)))));
                d3 += @reduce(.Add, @as(@Vector(4, u32), @popCount(vq ^ @as(@Vector(4, u64), @bitCast(b3[i..][0..32].*)))));
                i += 32;
            }
            if (i + 16 <= len) {
                const vq: @Vector(2, u64) = @bitCast(q[i..][0..16].*);
                d0 += @reduce(.Add, @as(@Vector(2, u32), @popCount(vq ^ @as(@Vector(2, u64), @bitCast(b0[i..][0..16].*)))));
                d1 += @reduce(.Add, @as(@Vector(2, u32), @popCount(vq ^ @as(@Vector(2, u64), @bitCast(b1[i..][0..16].*)))));
                d2 += @reduce(.Add, @as(@Vector(2, u32), @popCount(vq ^ @as(@Vector(2, u64), @bitCast(b2[i..][0..16].*)))));
                d3 += @reduce(.Add, @as(@Vector(2, u32), @popCount(vq ^ @as(@Vector(2, u64), @bitCast(b3[i..][0..16].*)))));
                i += 16;
            }
        }
    } else if (comptime is_aarch64) {
        while (i + 16 <= len) {
            var acc0: @Vector(16, u16) = @splat(0);
            var acc1: @Vector(16, u16) = @splat(0);
            var acc2: @Vector(16, u16) = @splat(0);
            var acc3: @Vector(16, u16) = @splat(0);
            var chunk_iters: usize = 0;
            while (i + 16 <= len and chunk_iters < 4096) : ({
                i += 16;
                chunk_iters += 1;
            }) {
                const vq: @Vector(16, u8) = q[i..][0..16].*;
                acc0 += @as(@Vector(16, u16), @popCount(vq ^ @as(@Vector(16, u8), b0[i..][0..16].*)));
                acc1 += @as(@Vector(16, u16), @popCount(vq ^ @as(@Vector(16, u8), b1[i..][0..16].*)));
                acc2 += @as(@Vector(16, u16), @popCount(vq ^ @as(@Vector(16, u8), b2[i..][0..16].*)));
                acc3 += @as(@Vector(16, u16), @popCount(vq ^ @as(@Vector(16, u8), b3[i..][0..16].*)));
            }
            d0 += @reduce(.Add, @as(@Vector(16, u32), acc0));
            d1 += @reduce(.Add, @as(@Vector(16, u32), acc1));
            d2 += @reduce(.Add, @as(@Vector(16, u32), acc2));
            d3 += @reduce(.Add, @as(@Vector(16, u32), acc3));
        }
    } else {
        while (i + 16 <= len) : (i += 16) {
            const wq0: u64 = @bitCast(q[i..][0..8].*);
            const wq1: u64 = @bitCast(q[i + 8 ..][0..8].*);
            d0 += @popCount(wq0 ^ @as(u64, @bitCast(b0[i..][0..8].*))) + @popCount(wq1 ^ @as(u64, @bitCast(b0[i + 8 ..][0..8].*)));
            d1 += @popCount(wq0 ^ @as(u64, @bitCast(b1[i..][0..8].*))) + @popCount(wq1 ^ @as(u64, @bitCast(b1[i + 8 ..][0..8].*)));
            d2 += @popCount(wq0 ^ @as(u64, @bitCast(b2[i..][0..8].*))) + @popCount(wq1 ^ @as(u64, @bitCast(b2[i + 8 ..][0..8].*)));
            d3 += @popCount(wq0 ^ @as(u64, @bitCast(b3[i..][0..8].*))) + @popCount(wq1 ^ @as(u64, @bitCast(b3[i + 8 ..][0..8].*)));
        }
    }

    while (i + 8 <= len) : (i += 8) {
        const wq: u64 = @bitCast(q[i..][0..8].*);
        d0 += @popCount(wq ^ @as(u64, @bitCast(b0[i..][0..8].*)));
        d1 += @popCount(wq ^ @as(u64, @bitCast(b1[i..][0..8].*)));
        d2 += @popCount(wq ^ @as(u64, @bitCast(b2[i..][0..8].*)));
        d3 += @popCount(wq ^ @as(u64, @bitCast(b3[i..][0..8].*)));
    }

    while (i < len) : (i += 1) {
        const qb = q[i];
        d0 += @popCount(@as(u8, qb ^ b0[i]));
        d1 += @popCount(@as(u8, qb ^ b1[i]));
        d2 += @popCount(@as(u8, qb ^ b2[i]));
        d3 += @popCount(@as(u8, qb ^ b3[i]));
    }

    return .{ d0, d1, d2, d3 };
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
/// Output length: ceil(input.len / 8) bytes (MSB-first within each byte).
pub fn binaryQuantize(vec: []align(1) const f32, out: []u8) void {
    const byte_count = (vec.len + 7) / 8;
    const actual = @min(byte_count, out.len);
    const full_bytes = @min(vec.len / 8, actual);

    var byte_idx: usize = 0;

    if (comptime has_avx512f) {
        const zero16: @Vector(16, f32) = @splat(0.0);
        while (byte_idx + 2 <= full_bytes) : (byte_idx += 2) {
            const chunk: @Vector(16, f32) = vec[byte_idx * 8 ..][0..16].*;
            const mask: u16 = @bitCast(chunk >= zero16);
            out[byte_idx] = BITREV_LUT[mask & 0xFF];
            out[byte_idx + 1] = BITREV_LUT[mask >> 8];
        }
    }

    if (comptime SIMD_LANES >= 4) {
        const zero8: @Vector(8, f32) = @splat(0.0);
        while (byte_idx < full_bytes) : (byte_idx += 1) {
            const chunk: @Vector(8, f32) = vec[byte_idx * 8 ..][0..8].*;
            const mask: u8 = @bitCast(chunk >= zero8);
            out[byte_idx] = BITREV_LUT[mask];
        }
    }

    while (byte_idx < actual) : (byte_idx += 1) {
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
/// For each dimension: bit = sign(vec[i] - centroid[i]) (1 iff >= 0.0).
/// `centroid` must be the same length as `vec`.
pub fn binaryQuantizeCentered(
    vec: []align(1) const f32,
    centroid: []align(1) const f32,
    out: []u8,
) void {
    std.debug.assert(centroid.len == vec.len);
    const byte_count = (vec.len + 7) / 8;
    const actual = @min(byte_count, out.len);
    const full_bytes = @min(vec.len / 8, actual);

    var byte_idx: usize = 0;

    if (comptime has_avx512f) {
        const zero16: @Vector(16, f32) = @splat(0.0);
        while (byte_idx + 2 <= full_bytes) : (byte_idx += 2) {
            const v_chunk: @Vector(16, f32) = vec[byte_idx * 8 ..][0..16].*;
            const c_chunk: @Vector(16, f32) = centroid[byte_idx * 8 ..][0..16].*;
            const mask: u16 = @bitCast((v_chunk - c_chunk) >= zero16);
            out[byte_idx] = BITREV_LUT[mask & 0xFF];
            out[byte_idx + 1] = BITREV_LUT[mask >> 8];
        }
    }

    if (comptime SIMD_LANES >= 4) {
        const zero8: @Vector(8, f32) = @splat(0.0);
        while (byte_idx < full_bytes) : (byte_idx += 1) {
            const v_chunk: @Vector(8, f32) = vec[byte_idx * 8 ..][0..8].*;
            const c_chunk: @Vector(8, f32) = centroid[byte_idx * 8 ..][0..8].*;
            const mask: u8 = @bitCast((v_chunk - c_chunk) >= zero8);
            out[byte_idx] = BITREV_LUT[mask];
        }
    }

    while (byte_idx < actual) : (byte_idx += 1) {
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
/// Returns an align(1) slice. Returns null if byte length is 0 or not a multiple of 4.
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

test "cosine: empty and zero-norm vectors" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cosine(&[_]f32{}, &[_]f32{}), 1e-6);
    const z = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    try std.testing.expectEqual(@as(f32, 0.0), cosine(&z, &a));
    try std.testing.expectEqual(@as(f32, 0.0), cosine(&a, &z));
    try std.testing.expectEqual(@as(f32, 0.0), cosine(&z, &z));
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
    try std.testing.expect(result >= -1.0 and result <= 1.0);
}

test "dot: known values" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 5.0, 6.0 };
    const result = dot(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 32.0), result, 1e-6);
}

test "l2Squared: known values" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 5.0, 6.0 };
    const result = l2Squared(&a, &b);
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

    try std.testing.expectEqual(@as(u8, 0xAD), qa[0]);
    try std.testing.expectEqual(@as(u8, 0xE9), qb[0]);
    try std.testing.expectEqual(@as(u32, 2), hamming(&qa, &qb));
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
    const bytes = [_]u8{ 0, 0, 0 };
    try std.testing.expect(bytesToF32(&bytes) == null);
}

fn oracleDot(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const n = @min(a.len, b.len);
    var s: f64 = 0.0;
    for (0..n) |i| s += @as(f64, a[i]) * @as(f64, b[i]);
    return @floatCast(s);
}

fn oracleL2Sq(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const n = @min(a.len, b.len);
    var s: f64 = 0.0;
    for (0..n) |i| {
        const d = @as(f64, a[i]) - @as(f64, b[i]);
        s += d * d;
    }
    return @floatCast(s);
}

fn oracleCosine(a: []align(1) const f32, b: []align(1) const f32) f32 {
    const n = @min(a.len, b.len);
    if (n == 0) return 0.0;
    var dp: f64 = 0.0;
    var na: f64 = 0.0;
    var nb: f64 = 0.0;
    for (0..n) |i| {
        const xa: f64 = a[i];
        const xb: f64 = b[i];
        dp += xa * xb;
        na += xa * xa;
        nb += xb * xb;
    }
    const denom = @sqrt(na) * @sqrt(nb);
    if (denom == 0.0) return 0.0;
    return clampUnit(@floatCast(dp / denom));
}

fn oracleHamming(a: []const u8, b: []const u8) u32 {
    const n = @min(a.len, b.len);
    var acc: u32 = 0;
    for (0..n) |i| acc += @popCount(@as(u8, a[i] ^ b[i]));
    return acc;
}

fn oracleBinaryQuantize(vec: []align(1) const f32, centroid: ?[]align(1) const f32, out: []u8) void {
    const actual = @min((vec.len + 7) / 8, out.len);
    for (0..actual) |byte_idx| {
        var byte: u8 = 0;
        for (0..8) |bit| {
            const dim = byte_idx * 8 + bit;
            if (dim < vec.len) {
                const val = if (centroid) |c| vec[dim] - c[dim] else vec[dim];
                if (val >= 0.0) byte |= (@as(u8, 1) << @intCast(7 - bit));
            }
        }
        out[byte_idx] = byte;
    }
}

test "SIMD parity vs scalar f64 oracle across dims and unaligned byte offsets (+1/+2/+3)" {
    const alloc = std.testing.allocator;
    const dims = [_]usize{ 0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 128, 129, 384, 768, 1536 };
    var prng = std.Random.DefaultPrng.init(0xD157_A4CE);
    const rand = prng.random();

    const max_dim: usize = 1536;
    const raw_q = try alloc.alloc(u8, max_dim * 4 + 4);
    defer alloc.free(raw_q);
    var raw_b: [4][]u8 = undefined;
    for (0..4) |k| {
        raw_b[k] = try alloc.alloc(u8, max_dim * 4 + 4);
    }
    defer for (0..4) |k| alloc.free(raw_b[k]);

    const raw_c = try alloc.alloc(u8, max_dim * 4 + 4);
    defer alloc.free(raw_c);

    for ([_]usize{ 0, 1, 2, 3 }) |offset| {
        // Fill unaligned f32 buffers at byte offset +0/+1/+2/+3
        const q_full: [*]align(1) f32 = @ptrCast(raw_q.ptr + offset);
        const c_full: [*]align(1) f32 = @ptrCast(raw_c.ptr + offset);
        for (0..max_dim) |i| {
            q_full[i] = rand.floatNorm(f32);
            c_full[i] = rand.floatNorm(f32) * 0.5;
        }
        var b_full: [4][*]align(1) f32 = undefined;
        for (0..4) |k| {
            b_full[k] = @ptrCast(raw_b[k].ptr + offset);
            for (0..max_dim) |i| b_full[k][i] = rand.floatNorm(f32);
        }

        for (dims) |d| {
            const q: []align(1) const f32 = q_full[0..d];
            const c: []align(1) const f32 = c_full[0..d];
            const bs: [4][]align(1) const f32 = .{
                b_full[0][0..d],
                b_full[1][0..d],
                b_full[2][0..d],
                b_full[3][0..d],
            };

            const qn = l2Norm(q);
            const inv_qn: f32 = if (qn > 0.0) 1.0 / qn else 0.0;

            const dots4 = dotBatch4(q, bs);
            const l2s4 = l2SquaredBatch4(q, bs);
            const cos4 = cosineBatch4(q, bs);
            const cosqn4 = cosineWithQueryNormBatch4(q, inv_qn, bs);

            for (0..4) |k| {
                const exp_dot = oracleDot(q, bs[k]);
                const exp_l2 = oracleL2Sq(q, bs[k]);
                const exp_cos = oracleCosine(q, bs[k]);

                const dot_tol: f32 = @max(@as(f32, 1e-4), @abs(exp_dot) * 1e-5);
                const l2_tol: f32 = @max(@as(f32, 1e-4), @abs(exp_l2) * 1e-5);

                try std.testing.expectApproxEqAbs(exp_dot, dot(q, bs[k]), dot_tol);
                try std.testing.expectApproxEqAbs(exp_dot, dots4[k], dot_tol);
                try std.testing.expectApproxEqAbs(exp_l2, l2Squared(q, bs[k]), l2_tol);
                try std.testing.expectApproxEqAbs(exp_l2, l2s4[k], l2_tol);
                try std.testing.expect(l2Squared(q, bs[k]) >= 0.0);
                try std.testing.expect(l2s4[k] >= 0.0);

                const got_cos = cosine(q, bs[k]);
                const got_cos_qn = cosineWithQueryNorm(q, inv_qn, bs[k]);
                try std.testing.expect(got_cos >= -1.0 and got_cos <= 1.0);
                try std.testing.expect(got_cos_qn >= -1.0 and got_cos_qn <= 1.0);
                try std.testing.expectApproxEqAbs(exp_cos, got_cos, 1e-5);
                try std.testing.expectApproxEqAbs(exp_cos, got_cos_qn, 1e-5);
                try std.testing.expectApproxEqAbs(exp_cos, cos4[k], 1e-5);
                try std.testing.expectApproxEqAbs(exp_cos, cosqn4[k], 1e-5);
            }

            // Binary quantization & centered BQ bit-exact parity
            const bq_len = binaryQuantizedSize(d);
            const got_bq = try alloc.alloc(u8, bq_len);
            defer alloc.free(got_bq);
            const exp_bq = try alloc.alloc(u8, bq_len);
            defer alloc.free(exp_bq);

            binaryQuantize(q, got_bq);
            oracleBinaryQuantize(q, null, exp_bq);
            try std.testing.expectEqualSlices(u8, exp_bq, got_bq);

            binaryQuantizeCentered(q, c, got_bq);
            oracleBinaryQuantize(q, c, exp_bq);
            try std.testing.expectEqualSlices(u8, exp_bq, got_bq);
        }
    }
}

test "aligned padded kernels match unaligned and f64 oracle" {
    const alloc = std.testing.allocator;
    const dims = [_]usize{ 0, 1, 7, 15, 16, 17, 32, 48, 63, 128, 384, 768, 1536 };
    var prng = std.Random.DefaultPrng.init(0xA116_9ED0);
    const rand = prng.random();

    for (dims) |d| {
        const padded = std.mem.alignForward(usize, d, 16);
        const q_buf = try alloc.alignedAlloc(f32, .@"32", padded);
        defer alloc.free(q_buf);
        @memset(q_buf, 0.0);
        for (0..d) |i| q_buf[i] = rand.floatNorm(f32);

        var b_bufs: [4][]align(32) f32 = undefined;
        for (0..4) |k| {
            b_bufs[k] = try alloc.alignedAlloc(f32, .@"32", padded);
            @memset(b_bufs[k], 0.0);
            for (0..d) |i| b_bufs[k][i] = rand.floatNorm(f32);
        }
        defer for (0..4) |k| alloc.free(b_bufs[k]);

        const b_ptrs: [4][*]align(32) const f32 = .{
            b_bufs[0].ptr,
            b_bufs[1].ptr,
            b_bufs[2].ptr,
            b_bufs[3].ptr,
        };

        const dots4 = dotBatch4Aligned(q_buf.ptr, b_ptrs, padded);
        const l2s4 = l2SquaredBatch4Aligned(q_buf.ptr, b_ptrs, padded);

        for (0..4) |k| {
            const qa: []align(1) const f32 = @ptrCast(q_buf[0..d]);
            const ba: []align(1) const f32 = @ptrCast(b_bufs[k][0..d]);
            const exp_dot = oracleDot(qa, ba);
            const exp_l2 = oracleL2Sq(qa, ba);
            const dot_tol: f32 = @max(@as(f32, 1e-4), @abs(exp_dot) * 1e-5);
            const l2_tol: f32 = @max(@as(f32, 1e-4), @abs(exp_l2) * 1e-5);

            try std.testing.expectApproxEqAbs(exp_dot, dotAligned(q_buf.ptr, b_ptrs[k], padded), dot_tol);
            try std.testing.expectApproxEqAbs(exp_dot, dots4[k], dot_tol);
            try std.testing.expectApproxEqAbs(exp_l2, l2SquaredAligned(q_buf.ptr, b_ptrs[k], padded), l2_tol);
            try std.testing.expectApproxEqAbs(exp_l2, l2s4[k], l2_tol);
        }
    }
}

test "l2Norm and normalizeInto edge cases" {
    const alloc = std.testing.allocator;
    const dims = [_]usize{ 0, 1, 7, 16, 33, 128, 384, 768 };
    var prng = std.Random.DefaultPrng.init(0x9083);
    const rand = prng.random();

    for (dims) |d| {
        const src = try alloc.alloc(f32, d);
        defer alloc.free(src);
        const dst = try alloc.alloc(f32, d);
        defer alloc.free(dst);

        // Zero vector -> returns 0.0 and zero-fills dst (no NaN)
        @memset(src, 0.0);
        @memset(dst, 42.0);
        try std.testing.expectEqual(@as(f32, 0.0), normalizeInto(src, dst));
        for (dst) |x| try std.testing.expectEqual(@as(f32, 0.0), x);

        if (d == 0) continue;
        for (src) |*x| x.* = rand.floatNorm(f32) * 3.5;
        const orig_norm = normalizeInto(src, dst);
        try std.testing.expect(orig_norm > 0.0);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), l2Norm(dst), 1e-5);
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), cosine(src, dst), 1e-5);
    }
}

test "hamming and hammingBatch4 bit-exact parity across byte lengths" {
    const alloc = std.testing.allocator;
    const lengths = [_]usize{ 0, 1, 3, 7, 8, 9, 15, 16, 17, 24, 31, 32, 48, 63, 64, 65, 96, 128, 192, 257 };
    var prng = std.Random.DefaultPrng.init(0x4A33_1234);
    const rand = prng.random();

    for (lengths) |n| {
        const q = try alloc.alloc(u8, n);
        defer alloc.free(q);
        rand.bytes(q);

        var bs: [4][]u8 = undefined;
        for (0..4) |k| {
            bs[k] = try alloc.alloc(u8, n);
            rand.bytes(bs[k]);
        }
        defer for (0..4) |k| alloc.free(bs[k]);

        const const_bs: [4][]const u8 = .{ bs[0], bs[1], bs[2], bs[3] };
        const got4 = hammingBatch4(q, const_bs);
        for (0..4) |k| {
            const exp = oracleHamming(q, const_bs[k]);
            try std.testing.expectEqual(exp, hamming(q, const_bs[k]));
            try std.testing.expectEqual(exp, got4[k]);
        }
    }

    // Mismatched lengths safety
    const qa = [_]u8{ 0xFF, 0x00, 0xAA, 0x55 };
    const b0 = [_]u8{ 0x0F, 0x00 };
    const b1 = [_]u8{ 0xFF, 0xFF, 0xAA };
    const b2 = [_]u8{};
    const b3 = [_]u8{ 0x00, 0xFF, 0x55, 0xAA, 0xFF };
    const h4 = hammingBatch4(&qa, .{ &b0, &b1, &b2, &b3 });
    try std.testing.expectEqual(oracleHamming(&qa, &b0), h4[0]);
    try std.testing.expectEqual(oracleHamming(&qa, &b1), h4[1]);
    try std.testing.expectEqual(oracleHamming(&qa, &b2), h4[2]);
    try std.testing.expectEqual(oracleHamming(&qa, &b3), h4[3]);
}

test "mismatched lengths safety across float batch kernels" {
    const q = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const b0 = [_]f32{ 1.0, 2.0 };
    const b1 = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const b2 = [_]f32{};
    const b3 = [_]f32{ -1.0, -2.0, -3.0, -4.0 };
    const bs: [4][]align(1) const f32 = .{ &b0, &b1, &b2, &b3 };

    const d4 = dotBatch4(&q, bs);
    const l4 = l2SquaredBatch4(&q, bs);
    const c4 = cosineBatch4(&q, bs);
    for (0..4) |k| {
        try std.testing.expectApproxEqAbs(dot(&q, bs[k]), d4[k], 1e-6);
        try std.testing.expectApproxEqAbs(l2Squared(&q, bs[k]), l4[k], 1e-6);
        try std.testing.expectApproxEqAbs(cosine(&q, bs[k]), c4[k], 1e-6);
    }
}
