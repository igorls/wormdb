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

const CollectedEntry = struct {
    key_off: usize,
    key_len: usize,
    vec_off: usize,
};

/// Single read-only scan: accumulate SIMD f32→f64 sum AND stage `(key, vec)`
/// copies so we NEVER call `setDurable` inside `scanPrefixCallback` (eliminates
/// AB-BA shard deadlock #3 and halves KV scan overhead).
const CollectSumCtx = struct {
    allocator: std.mem.Allocator,
    sum: []f64,
    norm_scratch: []f32,
    normalize: bool,
    keys_blob: std.ArrayListUnmanaged(u8) = .empty,
    vecs_blob: std.ArrayListUnmanaged(f32) = .empty,
    entries: std.ArrayListUnmanaged(CollectedEntry) = .empty,
    expected_dim: usize = 0,
    mismatches: usize = 0,
    oom: bool = false,

    fn deinit(self: *CollectSumCtx) void {
        self.keys_blob.deinit(self.allocator);
        self.vecs_blob.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }
};

fn accumulateF32ToF64(sum: []f64, src: []const f32) void {
    const dim = src.len;
    const vec_dim = dim - (dim % 4);
    var i: usize = 0;
    while (i < vec_dim) : (i += 4) {
        const v4: @Vector(4, f32) = src[i..][0..4].*;
        const d4: @Vector(4, f64) = @floatCast(v4);
        const s4: @Vector(4, f64) = sum[i..][0..4].*;
        sum[i..][0..4].* = s4 + d4;
    }
    while (i < dim) : (i += 1) {
        sum[i] += src[i];
    }
}

fn collectAndSum(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = timestamp;
    _ = is_worm;
    const sc: *CollectSumCtx = @ptrCast(@alignCast(raw_ctx));
    const vec = distance.bytesToF32(value) orelse return .cont;

    if (sc.expected_dim == 0) {
        if (vec.len > sc.sum.len) return .cont;
        sc.expected_dim = vec.len;
    } else if (vec.len != sc.expected_dim) {
        sc.mismatches += 1;
        return .cont;
    }

    const dim = vec.len;
    const key_off = sc.keys_blob.items.len;
    const vec_off = sc.vecs_blob.items.len;

    if (sc.normalize) {
        if (!rabitq.normalizeInto(vec, sc.norm_scratch[0..dim])) return .cont;
        accumulateF32ToF64(sc.sum[0..dim], sc.norm_scratch[0..dim]);
        sc.keys_blob.appendSlice(sc.allocator, key) catch {
            sc.oom = true;
            return .stop;
        };
        const dst = sc.vecs_blob.addManyAsSlice(sc.allocator, dim) catch {
            sc.oom = true;
            return .stop;
        };
        @memcpy(dst, sc.norm_scratch[0..dim]);
    } else {
        sc.keys_blob.appendSlice(sc.allocator, key) catch {
            sc.oom = true;
            return .stop;
        };
        const dst = sc.vecs_blob.addManyAsSlice(sc.allocator, dim) catch {
            sc.oom = true;
            return .stop;
        };
        @memcpy(std.mem.sliceAsBytes(dst), value);
        accumulateF32ToF64(sc.sum[0..dim], dst);
    }

    sc.entries.append(sc.allocator, .{
        .key_off = key_off,
        .key_len = key.len,
        .vec_off = vec_off,
    }) catch {
        sc.oom = true;
        return .stop;
    };
    return .cont;
}

/// Fused `residual = v - centroid` and `||residual||²` for aligned f32 slices.
fn residualAndNormSq(v: []const f32, centroid: []const f32, residual_out: []f32) f32 {
    const dim = v.len;
    const vec_dim = dim - (dim % 8);
    var acc: @Vector(8, f32) = @splat(0.0);
    var i: usize = 0;
    while (i < vec_dim) : (i += 8) {
        const r = @as(@Vector(8, f32), v[i..][0..8].*) - @as(@Vector(8, f32), centroid[i..][0..8].*);
        residual_out[i..][0..8].* = r;
        acc = @mulAdd(@Vector(8, f32), r, r, acc);
    }
    var sum_sq: f32 = @reduce(.Add, acc);
    while (i < dim) : (i += 1) {
        const r = v[i] - centroid[i];
        residual_out[i] = r;
        sum_sq += r * r;
    }
    return sum_sq;
}

