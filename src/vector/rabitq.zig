//! RaBitQ (Gao & Long, SIGMOD 2024) — 1-bit quantization with an
//! unbiased distance estimator.
//!
//! Builds on phase-1 centered BQ by adding:
//!   - A random orthogonal rotation per namespace so bits are
//!     decorrelated across dimensions (critical for structured data
//!     like SIFT where raw components are highly correlated).
//!   - A per-vector bias-correction factor that makes the estimated
//!     distance unbiased, eliminating the need for a full-precision
//!     rerank step in the common case.
//!
//! Math recap (see paper §3–4, arxiv 2405.12497):
//!   Let c = namespace centroid, R = d×d random orthogonal matrix.
//!   For a database vector v:
//!     r = v − c
//!     ||r|| = L2 norm of the residual         (stored)
//!     ō = R (r / ||r||)                       (rotated unit residual)
//!     code[i] = 1 if ō[i] ≥ 0 else 0
//!     b̄ = (2·code − 1) / √d                   (unit-norm signed binary)
//!     corr = ⟨ō, b̄⟩ = (1/√d)·Σᵢ |ōᵢ|          (stored)
//!
//!   For a query q at estimate time:
//!     r_q = q − c, ||r_q||                    (scalar)
//!     q_rot_unit = R (r_q / ||r_q||)          (computed once per query)
//!     ⟨q_rot_unit, b̄⟩ = (1/√d)·(Σ_{bit set} q_rot_unit[i] − Σ_{bit unset} q_rot_unit[i])
//!     cos_est ≈ ⟨q_rot_unit, b̄⟩ / corr        (debiased cos of unit residuals)
//!     d²(q,v) ≈ ||r_q||² + ||r||² − 2·||r_q||·||r||·cos_est
//!
//! Includes three query-time distance estimators sharing the exact same
//! on-disk `[code][l2 f32 LE][corr f32 LE]` format:
//!   1. Exact-f32 (`estimateL2Sq`, `estimateL2SqPrepared`, `estimateL2SqBatch4Prepared`)
//!   2. 4-bit Query Bit-Plane AND-Popcount (`estimateL2Sq4Bit`, `estimateL2Sq4BitBatch4`,
//!      `estimateL2Sq4BitSlabBatch4` — paper §3.3, zero FP ops in inner loop)
//!   3. FastScan 32-vector transposed-nibble LUT (`buildFastScanLut`, `packFastScanBlock32`,
//!      `estimateFastScanBlock32` — paper §4, `vpshufb`/NEON `tbl` with portable fallback)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const distance = @import("distance.zig");

const LANES: usize = distance.SIMD_LANES;
const F32xN = @Vector(LANES, f32);
const ZERO: F32xN = @splat(0.0);

const has_avx512f: bool = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f);

const has_avx512_vpopcntdq: bool = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vpopcntdq);

const has_avx512vl: bool = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512vl);

/// Gates the `pshufb512` FastScan kernel only. Its zmm (`v`) inline-asm constraints are
/// accepted by the LLVM backend alone; Debug builds on x86_64 Linux use Zig's self-hosted
/// backend, so on an AVX-512 host they fall through to the AVX2 kernel instead of failing
/// to compile.
const has_avx512bw: bool = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx512bw) and
    builtin.zig_backend == .stage2_llvm;

const has_avx2: bool = (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) and
    std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);

const is_aarch64: bool = (builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .aarch64_be);

inline fn fmadd(a: F32xN, b: F32xN, c: F32xN) F32xN {
    return distance.fmaddVec(LANES, a, b, c);
}

// ╔═══════════════════════════════════════════════════╗
// ║  Types                                             ║
// ╚═══════════════════════════════════════════════════╝

/// Per-namespace RaBitQ parameters. Owned by a NamespaceIndex; install
/// atomically on first `EXEC vrabitq` and freeze thereafter. Frozen so
/// stored `bq:*` codes remain decodable — rotating R would invalidate
/// every existing entry.
pub const RabitqParams = struct {
    allocator: Allocator,
    /// Dataset centroid, length = dim.
    centroid: []f32,
    /// Row-major d×d orthogonal matrix; length = dim*dim.
    /// `out = rotation @ v` iterates row i and dots with `v` to produce
    /// `out[i]`. The matrix itself is stored in a single flat buffer
    /// so serde can reuse `std.mem.sliceAsBytes`.
    rotation: []f32,
    dim: u32,
    /// RNG seed used to build `rotation`. Kept so the same params can
    /// be re-derived if ever needed, and so snapshots can be diffed for
    /// equivalence.
    seed: u64,

    pub fn deinit(self: *RabitqParams) void {
        self.allocator.free(self.centroid);
        self.allocator.free(self.rotation);
    }
};

/// A single quantized vector's factors. The `code` slice points into
/// caller-owned storage (usually the buffer that will be written to the
/// store); the scalars are the bias-correction pieces recomputed every
/// encode.
pub const Encoded = struct {
    code: []u8,
    l2_norm: f32,
    corr: f32,
};

/// Precomputed per-vector SoA slab factors that eliminate per-candidate
/// square roots, divisions, and code popcounts during slab scans.
///
/// Distance formula:
///   d²_est = q_l2_sq + f_add - (q_l2 * f_rescale) * ip_raw
/// When `v_corr < 1e-8`: `f_add = +inf`, `f_rescale = 0.0` (yields `+inf` with no NaN).
pub const SlabFactors = struct {
    f_add: f32,
    f_rescale: f32,
    popc: u16,
};

/// Precomputed per-query state for zero-allocation RaBitQ estimation across
/// both exact-f32 and 4-bit bit-parallel AND-Popcount estimators.
pub const PreparedQuery = struct {
    q_rot_unit: []const f32,
    q_l2: f32,
    q_l2_sq: f32,
    inv_sqrt_d: f32,
    /// Σ q_rot_unit[i]
    q_sum: f32,
    /// 4-bit scalar quantization lower bound and step size for `q_rot_unit`
    q_vl: f32,
    q_delta: f32,
    /// 4 transposed bit-planes (weight 1, 2, 4, 8), each `code_bytes` bytes,
    /// MSB-first layout matching stored 1-bit `code` bytes.
    q_planes: [4][]u8,
    code_bytes: usize,
    dim: usize,
};

/// Quantization parameters returned by `buildFastScanLut`.
pub const FastScanLutScale = struct {
    vl: f32,
    delta: f32,
};

// ╔═══════════════════════════════════════════════════╗
// ║  Storage layout                                    ║
// ╚═══════════════════════════════════════════════════╝

/// On-disk layout of `bq:<key>` for a RaBitQ-encoded vector:
///   [ceil(d/8) bytes: code][4 bytes: l2_norm f32][4 bytes: corr f32]
///
/// Size discriminates RaBitQ entries (code_bytes + 8) from legacy
/// naive/centered entries (code_bytes). `vsearch` and `applyVinsert`
/// dispatch on length.
pub fn encodedSize(dim: usize) usize {
    return ((dim + 7) / 8) + 8;
}

/// L2-normalize `in` into `out`. Both slices have the same length.
/// Returns true if normalization succeeded; false if `in` was the zero
/// vector (in which case `out` is left as a copy of `in`).
///
/// Used by the cosine path: we pre-normalize at both encode and query
/// time so the estimator's L2² output maps to cosine via
/// `cos = 1 − L²/2` on the unit sphere. Idempotent on already-unit
/// inputs (round-trip error < 1e-7).
pub fn normalizeInto(in: []align(1) const f32, out: []f32) bool {
    std.debug.assert(in.len == out.len);
    const len = in.len;
    if (len == 0) return false;

    const norm = distance.l2Norm(in);
    const sum_sq = norm * norm;
    if (!(sum_sq > 1e-30)) {
        @memcpy(out, in);
        return false;
    }
    const inv = 1.0 / norm;
    const inv_v: F32xN = @splat(inv);
    var i: usize = 0;
    const step4 = LANES * 4;
    const vec4_len = len - (len % step4);
    while (i < vec4_len) : (i += step4) {
        out[i..][0..LANES].* = @as(F32xN, in[i..][0..LANES].*) * inv_v;
        out[i + LANES ..][0..LANES].* = @as(F32xN, in[i + LANES ..][0..LANES].*) * inv_v;
        out[i + LANES * 2 ..][0..LANES].* = @as(F32xN, in[i + LANES * 2 ..][0..LANES].*) * inv_v;
        out[i + LANES * 3 ..][0..LANES].* = @as(F32xN, in[i + LANES * 3 ..][0..LANES].*) * inv_v;
    }
    const vec_len = len - (len % LANES);
    while (i < vec_len) : (i += LANES) {
        out[i..][0..LANES].* = @as(F32xN, in[i..][0..LANES].*) * inv_v;
    }
    while (i < len) : (i += 1) {
        out[i] = in[i] * inv;
    }
    return true;
}

pub fn codeBytes(dim: usize) usize {
    return (dim + 7) / 8;
}

/// Number of 4-dimension nibble groups per vector in FastScan layout.
pub fn fastScanGroups(dim: usize) usize {
    return (dim + 3) / 4;
}

/// Byte size of one packed 32-vector FastScan block (`fastScanGroups(dim) * 16`).
pub fn fastScanBlockBytes(dim: usize) usize {
    return fastScanGroups(dim) * 16;
}

/// Compute precomputed SoA slab factors for one encoded vector.
pub fn computeSlabFactors(dim: usize, v_l2: f32, v_corr: f32, code: []const u8) SlabFactors {
    const popc: u16 = @intCast(popcountSlice(code));
    if (v_corr < 1e-8 or dim == 0) {
        return .{
            .f_add = std.math.inf(f32),
            .f_rescale = 0.0,
            .popc = popc,
        };
    }
    const sqrt_d: f32 = @sqrt(@as(f32, @floatFromInt(dim)));
    return .{
        .f_add = v_l2 * v_l2,
        .f_rescale = (2.0 * v_l2) / (v_corr * sqrt_d),
        .popc = popc,
    };
}

/// Serialize an encoded vector into `out`. Caller supplies a buffer of
/// exactly `encodedSize(dim)` bytes.
///
/// Common pattern: callers pass `code_out = full_buf[0..codeBytes(dim)]`
/// to `encode`, then call `serialize(enc, full_buf)`. In that case the
/// code is already at the right offset — we only need to write the
/// scalar trailer. Detect that aliasing and skip the redundant memcpy.
pub fn serialize(enc: Encoded, out: []u8) void {
    const cb = enc.code.len;
    std.debug.assert(out.len == cb + 8);
    if (enc.code.ptr != out.ptr) {
        @memcpy(out[0..cb], enc.code);
    }
    // Store scalars as little-endian f32 bit-patterns so the format
    // is portable across architectures.
    std.mem.writeInt(u32, out[cb..][0..4], @bitCast(enc.l2_norm), .little);
    std.mem.writeInt(u32, out[cb + 4 ..][0..4], @bitCast(enc.corr), .little);
}

/// Parse a RaBitQ-formatted bq value. Returns null if the length
/// doesn't match `encodedSize(dim)` — callers can treat null as
/// "legacy format, fall back to Hamming prefilter".
pub fn parse(bytes: []const u8, dim: usize) ?Encoded {
    const cb = codeBytes(dim);
    if (bytes.len != cb + 8) return null;
    const l2_bits = std.mem.readInt(u32, bytes[cb..][0..4], .little);
    const corr_bits = std.mem.readInt(u32, bytes[cb + 4 ..][0..4], .little);
    return .{
        .code = @constCast(bytes[0..cb]),
        .l2_norm = @bitCast(l2_bits),
        .corr = @bitCast(corr_bits),
    };
}

// ╔═══════════════════════════════════════════════════╗
// ║  Rotation generation & application                 ║
// ╚═══════════════════════════════════════════════════╝

/// Generate a d×d orthogonal matrix deterministically from `seed` via
/// modified Gram-Schmidt on i.i.d. Gaussian rows. O(d³) one-time cost
/// per namespace; ~2M ops for d=128.
///
/// Returns a row-major buffer owned by the caller.
pub fn generateRotation(allocator: Allocator, dim: usize, seed: u64) ![]f32 {
    if (dim == 0) return error.InvalidDimension;
    const total = dim * dim;
    const m = try allocator.alloc(f32, total);
    errdefer allocator.free(m);

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (m) |*x| x.* = rand.floatNorm(f32);

    const step4 = LANES * 4;
    const vec4_dim = dim - (dim % step4);
    const vec_dim = dim - (dim % LANES);

    var i: usize = 0;
    while (i < dim) : (i += 1) {
        const row_i = m[i * dim ..][0..dim];

        var j: usize = 0;
        while (j < i) : (j += 1) {
            const row_j = m[j * dim ..][0..dim];

            // 4-way unrolled dot(row_i, row_j)
            var d0: F32xN = ZERO;
            var d1: F32xN = ZERO;
            var d2: F32xN = ZERO;
            var d3: F32xN = ZERO;
            var k: usize = 0;
            while (k < vec4_dim) : (k += step4) {
                d0 = fmadd(row_i[k..][0..LANES].*, row_j[k..][0..LANES].*, d0);
                d1 = fmadd(row_i[k + LANES ..][0..LANES].*, row_j[k + LANES ..][0..LANES].*, d1);
                d2 = fmadd(row_i[k + LANES * 2 ..][0..LANES].*, row_j[k + LANES * 2 ..][0..LANES].*, d2);
                d3 = fmadd(row_i[k + LANES * 3 ..][0..LANES].*, row_j[k + LANES * 3 ..][0..LANES].*, d3);
            }
            while (k < vec_dim) : (k += LANES) {
                d0 = fmadd(row_i[k..][0..LANES].*, row_j[k..][0..LANES].*, d0);
            }
            var dp: f32 = distance.hsumVec(LANES, (d0 + d1) + (d2 + d3));
            while (k < dim) : (k += 1) dp += row_i[k] * row_j[k];

            // 4-way unrolled axpy: row_i -= dp * row_j
            const neg_dp_v: F32xN = @splat(-dp);
            k = 0;
            while (k < vec4_dim) : (k += step4) {
                row_i[k..][0..LANES].* = fmadd(neg_dp_v, row_j[k..][0..LANES].*, row_i[k..][0..LANES].*);
                row_i[k + LANES ..][0..LANES].* = fmadd(neg_dp_v, row_j[k + LANES ..][0..LANES].*, row_i[k + LANES ..][0..LANES].*);
                row_i[k + LANES * 2 ..][0..LANES].* = fmadd(neg_dp_v, row_j[k + LANES * 2 ..][0..LANES].*, row_i[k + LANES * 2 ..][0..LANES].*);
                row_i[k + LANES * 3 ..][0..LANES].* = fmadd(neg_dp_v, row_j[k + LANES * 3 ..][0..LANES].*, row_i[k + LANES * 3 ..][0..LANES].*);
            }
            while (k < vec_dim) : (k += LANES) {
                row_i[k..][0..LANES].* = fmadd(neg_dp_v, row_j[k..][0..LANES].*, row_i[k..][0..LANES].*);
            }
            while (k < dim) : (k += 1) row_i[k] -= dp * row_j[k];
        }

        // 4-way unrolled norm²
        var n0: F32xN = ZERO;
        var n1: F32xN = ZERO;
        var n2: F32xN = ZERO;
        var n3: F32xN = ZERO;
        var k: usize = 0;
        while (k < vec4_dim) : (k += step4) {
            const r0: F32xN = row_i[k..][0..LANES].*;
            const r1: F32xN = row_i[k + LANES ..][0..LANES].*;
            const r2: F32xN = row_i[k + LANES * 2 ..][0..LANES].*;
            const r3: F32xN = row_i[k + LANES * 3 ..][0..LANES].*;
            n0 = fmadd(r0, r0, n0);
            n1 = fmadd(r1, r1, n1);
            n2 = fmadd(r2, r2, n2);
            n3 = fmadd(r3, r3, n3);
        }
        while (k < vec_dim) : (k += LANES) {
            const ri: F32xN = row_i[k..][0..LANES].*;
            n0 = fmadd(ri, ri, n0);
        }
        var norm_sq: f32 = distance.hsumVec(LANES, (n0 + n1) + (n2 + n3));
        while (k < dim) : (k += 1) norm_sq += row_i[k] * row_i[k];

        const norm = @sqrt(norm_sq);
        if (norm < 1e-12) return error.DegenerateRotation;

        const inv = 1.0 / norm;
        const inv_v: F32xN = @splat(inv);
        k = 0;
        while (k < vec4_dim) : (k += step4) {
            row_i[k..][0..LANES].* = @as(F32xN, row_i[k..][0..LANES].*) * inv_v;
            row_i[k + LANES ..][0..LANES].* = @as(F32xN, row_i[k + LANES ..][0..LANES].*) * inv_v;
            row_i[k + LANES * 2 ..][0..LANES].* = @as(F32xN, row_i[k + LANES * 2 ..][0..LANES].*) * inv_v;
            row_i[k + LANES * 3 ..][0..LANES].* = @as(F32xN, row_i[k + LANES * 3 ..][0..LANES].*) * inv_v;
        }
        while (k < vec_dim) : (k += LANES) {
            row_i[k..][0..LANES].* = @as(F32xN, row_i[k..][0..LANES].*) * inv_v;
        }
        while (k < dim) : (k += 1) row_i[k] *= inv;
    }

    return m;
}

