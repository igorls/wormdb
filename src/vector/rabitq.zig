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
//! This module ships the scalar reference implementation. SIMD comes
//! later once correctness is pinned.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// SIMD lane width — 8 × f32 = 256 bits (AVX2 baseline).
/// On AVX-512 hardware, LLVM may further auto-widen.
const LANES: usize = 8;
const F32xN = @Vector(LANES, f32);
const U32xN = @Vector(LANES, u32);
const ZERO: F32xN = @splat(0.0);

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

pub fn codeBytes(dim: usize) usize {
    return (dim + 7) / 8;
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
// ║  Rotation generation                               ║
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

    // Modified Gram-Schmidt over rows. For each row, subtract its
    // projection onto every previously-orthonormalized row, then
    // normalize. "Modified" = subtract projections one-by-one rather
    // than computing them all from the original row (numerically
    // stabler for small/degenerate gaussian draws).
    var i: usize = 0;
    while (i < dim) : (i += 1) {
        const row_i = m[i * dim ..][0..dim];

        var j: usize = 0;
        while (j < i) : (j += 1) {
            const row_j = m[j * dim ..][0..dim];
            var dp: f32 = 0.0;
            for (0..dim) |k| dp += row_i[k] * row_j[k];
            for (0..dim) |k| row_i[k] -= dp * row_j[k];
        }

        var norm_sq: f32 = 0.0;
        for (row_i) |x| norm_sq += x * x;
        const norm = @sqrt(norm_sq);
        if (norm < 1e-12) return error.DegenerateRotation;

        const inv = 1.0 / norm;
        for (row_i) |*x| x.* *= inv;
    }

    return m;
}

/// Compute `out = rotation @ v`. All three slices have length `dim`;
/// `rotation` is row-major d×d (length `dim * dim`). 8-wide SIMD over
/// the inner dot product; LLVM auto-widens to AVX-512 when available.
pub fn applyRotation(rotation: []const f32, v: []align(1) const f32, out: []f32) void {
    const dim = v.len;
    std.debug.assert(out.len == dim);
    std.debug.assert(rotation.len == dim * dim);

    const vec_dim = dim - (dim % LANES);

    var i: usize = 0;
    while (i < dim) : (i += 1) {
        const row = rotation[i * dim ..];
        var acc: F32xN = ZERO;
        var k: usize = 0;
        while (k < vec_dim) : (k += LANES) {
            const r_chunk: F32xN = row[k..][0..LANES].*;
            const v_chunk: F32xN = v[k..][0..LANES].*;
            acc = @mulAdd(F32xN, r_chunk, v_chunk, acc);
        }
        var s = @reduce(.Add, acc);
        while (k < dim) : (k += 1) s += row[k] * v[k];
        out[i] = s;
    }
}

// ╔═══════════════════════════════════════════════════╗
// ║  Encode                                            ║
// ╚═══════════════════════════════════════════════════╝

