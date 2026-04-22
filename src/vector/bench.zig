//! Vector search microbenchmark.
//!
//! Measures:
//!   1. Raw SIMD throughput for cosine/dot/l2 at common embedding dims.
//!   2. Hamming throughput on binary-quantized vectors.
//!   3. "phase1" — full cosine scan + top-K push (baseline / mode=exact path).
//!   4. "phase2.1" — Hamming top-M → exact top-K two-stage (matches the
//!      default `vsearch` mode=auto inner loop).
//!
//! Run with:
//!   zig run src/vector/bench.zig -O ReleaseFast -lc
//!
//! Data is synthetic (normal-distributed random f32). Real embeddings have
//! tighter score distributions so the heap-admission fast path fires more
//! often in production — these numbers are conservative.
//!
//! Numbers are inner-loop-only: no shard lock acquire/release, no hash-map
//! walk, no getCopy per stage-2 candidate. Absolute query latency through
//! the real `vsearch` procedure will be somewhat higher; the relative
//! speedup (phase1 vs phase2.1) should hold because both paths pay the
//! same infrastructure overhead.

const std = @import("std");
const distance = @import("distance.zig");
const topk_mod = @import("topk.zig");

const N_VECTORS: usize = 50_000;
const TOP_K: usize = 10;
const OVERSAMPLE: usize = 10; // M = TOP_K * OVERSAMPLE candidates kept from stage 1
const WARMUP_ITERS: usize = 2;
const MEASURE_ITERS: usize = 5;

const DIMS = [_]usize{ 384, 768, 1536 };

const Candidate = struct { idx: u32, score: f32 };
fn candScore(c: Candidate) f32 {
    return c.score;
}
const TopKCand = topk_mod.TopK(Candidate, candScore);

// Invert so "higher = more similar" for Hamming, matching the cosine convention.
inline fn hammingScore(dist_bits: u32, total_bits: u32) f32 {
    const d: f32 = @floatFromInt(dist_bits);
    const t: f32 = @floatFromInt(total_bits);
    return 1.0 - (d / t);
}

pub fn main() !void {
    // Use page_allocator directly — large slab allocations for the vector
    // arrays don't benefit from a GPA tracker here.
    const alloc = std.heap.page_allocator;

    const out = std.debug;

    out.print("WormDB vector microbench\n", .{});
    out.print("arch={s}  N={d}  K={d}  oversample={d}×  iters={d}\n\n", .{
        @tagName(@import("builtin").cpu.arch),
        N_VECTORS,
        TOP_K,
        OVERSAMPLE,
        MEASURE_ITERS,
    });

    for (DIMS) |dim| {
        try runForDim(alloc, dim);
        out.print("\n", .{});
    }
}