/// Compute `out = rotation @ v`. All three slices have length `dim`;
/// `rotation` is row-major d×d (length `dim * dim`). 4-row × 2-accumulator
/// register-blocked adaptive-width SIMD so `v` is loaded once per 4 rows
/// and 8 independent FMA chains saturate dual FMA pipelines.
pub fn applyRotation(rotation: []const f32, v: []align(1) const f32, out: []f32) void {
    const dim = v.len;
    std.debug.assert(out.len == dim);
    std.debug.assert(rotation.len == dim * dim);

    const step2 = LANES * 2;
    const vec2_dim = dim - (dim % step2);
    const vec_dim = dim - (dim % LANES);

    var i: usize = 0;
    while (i + 4 <= dim) : (i += 4) {
        const row0 = rotation[(i + 0) * dim ..];
        const row1 = rotation[(i + 1) * dim ..];
        const row2 = rotation[(i + 2) * dim ..];
        const row3 = rotation[(i + 3) * dim ..];
        var a0: F32xN = ZERO;
        var a1: F32xN = ZERO;
        var a2: F32xN = ZERO;
        var a3: F32xN = ZERO;
        var b0: F32xN = ZERO;
        var b1: F32xN = ZERO;
        var b2: F32xN = ZERO;
        var b3: F32xN = ZERO;

        var k: usize = 0;
        while (k < vec2_dim) : (k += step2) {
            const v0: F32xN = v[k..][0..LANES].*;
            a0 = fmadd(row0[k..][0..LANES].*, v0, a0);
            a1 = fmadd(row1[k..][0..LANES].*, v0, a1);
            a2 = fmadd(row2[k..][0..LANES].*, v0, a2);
            a3 = fmadd(row3[k..][0..LANES].*, v0, a3);

            const v1: F32xN = v[k + LANES ..][0..LANES].*;
            b0 = fmadd(row0[k + LANES ..][0..LANES].*, v1, b0);
            b1 = fmadd(row1[k + LANES ..][0..LANES].*, v1, b1);
            b2 = fmadd(row2[k + LANES ..][0..LANES].*, v1, b2);
            b3 = fmadd(row3[k + LANES ..][0..LANES].*, v1, b3);
        }
        while (k < vec_dim) : (k += LANES) {
            const vc: F32xN = v[k..][0..LANES].*;
            a0 = fmadd(row0[k..][0..LANES].*, vc, a0);
            a1 = fmadd(row1[k..][0..LANES].*, vc, a1);
            a2 = fmadd(row2[k..][0..LANES].*, vc, a2);
            a3 = fmadd(row3[k..][0..LANES].*, vc, a3);
        }
        var sums = distance.hsum4Vec(LANES, a0 + b0, a1 + b1, a2 + b2, a3 + b3);
        if (k < dim) {
            while (k < dim) : (k += 1) {
                const vk = v[k];
                sums[0] += row0[k] * vk;
                sums[1] += row1[k] * vk;
                sums[2] += row2[k] * vk;
                sums[3] += row3[k] * vk;
            }
        }
        out[i + 0] = sums[0];
        out[i + 1] = sums[1];
        out[i + 2] = sums[2];
        out[i + 3] = sums[3];
    }

    while (i < dim) : (i += 1) {
        const row = rotation[i * dim ..];
        var a0: F32xN = ZERO;
        var a1: F32xN = ZERO;
        var k: usize = 0;
        while (k < vec2_dim) : (k += step2) {
            a0 = fmadd(row[k..][0..LANES].*, v[k..][0..LANES].*, a0);
            a1 = fmadd(row[k + LANES ..][0..LANES].*, v[k + LANES ..][0..LANES].*, a1);
        }
        while (k < vec_dim) : (k += LANES) {
            a0 = fmadd(row[k..][0..LANES].*, v[k..][0..LANES].*, a0);
        }
        var s = distance.hsumVec(LANES, a0 + a1);
        if (k < dim) {
            while (k < dim) : (k += 1) s += row[k] * v[k];
        }
        out[i] = s;
    }
}

/// 4-vector batched rotation (`out[j] = rotation @ v[j]` for j = 0..3).
/// Uses a 2-row × 4-vector register tile (8 accumulators) so each row of the
/// large `d×d` rotation matrix is streamed from L2/L3 once across 4 vectors.
pub fn applyRotationBatch4(
    rotation: []const f32,
    v: [4][]align(1) const f32,
    out: [4][]f32,
) void {
    const dim = v[0].len;
    std.debug.assert(rotation.len == dim * dim);
    inline for (0..4) |j| {
        std.debug.assert(v[j].len == dim);
        std.debug.assert(out[j].len == dim);
    }

    const v0 = v[0];
    const v1 = v[1];
    const v2 = v[2];
    const v3 = v[3];
    const vec_dim = dim - (dim % LANES);

    var i: usize = 0;
    while (i + 2 <= dim) : (i += 2) {
        const row0 = rotation[(i + 0) * dim ..];
        const row1 = rotation[(i + 1) * dim ..];
        var c00: F32xN = ZERO;
        var c01: F32xN = ZERO;
        var c02: F32xN = ZERO;
        var c03: F32xN = ZERO;
        var c10: F32xN = ZERO;
        var c11: F32xN = ZERO;
        var c12: F32xN = ZERO;
        var c13: F32xN = ZERO;

        var k: usize = 0;
        while (k < vec_dim) : (k += LANES) {
            const r0: F32xN = row0[k..][0..LANES].*;
            const r1: F32xN = row1[k..][0..LANES].*;
            const x0: F32xN = v0[k..][0..LANES].*;
            const x1: F32xN = v1[k..][0..LANES].*;
            const x2: F32xN = v2[k..][0..LANES].*;
            const x3: F32xN = v3[k..][0..LANES].*;
            c00 = fmadd(r0, x0, c00);
            c01 = fmadd(r0, x1, c01);
            c02 = fmadd(r0, x2, c02);
            c03 = fmadd(r0, x3, c03);
            c10 = fmadd(r1, x0, c10);
            c11 = fmadd(r1, x1, c11);
            c12 = fmadd(r1, x2, c12);
            c13 = fmadd(r1, x3, c13);
        }

        var s0 = distance.hsum4Vec(LANES, c00, c01, c02, c03);
        var s1 = distance.hsum4Vec(LANES, c10, c11, c12, c13);

        if (k < dim) {
            while (k < dim) : (k += 1) {
                const r0k = row0[k];
                const r1k = row1[k];
                const x0k = v0[k];
                const x1k = v1[k];
                const x2k = v2[k];
                const x3k = v3[k];
                s0[0] += r0k * x0k;
                s0[1] += r0k * x1k;
                s0[2] += r0k * x2k;
                s0[3] += r0k * x3k;
                s1[0] += r1k * x0k;
                s1[1] += r1k * x1k;
                s1[2] += r1k * x2k;
                s1[3] += r1k * x3k;
            }
        }
        out[0][i + 0] = s0[0];
        out[1][i + 0] = s0[1];
        out[2][i + 0] = s0[2];
        out[3][i + 0] = s0[3];
        out[0][i + 1] = s1[0];
        out[1][i + 1] = s1[1];
        out[2][i + 1] = s1[2];
        out[3][i + 1] = s1[3];
    }

    while (i < dim) : (i += 1) {
        const row = rotation[i * dim ..];
        var c0: F32xN = ZERO;
        var c1: F32xN = ZERO;
        var c2: F32xN = ZERO;
        var c3: F32xN = ZERO;
        var k: usize = 0;
        while (k < vec_dim) : (k += LANES) {
            const rk: F32xN = row[k..][0..LANES].*;
            c0 = fmadd(rk, v0[k..][0..LANES].*, c0);
            c1 = fmadd(rk, v1[k..][0..LANES].*, c1);
            c2 = fmadd(rk, v2[k..][0..LANES].*, c2);
            c3 = fmadd(rk, v3[k..][0..LANES].*, c3);
        }
        var s = distance.hsum4Vec(LANES, c0, c1, c2, c3);
        if (k < dim) {
            while (k < dim) : (k += 1) {
                const rk = row[k];
                s[0] += rk * v0[k];
                s[1] += rk * v1[k];
                s[2] += rk * v2[k];
                s[3] += rk * v3[k];
            }
        }
        out[0][i] = s[0];
        out[1][i] = s[1];
        out[2][i] = s[2];
        out[3][i] = s[3];
    }
}

// ╔═══════════════════════════════════════════════════╗
// ║  Encode                                            ║
// ╚═══════════════════════════════════════════════════╝

/// Fused `residual = v - centroid` and `sum_sq = Σ residual[i]²` in one pass.
inline fn computeResidualAndNormSq(
    v: []align(1) const f32,
    centroid: []const f32,
    residual_out: []f32,
) f32 {
    const dim = v.len;
    const step4 = LANES * 4;
    const vec4_dim = dim - (dim % step4);
    const vec_dim = dim - (dim % LANES);

    var acc0: F32xN = ZERO;
    var acc1: F32xN = ZERO;
    var acc2: F32xN = ZERO;
    var acc3: F32xN = ZERO;

    var i: usize = 0;
    while (i < vec4_dim) : (i += step4) {
        const r0 = @as(F32xN, v[i..][0..LANES].*) - @as(F32xN, centroid[i..][0..LANES].*);
        const r1 = @as(F32xN, v[i + LANES ..][0..LANES].*) - @as(F32xN, centroid[i + LANES ..][0..LANES].*);
        const r2 = @as(F32xN, v[i + LANES * 2 ..][0..LANES].*) - @as(F32xN, centroid[i + LANES * 2 ..][0..LANES].*);
        const r3 = @as(F32xN, v[i + LANES * 3 ..][0..LANES].*) - @as(F32xN, centroid[i + LANES * 3 ..][0..LANES].*);
        residual_out[i..][0..LANES].* = r0;
        residual_out[i + LANES ..][0..LANES].* = r1;
        residual_out[i + LANES * 2 ..][0..LANES].* = r2;
        residual_out[i + LANES * 3 ..][0..LANES].* = r3;
        acc0 = fmadd(r0, r0, acc0);
        acc1 = fmadd(r1, r1, acc1);
        acc2 = fmadd(r2, r2, acc2);
        acc3 = fmadd(r3, r3, acc3);
    }
    while (i < vec_dim) : (i += LANES) {
        const r0 = @as(F32xN, v[i..][0..LANES].*) - @as(F32xN, centroid[i..][0..LANES].*);
        residual_out[i..][0..LANES].* = r0;
        acc0 = fmadd(r0, r0, acc0);
    }
    var sum_sq = distance.hsumVec(LANES, (acc0 + acc1) + (acc2 + acc3));
    if (i < dim) {
        while (i < dim) : (i += 1) {
            const r = v[i] - centroid[i];
            residual_out[i] = r;
            sum_sq += r * r;
        }
    }
    return sum_sq;
}

/// Encode `v` against the namespace params. Caller supplies scratch
/// buffers sized to `dim` (residual and rotated) and a code buffer
/// sized to `codeBytes(dim)`.
///
/// The code bit layout matches `distance.binaryQuantize`: for dimension
/// i, bit (7 - i%8) of byte (i/8) is 1 iff the rotated residual is
/// non-negative (`>= 0.0`) at i.
pub fn encode(
    v: []align(1) const f32,
    params: *const RabitqParams,
    residual_scratch: []f32,
    rotated_scratch: []f32,
    code_out: []u8,
) Encoded {
    const dim = v.len;
    std.debug.assert(dim == params.dim);
    std.debug.assert(residual_scratch.len == dim);
    std.debug.assert(rotated_scratch.len == dim);
    std.debug.assert(code_out.len == codeBytes(dim));

    // Fused Pass 1+2: residual = v - c and sum_sq = ||residual||²
    const sum_sq = computeResidualAndNormSq(v, params.centroid, residual_scratch);
    const l2 = @sqrt(sum_sq);

    // Degenerate: v sits at the centroid.
    if (l2 < 1e-20) {
        @memset(code_out, 0);
        return .{ .code = code_out, .l2_norm = 0.0, .corr = 1.0 };
    }

    // By linearity of R, sign(R @ r) == sign(R @ (r / ||r||)) and
    // Σ |R @ (r/||r||)| = (Σ |R @ r|) / ||r||. Only pre-scale on extreme
    // magnitudes to prevent overflow/underflow; normal vectors skip Pass 3.
    const prescale = (l2 > 1e15 or l2 < 1e-15);
    if (prescale) {
        const inv_l2 = 1.0 / l2;
        const inv_v: F32xN = @splat(inv_l2);
        const vec_dim = dim - (dim % LANES);
        var i: usize = 0;
        while (i < vec_dim) : (i += LANES) {
            residual_scratch[i..][0..LANES].* = @as(F32xN, residual_scratch[i..][0..LANES].*) * inv_v;
        }
        while (i < dim) : (i += 1) residual_scratch[i] *= inv_l2;
    }

    // rotated = R @ residual
    const resid_bytes: []align(1) const f32 = @ptrCast(residual_scratch);
    applyRotation(params.rotation, resid_bytes, rotated_scratch);

    // Quantize (1-bit MSB-first code) + accumulate Σ |rotated[i]|.
    // Uses `>= 0.0` (consistent with `distance.binaryQuantize` and tail).
    var abs_sum: f32 = 0.0;
    var i: usize = 0;

    if (comptime has_avx512f) {
        const zero16: @Vector(16, f32) = @splat(0.0);
        const rev16 = [16]i32{ 7, 6, 5, 4, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8 };
        var abs16_0: @Vector(16, f32) = @splat(0.0);
        var abs16_1: @Vector(16, f32) = @splat(0.0);
        const vec32 = dim - (dim % 32);
        while (i < vec32) : (i += 32) {
            const r0: @Vector(16, f32) = rotated_scratch[i..][0..16].*;
            const r1: @Vector(16, f32) = rotated_scratch[i + 16 ..][0..16].*;
            abs16_0 += @abs(r0);
            abs16_1 += @abs(r1);
            const m0: u16 = @bitCast(@shuffle(f32, r0, undefined, rev16) >= zero16);
            const m1: u16 = @bitCast(@shuffle(f32, r1, undefined, rev16) >= zero16);
            std.mem.writeInt(u16, code_out[i / 8 ..][0..2], m0, .little);
            std.mem.writeInt(u16, code_out[i / 8 + 2 ..][0..2], m1, .little);
        }
        if (i + 16 <= dim) {
            const r0: @Vector(16, f32) = rotated_scratch[i..][0..16].*;
            abs16_0 += @abs(r0);
            const m0: u16 = @bitCast(@shuffle(f32, r0, undefined, rev16) >= zero16);
            std.mem.writeInt(u16, code_out[i / 8 ..][0..2], m0, .little);
            i += 16;
        }
        abs_sum += distance.hsumVec(16, abs16_0 + abs16_1);
        if (i + 8 <= dim) {
            const zero8: @Vector(8, f32) = @splat(0.0);
            const rev8 = [8]i32{ 7, 6, 5, 4, 3, 2, 1, 0 };
            const r_chunk: @Vector(8, f32) = rotated_scratch[i..][0..8].*;
            abs_sum += distance.hsumVec(8, @abs(r_chunk));
            code_out[i / 8] = @bitCast(@shuffle(f32, r_chunk, undefined, rev8) >= zero8);
            i += 8;
        }
    } else if (comptime LANES >= 8) {
        const zero8: @Vector(8, f32) = @splat(0.0);
        const rev8 = [8]i32{ 7, 6, 5, 4, 3, 2, 1, 0 };
        var abs8: @Vector(8, f32) = @splat(0.0);
        const vec8 = dim - (dim % 8);
        while (i < vec8) : (i += 8) {
            const r_chunk: @Vector(8, f32) = rotated_scratch[i..][0..8].*;
            abs8 += @abs(r_chunk);
            code_out[i / 8] = @bitCast(@shuffle(f32, r_chunk, undefined, rev8) >= zero8);
        }
        abs_sum += distance.hsumVec(8, abs8);
    } else if (comptime LANES >= 4) {
        const zero8: @Vector(8, f32) = @splat(0.0);
        var abs8: @Vector(8, f32) = @splat(0.0);
        const vec8 = dim - (dim % 8);
        while (i < vec8) : (i += 8) {
            const r_chunk: @Vector(8, f32) = rotated_scratch[i..][0..8].*;
            abs8 += @abs(r_chunk);
            const mask: u8 = @bitCast(r_chunk >= zero8);
            code_out[i / 8] = distance.BITREV_LUT[mask];
        }
        abs_sum += distance.hsumVec(8, abs8);
    } else {
        const vec8 = dim - (dim % 8);
        while (i < vec8) : (i += 8) {
            var byte: u8 = 0;
            inline for (0..8) |bit| {
                const r = rotated_scratch[i + bit];
                abs_sum += @abs(r);
                if (r >= 0.0) byte |= (@as(u8, 1) << @intCast(7 - bit));
            }
            code_out[i / 8] = byte;
        }
    }

    // Scalar tail for final partial byte when dim % 8 != 0.
    if (i < dim) {
        const byte_idx = i / 8;
        var tail_byte: u8 = 0;
        while (i < dim) : (i += 1) {
            const r = rotated_scratch[i];
            abs_sum += @abs(r);
            if (r >= 0.0) {
                tail_byte |= @as(u8, 1) << @intCast(7 - (i % 8));
            }
        }
        code_out[byte_idx] = tail_byte;
    }

    const sqrt_d = @sqrt(@as(f32, @floatFromInt(dim)));
    const denom = if (prescale) sqrt_d else l2 * sqrt_d;
    const corr = abs_sum / denom;

    return .{ .code = code_out, .l2_norm = l2, .corr = corr };
}