/// Encode `v` against the namespace params. Caller supplies scratch
/// buffers sized to `dim` (residual and rotated) and a code buffer
/// sized to `codeBytes(dim)`.
///
/// The code bit layout matches `distance.binaryQuantize`: for dimension
/// i, bit (7 - i%8) of byte (i/8) is 1 iff the rotated residual is
/// non-negative at i. Keeping the layout identical means a legacy
/// Hamming scan over a code produced here still behaves sensibly on
/// mixed corpora (it just ignores the trailing 8 scalar bytes).
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

    const vec_dim = dim - (dim % LANES);

    // residual = v − c (8-wide)
    {
        var i: usize = 0;
        while (i < vec_dim) : (i += LANES) {
            const v_chunk: F32xN = v[i..][0..LANES].*;
            const c_chunk: F32xN = params.centroid[i..][0..LANES].*;
            residual_scratch[i..][0..LANES].* = v_chunk - c_chunk;
        }
        while (i < dim) : (i += 1) residual_scratch[i] = v[i] - params.centroid[i];
    }

    // l2² = Σ residual[i]² (8-wide)
    const sum_sq: f32 = blk: {
        var acc: F32xN = ZERO;
        var i: usize = 0;
        while (i < vec_dim) : (i += LANES) {
            const r: F32xN = residual_scratch[i..][0..LANES].*;
            acc = @mulAdd(F32xN, r, r, acc);
        }
        var s = @reduce(.Add, acc);
        while (i < dim) : (i += 1) s += residual_scratch[i] * residual_scratch[i];
        break :blk s;
    };
    const l2 = @sqrt(sum_sq);

    // Degenerate: v sits at the centroid. No direction to quantize; the
    // estimator treats such points as "distance = q_l2" (cos_est = 0
    // contributes nothing). Flag with l2=0, code=0, corr=1 (avoids the
    // div-by-zero branch in rabitqEstimate).
    @memset(code_out, 0);
    if (l2 < 1e-20) return .{ .code = code_out, .l2_norm = 0.0, .corr = 1.0 };

    // Normalize residual in place: residual_scratch *= 1/l2 (8-wide)
    {
        const inv_l2 = 1.0 / l2;
        const inv_v: F32xN = @splat(inv_l2);
        var i: usize = 0;
        while (i < vec_dim) : (i += LANES) {
            const r: F32xN = residual_scratch[i..][0..LANES].*;
            residual_scratch[i..][0..LANES].* = r * inv_v;
        }
        while (i < dim) : (i += 1) residual_scratch[i] *= inv_l2;
    }

    // rotated = R @ residual_unit
    const resid_unit_bytes: []align(1) const f32 = @ptrCast(residual_scratch);
    applyRotation(params.rotation, resid_unit_bytes, rotated_scratch);

    // Quantize (1-bit code) + accumulate Σ |rotated[i]|.
    // Per byte (8 dims): pack signs branchlessly via the f32 sign bit,
    // and accumulate |r| via @abs across the lane.
    const SHIFTS: U32xN = .{ 7, 6, 5, 4, 3, 2, 1, 0 };
    const SIGN_BIT: U32xN = @splat(0x80000000);
    const ONE_U32: U32xN = @splat(1);
    var abs_acc: F32xN = ZERO;
    {
        var i: usize = 0;
        while (i < vec_dim) : (i += LANES) {
            const r_chunk: F32xN = rotated_scratch[i..][0..LANES].*;
            abs_acc += @abs(r_chunk);

            // bit = 1 iff r_chunk[k] >= 0. The f32 sign bit is set iff
            // negative, so invert it and isolate the LSB.
            const r_bits: U32xN = @bitCast(r_chunk);
            const non_neg: U32xN = (~r_bits >> @splat(@as(u5, 31))) & ONE_U32;
            const positioned: U32xN = non_neg << @intCast(SHIFTS);
            // (Note: if the sign bit was set and value was -0, we'd
            // record bit=0 — semantically v[k] is treated as < 0, which
            // is fine as a tiebreak.)
            _ = SIGN_BIT;
            const byte: u8 = @intCast(@reduce(.Or, positioned));
            code_out[i / 8] = byte;
        }
        // Tail: scalar fallback when dim is not a multiple of 8.
        while (i < dim) : (i += 1) {
            const r = rotated_scratch[i];
            // abs accumulation via scalar path (not lane-merged with abs_acc).
            const abs_r = @abs(r);
            // Fold into a single lane of abs_acc to avoid a separate scalar tally.
            var single: [LANES]f32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
            single[0] = abs_r;
            abs_acc += @as(F32xN, single);
            if (r >= 0.0) {
                code_out[i / 8] |= @as(u8, 1) << @intCast(7 - (i % 8));
            }
        }
    }
    const abs_sum = @reduce(.Add, abs_acc);

    const inv_sqrt_d: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(dim)));
    const corr = abs_sum * inv_sqrt_d;

    return .{ .code = code_out, .l2_norm = l2, .corr = corr };
}

// ╔═══════════════════════════════════════════════════╗
// ║  Estimate (query-side)                             ║
// ╚═══════════════════════════════════════════════════╝