/// Quantize a rotated residual vector into 1-bit MSB-first code + scalar trailer
/// matching `rabitq.encode` + `rabitq.serialize` bit-for-bit.
fn finalizeRotatedAndSerialize(
    rotated: []const f32,
    l2: f32,
    prescale: bool,
    degenerate: bool,
    out_buf: []u8,
) void {
    const dim = rotated.len;
    const cb = rabitq.codeBytes(dim);
    const code_out = out_buf[0..cb];
    if (degenerate) {
        @memset(code_out, 0);
        rabitq.serialize(.{ .code = code_out, .l2_norm = 0.0, .corr = 1.0 }, out_buf);
        return;
    }

    var abs_sum: f32 = 0.0;
    var i: usize = 0;
    const zero8: @Vector(8, f32) = @splat(0.0);
    var abs8: @Vector(8, f32) = @splat(0.0);
    const vec8 = dim - (dim % 8);
    while (i < vec8) : (i += 8) {
        const r_chunk: @Vector(8, f32) = rotated[i..][0..8].*;
        abs8 += @abs(r_chunk);
        const mask: u8 = @bitCast(r_chunk >= zero8);
        code_out[i / 8] = distance.BITREV_LUT[mask];
    }
    abs_sum += @reduce(.Add, abs8);

    if (i < dim) {
        const byte_idx = i / 8;
        var tail_byte: u8 = 0;
        while (i < dim) : (i += 1) {
            const r = rotated[i];
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
    rabitq.serialize(.{ .code = code_out, .l2_norm = l2, .corr = corr }, out_buf);
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

    // Installs quantizer params and rewrites every bq:<namespace>* entry.
    try ctx.requirePrefix(namespace, .write);

    const seed: u64 = if (ctx.arg(1)) |s|
        std.fmt.parseInt(u64, s, 0) catch deriveDefaultSeed(namespace)
    else
        deriveDefaultSeed(namespace);

    // Resolve the namespace's metric *before* the centroid scan so the
    // accumulator knows whether to pre-normalize.
    const registry = ctx.vector_registry orelse
        return ctx.err("vrabitq: vector registry not available");
    const ns_idx = registry.get(namespace) orelse
        return ctx.err("vrabitq: namespace has no index (run VINSERT first)");
    const normalize_for_metric = (ns_idx.metric == .cosine);

    // Oversized but safe: SIFT=128, OpenAI=1536, future anything up to 4096.
    const MAX_DIM: usize = 4096;
    const sum_buf = try ctx.allocator.alloc(f64, MAX_DIM);
    defer ctx.allocator.free(sum_buf);
    @memset(sum_buf, 0);

    const norm_scratch = try ctx.allocator.alloc(f32, MAX_DIM);
    defer ctx.allocator.free(norm_scratch);

    // ── Phase 1: single read-only scan (collect + SIMD centroid sum) ──
    var sc = CollectSumCtx{
        .allocator = ctx.allocator,
        .sum = sum_buf,
        .norm_scratch = norm_scratch,
        .normalize = normalize_for_metric,
    };
    defer sc.deinit();
    ctx.scanCallback(namespace, @ptrCast(&sc), collectAndSum);

    if (sc.oom) return ctx.err("vrabitq: out of memory during scan");
    const count = sc.entries.items.len;
    if (count == 0) {
        return ctx.err("vrabitq: no vectors found in namespace");
    }
    if (sc.expected_dim == 0) {
        return ctx.err("vrabitq: failed to detect vector dimension");
    }

    const dim = sc.expected_dim;

    const centroid = try ns_idx.allocator.alloc(f32, dim);
    var ownership_transferred = false;
    errdefer if (!ownership_transferred) ns_idx.allocator.free(centroid);
    const count_f: f64 = @floatFromInt(count);
    for (0..dim) |i| centroid[i] = @floatCast(sum_buf[i] / count_f);

    const rotation = rabitq.generateRotation(ns_idx.allocator, dim, seed) catch |e| {
        std.log.warn("vrabitq: generateRotation failed: {s}", .{@errorName(e)});
        return ctx.err("vrabitq: failed to generate rotation matrix");
    };
    errdefer if (!ownership_transferred) ns_idx.allocator.free(rotation);

    const params_ptr = try ns_idx.allocator.create(rabitq.RabitqParams);
    errdefer if (!ownership_transferred) ns_idx.allocator.destroy(params_ptr);
    params_ptr.* = .{
        .allocator = ns_idx.allocator,
        .centroid = centroid,
        .rotation = rotation,
        .dim = @intCast(dim),
        .seed = seed,
    };

    // Install under write-lock and retain a local handle so `params_ptr` stays
    // valid throughout Phase 2 even if another `vrabitq` runs concurrently.
    var rq_handle: ?*IndexModule.RabitqParamsHandle = null;
    defer if (rq_handle) |h| h.release();
    {
        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        try ns_idx.setRabitqParams(params_ptr);
        ownership_transferred = true;
        rq_handle = ns_idx.acquireRabitqHandleLocked();
    }

    // Broadcast params to peers BEFORE writing re-encoded bq:* SETs.
    if (ctx.cluster) |c| {
        const centroid_bytes = std.mem.sliceAsBytes(params_ptr.centroid);
        const rotation_bytes = std.mem.sliceAsBytes(params_ptr.rotation);
        c.replicateVrabitqInstall(.{
            .namespace = namespace,
            .dim = params_ptr.dim,
            .seed = params_ptr.seed,
            .centroid = centroid_bytes,
            .rotation = rotation_bytes,
        }) catch |e| {
            std.log.warn("vrabitq: replicateVrabitqInstall failed: {s}", .{@errorName(e)});
        };
    }

    // ── Phase 2A: bulk 4-way batched RaBitQ encoding off all locks ────
    const enc_size = rabitq.encodedSize(dim);
    const encoded_blob = try ctx.allocator.alloc(u8, count * enc_size);
    defer ctx.allocator.free(encoded_blob);
    const slab_entries = try ctx.allocator.alloc(IndexModule.NamespaceIndex.EncodedSlabEntry, count);
    defer ctx.allocator.free(slab_entries);

    const res_batch_mem = try ctx.allocator.alloc(f32, 4 * dim);
    defer ctx.allocator.free(res_batch_mem);
    const rot_batch_mem = try ctx.allocator.alloc(f32, 4 * dim);
    defer ctx.allocator.free(rot_batch_mem);

    const res4 = [4][]f32{
        res_batch_mem[0..dim],
        res_batch_mem[dim .. 2 * dim],
        res_batch_mem[2 * dim .. 3 * dim],
        res_batch_mem[3 * dim .. 4 * dim],
    };
    const rot4 = [4][]f32{
        rot_batch_mem[0..dim],
        rot_batch_mem[dim .. 2 * dim],
        rot_batch_mem[2 * dim .. 3 * dim],
        rot_batch_mem[3 * dim .. 4 * dim],
    };

    var idx_i: usize = 0;
    while (idx_i + 4 <= count) : (idx_i += 4) {
        var l2s: [4]f32 = undefined;
        var degenerates: [4]bool = undefined;
        var prescales: [4]bool = undefined;

        inline for (0..4) |lane| {
            const e = sc.entries.items[idx_i + lane];
            const vec = sc.vecs_blob.items[e.vec_off..][0..dim];
            const sum_sq = residualAndNormSq(vec, params_ptr.centroid, res4[lane]);
            const l2 = @sqrt(sum_sq);
            l2s[lane] = l2;
            const degen = (l2 < 1e-20);
            degenerates[lane] = degen;
            const pre = (!degen and (l2 > 1e15 or l2 < 1e-15));
            prescales[lane] = pre;
            if (degen) {
                @memset(res4[lane], 0.0);
            } else if (pre) {
                const inv_l2 = 1.0 / l2;
                for (res4[lane]) |*x| x.* *= inv_l2;
            }
        }

        rabitq.applyRotationBatch4(
            params_ptr.rotation,
            .{ res4[0], res4[1], res4[2], res4[3] },
            rot4,
        );

        inline for (0..4) |lane| {
            const pos = idx_i + lane;
            const e = sc.entries.items[pos];
            const out_slice = encoded_blob[pos * enc_size ..][0..enc_size];
            finalizeRotatedAndSerialize(rot4[lane], l2s[lane], prescales[lane], degenerates[lane], out_slice);
            slab_entries[pos] = .{
                .key = sc.keys_blob.items[e.key_off..][0..e.key_len],
                .encoded = out_slice,
            };
        }
    }

    while (idx_i < count) : (idx_i += 1) {
        const e = sc.entries.items[idx_i];
        const vec: []align(1) const f32 = sc.vecs_blob.items[e.vec_off..][0..dim];
        const out_slice = encoded_blob[idx_i * enc_size ..][0..enc_size];
        const enc = rabitq.encode(vec, params_ptr, res4[0], rot4[0], out_slice[0..rabitq.codeBytes(dim)]);
        rabitq.serialize(enc, out_slice);
        slab_entries[idx_i] = .{
            .key = sc.keys_blob.items[e.key_off..][0..e.key_len],
            .encoded = out_slice,
        };
    }

    // ── Phase 2B: populate in-index RaBitQ FastScan32/SoA slab atomically ──
    {
        ns_idx.lock.lock();
        defer ns_idx.lock.unlock();
        ns_idx.installRabitqSlabFromEncodedLocked(params_ptr, slab_entries) catch |e| {
            std.log.warn("vrabitq: installRabitqSlab failed: {s}", .{@errorName(e)});
        };
    }

    // ── Phase 2C: persist `bq:<key>` entries OUTSIDE all scan/index locks ──
    var requantized: usize = 0;
    var bq_key_stack: [512]u8 = undefined;
    for (slab_entries) |se| {
        const need = 3 + se.key.len;
        var bq_key_heap: ?[]u8 = null;
        defer if (bq_key_heap) |b| ctx.allocator.free(b);
        const bq_key: []const u8 = if (need <= bq_key_stack.len) blk: {
            @memcpy(bq_key_stack[0..3], "bq:");
            @memcpy(bq_key_stack[3..need], se.key);
            break :blk bq_key_stack[0..need];
        } else blk: {
            const b = ctx.allocator.alloc(u8, need) catch continue;
            bq_key_heap = b;
            @memcpy(b[0..3], "bq:");
            @memcpy(b[3..need], se.key);
            break :blk b;
        };

        ctx.setDurable(bq_key, se.encoded) catch continue;
        requantized += 1;
    }

    // ── Emit JSON result ───────────────────────────────────────────
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.ensureTotalCapacity(ctx.allocator, namespace.len + 96);
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try json.appendSlice(ctx.allocator, namespace);
    try json.appendSlice(ctx.allocator, "\",\"count\":");
    var num_buf: [32]u8 = undefined;
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{count}) catch "0");
    try json.appendSlice(ctx.allocator, ",\"dim\":");
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{dim}) catch "0");
    try json.appendSlice(ctx.allocator, ",\"seed\":");
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{seed}) catch "0");
    try json.appendSlice(ctx.allocator, ",\"requantized\":");
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&num_buf, "{d}", .{requantized}) catch "0");
    try json.append(ctx.allocator, '}');

    return ctx.valueOwned(try json.toOwnedSlice(ctx.allocator));
}