// ╔═══════════════════════════════════════════════════╗
// ║  Query Preparation                                 ║
// ╚═══════════════════════════════════════════════════╝

/// Prepare a query for RaBitQ estimation: compute ||q - c||, write
/// R @ (q - c)/||q - c|| into `q_rot_unit_out`. The caller then reuses
/// these across all candidates.
pub fn prepareQuery(
    q: []align(1) const f32,
    params: *const RabitqParams,
    residual_scratch: []f32,
    q_rot_unit_out: []f32,
) f32 {
    const dim = q.len;
    std.debug.assert(dim == params.dim);
    std.debug.assert(residual_scratch.len == dim);
    std.debug.assert(q_rot_unit_out.len == dim);

    const sum_sq = computeResidualAndNormSq(q, params.centroid, residual_scratch);
    const l2 = @sqrt(sum_sq);

    if (l2 < 1e-20) {
        @memset(q_rot_unit_out, 0);
        return 0.0;
    }

    const inv_l2 = 1.0 / l2;
    const inv_v: F32xN = @splat(inv_l2);
    const step4 = LANES * 4;
    const vec4_dim = dim - (dim % step4);
    const vec_dim = dim - (dim % LANES);
    var i: usize = 0;
    while (i < vec4_dim) : (i += step4) {
        residual_scratch[i..][0..LANES].* = @as(F32xN, residual_scratch[i..][0..LANES].*) * inv_v;
        residual_scratch[i + LANES ..][0..LANES].* = @as(F32xN, residual_scratch[i + LANES ..][0..LANES].*) * inv_v;
        residual_scratch[i + LANES * 2 ..][0..LANES].* = @as(F32xN, residual_scratch[i + LANES * 2 ..][0..LANES].*) * inv_v;
        residual_scratch[i + LANES * 3 ..][0..LANES].* = @as(F32xN, residual_scratch[i + LANES * 3 ..][0..LANES].*) * inv_v;
    }
    while (i < vec_dim) : (i += LANES) {
        residual_scratch[i..][0..LANES].* = @as(F32xN, residual_scratch[i..][0..LANES].*) * inv_v;
    }
    while (i < dim) : (i += 1) residual_scratch[i] *= inv_l2;

    const resid_unit: []align(1) const f32 = @ptrCast(residual_scratch);
    applyRotation(params.rotation, resid_unit, q_rot_unit_out);
    return l2;
}

/// Zero-allocation full query preparation: rotates `q`, precomputes scalar
/// constants (`q_l2_sq`, `inv_sqrt_d`, `q_sum`), and scalar-quantizes
/// `q_rot_unit` into 4 MSB-first bit-planes in `plane_buf` (`len == 4 * codeBytes(dim)`).
pub fn prepareQueryFull(
    q: []align(1) const f32,
    params: *const RabitqParams,
    residual_scratch: []f32,
    q_rot_unit_out: []f32,
    plane_buf: []u8,
) PreparedQuery {
    const q_l2 = prepareQuery(q, params, residual_scratch, q_rot_unit_out);
    return prepareQueryFromRotated(q_rot_unit_out, q_l2, plane_buf);
}

/// Build a `PreparedQuery` (including 4-bit MSB-first bit-planes) from an
/// already-rotated unit query residual `q_rot_unit` and its L2 norm `q_l2`.
pub fn prepareQueryFromRotated(
    q_rot_unit: []const f32,
    q_l2: f32,
    plane_buf: []u8,
) PreparedQuery {
    const dim = q_rot_unit.len;
    const cb = codeBytes(dim);
    std.debug.assert(plane_buf.len == 4 * cb);

    const inv_sqrt_d: f32 = if (dim > 0) 1.0 / @sqrt(@as(f32, @floatFromInt(dim))) else 0.0;

    const q_planes: [4][]u8 = .{
        plane_buf[0 * cb ..][0..cb],
        plane_buf[1 * cb ..][0..cb],
        plane_buf[2 * cb ..][0..cb],
        plane_buf[3 * cb ..][0..cb],
    };
    @memset(plane_buf, 0);

    if (dim == 0) {
        return .{
            .q_rot_unit = q_rot_unit,
            .q_l2 = 0.0,
            .q_l2_sq = 0.0,
            .inv_sqrt_d = 0.0,
            .q_sum = 0.0,
            .q_vl = 0.0,
            .q_delta = 0.0,
            .q_planes = q_planes,
            .code_bytes = cb,
            .dim = 0,
        };
    }

    var q_min: f32 = q_rot_unit[0];
    var q_max: f32 = q_rot_unit[0];
    var q_sum: f32 = 0.0;
    for (q_rot_unit) |x| {
        if (x < q_min) q_min = x;
        if (x > q_max) q_max = x;
        q_sum += x;
    }

    const range = q_max - q_min;
    const q_vl = q_min;
    var q_delta: f32 = 0.0;

    if (range > 1e-30) {
        q_delta = range / 15.0;
        const inv_delta = 15.0 / range;
        var byte_idx: usize = 0;
        const full_bytes = dim / 8;
        while (byte_idx < full_bytes) : (byte_idx += 1) {
            const base = byte_idx * 8;
            var p0: u8 = 0;
            var p1: u8 = 0;
            var p2: u8 = 0;
            var p3: u8 = 0;
            inline for (0..8) |bit| {
                const scaled = (q_rot_unit[base + bit] - q_vl) * inv_delta;
                const clamped = @min(@as(f32, 15.0), @max(@as(f32, 0.0), @floor(scaled + 0.5)));
                const qi: u4 = @intFromFloat(clamped);
                const shift: u3 = @intCast(7 - bit);
                p0 |= @as(u8, qi & 1) << shift;
                p1 |= @as(u8, (qi >> 1) & 1) << shift;
                p2 |= @as(u8, (qi >> 2) & 1) << shift;
                p3 |= @as(u8, (qi >> 3) & 1) << shift;
            }
            q_planes[0][byte_idx] = p0;
            q_planes[1][byte_idx] = p1;
            q_planes[2][byte_idx] = p2;
            q_planes[3][byte_idx] = p3;
        }
        const tail_start = full_bytes * 8;
        if (tail_start < dim) {
            var p0: u8 = 0;
            var p1: u8 = 0;
            var p2: u8 = 0;
            var p3: u8 = 0;
            var d: usize = tail_start;
            while (d < dim) : (d += 1) {
                const scaled = (q_rot_unit[d] - q_vl) * inv_delta;
                const clamped = @min(@as(f32, 15.0), @max(@as(f32, 0.0), @floor(scaled + 0.5)));
                const qi: u4 = @intFromFloat(clamped);
                const shift: u3 = @intCast(7 - (d % 8));
                p0 |= @as(u8, qi & 1) << shift;
                p1 |= @as(u8, (qi >> 1) & 1) << shift;
                p2 |= @as(u8, (qi >> 2) & 1) << shift;
                p3 |= @as(u8, (qi >> 3) & 1) << shift;
            }
            q_planes[0][full_bytes] = p0;
            q_planes[1][full_bytes] = p1;
            q_planes[2][full_bytes] = p2;
            q_planes[3][full_bytes] = p3;
        }
    }

    return .{
        .q_rot_unit = q_rot_unit,
        .q_l2 = q_l2,
        .q_l2_sq = q_l2 * q_l2,
        .inv_sqrt_d = inv_sqrt_d,
        .q_sum = q_sum,
        .q_vl = q_vl,
        .q_delta = q_delta,
        .q_planes = q_planes,
        .code_bytes = cb,
        .dim = dim,
    };
}

// ╔═══════════════════════════════════════════════════╗
// ║  Estimate — Exact F32 (Single & Batch4)            ║
// ╚═══════════════════════════════════════════════════╝

const BIT_MASKS_8: @Vector(8, u32) = .{ 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 };
const BIT_MASKS_LO16: @Vector(16, u32) = .{
    0x0000_0080, 0x0000_0040, 0x0000_0020, 0x0000_0010,
    0x0000_0008, 0x0000_0004, 0x0000_0002, 0x0000_0001,
    0x0000_8000, 0x0000_4000, 0x0000_2000, 0x0000_1000,
    0x0000_0800, 0x0000_0400, 0x0000_0200, 0x0000_0100,
};
const BIT_MASKS_HI16: @Vector(16, u32) = .{
    0x0080_0000, 0x0040_0000, 0x0020_0000, 0x0010_0000,
    0x0008_0000, 0x0004_0000, 0x0002_0000, 0x0001_0000,
    0x8000_0000, 0x4000_0000, 0x2000_0000, 0x1000_0000,
    0x0800_0000, 0x0400_0000, 0x0200_0000, 0x0100_0000,
};

inline fn rawIpExactF32(q_rot_unit: []const f32, code: []const u8) f32 {
    const dim = q_rot_unit.len;
    var ip_raw: f32 = 0.0;
    var i: usize = 0;

    if (comptime has_avx512f) {
        const sign16: @Vector(16, u32) = @splat(0x80000000);
        const zero16: @Vector(16, u32) = @splat(0);
        var acc0: @Vector(16, f32) = @splat(0.0);
        var acc1: @Vector(16, f32) = @splat(0.0);
        const vec32 = dim - (dim % 32);
        while (i < vec32) : (i += 32) {
            const b = i / 8;
            const w: u32 = std.mem.readInt(u32, code[b..][0..4], .little);
            const wv: @Vector(16, u32) = @splat(w);
            const neg0 = (wv & BIT_MASKS_LO16) == zero16;
            const neg1 = (wv & BIT_MASKS_HI16) == zero16;
            const q0: @Vector(16, u32) = @bitCast(@as(@Vector(16, f32), q_rot_unit[i..][0..16].*));
            const q1: @Vector(16, u32) = @bitCast(@as(@Vector(16, f32), q_rot_unit[i + 16 ..][0..16].*));
            acc0 += @as(@Vector(16, f32), @bitCast(@select(u32, neg0, q0 ^ sign16, q0)));
            acc1 += @as(@Vector(16, f32), @bitCast(@select(u32, neg1, q1 ^ sign16, q1)));
        }
        if (i + 16 <= dim) {
            const b = i / 8;
            const w: u32 = std.mem.readInt(u16, code[b..][0..2], .little);
            const wv: @Vector(16, u32) = @splat(w);
            const neg0 = (wv & BIT_MASKS_LO16) == zero16;
            const q0: @Vector(16, u32) = @bitCast(@as(@Vector(16, f32), q_rot_unit[i..][0..16].*));
            acc0 += @as(@Vector(16, f32), @bitCast(@select(u32, neg0, q0 ^ sign16, q0)));
            i += 16;
        }
        ip_raw = distance.hsumVec(16, acc0 + acc1);
        if (i + 8 <= dim) {
            const sign8: @Vector(8, u32) = @splat(0x80000000);
            const zero8: @Vector(8, u32) = @splat(0);
            const bv: @Vector(8, u32) = @splat(@as(u32, code[i / 8]));
            const neg = (bv & BIT_MASKS_8) == zero8;
            const q0: @Vector(8, u32) = @bitCast(@as(@Vector(8, f32), q_rot_unit[i..][0..8].*));
            ip_raw += distance.hsumVec(8, @as(@Vector(8, f32), @bitCast(@select(u32, neg, q0 ^ sign8, q0))));
            i += 8;
        }
    } else if (comptime LANES >= 4) {
        const sign8: @Vector(8, u32) = @splat(0x80000000);
        const zero8: @Vector(8, u32) = @splat(0);
        var acc0: @Vector(8, f32) = @splat(0.0);
        var acc1: @Vector(8, f32) = @splat(0.0);
        const vec16 = dim - (dim % 16);
        while (i < vec16) : (i += 16) {
            const b = i / 8;
            const b0: @Vector(8, u32) = @splat(@as(u32, code[b]));
            const b1: @Vector(8, u32) = @splat(@as(u32, code[b + 1]));
            const flip0 = @select(u32, (b0 & BIT_MASKS_8) == zero8, sign8, zero8);
            const flip1 = @select(u32, (b1 & BIT_MASKS_8) == zero8, sign8, zero8);
            const q0: @Vector(8, u32) = @bitCast(@as(@Vector(8, f32), q_rot_unit[i..][0..8].*));
            const q1: @Vector(8, u32) = @bitCast(@as(@Vector(8, f32), q_rot_unit[i + 8 ..][0..8].*));
            acc0 += @as(@Vector(8, f32), @bitCast(q0 ^ flip0));
            acc1 += @as(@Vector(8, f32), @bitCast(q1 ^ flip1));
        }
        if (i + 8 <= dim) {
            const b0: @Vector(8, u32) = @splat(@as(u32, code[i / 8]));
            const flip0 = @select(u32, (b0 & BIT_MASKS_8) == zero8, sign8, zero8);
            const q0: @Vector(8, u32) = @bitCast(@as(@Vector(8, f32), q_rot_unit[i..][0..8].*));
            acc0 += @as(@Vector(8, f32), @bitCast(q0 ^ flip0));
            i += 8;
        }
        ip_raw = distance.hsumVec(8, acc0 + acc1);
    }

    if (i < dim) {
        while (i < dim) : (i += 1) {
            const bit_set = (code[i / 8] >> @as(u3, @intCast(7 - (i % 8)))) & 1;
            ip_raw += if (bit_set != 0) q_rot_unit[i] else -q_rot_unit[i];
        }
    }

    return ip_raw;
}

