//! Built-in VRABITQ procedure — install full RaBitQ parameters
//! (centroid + random orthogonal rotation) on a namespace and
//! re-encode every stored BQ hash into the unbiased-estimator format.
//!
//! EXEC vrabitq [<namespace>] [<seed>]
//!
//! - namespace: prefix to process (default: "vec:")
//! - seed:      u64 RNG seed for the rotation; default = stable hash of
//!              the namespace. Pass an explicit seed to reproduce a
//!              prior build bit-for-bit.
//!
//! RaBitQ (Gao & Long, SIGMOD 2024) gives a 1-bit quantizer with an
//! unbiased distance estimator. The two additions over phase-1 centered
//! BQ are:
//!
//!   1. **Random orthogonal rotation.** Before quantizing, project the
//!      centered residual through a d×d rotation matrix. Rotation
//!      decorrelates components so each bit carries roughly log(2)
//!      independent information — crucial for structured data like
//!      SIFT where raw dimensions are highly correlated.
//!
//!   2. **Per-vector bias-correction factor.** Store the L2 norm of the
//!      residual and the scalar `corr = ⟨ō, b̄⟩` alongside the bit
//!      pattern. With these, the distance estimator is unbiased:
//!      `d²(q,v) ≈ ||r_q||² + ||r||² − 2·||r_q||·||r||·⟨q_rot, b̄⟩/corr`,
//!      eliminating the full-precision rerank step for most queries.
//!
//! Procedure flow:
//!   1. Scan namespace to accumulate sum → centroid c.
//!   2. Generate R = deterministic d×d orthogonal matrix from seed.
//!   3. Install RabitqParams{c, R, dim, seed} on the namespace index.
//!   4. Second-pass scan: re-encode every vector as 24-byte (on d=128)
//!      `[code][l2][corr]` and overwrite the `bq:*` entry.
//!
//! Installing the params BEFORE the re-encode pass matters: any
//! concurrent VINSERT that lands between steps 3 and 4 will already use
//! the new format (via `encodeBqOwned` in vector_ops), so the namespace
//! never has a mixed 16B/24B population after this procedure returns.
//!
//! Returns JSON: {"namespace":"…","count":N,"dim":D,"seed":S,"requantized":M}

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const distance = @import("../vector/distance.zig");
const rabitq = @import("../vector/rabitq.zig");
const Store = @import("../storage/store.zig").Store;
const IndexModule = @import("../vector/index.zig");
const Metric = @import("../vector/metric.zig").Metric;

const DEFAULT_NAMESPACE: []const u8 = "vec:";

/// Phase 1 scan: accumulate the running sum into `sum_buf` and count.
const SumCtx = struct {
    sum: []f64, // f64 to avoid precision loss over millions of f32 adds
    count: usize,
    expected_dim: usize, // 0 = not yet captured
    mismatches: usize,
};

fn accumulateVector(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = key;
    _ = timestamp;
    _ = is_worm;
    const sc: *SumCtx = @ptrCast(@alignCast(raw_ctx));
    const vec = distance.bytesToF32(value) orelse return .cont;

    if (sc.expected_dim == 0) {
        if (vec.len > sc.sum.len) return .cont; // caller-supplied buffer too small
        sc.expected_dim = vec.len;
    } else if (vec.len != sc.expected_dim) {
        sc.mismatches += 1;
        return .cont;
    }

    for (vec, 0..) |v, i| sc.sum[i] += v;
    sc.count += 1;
    return .cont;
}

/// Phase 2 scan: for each vector, encode via RaBitQ and write the
/// serialized 24-byte (on d=128) record to `bq:<key>`.
const RequantCtx = struct {
    ctx: *Ctx,
    params: *const rabitq.RabitqParams,
    residual: []f32,
    rotated: []f32,
    bq_buf: []u8,
    requantized: usize,
};

fn requantizeOne(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = timestamp;
    _ = is_worm;
    const rc: *RequantCtx = @ptrCast(@alignCast(raw_ctx));
    const vec = distance.bytesToF32(value) orelse return .cont;
    if (vec.len != rc.params.dim) return .cont;

    const code_slice = rc.bq_buf[0..rabitq.codeBytes(vec.len)];
    const enc = rabitq.encode(vec, rc.params, rc.residual, rc.rotated, code_slice);
    rabitq.serialize(enc, rc.bq_buf);

    const bq_key = std.fmt.allocPrint(rc.ctx.allocator, "bq:{s}", .{key}) catch return .cont;
    defer rc.ctx.allocator.free(bq_key);

    // Use setDurable so the replacement replicates (BQ hashes are normally
    // non-WORM so this is allowed even if the vec entry is WORM).
    rc.ctx.setDurable(bq_key, rc.bq_buf) catch return .cont;
    rc.requantized += 1;
    return .cont;
}