test "vrabitq: two-phase build populates RaBitQ FastScan32 slab + 24B KV entries for l2 and cosine" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const vector_ops = @import("vector_ops.zig");

    inline for ([_]Metric{ .l2, .cosine }) |metric| {
        var store = try Store.init(alloc, .{ .persistence = .none });
        defer store.deinit();
        var reg = IndexModule.NamespaceRegistry.init(alloc, .{ .m = 8, .ef_construction = 32 });
        defer reg.deinit();
        store.vector_registry = &reg;

        const ns = if (metric == .l2) "vec:rq_l2:" else "vec:rq_cos:";
        const dim: usize = 128;
        var prng = std.Random.DefaultPrng.init(0x5eed1234);
        const rand = prng.random();
        var key_buf: [64]u8 = undefined;
        var vec_buf: [dim]f32 = undefined;

        for (0..40) |i| {
            for (&vec_buf) |*x| x.* = rand.floatNorm(f32);
            const k = std.fmt.bufPrint(&key_buf, "{s}{d}", .{ ns, i }) catch unreachable;
            try vector_ops.applyVinsert(&store, null, null, &reg, alloc, .{
                .key = k,
                .vector = std.mem.sliceAsBytes(&vec_buf),
                .worm = false,
                .namespace = ns,
                .metric = metric,
                .timestamp = 100 + i,
                .replicate = false,
            });
        }

        const args = [_][]const u8{ ns, "42" };
        var ctx = Ctx.init(&store, &args, alloc, null, null, null, &reg);
        defer ctx.deinit();

        const res = try execute(&ctx);
        defer if (res == .value) if (res.value) |v| alloc.free(v);
        try testing.expect(res == .value);
        const json = res.value.?;
        try testing.expect(std.mem.indexOf(u8, json, "\"count\":40") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"dim\":128") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"requantized\":40") != null);

        // Verify slab is populated + FastScan32 block packed and KV bq:* is 24 bytes (16B code + 8B factors).
        const idx = reg.get(ns).?;
        idx.lock.lockShared();
        try testing.expect(idx.canUseRabitqSlabLocked(dim));
        try testing.expectEqual(@as(usize, 1), idx.rq_slab.packed_blocks);
        idx.lock.unlockShared();

        const bq_key = std.fmt.bufPrint(&key_buf, "bq:{s}0", .{ns}) catch unreachable;
        const bq_val = (try store.getValueDupe(bq_key, alloc)).?;
        defer alloc.free(bq_val);
        try testing.expectEqual(@as(usize, rabitq.encodedSize(dim)), bq_val.len);
        try testing.expect(rabitq.parse(bq_val, dim) != null);
    }
}