inline fn finalizeL2Sq(q_l2: f32, q_l2_sq: f32, inv_sqrt_d: f32, ip_raw: f32, v_l2: f32, v_corr: f32) f32 {
    if (v_corr < 1e-8) return std.math.inf(f32);
    const cos_est = (ip_raw * inv_sqrt_d) / v_corr;
    return q_l2_sq + v_l2 * v_l2 - 2.0 * q_l2 * v_l2 * cos_est;
}

/// Estimate squared L2 distance from a prepared query to an encoded
/// database point (exact f32 query inner product).
pub fn estimateL2Sq(
    q_rot_unit: []const f32,
    q_l2: f32,
    code: []const u8,
    v_l2: f32,
    v_corr: f32,
) f32 {
    if (v_corr < 1e-8) return std.math.inf(f32);
    const dim = q_rot_unit.len;
    if (dim == 0) return q_l2 * q_l2 + v_l2 * v_l2;
    const ip_raw = rawIpExactF32(q_rot_unit, code);
    const inv_sqrt_d: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(dim)));
    return finalizeL2Sq(q_l2, q_l2 * q_l2, inv_sqrt_d, ip_raw, v_l2, v_corr);
}

/// Exact-f32 RaBitQ estimator using precomputed `PreparedQuery` (no per-candidate `sqrt`).
pub fn estimateL2SqPrepared(
    pq: *const PreparedQuery,
    code: []const u8,
    v_l2: f32,
    v_corr: f32,
) f32 {
    if (v_corr < 1e-8) return std.math.inf(f32);
    if (pq.dim == 0) return pq.q_l2_sq + v_l2 * v_l2;
    const ip_raw = rawIpExactF32(pq.q_rot_unit, code);
    return finalizeL2Sq(pq.q_l2, pq.q_l2_sq, pq.inv_sqrt_d, ip_raw, v_l2, v_corr);
}

/// 4-way batched exact-f32 RaBitQ estimator sharing `q_rot_unit` loads across 4 candidates.
pub fn estimateL2SqBatch4Prepared(
    pq: *const PreparedQuery,
    codes: [4][]const u8,
    v_l2: [4]f32,
    v_corr: [4]f32,
) [4]f32 {
    const dim = pq.dim;
    if (dim == 0) {
        return .{
            if (v_corr[0] < 1e-8) std.math.inf(f32) else pq.q_l2_sq + v_l2[0] * v_l2[0],
            if (v_corr[1] < 1e-8) std.math.inf(f32) else pq.q_l2_sq + v_l2[1] * v_l2[1],
            if (v_corr[2] < 1e-8) std.math.inf(f32) else pq.q_l2_sq + v_l2[2] * v_l2[2],
            if (v_corr[3] < 1e-8) std.math.inf(f32) else pq.q_l2_sq + v_l2[3] * v_l2[3],
        };
    }

    const q = pq.q_rot_unit;
    const c0 = codes[0];
    const c1 = codes[1];
    const c2 = codes[2];
    const c3 = codes[3];

    var ips: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
    var i: usize = 0;

    if (comptime has_avx512f) {
        const sign16: @Vector(16, u32) = @splat(0x80000000);
        const zero16: @Vector(16, u32) = @splat(0);
        var a0: @Vector(16, f32) = @splat(0.0);
        var a1: @Vector(16, f32) = @splat(0.0);
        var a2: @Vector(16, f32) = @splat(0.0);
        var a3: @Vector(16, f32) = @splat(0.0);
        const vec16 = dim - (dim % 16);
        while (i < vec16) : (i += 16) {
            const b = i / 8;
            const qb: @Vector(16, u32) = @bitCast(@as(@Vector(16, f32), q[i..][0..16].*));
            const w0: @Vector(16, u32) = @splat(@as(u32, std.mem.readInt(u16, c0[b..][0..2], .little)));
            const w1: @Vector(16, u32) = @splat(@as(u32, std.mem.readInt(u16, c1[b..][0..2], .little)));
            const w2: @Vector(16, u32) = @splat(@as(u32, std.mem.readInt(u16, c2[b..][0..2], .little)));
            const w3: @Vector(16, u32) = @splat(@as(u32, std.mem.readInt(u16, c3[b..][0..2], .little)));
            a0 += @as(@Vector(16, f32), @bitCast(@select(u32, (w0 & BIT_MASKS_LO16) == zero16, qb ^ sign16, qb)));
            a1 += @as(@Vector(16, f32), @bitCast(@select(u32, (w1 & BIT_MASKS_LO16) == zero16, qb ^ sign16, qb)));
            a2 += @as(@Vector(16, f32), @bitCast(@select(u32, (w2 & BIT_MASKS_LO16) == zero16, qb ^ sign16, qb)));
            a3 += @as(@Vector(16, f32), @bitCast(@select(u32, (w3 & BIT_MASKS_LO16) == zero16, qb ^ sign16, qb)));
        }
        ips = distance.hsum4Vec(16, a0, a1, a2, a3);
        if (i + 8 <= dim) {
            const sign8: @Vector(8, u32) = @splat(0x80000000);
            const zero8: @Vector(8, u32) = @splat(0);
            const b = i / 8;
            const qb: @Vector(8, u32) = @bitCast(@as(@Vector(8, f32), q[i..][0..8].*));
            const s8 = distance.hsum4Vec(
                8,
                @as(@Vector(8, f32), @bitCast(@select(u32, (@as(@Vector(8, u32), @splat(@as(u32, c0[b]))) & BIT_MASKS_8) == zero8, qb ^ sign8, qb))),
                @as(@Vector(8, f32), @bitCast(@select(u32, (@as(@Vector(8, u32), @splat(@as(u32, c1[b]))) & BIT_MASKS_8) == zero8, qb ^ sign8, qb))),
                @as(@Vector(8, f32), @bitCast(@select(u32, (@as(@Vector(8, u32), @splat(@as(u32, c2[b]))) & BIT_MASKS_8) == zero8, qb ^ sign8, qb))),
                @as(@Vector(8, f32), @bitCast(@select(u32, (@as(@Vector(8, u32), @splat(@as(u32, c3[b]))) & BIT_MASKS_8) == zero8, qb ^ sign8, qb))),
            );
            inline for (0..4) |k| ips[k] += s8[k];
            i += 8;
        }
    } else if (comptime LANES >= 4) {
        const sign8: @Vector(8, u32) = @splat(0x80000000);
        const zero8: @Vector(8, u32) = @splat(0);
        var a0: @Vector(8, f32) = @splat(0.0);
        var a1: @Vector(8, f32) = @splat(0.0);
        var a2: @Vector(8, f32) = @splat(0.0);
        var a3: @Vector(8, f32) = @splat(0.0);
        const vec8 = dim - (dim % 8);
        while (i < vec8) : (i += 8) {
            const b = i / 8;
            const qb: @Vector(8, u32) = @bitCast(@as(@Vector(8, f32), q[i..][0..8].*));
            const w0: @Vector(8, u32) = @splat(@as(u32, c0[b]));
            const w1: @Vector(8, u32) = @splat(@as(u32, c1[b]));
            const w2: @Vector(8, u32) = @splat(@as(u32, c2[b]));
            const w3: @Vector(8, u32) = @splat(@as(u32, c3[b]));
            a0 += @as(@Vector(8, f32), @bitCast(qb ^ @select(u32, (w0 & BIT_MASKS_8) == zero8, sign8, zero8)));
            a1 += @as(@Vector(8, f32), @bitCast(qb ^ @select(u32, (w1 & BIT_MASKS_8) == zero8, sign8, zero8)));
            a2 += @as(@Vector(8, f32), @bitCast(qb ^ @select(u32, (w2 & BIT_MASKS_8) == zero8, sign8, zero8)));
            a3 += @as(@Vector(8, f32), @bitCast(qb ^ @select(u32, (w3 & BIT_MASKS_8) == zero8, sign8, zero8)));
        }
        ips = distance.hsum4Vec(8, a0, a1, a2, a3);
    }

    if (i < dim) {
        while (i < dim) : (i += 1) {
            const b = i / 8;
            const shift: u3 = @intCast(7 - (i % 8));
            const qv = q[i];
            ips[0] += if (((c0[b] >> shift) & 1) != 0) qv else -qv;
            ips[1] += if (((c1[b] >> shift) & 1) != 0) qv else -qv;
            ips[2] += if (((c2[b] >> shift) & 1) != 0) qv else -qv;
            ips[3] += if (((c3[b] >> shift) & 1) != 0) qv else -qv;
        }
    }

    return .{
        finalizeL2Sq(pq.q_l2, pq.q_l2_sq, pq.inv_sqrt_d, ips[0], v_l2[0], v_corr[0]),
        finalizeL2Sq(pq.q_l2, pq.q_l2_sq, pq.inv_sqrt_d, ips[1], v_l2[1], v_corr[1]),
        finalizeL2Sq(pq.q_l2, pq.q_l2_sq, pq.inv_sqrt_d, ips[2], v_l2[2], v_corr[2]),
        finalizeL2Sq(pq.q_l2, pq.q_l2_sq, pq.inv_sqrt_d, ips[3], v_l2[3], v_corr[3]),
    };
}

// ╔═══════════════════════════════════════════════════╗
// ║  Estimate — 4-Bit Query Bit-Plane AND-Popcount     ║
// ╚═══════════════════════════════════════════════════╝

inline fn popcountSlice(bytes: []const u8) u32 {
    const len = bytes.len;
    var acc: u32 = 0;
    var i: usize = 0;
    if (comptime has_avx512_vpopcntdq) {
        if (len >= 64) {
            var v_acc: @Vector(8, u64) = @splat(0);
            const end64 = len - (len % 64);
            while (i < end64) : (i += 64) {
                const v = distance.loadU64Vec(8, bytes.ptr + i);
                v_acc += @popCount(v);
            }
            acc += @truncate(@reduce(.Add, v_acc));
        }
    } else if (comptime is_aarch64) {
        while (i + 16 <= len) {
            var v_acc: @Vector(16, u16) = @splat(0);
            var iters: usize = 0;
            while (i + 16 <= len and iters < 4096) : ({
                i += 16;
                iters += 1;
            }) {
                const v: @Vector(16, u8) = bytes[i..][0..16].*;
                v_acc += @as(@Vector(16, u16), @popCount(v));
            }
            acc += @reduce(.Add, @as(@Vector(16, u32), v_acc));
        }
    }
    while (i + 8 <= len) : (i += 8) {
        const w: u64 = @bitCast(bytes[i..][0..8].*);
        acc += @popCount(w);
    }
    while (i < len) : (i += 1) {
        acc += @popCount(bytes[i]);
    }
    return acc;
}

/// Bit-parallel inner product `⟨code, q'⟩` and `popcount(code)` over 4 query bit-planes.
/// Zero floating-point operations in the inner loop.
inline fn andPopcount4Bit(
    code: []const u8,
    q_planes: [4][]u8,
    comptime need_code_popc: bool,
) struct { int_ip: u32, code_popc: u32 } {
    const len = q_planes[0].len;
    const qp0 = q_planes[0];
    const qp1 = q_planes[1];
    const qp2 = q_planes[2];
    const qp3 = q_planes[3];

    var p0: u32 = 0;
    var p1: u32 = 0;
    var p2: u32 = 0;
    var p3: u32 = 0;
    var pc: u32 = 0;
    var i: usize = 0;

    if (comptime has_avx512_vpopcntdq) {
        if (len >= 64) {
            var a0: @Vector(8, u64) = @splat(0);
            var a1: @Vector(8, u64) = @splat(0);
            var a2: @Vector(8, u64) = @splat(0);
            var a3: @Vector(8, u64) = @splat(0);
            var ac: @Vector(8, u64) = @splat(0);
            const end64 = len - (len % 64);
            while (i < end64) : (i += 64) {
                const vc = distance.loadU64Vec(8, code.ptr + i);
                a0 += @popCount(vc & distance.loadU64Vec(8, qp0.ptr + i));
                a1 += @popCount(vc & distance.loadU64Vec(8, qp1.ptr + i));
                a2 += @popCount(vc & distance.loadU64Vec(8, qp2.ptr + i));
                a3 += @popCount(vc & distance.loadU64Vec(8, qp3.ptr + i));
                if (comptime need_code_popc) ac += @popCount(vc);
            }
            p0 += @truncate(@reduce(.Add, a0));
            p1 += @truncate(@reduce(.Add, a1));
            p2 += @truncate(@reduce(.Add, a2));
            p3 += @truncate(@reduce(.Add, a3));
            if (comptime need_code_popc) pc += @truncate(@reduce(.Add, ac));
        }
        if (comptime has_avx512vl) {
            if (i + 32 <= len) {
                const vc = distance.loadU64Vec(4, code.ptr + i);
                p0 += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vc & distance.loadU64Vec(4, qp0.ptr + i)))));
                p1 += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vc & distance.loadU64Vec(4, qp1.ptr + i)))));
                p2 += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vc & distance.loadU64Vec(4, qp2.ptr + i)))));
                p3 += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vc & distance.loadU64Vec(4, qp3.ptr + i)))));
                if (comptime need_code_popc) pc += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vc))));
                i += 32;
            }
        }
    } else if (comptime is_aarch64) {
        while (i + 16 <= len) {
            var a0: @Vector(16, u16) = @splat(0);
            var a1: @Vector(16, u16) = @splat(0);
            var a2: @Vector(16, u16) = @splat(0);
            var a3: @Vector(16, u16) = @splat(0);
            var ac: @Vector(16, u16) = @splat(0);
            var iters: usize = 0;
            while (i + 16 <= len and iters < 4096) : ({
                i += 16;
                iters += 1;
            }) {
                const vc: @Vector(16, u8) = code[i..][0..16].*;
                a0 += @as(@Vector(16, u16), @popCount(vc & @as(@Vector(16, u8), qp0[i..][0..16].*)));
                a1 += @as(@Vector(16, u16), @popCount(vc & @as(@Vector(16, u8), qp1[i..][0..16].*)));
                a2 += @as(@Vector(16, u16), @popCount(vc & @as(@Vector(16, u8), qp2[i..][0..16].*)));
                a3 += @as(@Vector(16, u16), @popCount(vc & @as(@Vector(16, u8), qp3[i..][0..16].*)));
                if (comptime need_code_popc) ac += @as(@Vector(16, u16), @popCount(vc));
            }
            p0 += @reduce(.Add, @as(@Vector(16, u32), a0));
            p1 += @reduce(.Add, @as(@Vector(16, u32), a1));
            p2 += @reduce(.Add, @as(@Vector(16, u32), a2));
            p3 += @reduce(.Add, @as(@Vector(16, u32), a3));
            if (comptime need_code_popc) pc += @reduce(.Add, @as(@Vector(16, u32), ac));
        }
    }

    while (i + 8 <= len) : (i += 8) {
        const wc: u64 = @bitCast(code[i..][0..8].*);
        p0 += @popCount(wc & @as(u64, @bitCast(qp0[i..][0..8].*)));
        p1 += @popCount(wc & @as(u64, @bitCast(qp1[i..][0..8].*)));
        p2 += @popCount(wc & @as(u64, @bitCast(qp2[i..][0..8].*)));
        p3 += @popCount(wc & @as(u64, @bitCast(qp3[i..][0..8].*)));
        if (comptime need_code_popc) pc += @popCount(wc);
    }

    while (i < len) : (i += 1) {
        const cb = code[i];
        p0 += @popCount(cb & qp0[i]);
        p1 += @popCount(cb & qp1[i]);
        p2 += @popCount(cb & qp2[i]);
        p3 += @popCount(cb & qp3[i]);
        if (comptime need_code_popc) pc += @popCount(cb);
    }

    return .{
        .int_ip = p0 + (p1 << 1) + (p2 << 2) + (p3 << 3),
        .code_popc = pc,
    };
}