/// Prepare a query for RaBitQ estimation: compute ||q - c||, write
/// R @ (q - c)/||q - c|| into `q_rot_unit_out`. The caller then reuses
/// these across all candidates.
///
/// `q_l2_out` is populated with ||q - c||. If q sits at the centroid
/// (l2 = 0), the rotated buffer is zeroed and callers should treat
/// estimated distances as dominated by the candidate's ||r|| term.
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

    const vec_dim = dim - (dim % LANES);

    // residual = q - centroid (8-wide)
    {
        var i: usize = 0;
        while (i < vec_dim) : (i += LANES) {
            const q_chunk: F32xN = q[i..][0..LANES].*;
            const c_chunk: F32xN = params.centroid[i..][0..LANES].*;
            residual_scratch[i..][0..LANES].* = q_chunk - c_chunk;
        }
        while (i < dim) : (i += 1) residual_scratch[i] = q[i] - params.centroid[i];
    }

    // l2² (8-wide)
    const l2 = blk: {
        var acc: F32xN = ZERO;
        var i: usize = 0;
        while (i < vec_dim) : (i += LANES) {
            const r: F32xN = residual_scratch[i..][0..LANES].*;
            acc = @mulAdd(F32xN, r, r, acc);
        }
        var s = @reduce(.Add, acc);
        while (i < dim) : (i += 1) s += residual_scratch[i] * residual_scratch[i];
        break :blk @sqrt(s);
    };

    if (l2 < 1e-20) {
        @memset(q_rot_unit_out, 0);
        return 0.0;
    }

    // Normalize residual_scratch *= 1/l2 (8-wide)
    {
        const inv_l2 = 1.0 / l2;
        const inv_v: F32xN = @splat(inv_l2);
        var i: usize = 0;
        while (i < vec_dim) : (i += LANES) {
            const r: F32xN = residual_scratch[i..][0..LANES].*;
            residual_scratch[i..][0..LANES].* = r * inv_v;
        }
        while (i < dim) : (i += 1) residual_scratch[i] *= inv_l2;
    }

    const resid_unit: []align(1) const f32 = @ptrCast(residual_scratch);
    applyRotation(params.rotation, resid_unit, q_rot_unit_out);
    return l2;
}