fn runForDim(alloc: std.mem.Allocator, dim: usize) !void {
    const out = std.debug;

    // ── Allocate + randomize vectors and BQ hashes ──────────────
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    const vec_mem = try alloc.alloc(f32, (N_VECTORS + 1) * dim);
    defer alloc.free(vec_mem);
    for (vec_mem) |*f| f.* = rand.floatNorm(f32);

    const bq_size = (dim + 7) / 8;
    const bq_mem = try alloc.alloc(u8, (N_VECTORS + 1) * bq_size);
    defer alloc.free(bq_mem);
    for (0..N_VECTORS + 1) |i| {
        const src: []align(1) const f32 = vec_mem[i * dim ..][0..dim];
        distance.binaryQuantize(src, bq_mem[i * bq_size ..][0..bq_size]);
    }

    const query_vec: []align(1) const f32 = vec_mem[0..dim];
    const query_bq = bq_mem[0..bq_size];

    // ── Micro-benchmarks (distance functions in isolation) ───────
    const cosine_ns = try timeRepeated(struct {
        fn run(p: anytype) void {
            var sink: f32 = 0;
            for (1..N_VECTORS + 1) |i| {
                const v: []align(1) const f32 = p.vec_mem[i * p.dim ..][0..p.dim];
                sink += distance.cosine(p.q, v);
            }
            std.mem.doNotOptimizeAway(sink);
        }
    }.run, .{ .vec_mem = vec_mem, .dim = dim, .q = query_vec });

    const hamming_ns = try timeRepeated(struct {
        fn run(p: anytype) void {
            var sink: u32 = 0;
            for (1..N_VECTORS + 1) |i| {
                const h = p.bq_mem[i * p.bq_size ..][0..p.bq_size];
                sink +%= distance.hamming(p.q, h);
            }
            std.mem.doNotOptimizeAway(sink);
        }
    }.run, .{ .bq_mem = bq_mem, .bq_size = bq_size, .q = query_bq });

    // ── Phase 1: full vsearch inner loop (cosine + top-K push) ───
    const phase1_ns = try timeRepeated(struct {
        fn run(p: anytype) void {
            var heap_buf: [TOP_K]Candidate = undefined;
            var heap = TopKCand.init(&heap_buf);
            for (1..N_VECTORS + 1) |i| {
                const v: []align(1) const f32 = p.vec_mem[i * p.dim ..][0..p.dim];
                const score = distance.cosine(p.q, v);
                if (score > heap.thresholdScore()) {
                    heap.push(.{ .idx = @intCast(i), .score = score });
                }
            }
            _ = heap.sortedDesc();
        }
    }.run, .{ .vec_mem = vec_mem, .dim = dim, .q = query_vec });

    // ── Phase 2.1: Hamming stage-1 → exact refine on top-M ───────
    const m_buf_size = TOP_K * OVERSAMPLE;
    const stage1_buf = try alloc.alloc(Candidate, m_buf_size);
    defer alloc.free(stage1_buf);

    const total_bits: u32 = @intCast(bq_size * 8);

    const phase2_ns = try timeRepeated(struct {
        fn run(p: anytype) void {
            var stage1 = TopKCand.init(p.stage1_buf);
            for (1..N_VECTORS + 1) |i| {
                const h = p.bq_mem[i * p.bq_size ..][0..p.bq_size];
                const dist = distance.hamming(p.q_bq, h);
                const score = hammingScore(dist, p.total_bits);
                if (score > stage1.thresholdScore()) {
                    stage1.push(.{ .idx = @intCast(i), .score = score });
                }
            }
            const candidates = stage1.sortedDesc();

            var heap_buf: [TOP_K]Candidate = undefined;
            var heap = TopKCand.init(&heap_buf);
            for (candidates) |c| {
                const v: []align(1) const f32 = p.vec_mem[c.idx * p.dim ..][0..p.dim];
                const score = distance.cosine(p.q_vec, v);
                heap.push(.{ .idx = c.idx, .score = score });
            }
            _ = heap.sortedDesc();
        }
    }.run, .{
        .vec_mem = vec_mem,
        .bq_mem = bq_mem,
        .dim = dim,
        .bq_size = bq_size,
        .stage1_buf = stage1_buf,
        .total_bits = total_bits,
        .q_vec = query_vec,
        .q_bq = query_bq,
    });

    // ── Report ──────────────────────────────────────────────────
    const cosine_per = cosine_ns / @as(f64, @floatFromInt(N_VECTORS));
    const hamming_per = hamming_ns / @as(f64, @floatFromInt(N_VECTORS));
    const phase1_ms = phase1_ns / 1_000_000.0;
    const phase2_ms = phase2_ns / 1_000_000.0;
    const speedup = phase1_ns / phase2_ns;
    const phase1_qps = 1_000.0 / phase1_ms;
    const phase2_qps = 1_000.0 / phase2_ms;

    out.print("dim={d}  bq_bytes={d}\n", .{ dim, bq_size });
    out.print("  cosine        {d:>8.1} ns/op  ({d:>5.2} GFLOP/s)\n", .{
        cosine_per,
        // ~3 flops per dim (mul-add + 2 norms are amortized)
        @as(f64, @floatFromInt(dim)) * 3.0 / cosine_per,
    });
    out.print("  hamming(BQ)   {d:>8.1} ns/op  ({d:>5.1}× faster)\n", .{
        hamming_per,
        cosine_per / hamming_per,
    });
    out.print("  phase1 (cos)  {d:>8.2} ms/query  →  {d:>7.1} QPS\n", .{ phase1_ms, phase1_qps });
    out.print("  phase2.1 (BQ) {d:>8.2} ms/query  →  {d:>7.1} QPS   [speedup {d:.1}×]\n", .{
        phase2_ms,
        phase2_qps,
        speedup,
    });
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn timeRepeated(comptime run: anytype, params: anytype) !f64 {
    var i: usize = 0;
    while (i < WARMUP_ITERS) : (i += 1) run(params);

    var best_ns: u64 = std.math.maxInt(u64);
    var k: usize = 0;
    while (k < MEASURE_ITERS) : (k += 1) {
        const t0 = nowNs();
        run(params);
        const t1 = nowNs();
        const elapsed = t1 - t0;
        if (elapsed < best_ns) best_ns = elapsed;
    }
    return @floatFromInt(best_ns);
}