/// 4-way batched bit-parallel AND-Popcount sharing query bit-plane loads across 4 codes.
inline fn andPopcount4BitBatch4(
    codes: [4][]const u8,
    q_planes: [4][]u8,
    comptime need_code_popc: bool,
) struct { int_ip: [4]u32, code_popc: [4]u32 } {
    const len = q_planes[0].len;
    const qp0 = q_planes[0];
    const qp1 = q_planes[1];
    const qp2 = q_planes[2];
    const qp3 = q_planes[3];
    const c0 = codes[0];
    const c1 = codes[1];
    const c2 = codes[2];
    const c3 = codes[3];

    var r_p0: [4]u32 = .{ 0, 0, 0, 0 };
    var r_p1: [4]u32 = .{ 0, 0, 0, 0 };
    var r_p2: [4]u32 = .{ 0, 0, 0, 0 };
    var r_p3: [4]u32 = .{ 0, 0, 0, 0 };
    var r_pc: [4]u32 = .{ 0, 0, 0, 0 };
    var i: usize = 0;

    if (comptime has_avx512_vpopcntdq) {
        if (len >= 64) {
            var a0: [4]@Vector(8, u64) = @splat(@splat(0));
            var a1: [4]@Vector(8, u64) = @splat(@splat(0));
            var a2: [4]@Vector(8, u64) = @splat(@splat(0));
            var a3: [4]@Vector(8, u64) = @splat(@splat(0));
            var ac: [4]@Vector(8, u64) = @splat(@splat(0));
            const end64 = len - (len % 64);
            while (i < end64) : (i += 64) {
                const vq0 = distance.loadU64Vec(8, qp0.ptr + i);
                const vq1 = distance.loadU64Vec(8, qp1.ptr + i);
                const vq2 = distance.loadU64Vec(8, qp2.ptr + i);
                const vq3 = distance.loadU64Vec(8, qp3.ptr + i);
                const vcs: [4]@Vector(8, u64) = .{
                    distance.loadU64Vec(8, c0.ptr + i),
                    distance.loadU64Vec(8, c1.ptr + i),
                    distance.loadU64Vec(8, c2.ptr + i),
                    distance.loadU64Vec(8, c3.ptr + i),
                };
                inline for (0..4) |k| {
                    a0[k] += @popCount(vcs[k] & vq0);
                    a1[k] += @popCount(vcs[k] & vq1);
                    a2[k] += @popCount(vcs[k] & vq2);
                    a3[k] += @popCount(vcs[k] & vq3);
                    if (comptime need_code_popc) ac[k] += @popCount(vcs[k]);
                }
            }
            inline for (0..4) |k| {
                r_p0[k] += @truncate(@reduce(.Add, a0[k]));
                r_p1[k] += @truncate(@reduce(.Add, a1[k]));
                r_p2[k] += @truncate(@reduce(.Add, a2[k]));
                r_p3[k] += @truncate(@reduce(.Add, a3[k]));
                if (comptime need_code_popc) r_pc[k] += @truncate(@reduce(.Add, ac[k]));
            }
        }
        if (comptime has_avx512vl) {
            if (i + 32 <= len) {
                const vq0 = distance.loadU64Vec(4, qp0.ptr + i);
                const vq1 = distance.loadU64Vec(4, qp1.ptr + i);
                const vq2 = distance.loadU64Vec(4, qp2.ptr + i);
                const vq3 = distance.loadU64Vec(4, qp3.ptr + i);
                const vcs: [4]@Vector(4, u64) = .{
                    distance.loadU64Vec(4, c0.ptr + i),
                    distance.loadU64Vec(4, c1.ptr + i),
                    distance.loadU64Vec(4, c2.ptr + i),
                    distance.loadU64Vec(4, c3.ptr + i),
                };
                inline for (0..4) |k| {
                    r_p0[k] += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vcs[k] & vq0))));
                    r_p1[k] += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vcs[k] & vq1))));
                    r_p2[k] += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vcs[k] & vq2))));
                    r_p3[k] += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vcs[k] & vq3))));
                    if (comptime need_code_popc) r_pc[k] += @truncate(@reduce(.Add, @as(@Vector(4, u64), @popCount(vcs[k]))));
                }
                i += 32;
            }
        }
    } else if (comptime is_aarch64) {
        while (i + 16 <= len) {
            var a0: [4]@Vector(16, u16) = @splat(@splat(0));
            var a1: [4]@Vector(16, u16) = @splat(@splat(0));
            var a2: [4]@Vector(16, u16) = @splat(@splat(0));
            var a3: [4]@Vector(16, u16) = @splat(@splat(0));
            var ac: [4]@Vector(16, u16) = @splat(@splat(0));
            var iters: usize = 0;
            while (i + 16 <= len and iters < 4096) : ({
                i += 16;
                iters += 1;
            }) {
                const vq0: @Vector(16, u8) = qp0[i..][0..16].*;
                const vq1: @Vector(16, u8) = qp1[i..][0..16].*;
                const vq2: @Vector(16, u8) = qp2[i..][0..16].*;
                const vq3: @Vector(16, u8) = qp3[i..][0..16].*;
                const vcs: [4]@Vector(16, u8) = .{
                    c0[i..][0..16].*,
                    c1[i..][0..16].*,
                    c2[i..][0..16].*,
                    c3[i..][0..16].*,
                };
                inline for (0..4) |k| {
                    a0[k] += @as(@Vector(16, u16), @popCount(vcs[k] & vq0));
                    a1[k] += @as(@Vector(16, u16), @popCount(vcs[k] & vq1));
                    a2[k] += @as(@Vector(16, u16), @popCount(vcs[k] & vq2));
                    a3[k] += @as(@Vector(16, u16), @popCount(vcs[k] & vq3));
                    if (comptime need_code_popc) ac[k] += @as(@Vector(16, u16), @popCount(vcs[k]));
                }
            }
            inline for (0..4) |k| {
                r_p0[k] += @reduce(.Add, @as(@Vector(16, u32), a0[k]));
                r_p1[k] += @reduce(.Add, @as(@Vector(16, u32), a1[k]));
                r_p2[k] += @reduce(.Add, @as(@Vector(16, u32), a2[k]));
                r_p3[k] += @reduce(.Add, @as(@Vector(16, u32), a3[k]));
                if (comptime need_code_popc) r_pc[k] += @reduce(.Add, @as(@Vector(16, u32), ac[k]));
            }
        }
    }

    while (i + 8 <= len) : (i += 8) {
        const wq0: u64 = @bitCast(qp0[i..][0..8].*);
        const wq1: u64 = @bitCast(qp1[i..][0..8].*);
        const wq2: u64 = @bitCast(qp2[i..][0..8].*);
        const wq3: u64 = @bitCast(qp3[i..][0..8].*);
        const wcs: [4]u64 = .{
            @bitCast(c0[i..][0..8].*),
            @bitCast(c1[i..][0..8].*),
            @bitCast(c2[i..][0..8].*),
            @bitCast(c3[i..][0..8].*),
        };
        inline for (0..4) |k| {
            r_p0[k] += @popCount(wcs[k] & wq0);
            r_p1[k] += @popCount(wcs[k] & wq1);
            r_p2[k] += @popCount(wcs[k] & wq2);
            r_p3[k] += @popCount(wcs[k] & wq3);
            if (comptime need_code_popc) r_pc[k] += @popCount(wcs[k]);
        }
    }

    while (i < len) : (i += 1) {
        const bq0 = qp0[i];
        const bq1 = qp1[i];
        const bq2 = qp2[i];
        const bq3 = qp3[i];
        const bcs: [4]u8 = .{ c0[i], c1[i], c2[i], c3[i] };
        inline for (0..4) |k| {
            r_p0[k] += @popCount(bcs[k] & bq0);
            r_p1[k] += @popCount(bcs[k] & bq1);
            r_p2[k] += @popCount(bcs[k] & bq2);
            r_p3[k] += @popCount(bcs[k] & bq3);
            if (comptime need_code_popc) r_pc[k] += @popCount(bcs[k]);
        }
    }

    return .{
        .int_ip = .{
            r_p0[0] + (r_p1[0] << 1) + (r_p2[0] << 2) + (r_p3[0] << 3),
            r_p0[1] + (r_p1[1] << 1) + (r_p2[1] << 2) + (r_p3[1] << 3),
            r_p0[2] + (r_p1[2] << 1) + (r_p2[2] << 2) + (r_p3[2] << 3),
            r_p0[3] + (r_p1[3] << 1) + (r_p2[3] << 2) + (r_p3[3] << 3),
        },
        .code_popc = r_pc,
    };
}

/// 4-bit bit-parallel AND-Popcount RaBitQ estimator (paper §3.3).
/// Works on the exact existing `[code][l2][corr]` format with zero FP ops in the inner loop.
pub fn estimateL2Sq4Bit(
    pq: *const PreparedQuery,
    code: []const u8,
    v_l2: f32,
    v_corr: f32,
) f32 {
    if (v_corr < 1e-8) return std.math.inf(f32);
    if (pq.dim == 0) return pq.q_l2_sq + v_l2 * v_l2;
    const res = andPopcount4Bit(code, pq.q_planes, true);
    const sum_xq = pq.q_vl * @as(f32, @floatFromInt(res.code_popc)) +
        pq.q_delta * @as(f32, @floatFromInt(res.int_ip));
    const ip_raw = 2.0 * sum_xq - pq.q_sum;
    return finalizeL2Sq(pq.q_l2, pq.q_l2_sq, pq.inv_sqrt_d, ip_raw, v_l2, v_corr);
}

/// 4-way batched 4-bit bit-parallel AND-Popcount RaBitQ estimator.
pub fn estimateL2Sq4BitBatch4(
    pq: *const PreparedQuery,
    codes: [4][]const u8,
    v_l2: [4]f32,
    v_corr: [4]f32,
) [4]f32 {
    if (pq.dim == 0) {
        return .{
            if (v_corr[0] < 1e-8) std.math.inf(f32) else pq.q_l2_sq + v_l2[0] * v_l2[0],
            if (v_corr[1] < 1e-8) std.math.inf(f32) else pq.q_l2_sq + v_l2[1] * v_l2[1],
            if (v_corr[2] < 1e-8) std.math.inf(f32) else pq.q_l2_sq + v_l2[2] * v_l2[2],
            if (v_corr[3] < 1e-8) std.math.inf(f32) else pq.q_l2_sq + v_l2[3] * v_l2[3],
        };
    }
    const res = andPopcount4BitBatch4(codes, pq.q_planes, true);
    var out: [4]f32 = undefined;
    inline for (0..4) |k| {
        const sum_xq = pq.q_vl * @as(f32, @floatFromInt(res.code_popc[k])) +
            pq.q_delta * @as(f32, @floatFromInt(res.int_ip[k]));
        const ip_raw = 2.0 * sum_xq - pq.q_sum;
        out[k] = finalizeL2Sq(pq.q_l2, pq.q_l2_sq, pq.inv_sqrt_d, ip_raw, v_l2[k], v_corr[k]);
    }
    return out;
}

/// 4-way batched 4-bit AND-Popcount estimator for contiguous SoA RaBitQ slabs.
/// Uses precomputed `f_add = v_l2²`, `f_rescale = 2*v_l2 / (v_corr * √d)` (or `+inf, 0`
/// when `v_corr < 1e-8`), and `v_popc = popcount(code)` — zero division, zero sqrt,
/// and 20% fewer popcounts than the non-slab path.
pub fn estimateL2Sq4BitSlabBatch4(
    pq: *const PreparedQuery,
    codes: [4][]const u8,
    f_add: [4]f32,
    f_rescale: [4]f32,
    v_popc: [4]u16,
) [4]f32 {
    if (pq.dim == 0) {
        return .{
            pq.q_l2_sq + f_add[0],
            pq.q_l2_sq + f_add[1],
            pq.q_l2_sq + f_add[2],
            pq.q_l2_sq + f_add[3],
        };
    }
    const res = andPopcount4BitBatch4(codes, pq.q_planes, false);
    const two_vl = 2.0 * pq.q_vl;
    const two_delta = 2.0 * pq.q_delta;
    var out: [4]f32 = undefined;
    inline for (0..4) |k| {
        const ip_raw = two_vl * @as(f32, @floatFromInt(v_popc[k])) +
            two_delta * @as(f32, @floatFromInt(res.int_ip[k])) - pq.q_sum;
        out[k] = pq.q_l2_sq + f_add[k] - (pq.q_l2 * f_rescale[k]) * ip_raw;
    }
    return out;
}

// ╔═══════════════════════════════════════════════════╗
// ║  Estimate — FastScan 32-Vector Transposed LUT      ║
// ╚═══════════════════════════════════════════════════╝

/// Build a per-4-dim 16-entry quantized u8 lookup table for `q_rot_unit`.
/// `lut_out.len` must equal `fastScanGroups(q_rot_unit.len)`.
/// For group `g`, entry `p ∈ [0..15]` stores the quantized partial signed sum
/// over dimensions `4g .. min(4g+4, dim)` where MSB bit `(3 - b)` corresponds
/// to dimension `4g + b` (matching MSB-first `code` nibbles directly).
pub fn buildFastScanLut(q_rot_unit: []const f32, lut_out: [][16]u8) FastScanLutScale {
    const dim = q_rot_unit.len;
    const n_groups = fastScanGroups(dim);
    std.debug.assert(lut_out.len == n_groups);
    if (n_groups == 0) return .{ .vl = 0.0, .delta = 0.0 };

    // Pass 1: find exact global min/max across all 4-dim partial signed sums.
    // Note: max partial sum in group g is Σ_{b} |q[4g+b]| and min is -max.
    var max_abs: f32 = 0.0;
    for (0..n_groups) |g| {
        var group_abs: f32 = 0.0;
        inline for (0..4) |b| {
            const d = g * 4 + b;
            if (d < dim) group_abs += @abs(q_rot_unit[d]);
        }
        if (group_abs > max_abs) max_abs = group_abs;
    }

    const vl = -max_abs;
    const span = 2.0 * max_abs;
    if (!(span > 1e-30)) {
        for (lut_out) |*entry| entry.* = @splat(0);
        return .{ .vl = 0.0, .delta = 0.0 };
    }

    const delta = span / 255.0;
    const inv_delta = 255.0 / span;

    // Pass 2: quantize all 16 nibble patterns per group into [0..255].
    for (0..n_groups) |g| {
        const base = g * 4;
        const q0: f32 = if (base + 0 < dim) q_rot_unit[base + 0] else 0.0;
        const q1: f32 = if (base + 1 < dim) q_rot_unit[base + 1] else 0.0;
        const q2: f32 = if (base + 2 < dim) q_rot_unit[base + 2] else 0.0;
        const q3: f32 = if (base + 3 < dim) q_rot_unit[base + 3] else 0.0;

        inline for (0..16) |p| {
            const s0: f32 = if ((p & 8) != 0) q0 else -q0;
            const s1: f32 = if ((p & 4) != 0) q1 else -q1;
            const s2: f32 = if ((p & 2) != 0) q2 else -q2;
            const s3: f32 = if ((p & 1) != 0) q3 else -q3;
            const s = (s0 + s1) + (s2 + s3);
            const q_val = @min(@as(f32, 255.0), @max(@as(f32, 0.0), @floor((s - vl) * inv_delta + 0.5)));
            lut_out[g][p] = @intFromFloat(q_val);
        }
    }

    return .{ .vl = vl, .delta = delta };
}