/// Estimate squared L2 distance from a prepared query to an encoded
/// database point. This is the per-candidate hot path called once per
/// stored vector during a stage-1 BQ scan — vectorized aggressively.
///
/// Strategy: for each byte of the code (8 dimensions), build a sign
/// vector `s ∈ {-1, +1}^8` from the bits and accumulate
/// `acc += s * q_rot_unit[i..i+8]` via FMA. The sign vector is built
/// branchlessly by mapping `bit_set` to a u32 mask and XOR-flipping
/// the sign bit of the corresponding q lane.
pub fn estimateL2Sq(
    q_rot_unit: []const f32,
    q_l2: f32,
    code: []const u8,
    v_l2: f32,
    v_corr: f32,
) f32 {
    const dim = q_rot_unit.len;
    const vec_dim = dim - (dim % LANES);

    var acc: F32xN = ZERO;

    // Per-byte unpack: bits 7..0 (MSB-first) map to lanes 0..7.
    // We compute, for each lane k, mask_lane[k] = 0xFFFFFFFF if bit clear,
    // 0 if bit set. XOR mask_lane with 0x80000000 selects the sign:
    //   bit set   → mask=0       → XOR with 0x80000000 ⇒ FLIPPED later? No.
    // Cleaner: precompute per-lane shift to extract bit, then map to
    // (1 - 2·bit) ∈ {-1, +1} as f32. Inline-for-8 produces a fully
    // unrolled, branchless sign builder.
    const SIGN_BIT: U32xN = @splat(0x80000000);

    var i: usize = 0;
    while (i < vec_dim) : (i += LANES) {
        const byte: u32 = code[i / 8];
        // Per lane k: extract bit (7 - k). Build per-lane mask in
        // {0, 1} where 1 = "bit set" = "DB component non-negative" =
        // "no sign flip on q".
        var bit_mask: U32xN = undefined;
        inline for (0..LANES) |k| {
            const bit_set: u32 = (byte >> @as(u5, @intCast(7 - k))) & 1;
            bit_mask[k] = bit_set;
        }
        // flip[k] = 0x80000000 if bit clear (DB negative → flip q's sign),
        //          0          if bit set   (DB non-negative → keep q sign).
        // Equivalently: flip = (1 ^ bit_mask) << 31.
        const ones: U32xN = @splat(1);
        const inv_bit: U32xN = bit_mask ^ ones;
        const flip: U32xN = inv_bit << @splat(@as(u5, 31));
        _ = SIGN_BIT;

        const q_chunk: F32xN = q_rot_unit[i..][0..LANES].*;
        const q_bits: U32xN = @bitCast(q_chunk);
        const flipped_q: F32xN = @bitCast(q_bits ^ flip);
        acc += flipped_q;
    }
    var ip_raw = @reduce(.Add, acc);

    // Tail (only if dim % 8 != 0).
    while (i < dim) : (i += 1) {
        const byte_idx = i / 8;
        const bit_set = (code[byte_idx] >> @as(u3, @intCast(7 - (i % 8)))) & 1;
        if (bit_set != 0) {
            ip_raw += q_rot_unit[i];
        } else {
            ip_raw -= q_rot_unit[i];
        }
    }

    const inv_sqrt_d: f32 = 1.0 / @sqrt(@as(f32, @floatFromInt(dim)));
    const ip_qb = ip_raw * inv_sqrt_d; // ⟨q_rot_unit, b̄⟩

    // Guard: corr is in [0, 1] by construction; a value near zero means
    // the rotated residual was almost axis-aligned (rare) and the
    // estimator is meaningless. Return +inf so the candidate ranks last.
    if (v_corr < 1e-8) return std.math.inf(f32);

    const cos_est = ip_qb / v_corr; // ≈ ⟨q̂, ō⟩ (cosine between unit residuals)
    return q_l2 * q_l2 + v_l2 * v_l2 - 2.0 * q_l2 * v_l2 * cos_est;
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

    // Verify R @ R^T ≈ I. For row-major R, (R R^T)[i][j] = Σ_k R[i][k] * R[j][k].
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
    // Spot-check: the two should differ on the first row at least.
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

    // Arbitrary centroid so the test exercises the residual path.
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

    // Prepare a query == v.
    var q_rot: [32]f32 = undefined;
    var q_residual: [32]f32 = undefined;
    const q_l2 = prepareQuery(v_align, &params, &q_residual, &q_rot);

    const d_est = estimateL2Sq(&q_rot, q_l2, &code, enc.l2_norm, enc.corr);
    // With q == v the true distance is 0; the estimator has quantization
    // error of O(1/√d), so for d=32 the error can be a few percent of
    // ||r||². Loose tolerance proportional to l2 squared.
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

    // Build n random vectors.
    const vecs = try alloc.alloc(f32, n * dim);
    defer alloc.free(vecs);
    for (vecs) |*x| x.* = rand.floatNorm(f32);

    // Encode all of them.
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

    // Pick the first vector as query; estimate distance to all others.
    const q = vecs[0..dim];
    const q_align: []align(1) const f32 = @ptrCast(q);

    const q_rot = try alloc.alloc(f32, dim);
    defer alloc.free(q_rot);
    const q_residual = try alloc.alloc(f32, dim);
    defer alloc.free(q_residual);

    const q_l2 = prepareQuery(q_align, &params, q_residual, q_rot);

    // For each candidate, compare true L2² vs estimated.
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

    // Sanity: at d=64, the paper predicts O(1/√d) = ~12% error. We
    // assert a lax mean-error bound that still catches coding bugs
    // (off-by-factor-of-2, wrong bit ordering, sign flips all land
    // at 50%+ error).
    try testing.expect(avg_rel_err < 0.30);
    // And that most candidates land within 20% — again, loose but
    // catches systematic bias.
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
    try testing.expect(parse(&buf, 32) == null); // would need 12 bytes
}