/// Derive a stable default seed from the namespace string when the
/// caller doesn't provide one. FNV-1a 64-bit — simple, fast, and
/// produces visibly different seeds for similar namespaces.
fn deriveDefaultSeed(namespace: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (namespace) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const namespace = ctx.arg(0) orelse DEFAULT_NAMESPACE;

    const seed: u64 = if (ctx.arg(1)) |s|
        std.fmt.parseInt(u64, s, 0) catch deriveDefaultSeed(namespace)
    else
        deriveDefaultSeed(namespace);

    // Oversized but safe: SIFT=128, OpenAI=1536, future anything up to 4096.
    const MAX_DIM: usize = 4096;
    const sum_buf = try ctx.allocator.alloc(f64, MAX_DIM);
    defer ctx.allocator.free(sum_buf);
    @memset(sum_buf, 0);

    var sc = SumCtx{
        .sum = sum_buf,
        .count = 0,
        .expected_dim = 0,
        .mismatches = 0,
    };
    ctx.scanCallback(namespace, @ptrCast(&sc), accumulateVector);

    if (sc.count == 0) {
        return ctx.err("vrabitq: no vectors found in namespace");
    }
    if (sc.expected_dim == 0) {
        return ctx.err("vrabitq: failed to detect vector dimension");
    }

    const dim = sc.expected_dim;

    // ── Build RabitqParams on the namespace's allocator ─────────────
    // The NamespaceIndex owns and frees these buffers when the index is
    // destroyed, so they must be allocated from the matching allocator.
    const registry = ctx.vector_registry orelse
        return ctx.err("vrabitq: vector registry not available");
    const ns_idx = registry.get(namespace) orelse
        return ctx.err("vrabitq: namespace has no index (run VINSERT first)");

    const centroid = try ns_idx.allocator.alloc(f32, dim);
    errdefer ns_idx.allocator.free(centroid);
    const count_f: f64 = @floatFromInt(sc.count);
    for (0..dim) |i| centroid[i] = @floatCast(sum_buf[i] / count_f);

    const rotation = rabitq.generateRotation(ns_idx.allocator, dim, seed) catch |e| {
        ns_idx.allocator.free(centroid);
        std.log.warn("vrabitq: generateRotation failed: {s}", .{@errorName(e)});
        return ctx.err("vrabitq: failed to generate rotation matrix");
    };
    errdefer ns_idx.allocator.free(rotation);

    const params_ptr = try ns_idx.allocator.create(rabitq.RabitqParams);
    errdefer ns_idx.allocator.destroy(params_ptr);
    params_ptr.* = .{
        .allocator = ns_idx.allocator,
        .centroid = centroid,
        .rotation = rotation,
        .dim = @intCast(dim),
        .seed = seed,
    };

    // Install under the write-lock; after this point new VINSERTs pick
    // up the new encoding path via `encodeBqOwned`.
    {
        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        ns_idx.setRabitqParams(params_ptr);
    }

    // ── Phase 2: re-encode every stored vector ─────────────────────
    const residual = try ctx.allocator.alloc(f32, dim);
    defer ctx.allocator.free(residual);
    const rotated = try ctx.allocator.alloc(f32, dim);
    defer ctx.allocator.free(rotated);
    const bq_buf = try ctx.allocator.alloc(u8, rabitq.encodedSize(dim));
    defer ctx.allocator.free(bq_buf);

    var rc = RequantCtx{
        .ctx = ctx,
        .params = params_ptr,
        .residual = residual,
        .rotated = rotated,
        .bq_buf = bq_buf,
        .requantized = 0,
    };
    ctx.scanCallback(namespace, @ptrCast(&rc), requantizeOne);

    // ── Emit JSON result ───────────────────────────────────────────
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try json.appendSlice(ctx.allocator, namespace);
    try json.appendSlice(ctx.allocator, "\",\"count\":");
    var num_buf: [32]u8 = undefined;
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{sc.count}) catch "0");
    try json.appendSlice(ctx.allocator, ",\"dim\":");
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{dim}) catch "0");
    try json.appendSlice(ctx.allocator, ",\"seed\":");
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{seed}) catch "0");
    try json.appendSlice(ctx.allocator, ",\"requantized\":");
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{rc.requantized}) catch "0");
    try json.append(ctx.allocator, '}');

    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}