/// Pack 32 1-bit RaBitQ codes into a transposed 4-bit-nibble FastScan block.
/// Layout: `fastScanGroups(dim)` chunks of 16 bytes. In chunk `g`, byte `j ∈ [0..15]`
/// stores vector `j`'s 4-bit pattern in the low nibble (`& 0x0F`) and vector `j + 16`'s
/// 4-bit pattern in the high nibble (`>> 4`).
/// `block_out.len` must equal `fastScanBlockBytes(dim)`.
pub fn packFastScanBlock32(codes: [32][]const u8, dim: usize, block_out: []u8) void {
    const n_groups = fastScanGroups(dim);
    std.debug.assert(block_out.len == n_groups * 16);
    if (n_groups == 0) return;

    for (0..n_groups) |g| {
        const byte_idx = g / 2;
        const is_high_nibble = (g & 1) == 0; // MSB-first: even group = high nibble, odd group = low nibble
        const dst = block_out[g * 16 ..][0..16];
        if (is_high_nibble) {
            inline for (0..16) |j| {
                const lo_vec: u8 = codes[j][byte_idx] >> 4;
                const hi_vec: u8 = codes[j + 16][byte_idx] & 0xF0;
                dst[j] = lo_vec | hi_vec;
            }
        } else {
            inline for (0..16) |j| {
                const lo_vec: u8 = codes[j][byte_idx] & 0x0F;
                const hi_vec: u8 = (codes[j + 16][byte_idx] & 0x0F) << 4;
                dst[j] = lo_vec | hi_vec;
            }
        }
    }
}

inline fn pshufb512(table_4x16: @Vector(64, u8), idx: @Vector(64, u8)) @Vector(64, u8) {
    return asm ("vpshufb %[idx], %[tbl], %[out]"
        : [out] "=v" (-> @Vector(64, u8)),
        : [tbl] "v" (table_4x16),
          [idx] "v" (idx),
    );
}

inline fn pshufb256(table_2x16: @Vector(32, u8), idx: @Vector(32, u8)) @Vector(32, u8) {
    return asm ("vpshufb %[idx], %[tbl], %[out]"
        : [out] "=x" (-> @Vector(32, u8)),
        : [tbl] "x" (table_2x16),
          [idx] "x" (idx),
    );
}

inline fn neonTbl16(table: @Vector(16, u8), idx: @Vector(16, u8)) @Vector(16, u8) {
    return asm ("tbl %[out].16b, {%[tbl].16b}, %[idx].16b"
        : [out] "=w" (-> @Vector(16, u8)),
        : [tbl] "w" (table),
          [idx] "w" (idx),
    );
}

/// Evaluate 32 packed vectors simultaneously via 4-bit transposed LUT lookup.
/// Uses `vpshufb` on x86_64 AVX-512BW (4 groups/iter) / AVX2 (2 groups/iter),
/// `tbl` on aarch64 NEON, and a bit-identical portable fallback on wasm32/baseline x86_64.
pub fn estimateFastScanBlock32(
    lut: []const [16]u8,
    lut_vl: f32,
    lut_delta: f32,
    q_l2: f32,
    q_l2_sq: f32,
    block_packed: []const u8,
    f_add: *const [32]f32,
    f_rescale: *const [32]f32,
    out_d2: *[32]f32,
) void {
    const n_groups = lut.len;
    std.debug.assert(block_packed.len == n_groups * 16);

    var sums_lo: @Vector(16, u32) = @splat(0);
    var sums_hi: @Vector(16, u32) = @splat(0);

    var g: usize = 0;
    if (comptime has_avx512bw) {
        const lut_bytes: [*]const u8 = @ptrCast(lut.ptr);
        const mask_0f_64: @Vector(64, u8) = @splat(0x0F);
        const shift4_64: @Vector(64, u3) = @splat(4);
        const lo32_m = [32]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
        const hi32_m = [32]i32{ 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63 };
        const lo16_m = [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        const hi16_m = [16]i32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };

        // 4 groups/iter in 512-bit ZMM; each u16 lane accumulates 2 groups/iter (flush <= 127 iters = 508 groups: 254*255 <= 65535).
        const groups4 = n_groups - (n_groups % 4);
        while (g < groups4) {
            const end = @min(groups4, g + 508);
            var acc_lo32: @Vector(32, u16) = @splat(0);
            var acc_hi32: @Vector(32, u16) = @splat(0);
            while (g < end) : (g += 4) {
                const off = g * 16;
                const packed64: @Vector(64, u8) = block_packed[off..][0..64].*;
                const lut64: @Vector(64, u8) = lut_bytes[off..][0..64].*;
                const res_lo64 = pshufb512(lut64, packed64 & mask_0f_64);
                const res_hi64 = pshufb512(lut64, packed64 >> shift4_64);
                acc_lo32 += @as(@Vector(32, u16), @shuffle(u8, res_lo64, undefined, lo32_m));
                acc_lo32 += @as(@Vector(32, u16), @shuffle(u8, res_lo64, undefined, hi32_m));
                acc_hi32 += @as(@Vector(32, u16), @shuffle(u8, res_hi64, undefined, lo32_m));
                acc_hi32 += @as(@Vector(32, u16), @shuffle(u8, res_hi64, undefined, hi32_m));
            }
            sums_lo += @as(@Vector(16, u32), @shuffle(u16, acc_lo32, undefined, lo16_m)) +
                @as(@Vector(16, u32), @shuffle(u16, acc_lo32, undefined, hi16_m));
            sums_hi += @as(@Vector(16, u32), @shuffle(u16, acc_hi32, undefined, lo16_m)) +
                @as(@Vector(16, u32), @shuffle(u16, acc_hi32, undefined, hi16_m));
        }

        if (g < n_groups) {
            const mask_0f: @Vector(16, u8) = @splat(0x0F);
            const shift4: @Vector(16, u3) = @splat(4);
            const dup_mask = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
            const cat_mask = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, -13, -14, -15, -16 };
            while (g < n_groups) : (g += 1) {
                const packed16: @Vector(16, u8) = block_packed[g * 16 ..][0..16].*;
                const lut16: @Vector(16, u8) = lut[g];
                const res32 = pshufb256(
                    @shuffle(u8, lut16, lut16, dup_mask),
                    @shuffle(u8, packed16 & mask_0f, packed16 >> shift4, cat_mask),
                );
                sums_lo += @as(@Vector(16, u32), @shuffle(u8, res32, undefined, lo16_m));
                sums_hi += @as(@Vector(16, u32), @shuffle(u8, res32, undefined, hi16_m));
            }
        }
    } else if (comptime has_avx2) {
        const lut_bytes: [*]const u8 = @ptrCast(lut.ptr);
        const mask_0f_32: @Vector(32, u8) = @splat(0x0F);
        const shift4_32: @Vector(32, u3) = @splat(4);
        const lo16_m = [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        const hi16_m = [16]i32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };

        // 2 groups/iter in 256-bit YMM; flush every <= 255 pairs (510 groups: 255*255 <= 65535).
        const groups2 = n_groups - (n_groups % 2);
        while (g < groups2) {
            const end = @min(groups2, g + 510);
            var acc_lo32: @Vector(32, u16) = @splat(0);
            var acc_hi32: @Vector(32, u16) = @splat(0);
            while (g < end) : (g += 2) {
                const off = g * 16;
                const packed32: @Vector(32, u8) = block_packed[off..][0..32].*;
                const lut32: @Vector(32, u8) = lut_bytes[off..][0..32].*;
                acc_lo32 += @as(@Vector(32, u16), pshufb256(lut32, packed32 & mask_0f_32));
                acc_hi32 += @as(@Vector(32, u16), pshufb256(lut32, packed32 >> shift4_32));
            }
            sums_lo += @as(@Vector(16, u32), @shuffle(u16, acc_lo32, undefined, lo16_m)) +
                @as(@Vector(16, u32), @shuffle(u16, acc_lo32, undefined, hi16_m));
            sums_hi += @as(@Vector(16, u32), @shuffle(u16, acc_hi32, undefined, lo16_m)) +
                @as(@Vector(16, u32), @shuffle(u16, acc_hi32, undefined, hi16_m));
        }
        if (g < n_groups) {
            const mask_0f: @Vector(16, u8) = @splat(0x0F);
            const shift4: @Vector(16, u3) = @splat(4);
            const dup_mask = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
            const cat_mask = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, -1, -2, -3, -4, -5, -6, -7, -8, -9, -10, -11, -12, -13, -14, -15, -16 };
            const packed16: @Vector(16, u8) = block_packed[g * 16 ..][0..16].*;
            const lut16: @Vector(16, u8) = lut[g];
            const res32 = pshufb256(
                @shuffle(u8, lut16, lut16, dup_mask),
                @shuffle(u8, packed16 & mask_0f, packed16 >> shift4, cat_mask),
            );
            sums_lo += @as(@Vector(16, u32), @shuffle(u8, res32, undefined, lo16_m));
            sums_hi += @as(@Vector(16, u32), @shuffle(u8, res32, undefined, hi16_m));
        }
    } else if (comptime is_aarch64) {
        const mask_0f: @Vector(16, u8) = @splat(0x0F);
        const shift4: @Vector(16, u3) = @splat(4);
        while (g < n_groups) {
            const end = @min(n_groups, g + 255);
            var acc_lo: @Vector(16, u16) = @splat(0);
            var acc_hi: @Vector(16, u16) = @splat(0);
            while (g < end) : (g += 1) {
                const packed16: @Vector(16, u8) = block_packed[g * 16 ..][0..16].*;
                const idx_lo = packed16 & mask_0f;
                const idx_hi = packed16 >> shift4;
                const lut16: @Vector(16, u8) = lut[g];
                acc_lo += @as(@Vector(16, u16), neonTbl16(lut16, idx_lo));
                acc_hi += @as(@Vector(16, u16), neonTbl16(lut16, idx_hi));
            }
            sums_lo += @as(@Vector(16, u32), acc_lo);
            sums_hi += @as(@Vector(16, u32), acc_hi);
        }
    } else {
        var s_lo: [16]u32 = @splat(0);
        var s_hi: [16]u32 = @splat(0);
        while (g < n_groups) : (g += 1) {
            const lut_g = &lut[g];
            const src = block_packed[g * 16 ..][0..16];
            inline for (0..16) |j| {
                const b = src[j];
                s_lo[j] += lut_g[b & 0x0F];
                s_hi[j] += lut_g[b >> 4];
            }
        }
        sums_lo = s_lo;
        sums_hi = s_hi;
    }

    const bias: f32 = @as(f32, @floatFromInt(n_groups)) * lut_vl;
    if (comptime LANES >= 4) {
        const W = if (LANES > 16) 16 else LANES;
        const VF = @Vector(W, f32);
        const VU = @Vector(W, u32);
        const bias_v: VF = @splat(bias);
        const delta_v: VF = @splat(lut_delta);
        const ql2_v: VF = @splat(q_l2);
        const ql2sq_v: VF = @splat(q_l2_sq);
        const arr_lo: [16]u32 = sums_lo;
        const arr_hi: [16]u32 = sums_hi;

        comptime var off: usize = 0;
        inline while (off < 16) : (off += W) {
            const slo: VF = @floatFromInt(@as(VU, arr_lo[off..][0..W].*));
            const ip_lo = distance.fmaddVec(W, slo, delta_v, bias_v);
            const sc_lo = ql2_v * @as(VF, f_rescale[off..][0..W].*);
            const add_lo = ql2sq_v + @as(VF, f_add[off..][0..W].*);
            out_d2[off..][0..W].* = distance.fmaddVec(W, -sc_lo, ip_lo, add_lo);

            const shi: VF = @floatFromInt(@as(VU, arr_hi[off..][0..W].*));
            const ip_hi = distance.fmaddVec(W, shi, delta_v, bias_v);
            const sc_hi = ql2_v * @as(VF, f_rescale[off + 16 ..][0..W].*);
            const add_hi = ql2sq_v + @as(VF, f_add[off + 16 ..][0..W].*);
            out_d2[off + 16 ..][0..W].* = distance.fmaddVec(W, -sc_hi, ip_hi, add_hi);
        }
    } else {
        const arr_lo: [16]u32 = sums_lo;
        const arr_hi: [16]u32 = sums_hi;
        inline for (0..16) |j| {
            const ip_lo = bias + lut_delta * @as(f32, @floatFromInt(arr_lo[j]));
            out_d2[j] = q_l2_sq + f_add[j] - (q_l2 * f_rescale[j]) * ip_lo;

            const ip_hi = bias + lut_delta * @as(f32, @floatFromInt(arr_hi[j]));
            out_d2[j + 16] = q_l2_sq + f_add[j + 16] - (q_l2 * f_rescale[j + 16]) * ip_hi;
        }
    }
}

// ╔═══════════════════════════════════════════════════╗
// ║  Tests                                             ║
// ╚═══════════════════════════════════════════════════╝

const testing = std.testing;

test "rabitq: generateRotation produces orthogonal matrix (d=4)" {
    const alloc = testing.allocator;
    const dim: usize = 4;
    const R = try generateRotation(alloc, dim, 42);
    defer alloc.free(R);

    for (0..dim) |i| {
        for (0..dim) |j| {
            var s: f32 = 0.0;
            for (0..dim) |k| s += R[i * dim + k] * R[j * dim + k];
            const expected: f32 = if (i == j) 1.0 else 0.0;
            try testing.expectApproxEqAbs(expected, s, 1e-5);
        }
    }
}

test "rabitq: generateRotation is deterministic for a given seed" {
    const alloc = testing.allocator;
    const dim: usize = 8;
    const a = try generateRotation(alloc, dim, 0xABCD_1234);
    defer alloc.free(a);
    const b = try generateRotation(alloc, dim, 0xABCD_1234);
    defer alloc.free(b);
    try testing.expectEqualSlices(f32, a, b);
}

test "rabitq: different seeds produce different rotations" {
    const alloc = testing.allocator;
    const dim: usize = 8;
    const a = try generateRotation(alloc, dim, 1);
    defer alloc.free(a);
    const b = try generateRotation(alloc, dim, 2);
    defer alloc.free(b);
    var any_diff = false;
    for (a[0..dim], b[0..dim]) |x, y| {
        if (@abs(x - y) > 1e-5) {
            any_diff = true;
            break;
        }
    }
    try testing.expect(any_diff);
}

test "rabitq: applyRotation preserves L2 norm" {
    const alloc = testing.allocator;
    const dim: usize = 16;
    const R = try generateRotation(alloc, dim, 123);
    defer alloc.free(R);

    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    var v: [16]f32 = undefined;
    for (&v) |*x| x.* = rand.floatNorm(f32);

    var orig_norm_sq: f32 = 0;
    for (v) |x| orig_norm_sq += x * x;

    var out: [16]f32 = undefined;
    const v_align: []align(1) const f32 = @ptrCast(&v);
    applyRotation(R, v_align, &out);

    var out_norm_sq: f32 = 0;
    for (out) |x| out_norm_sq += x * x;

    try testing.expectApproxEqAbs(orig_norm_sq, out_norm_sq, 1e-3);
}

test "rabitq: applyRotation preserves inner products between two vectors" {
    const alloc = testing.allocator;
    const dim: usize = 32;
    const R = try generateRotation(alloc, dim, 0xBEEF);
    defer alloc.free(R);

    var prng = std.Random.DefaultPrng.init(11);
    const rand = prng.random();
    var a: [32]f32 = undefined;
    var b: [32]f32 = undefined;
    for (&a) |*x| x.* = rand.floatNorm(f32);
    for (&b) |*x| x.* = rand.floatNorm(f32);

    var orig_ip: f32 = 0;
    for (a, b) |xa, xb| orig_ip += xa * xb;

    var ra: [32]f32 = undefined;
    var rb: [32]f32 = undefined;
    const a_align: []align(1) const f32 = @ptrCast(&a);
    const b_align: []align(1) const f32 = @ptrCast(&b);
    applyRotation(R, a_align, &ra);
    applyRotation(R, b_align, &rb);

    var rot_ip: f32 = 0;
    for (ra, rb) |xa, xb| rot_ip += xa * xb;

    try testing.expectApproxEqAbs(orig_ip, rot_ip, 1e-3);
}