test "rabitq: kNN recall on synthetic Gaussian corpus" {
    // End-to-end recall check: build params, encode a corpus, issue a
    // query, and verify the top-K estimated nearest neighbors overlap
    // substantially with the true top-K. The paper predicts ~0.85
    // recall at d=128 with rerank=off; for d=64 on isotropic Gaussians
    // the estimator still works but with more variance — we assert a
    // lax bound (≥0.5) that still catches coding regressions.
    const alloc = testing.allocator;
    const dim: usize = 64;
    const n: usize = 500;
    const top_k: usize = 10;
    const oversample: usize = 4; // stage-1 budget = top_k * oversample

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
    // Centroid = dataset mean so residuals are centered.
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

    const codes = try alloc.alloc(u8, n * codeBytes(dim));
    defer alloc.free(codes);
    const l2_norms = try alloc.alloc(f32, n);
    defer alloc.free(l2_norms);
    const corrs = try alloc.alloc(f32, n);
    defer alloc.free(corrs);

    for (0..n) |i| {
        const v = vecs[i * dim ..][0..dim];
        const v_align: []align(1) const f32 = @ptrCast(v);
        const code_slice = codes[i * codeBytes(dim) ..][0..codeBytes(dim)];
        const enc = encode(v_align, &params, residual, rotated, code_slice);
        l2_norms[i] = enc.l2_norm;
        corrs[i] = enc.corr;
    }

    // Build a query that's an existing database point perturbed — this
    // is the usual ANN benchmark shape.
    const q_vec = try alloc.alloc(f32, dim);
    defer alloc.free(q_vec);
    for (0..dim) |j| q_vec[j] = vecs[42 * dim + j] + rand.floatNorm(f32) * 0.1;

    // True top-K by brute-force L2 squared.
    const TrueEntry = struct { idx: usize, d2: f32 };
    const trues = try alloc.alloc(TrueEntry, n);
    defer alloc.free(trues);
    for (0..n) |i| {
        var d2: f32 = 0;
        for (0..dim) |j| {
            const diff = q_vec[j] - vecs[i * dim + j];
            d2 += diff * diff;
        }
        trues[i] = .{ .idx = i, .d2 = d2 };
    }
    std.sort.pdq(TrueEntry, trues, {}, struct {
        fn lt(_: void, a: TrueEntry, b: TrueEntry) bool {
            return a.d2 < b.d2;
        }
    }.lt);

    // Estimated distances via RaBitQ.
    const q_align: []align(1) const f32 = @ptrCast(q_vec);
    const q_rot = try alloc.alloc(f32, dim);
    defer alloc.free(q_rot);
    const q_l2 = prepareQuery(q_align, &params, residual, q_rot);

    const EstEntry = struct { idx: usize, d2_est: f32 };
    const ests = try alloc.alloc(EstEntry, n);
    defer alloc.free(ests);
    for (0..n) |i| {
        const code_slice = codes[i * codeBytes(dim) ..][0..codeBytes(dim)];
        const est = estimateL2Sq(q_rot, q_l2, code_slice, l2_norms[i], corrs[i]);
        ests[i] = .{ .idx = i, .d2_est = est };
    }
    std.sort.pdq(EstEntry, ests, {}, struct {
        fn lt(_: void, a: EstEntry, b: EstEntry) bool {
            return a.d2_est < b.d2_est;
        }
    }.lt);

    // Recall: how many of the true top-K are in the estimated top-(K*oversample)?
    var hit_set = std.AutoHashMapUnmanaged(usize, void).empty;
    defer hit_set.deinit(alloc);
    for (0..top_k) |i| try hit_set.put(alloc, trues[i].idx, {});
    var hits: usize = 0;
    for (0..top_k * oversample) |i| {
        if (hit_set.contains(ests[i].idx)) hits += 1;
    }
    const recall: f32 = @as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(top_k));

    // Also check: the recall at top-K (no oversample) should still
    // clearly beat random (which would be top_k/n = 2%).
    var hits_direct: usize = 0;
    for (0..top_k) |i| {
        if (hit_set.contains(ests[i].idx)) hits_direct += 1;
    }
    const recall_direct: f32 = @as(f32, @floatFromInt(hits_direct)) / @as(f32, @floatFromInt(top_k));

    try testing.expect(recall >= 0.5);
    try testing.expect(recall_direct >= 0.3);
}