test "rabitq: applyRotationBatch4 matches applyRotation across odd and SIMD dims" {
    const alloc = testing.allocator;
    const dims = [_]usize{ 1, 7, 13, 17, 33, 64, 129 };
    var prng = std.Random.DefaultPrng.init(0xBA7C_4001);
    const rand = prng.random();

    for (dims) |dim| {
        const R = try generateRotation(alloc, dim, 0x5151 + dim);
        defer alloc.free(R);

        var vs: [4][]f32 = undefined;
        var outs_batch: [4][]f32 = undefined;
        var outs_single: [4][]f32 = undefined;
        for (0..4) |k| {
            vs[k] = try alloc.alloc(f32, dim);
            outs_batch[k] = try alloc.alloc(f32, dim);
            outs_single[k] = try alloc.alloc(f32, dim);
            for (vs[k]) |*x| x.* = rand.floatNorm(f32);
        }
        defer for (0..4) |k| {
            alloc.free(vs[k]);
            alloc.free(outs_batch[k]);
            alloc.free(outs_single[k]);
        };

        const v_align: [4][]align(1) const f32 = .{
            @ptrCast(vs[0]),
            @ptrCast(vs[1]),
            @ptrCast(vs[2]),
            @ptrCast(vs[3]),
        };
        applyRotationBatch4(R, v_align, outs_batch);
        for (0..4) |k| {
            applyRotation(R, v_align[k], outs_single[k]);
            for (0..dim) |d| {
                try testing.expectApproxEqAbs(outs_single[k][d], outs_batch[k][d], 1e-4);
            }
        }
    }
}

test "rabitq: encode + estimate — exact same vector returns near-zero L2²" {
    const alloc = testing.allocator;
    const dim: usize = 32;

    var params = RabitqParams{
        .allocator = alloc,
        .centroid = try alloc.alloc(f32, dim),
        .rotation = try generateRotation(alloc, dim, 0xDEAD),
        .dim = @intCast(dim),
        .seed = 0xDEAD,
    };
    defer params.deinit();

    for (params.centroid, 0..) |*c, i| c.* = @floatFromInt(i);

    var v: [32]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(17);
    const rand = prng.random();
    for (&v) |*x| x.* = rand.floatNorm(f32);

    var residual: [32]f32 = undefined;
    var rotated: [32]f32 = undefined;
    var code: [4]u8 = undefined;

    const v_align: []align(1) const f32 = @ptrCast(&v);
    const enc = encode(v_align, &params, &residual, &rotated, &code);

    var q_rot: [32]f32 = undefined;
    var q_residual: [32]f32 = undefined;
    const q_l2 = prepareQuery(v_align, &params, &q_residual, &q_rot);

    const d_est = estimateL2Sq(&q_rot, q_l2, &code, enc.l2_norm, enc.corr);
    const tol = 0.3 * enc.l2_norm * enc.l2_norm;
    try testing.expect(d_est >= -tol and d_est <= tol);
}

test "rabitq: encode + estimate round-trip is unbiased on synthetic Gaussians" {
    const alloc = testing.allocator;
    const dim: usize = 64;
    const n: usize = 300;

    var params = RabitqParams{
        .allocator = alloc,
        .centroid = try alloc.alloc(f32, dim),
        .rotation = try generateRotation(alloc, dim, 0xFEED),
        .dim = @intCast(dim),
        .seed = 0xFEED,
    };
    defer params.deinit();
    @memset(params.centroid, 0);

    var prng = std.Random.DefaultPrng.init(999);
    const rand = prng.random();

    const vecs = try alloc.alloc(f32, n * dim);
    defer alloc.free(vecs);
    for (vecs) |*x| x.* = rand.floatNorm(f32);

    const codes = try alloc.alloc(u8, n * codeBytes(dim));
    defer alloc.free(codes);
    const l2_norms = try alloc.alloc(f32, n);
    defer alloc.free(l2_norms);
    const corrs = try alloc.alloc(f32, n);
    defer alloc.free(corrs);

    const residual = try alloc.alloc(f32, dim);
    defer alloc.free(residual);
    const rotated = try alloc.alloc(f32, dim);
    defer alloc.free(rotated);

    for (0..n) |i| {
        const v = vecs[i * dim ..][0..dim];
        const v_align: []align(1) const f32 = @ptrCast(v);
        const code_slice = codes[i * codeBytes(dim) ..][0..codeBytes(dim)];
        const enc = encode(v_align, &params, residual, rotated, code_slice);
        l2_norms[i] = enc.l2_norm;
        corrs[i] = enc.corr;
    }

    const q = vecs[0..dim];
    const q_align: []align(1) const f32 = @ptrCast(q);

    const q_rot = try alloc.alloc(f32, dim);
    defer alloc.free(q_rot);
    const q_residual = try alloc.alloc(f32, dim);
    defer alloc.free(q_residual);

    const q_l2 = prepareQuery(q_align, &params, q_residual, q_rot);

    var total_err: f64 = 0;
    var close_count: usize = 0;
    for (1..n) |i| {
        const vi = vecs[i * dim ..][0..dim];
        var true_d2: f32 = 0;
        for (q, vi) |a, b| {
            const diff = a - b;
            true_d2 += diff * diff;
        }
        const code_slice = codes[i * codeBytes(dim) ..][0..codeBytes(dim)];
        const est_d2 = estimateL2Sq(q_rot, q_l2, code_slice, l2_norms[i], corrs[i]);

        const rel_err = @abs((est_d2 - true_d2) / @max(true_d2, 1.0));
        total_err += @as(f64, rel_err);
        if (rel_err < 0.20) close_count += 1;
    }
    const avg_rel_err = total_err / @as(f64, @floatFromInt(n - 1));

    try testing.expect(avg_rel_err < 0.30);
    try testing.expect(close_count > (n - 1) / 2);
}

test "rabitq: encoded size matches expected layout" {
    try testing.expectEqual(@as(usize, 16 + 8), encodedSize(128));
    try testing.expectEqual(@as(usize, 13 + 8), encodedSize(100));
    try testing.expectEqual(@as(usize, 192 + 8), encodedSize(1536));
}

test "rabitq: serialize / parse roundtrip" {
    var code = [_]u8{ 0xAB, 0xCD, 0x12, 0x34 };
    const enc = Encoded{
        .code = &code,
        .l2_norm = 3.14,
        .corr = 0.78,
    };
    var buf: [4 + 8]u8 = undefined;
    serialize(enc, &buf);

    const parsed = parse(&buf, 32).?;
    try testing.expectEqualSlices(u8, &code, parsed.code);
    try testing.expectApproxEqAbs(enc.l2_norm, parsed.l2_norm, 1e-6);
    try testing.expectApproxEqAbs(enc.corr, parsed.corr, 1e-6);
}

test "rabitq: parse returns null for wrong size" {
    const buf = [_]u8{ 1, 2, 3, 4, 5, 6 };
    try testing.expect(parse(&buf, 32) == null);
}

test "rabitq: normalizeInto produces unit norm" {
    var in = [_]f32{ 3.0, 4.0, 0.0, 0.0 };
    var out: [4]f32 = undefined;
    const in_align: []align(1) const f32 = @ptrCast(&in);
    try testing.expect(normalizeInto(in_align, &out));
    var sq: f32 = 0;
    for (out) |x| sq += x * x;
    try testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(sq), 1e-6);
}

test "rabitq: normalizeInto returns false on zero vector" {
    var in = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    var out: [4]f32 = undefined;
    const in_align: []align(1) const f32 = @ptrCast(&in);
    try testing.expect(!normalizeInto(in_align, &out));
}

test "rabitq: cosine path — d² estimator on unit sphere converts to cosine" {
    const alloc = testing.allocator;
    const dim: usize = 32;

    var prng = std.Random.DefaultPrng.init(0xC05);
    const rand = prng.random();

    var v: [32]f32 = undefined;
    for (&v) |*x| x.* = rand.floatNorm(f32);
    var v_unit: [32]f32 = undefined;
    const v_align: []align(1) const f32 = @ptrCast(&v);
    try testing.expect(normalizeInto(v_align, &v_unit));

    var params = RabitqParams{
        .allocator = alloc,
        .centroid = try alloc.alloc(f32, dim),
        // Use a rotation seed independent of `v`'s PRNG seed so R[0] != v_unit.
        .rotation = try generateRotation(alloc, dim, 0xC051),
        .dim = @intCast(dim),
        .seed = 0xC051,
    };
    defer params.deinit();
    @memset(params.centroid, 0);

    var residual: [32]f32 = undefined;
    var rotated: [32]f32 = undefined;
    var code: [4]u8 = undefined;
    const v_unit_align: []align(1) const f32 = @ptrCast(&v_unit);
    const enc = encode(v_unit_align, &params, &residual, &rotated, &code);

    var q_residual: [32]f32 = undefined;
    var q_rot: [32]f32 = undefined;
    const q_l2 = prepareQuery(v_unit_align, &params, &q_residual, &q_rot);
    const d2 = estimateL2Sq(&q_rot, q_l2, &code, enc.l2_norm, enc.corr);
    const cos_est = 1.0 - d2 * 0.5;
    try testing.expect(cos_est > 0.5);

    var q_orth: [32]f32 = @splat(0);
    q_orth[0] = -v_unit[1];
    q_orth[1] = v_unit[0];
    var q_orth_unit: [32]f32 = undefined;
    const q_orth_align: []align(1) const f32 = @ptrCast(&q_orth);
    _ = normalizeInto(q_orth_align, &q_orth_unit);
    const q_orth_unit_align: []align(1) const f32 = @ptrCast(&q_orth_unit);
    var q_residual2: [32]f32 = undefined;
    var q_rot2: [32]f32 = undefined;
    const q_l2_2 = prepareQuery(q_orth_unit_align, &params, &q_residual2, &q_rot2);
    const d2_orth = estimateL2Sq(&q_rot2, q_l2_2, &code, enc.l2_norm, enc.corr);
    const cos_orth = 1.0 - d2_orth * 0.5;
    try testing.expect(cos_orth < cos_est);
}

test "rabitq: kNN recall on synthetic Gaussian corpus (exact, 4-bit AND-popcount, and FastScan32)" {
    const alloc = testing.allocator;
    const dim: usize = 128;
    const n: usize = 512; // exact multiple of 32 for FastScan32 comparison
    const top_k: usize = 10;
    const oversample: usize = 4;

    var prng = std.Random.DefaultPrng.init(0xC0DE);
    const rand = prng.random();

    const vecs = try alloc.alloc(f32, n * dim);
    defer alloc.free(vecs);
    for (vecs) |*x| x.* = rand.floatNorm(f32);

    var params = RabitqParams{
        .allocator = alloc,
        .centroid = try alloc.alloc(f32, dim),
        .rotation = try generateRotation(alloc, dim, 0xABCD),
        .dim = @intCast(dim),
        .seed = 0xABCD,
    };
    defer params.deinit();
    @memset(params.centroid, 0);
    for (0..n) |i| {
        for (0..dim) |j| params.centroid[j] += vecs[i * dim + j];
    }
    const n_f: f32 = @floatFromInt(n);
    for (params.centroid) |*c| c.* /= n_f;

    const residual = try alloc.alloc(f32, dim);
    defer alloc.free(residual);
    const rotated = try alloc.alloc(f32, dim);
    defer alloc.free(rotated);

    const cb = codeBytes(dim);
    const codes = try alloc.alloc(u8, n * cb);
    defer alloc.free(codes);
    const l2_norms = try alloc.alloc(f32, n);
    defer alloc.free(l2_norms);
    const corrs = try alloc.alloc(f32, n);
    defer alloc.free(corrs);
    const f_adds = try alloc.alloc(f32, n);
    defer alloc.free(f_adds);
    const f_rescales = try alloc.alloc(f32, n);
    defer alloc.free(f_rescales);
    const popcs = try alloc.alloc(u16, n);
    defer alloc.free(popcs);

    for (0..n) |i| {
        const v = vecs[i * dim ..][0..dim];
        const v_align: []align(1) const f32 = @ptrCast(v);
        const code_slice = codes[i * cb ..][0..cb];
        const enc = encode(v_align, &params, residual, rotated, code_slice);
        l2_norms[i] = enc.l2_norm;
        corrs[i] = enc.corr;
        const sf = computeSlabFactors(dim, enc.l2_norm, enc.corr, code_slice);
        f_adds[i] = sf.f_add;
        f_rescales[i] = sf.f_rescale;
        popcs[i] = sf.popc;
    }

    // Pack into FastScan 32-vector blocks
    const n_blocks = n / 32;
    const block_bytes = fastScanBlockBytes(dim);
    const packed_blocks = try alloc.alloc(u8, n_blocks * block_bytes);
    defer alloc.free(packed_blocks);
    for (0..n_blocks) |blk_idx| {
        var blk_codes: [32][]const u8 = undefined;
        for (0..32) |j| blk_codes[j] = codes[(blk_idx * 32 + j) * cb ..][0..cb];
        packFastScanBlock32(blk_codes, dim, packed_blocks[blk_idx * block_bytes ..][0..block_bytes]);
    }

    const q_vec = try alloc.alloc(f32, dim);
    defer alloc.free(q_vec);
    for (0..dim) |j| q_vec[j] = vecs[42 * dim + j] + rand.floatNorm(f32) * 0.1;

    const Entry = struct { idx: usize, d2: f32 };
    const lessThan = struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.d2 < b.d2;
        }
    }.lt;

    const trues = try alloc.alloc(Entry, n);
    defer alloc.free(trues);
    for (0..n) |i| {
        const vi = vecs[i * dim ..][0..dim];
        trues[i] = .{ .idx = i, .d2 = distance.l2Squared(q_vec, vi) };
    }
    std.sort.pdq(Entry, trues, {}, lessThan);

    const q_rot = try alloc.alloc(f32, dim);
    defer alloc.free(q_rot);
    const plane_buf = try alloc.alloc(u8, 4 * cb);
    defer alloc.free(plane_buf);
    const pq = prepareQueryFull(@ptrCast(q_vec), &params, residual, q_rot, plane_buf);

    const lut = try alloc.alloc([16]u8, fastScanGroups(dim));
    defer alloc.free(lut);
    const lut_scale = buildFastScanLut(q_rot, lut);

    const est_exact = try alloc.alloc(Entry, n);
    defer alloc.free(est_exact);
    const est_4bit = try alloc.alloc(Entry, n);
    defer alloc.free(est_4bit);
    const est_fs = try alloc.alloc(Entry, n);
    defer alloc.free(est_fs);

    // Evaluate all three estimators and verify batch4/slab parity
    var i: usize = 0;
    while (i < n) : (i += 4) {
        const c4: [4][]const u8 = .{
            codes[(i + 0) * cb ..][0..cb],
            codes[(i + 1) * cb ..][0..cb],
            codes[(i + 2) * cb ..][0..cb],
            codes[(i + 3) * cb ..][0..cb],
        };
        const l4: [4]f32 = .{ l2_norms[i], l2_norms[i + 1], l2_norms[i + 2], l2_norms[i + 3] };
        const cr4: [4]f32 = .{ corrs[i], corrs[i + 1], corrs[i + 2], corrs[i + 3] };
        const fa4: [4]f32 = .{ f_adds[i], f_adds[i + 1], f_adds[i + 2], f_adds[i + 3] };
        const fr4: [4]f32 = .{ f_rescales[i], f_rescales[i + 1], f_rescales[i + 2], f_rescales[i + 3] };
        const pc4: [4]u16 = .{ popcs[i], popcs[i + 1], popcs[i + 2], popcs[i + 3] };

        const d_prep4 = estimateL2SqBatch4Prepared(&pq, c4, l4, cr4);
        const d_4bit4 = estimateL2Sq4BitBatch4(&pq, c4, l4, cr4);
        const d_slab4 = estimateL2Sq4BitSlabBatch4(&pq, c4, fa4, fr4, pc4);

        for (0..4) |k| {
            const idx = i + k;
            const d_ref = estimateL2Sq(q_rot, pq.q_l2, c4[k], l4[k], cr4[k]);
            const d_prep = estimateL2SqPrepared(&pq, c4[k], l4[k], cr4[k]);
            const d_4bit = estimateL2Sq4Bit(&pq, c4[k], l4[k], cr4[k]);

            try testing.expectApproxEqAbs(d_ref, d_prep, 1e-3);
            try testing.expectApproxEqAbs(d_ref, d_prep4[k], 1e-3);
            try testing.expectApproxEqAbs(d_4bit, d_4bit4[k], 1e-3);
            try testing.expectApproxEqAbs(d_4bit, d_slab4[k], 1e-3);

            est_exact[idx] = .{ .idx = idx, .d2 = d_ref };
            est_4bit[idx] = .{ .idx = idx, .d2 = d_4bit };
        }
    }

    for (0..n_blocks) |blk_idx| {
        const base = blk_idx * 32;
        var out_d2: [32]f32 = undefined;
        estimateFastScanBlock32(
            lut,
            lut_scale.vl,
            lut_scale.delta,
            pq.q_l2,
            pq.q_l2_sq,
            packed_blocks[blk_idx * block_bytes ..][0..block_bytes],
            f_adds[base..][0..32],
            f_rescales[base..][0..32],
            &out_d2,
        );
        for (0..32) |j| {
            est_fs[base + j] = .{ .idx = base + j, .d2 = out_d2[j] };
            // FastScan LUT error vs exact f32 estimator is tiny (< 2% of d2)
            const diff = @abs(out_d2[j] - est_exact[base + j].d2);
            try testing.expect(diff < @max(@as(f32, 3.0), @abs(est_exact[base + j].d2) * 0.03));
        }
    }

    std.sort.pdq(Entry, est_exact, {}, lessThan);
    std.sort.pdq(Entry, est_4bit, {}, lessThan);
    std.sort.pdq(Entry, est_fs, {}, lessThan);

    var hit_set = std.AutoHashMapUnmanaged(usize, void).empty;
    defer hit_set.deinit(alloc);
    for (0..top_k) |j| try hit_set.put(alloc, trues[j].idx, {});

    inline for (.{ est_exact, est_4bit, est_fs }) |est| {
        var hits: usize = 0;
        for (0..top_k * oversample) |j| {
            if (hit_set.contains(est[j].idx)) hits += 1;
        }
        const recall: f32 = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(top_k));
        var hits_direct: usize = 0;
        for (0..top_k) |j| {
            if (hit_set.contains(est[j].idx)) hits_direct += 1;
        }
        const recall_direct: f32 = @as(f32, @floatFromInt(hits_direct)) / @as(f32, @floatFromInt(top_k));
        try testing.expect(recall >= 0.7);
        try testing.expect(recall_direct >= 0.4);
    }
}

test "rabitq: odd dims, high dim (d=384), and degenerate edge cases (v==c, q==c, corr<1e-8)" {
    const alloc = testing.allocator;
    const dims = [_]usize{ 1, 7, 13, 17, 33, 129, 384 };
    var prng = std.Random.DefaultPrng.init(0x0DD0_D135);
    const rand = prng.random();

    for (dims) |dim| {
        const cb = codeBytes(dim);
        var params = RabitqParams{
            .allocator = alloc,
            .centroid = try alloc.alloc(f32, dim),
            .rotation = try generateRotation(alloc, dim, 0x777 + dim),
            .dim = @intCast(dim),
            .seed = 0x777 + dim,
        };
        defer params.deinit();
        for (params.centroid) |*c| c.* = rand.floatNorm(f32) * 0.25;

        const residual = try alloc.alloc(f32, dim);
        defer alloc.free(residual);
        const rotated = try alloc.alloc(f32, dim);
        defer alloc.free(rotated);
        const q_rot = try alloc.alloc(f32, dim);
        defer alloc.free(q_rot);
        const plane_buf = try alloc.alloc(u8, 4 * cb);
        defer alloc.free(plane_buf);

        // Build 32 vectors (vector 0 == centroid to test degenerate v==c)
        const codes_flat = try alloc.alloc(u8, 32 * cb);
        defer alloc.free(codes_flat);
        var l2s: [32]f32 = undefined;
        var corrs: [32]f32 = undefined;
        var f_adds: [32]f32 = undefined;
        var f_rescales: [32]f32 = undefined;
        var popcs: [32]u16 = undefined;
        var code_slices: [32][]const u8 = undefined;

        const v_tmp = try alloc.alloc(f32, dim);
        defer alloc.free(v_tmp);
        for (0..32) |idx| {
            if (idx == 0) {
                @memcpy(v_tmp, params.centroid);
            } else {
                for (v_tmp) |*x| x.* = rand.floatNorm(f32);
            }
            const cs = codes_flat[idx * cb ..][0..cb];
            const enc = encode(@ptrCast(v_tmp), &params, residual, rotated, cs);
            l2s[idx] = enc.l2_norm;
            corrs[idx] = enc.corr;
            // Force vector 1 to test degenerate corr < 1e-8
            if (idx == 1) corrs[idx] = 1e-10;
            const sf = computeSlabFactors(dim, l2s[idx], corrs[idx], cs);
            f_adds[idx] = sf.f_add;
            f_rescales[idx] = sf.f_rescale;
            popcs[idx] = sf.popc;
            code_slices[idx] = cs;
        }

        // Vector 0 (v == centroid): l2_norm == 0, corr == 1
        try testing.expectEqual(@as(f32, 0.0), l2s[0]);
        try testing.expectEqual(@as(f32, 1.0), corrs[0]);

        const block = try alloc.alloc(u8, fastScanBlockBytes(dim));
        defer alloc.free(block);
        packFastScanBlock32(code_slices, dim, block);

        const lut = try alloc.alloc([16]u8, fastScanGroups(dim));
        defer alloc.free(lut);

        // Test 1: normal query
        for (v_tmp) |*x| x.* = rand.floatNorm(f32);
        const pq = prepareQueryFull(@ptrCast(v_tmp), &params, residual, q_rot, plane_buf);
        const lscale = buildFastScanLut(q_rot, lut);

        var fs_out: [32]f32 = undefined;
        estimateFastScanBlock32(lut, lscale.vl, lscale.delta, pq.q_l2, pq.q_l2_sq, block, &f_adds, &f_rescales, &fs_out);

        // Vector 0 (v == centroid) -> d2 == q_l2_sq across all estimators
        try testing.expectApproxEqAbs(pq.q_l2_sq, estimateL2Sq(q_rot, pq.q_l2, code_slices[0], l2s[0], corrs[0]), 1e-4);
        try testing.expectApproxEqAbs(pq.q_l2_sq, estimateL2Sq4Bit(&pq, code_slices[0], l2s[0], corrs[0]), 1e-4);
        try testing.expectApproxEqAbs(pq.q_l2_sq, fs_out[0], 1e-4);

        // Vector 1 (corr < 1e-8) -> +inf (never NaN) across all estimators
        try testing.expect(std.math.isPositiveInf(estimateL2Sq(q_rot, pq.q_l2, code_slices[1], l2s[1], corrs[1])));
        try testing.expect(std.math.isPositiveInf(estimateL2SqPrepared(&pq, code_slices[1], l2s[1], corrs[1])));
        try testing.expect(std.math.isPositiveInf(estimateL2Sq4Bit(&pq, code_slices[1], l2s[1], corrs[1])));
        try testing.expect(std.math.isPositiveInf(fs_out[1]));

        // Normal vectors 2..31: finite and close across exact, 4-bit, and FastScan32
        for (2..32) |idx| {
            const d_exact = estimateL2Sq(q_rot, pq.q_l2, code_slices[idx], l2s[idx], corrs[idx]);
            const d_prep = estimateL2SqPrepared(&pq, code_slices[idx], l2s[idx], corrs[idx]);
            const d_4b = estimateL2Sq4Bit(&pq, code_slices[idx], l2s[idx], corrs[idx]);
            try testing.expect(std.math.isFinite(d_exact));
            try testing.expect(std.math.isFinite(d_4b));
            try testing.expect(std.math.isFinite(fs_out[idx]));
            try testing.expectApproxEqAbs(d_exact, d_prep, @max(@as(f32, 1e-3), @abs(d_exact) * 1e-4));
            // FastScan 8-bit LUT matches exact f32 closely even on odd dims
            const fs_tol: f32 = @max(@as(f32, 1.5), @abs(d_exact) * 0.05 + pq.q_l2 * l2s[idx] * 0.15);
            try testing.expectApproxEqAbs(d_exact, fs_out[idx], fs_tol);
        }

        // Test 2: degenerate query q == centroid (q_l2 == 0)
        const pq_zero = prepareQueryFull(@ptrCast(params.centroid), &params, residual, q_rot, plane_buf);
        try testing.expectEqual(@as(f32, 0.0), pq_zero.q_l2);
        const lscale_zero = buildFastScanLut(q_rot, lut);
        estimateFastScanBlock32(lut, lscale_zero.vl, lscale_zero.delta, pq_zero.q_l2, pq_zero.q_l2_sq, block, &f_adds, &f_rescales, &fs_out);

        try testing.expectEqual(@as(f32, 0.0), estimateL2Sq(q_rot, pq_zero.q_l2, code_slices[0], l2s[0], corrs[0]));
        try testing.expect(std.math.isPositiveInf(fs_out[1]));
        for (2..32) |idx| {
            const exp = l2s[idx] * l2s[idx];
            try testing.expectApproxEqAbs(exp, estimateL2Sq(q_rot, pq_zero.q_l2, code_slices[idx], l2s[idx], corrs[idx]), 1e-4);
            try testing.expectApproxEqAbs(exp, estimateL2Sq4Bit(&pq_zero, code_slices[idx], l2s[idx], corrs[idx]), 1e-4);
            try testing.expectApproxEqAbs(exp, fs_out[idx], 1e-4);
        }
    }
}

test "rabitq: FastScan32 multi-chunk u16 flush and 4-bit slab parity at d=1536, d=1537, d=2053" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x1536_F532);
    const rand = prng.random();

    for ([_]usize{ 1536, 1537, 2053 }) |dim| {
        const cb = codeBytes(dim);
        const n_groups = fastScanGroups(dim);
        try testing.expect(n_groups > 255); // d=2053 (514 groups) crosses AVX-512BW 508-group & AVX2 510-group flush boundaries too!

        // Synthetic unit rotated query (avoids O(d^3) Gram-Schmidt so test runs in <1ms).
        const q_raw = try alloc.alloc(f32, dim);
        defer alloc.free(q_raw);
        const q_rot = try alloc.alloc(f32, dim);
        defer alloc.free(q_rot);
        for (q_raw) |*x| x.* = rand.floatNorm(f32);
        try testing.expect(normalizeInto(@ptrCast(q_raw), q_rot));

        const plane_buf = try alloc.alloc(u8, 4 * cb);
        defer alloc.free(plane_buf);
        const q_l2: f32 = 3.25;
        const pq = prepareQueryFromRotated(q_rot, q_l2, plane_buf);

        const lut = try alloc.alloc([16]u8, n_groups);
        defer alloc.free(lut);
        const lscale = buildFastScanLut(q_rot, lut);

        // 32 synthetic encoded vectors:
        //   0: signs match q_rot exactly (maximizes every LUT sum across 384+ groups -> proves no u16 wrap!)
        //   1: signs opposite to q_rot (minimizes every LUT sum)
        //   2..31: random codes (with tail padding bits strictly zeroed for odd dim=1537)
        const codes_flat = try alloc.alloc(u8, 32 * cb);
        defer alloc.free(codes_flat);
        @memset(codes_flat, 0);

        var code_slices: [32][]const u8 = undefined;
        var l2s: [32]f32 = undefined;
        var corrs: [32]f32 = undefined;
        var f_adds: [32]f32 = undefined;
        var f_rescales: [32]f32 = undefined;
        var popcs: [32]u16 = undefined;

        for (0..32) |idx| {
            const cs = codes_flat[idx * cb ..][0..cb];
            if (idx == 0) {
                distance.binaryQuantize(@ptrCast(q_rot), cs);
            } else if (idx == 1) {
                for (0..dim) |d| {
                    if (q_rot[d] < 0.0) {
                        cs[d / 8] |= @as(u8, 1) << @intCast(7 - (d % 8));
                    }
                }
            } else {
                rand.bytes(cs);
                if (dim % 8 != 0) {
                    const valid_bits: u3 = @intCast(dim % 8);
                    const keep_mask: u8 = @as(u8, 0xFF) << @intCast(8 - @as(u4, valid_bits));
                    cs[cb - 1] &= keep_mask;
                }
            }
            l2s[idx] = 2.0 + @as(f32, @floatFromInt(idx)) * 0.1;
            corrs[idx] = 0.79;
            const sf = computeSlabFactors(dim, l2s[idx], corrs[idx], cs);
            f_adds[idx] = sf.f_add;
            f_rescales[idx] = sf.f_rescale;
            popcs[idx] = sf.popc;
            code_slices[idx] = cs;
        }

        const block = try alloc.alloc(u8, fastScanBlockBytes(dim));
        defer alloc.free(block);
        packFastScanBlock32(code_slices, dim, block);

        var fs_out: [32]f32 = undefined;
        estimateFastScanBlock32(lut, lscale.vl, lscale.delta, pq.q_l2, pq.q_l2_sq, block, &f_adds, &f_rescales, &fs_out);

        var i: usize = 0;
        while (i < 32) : (i += 4) {
            const c4: [4][]const u8 = .{ code_slices[i], code_slices[i + 1], code_slices[i + 2], code_slices[i + 3] };
            const l4: [4]f32 = .{ l2s[i], l2s[i + 1], l2s[i + 2], l2s[i + 3] };
            const cr4: [4]f32 = .{ corrs[i], corrs[i + 1], corrs[i + 2], corrs[i + 3] };
            const fa4: [4]f32 = .{ f_adds[i], f_adds[i + 1], f_adds[i + 2], f_adds[i + 3] };
            const fr4: [4]f32 = .{ f_rescales[i], f_rescales[i + 1], f_rescales[i + 2], f_rescales[i + 3] };
            const pc4: [4]u16 = .{ popcs[i], popcs[i + 1], popcs[i + 2], popcs[i + 3] };

            const prep4 = estimateL2SqBatch4Prepared(&pq, c4, l4, cr4);
            const b4 = estimateL2Sq4BitBatch4(&pq, c4, l4, cr4);
            const slab4 = estimateL2Sq4BitSlabBatch4(&pq, c4, fa4, fr4, pc4);

            for (0..4) |k| {
                const idx = i + k;
                const d_exact = estimateL2Sq(q_rot, q_l2, c4[k], l4[k], cr4[k]);
                try testing.expectApproxEqAbs(d_exact, prep4[k], 1e-3);
                try testing.expectApproxEqAbs(b4[k], slab4[k], 1e-3);
                // 4-bit AND-Popcount and FastScan32 (over 384+ groups) both track exact f32 tightly
                const tol: f32 = @max(@as(f32, 0.5), @abs(d_exact) * 0.03);
                try testing.expectApproxEqAbs(d_exact, slab4[k], tol);
                try testing.expectApproxEqAbs(d_exact, fs_out[idx], tol);
            }
        }
        // Extreme alignment check: vector 0 (matching signs) must be dramatically closer than vector 1 (opposite signs)
        try testing.expect(fs_out[0] + 10.0 < fs_out[1]);
    }
}
