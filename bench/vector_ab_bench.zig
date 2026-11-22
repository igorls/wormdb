//! Comprehensive A/B Vector / HNSW / RaBitQ Benchmark Suite.
//!
//! Compiles against WormDB's public vector/storage/executor APIs so the exact
//! same source produces apples-to-apples binaries before and after engine
//! optimizations (for 5-round interleaved A/B comparisons).
//!
//! Usage:
//!   vector_ab_bench [--section=all|simd|hnsw|serde|rabitq|vsearch|filtered|mt] [--json]
//!
//! All workloads use deterministic PRNG seeds, explicit warmup passes, and
//! held-out query sets (never inserted into the HNSW graph) verified against
//! exact brute-force ground-truth top-10.

const std = @import("std");
const builtin = @import("builtin");
const wormdb = @import("wormdb");

/// Suppress engine `std.log.info` lines (e.g. snapshot load banners) so `--json`
/// output stays strictly valid JSON even when stdout and stderr are merged (`2>&1`).
pub const std_options: std.Options = .{
    .log_level = .warn,
};

const compat = wormdb.core.compat;
const Store = wormdb.storage.Store;
const EventBus = wormdb.event.EventBus;
const executor = wormdb.server.executor;
const distance = wormdb.vector.distance;
const rabitq = wormdb.vector.rabitq;
const Hnsw = wormdb.vector.Hnsw;
const HnswSearchResult = wormdb.vector.hnsw.SearchResult;
const NamespaceRegistry = wormdb.vector.NamespaceRegistry;
const IndexSearchResult = wormdb.vector.index.IndexSearchResult;
const topk_mod = wormdb.vector.topk;

fn nowNs() u64 {
    return @intCast(compat.nowNs());
}

/// Counting allocator wrapping a backing allocator to measure exact heap bytes & alloc counts.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    alloc_count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const res = self.child.rawAlloc(len, alignment, ret_addr);
        if (res != null) {
            self.live_bytes += len;
            self.alloc_count += 1;
            if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
        }
        return res;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len >= memory.len) {
                self.live_bytes += (new_len - memory.len);
                if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
            } else {
                self.live_bytes -= (memory.len - new_len);
            }
        }
        return ok;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const res = self.child.rawRemap(memory, alignment, new_len, ret_addr);
        if (res != null) {
            if (new_len >= memory.len) {
                self.live_bytes += (new_len - memory.len);
                if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
            } else {
                self.live_bytes -= (memory.len - new_len);
            }
        }
        return res;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.live_bytes -|= memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

const Reporter = struct {
    alloc: std.mem.Allocator,
    json_mode: bool,
    json_buf: std.ArrayListUnmanaged(u8) = .empty,
    item_count: usize = 0,

    fn init(alloc: std.mem.Allocator, json_mode: bool, section_name: []const u8) !Reporter {
        var r = Reporter{ .alloc = alloc, .json_mode = json_mode };
        if (json_mode) {
            try r.appendFmt("{{\"suite\":\"vector_ab_bench\",\"arch\":\"{s}\",\"os\":\"{s}\",\"section\":\"{s}\",\"results\":[", .{
                @tagName(builtin.cpu.arch),
                @tagName(builtin.os.tag),
                section_name,
            });
        }
        return r;
    }

    fn deinit(self: *Reporter) void {
        self.json_buf.deinit(self.alloc);
    }

    fn appendFmt(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        var tmp: [2048]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch {
            const heap_s = try std.fmt.allocPrint(self.alloc, fmt, args);
            defer self.alloc.free(heap_s);
            try self.json_buf.appendSlice(self.alloc, heap_s);
            return;
        };
        try self.json_buf.appendSlice(self.alloc, s);
    }

    fn header(self: *Reporter, title: []const u8) void {
        if (self.json_mode) return;
        std.debug.print("\n================================================================================\n", .{});
        std.debug.print("  {s}\n", .{title});
        std.debug.print("================================================================================\n", .{});
    }

    fn line(self: *Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.json_mode) return;
        std.debug.print(fmt, args);
    }

    fn emitJsonObj(self: *Reporter, comptime fmt: []const u8, args: anytype) !void {
        if (!self.json_mode) return;
        if (self.item_count > 0) try self.json_buf.append(self.alloc, ',');
        self.item_count += 1;
        try self.json_buf.append(self.alloc, '\n');
        try self.json_buf.appendSlice(self.alloc, "  ");
        try self.appendFmt(fmt, args);
    }

    fn finish(self: *Reporter) !void {
        if (!self.json_mode) return;
        try self.json_buf.appendSlice(self.alloc, "\n]}\n");
        try std.Io.File.stdout().writeStreamingAll(
            std.Io.Threaded.global_single_threaded.io(),
            self.json_buf.items,
        );
    }
};

const Cand = struct { id: u32, score: f32 };
fn candScore(c: Cand) f32 {
    return c.score;
}
const TopKCand = topk_mod.TopK(Cand, candScore);

const Dataset = struct {
    corpus: []f32,
    queries: []f32,
};

fn genDataset(
    alloc: std.mem.Allocator,
    n: usize,
    q: usize,
    dim: usize,
    clustered: bool,
    n_clusters: usize,
    sigma: f32,
    seed: u64,
) !Dataset {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    const corpus = try alloc.alloc(f32, n * dim);
    errdefer alloc.free(corpus);
    const queries = try alloc.alloc(f32, q * dim);
    errdefer alloc.free(queries);

    if (clustered) {
        const centers = try alloc.alloc(f32, n_clusters * dim);
        defer alloc.free(centers);
        for (centers) |*c| c.* = rand.floatNorm(f32);

        for (0..n) |i| {
            const cid = i % n_clusters;
            const center = centers[cid * dim ..][0..dim];
            const dst = corpus[i * dim ..][0..dim];
            for (0..dim) |d| dst[d] = center[d] + sigma * rand.floatNorm(f32);
        }
        for (0..q) |i| {
            const cid = rand.uintLessThan(usize, n_clusters);
            const center = centers[cid * dim ..][0..dim];
            const dst = queries[i * dim ..][0..dim];
            for (0..dim) |d| dst[d] = center[d] + sigma * rand.floatNorm(f32);
        }
    } else {
        for (corpus) |*v| v.* = rand.floatNorm(f32);
        for (queries) |*v| v.* = rand.floatNorm(f32);
    }

    return .{ .corpus = corpus, .queries = queries };
}

fn computeExactTop10Cosine(
    corpus: []const f32,
    queries: []const f32,
    n: usize,
    q: usize,
    dim: usize,
    skip: ?*const std.bit_set.Dynamic,
    out: [][10]u32,
) void {
    for (0..q) |qi| {
        const qv: []align(1) const f32 = queries[qi * dim ..][0..dim];
        var buf: [10]Cand = undefined;
        var heap = TopKCand.init(&buf);
        for (0..n) |i| {
            if (skip) |sk| {
                if (sk.isSet(i)) continue;
            }
            const v: []align(1) const f32 = corpus[i * dim ..][0..dim];
            const s = distance.cosine(qv, v);
            if (s > heap.thresholdScore()) heap.push(.{ .id = @intCast(i), .score = s });
        }
        const sorted = heap.sortedDesc();
        for (0..10) |k| out[qi][k] = sorted[k].id;
    }
}

fn computeExactTop10L2(
    corpus: []const f32,
    queries: []const f32,
    n: usize,
    q: usize,
    dim: usize,
    out: [][10]u32,
) void {
    for (0..q) |qi| {
        const qv: []align(1) const f32 = queries[qi * dim ..][0..dim];
        var buf: [10]Cand = undefined;
        var heap = TopKCand.init(&buf);
        for (0..n) |i| {
            const v: []align(1) const f32 = corpus[i * dim ..][0..dim];
            const s = -distance.l2Squared(qv, v);
            if (s > heap.thresholdScore()) heap.push(.{ .id = @intCast(i), .score = s });
        }
        const sorted = heap.sortedDesc();
        for (0..10) |k| out[qi][k] = sorted[k].id;
    }
}

fn countRecall10(gt: [10]u32, pred: []const u32) usize {
    var hits: usize = 0;
    for (pred) |p| {
        for (gt) |g| {
            if (p == g) {
                hits += 1;
                break;
            }
        }
    }
    return hits;
}

fn sortU64(slice: []u64) void {
    std.mem.sort(u64, slice, {}, std.sort.asc(u64));
}

fn extractJsonIds(json: []const u8, prefix: []const u8, out: []u32) usize {
    var count: usize = 0;
    var pos: usize = 0;
    const needle = "\"k\":\"";
    while (count < out.len) {
        const rel = std.mem.indexOfPos(u8, json, pos, needle) orelse break;
        const start = rel + needle.len;
        const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse break;
        const kstr = json[start..end];
        if (std.mem.startsWith(u8, kstr, prefix)) {
            if (std.fmt.parseInt(u32, kstr[prefix.len..], 10)) |id| {
                out[count] = id;
                count += 1;
            } else |_| {}
        }
        pos = end + 1;
    }
    return count;
}

const Section = enum { all, simd, hnsw, serde, rabitq, vsearch, filtered, mt };

fn parseSection(s: []const u8) ?Section {
    if (std.mem.eql(u8, s, "all")) return .all;
    if (std.mem.eql(u8, s, "simd")) return .simd;
    if (std.mem.eql(u8, s, "hnsw")) return .hnsw;
    if (std.mem.eql(u8, s, "serde")) return .serde;
    if (std.mem.eql(u8, s, "rabitq")) return .rabitq;
    if (std.mem.eql(u8, s, "vsearch")) return .vsearch;
    if (std.mem.eql(u8, s, "filtered")) return .filtered;
    if (std.mem.eql(u8, s, "mt")) return .mt;
    return null;
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;

    var section: Section = .all;
    var json_mode = false;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--section=")) {
            const val = arg["--section=".len..];
            section = parseSection(val) orelse {
                std.debug.print("unknown --section={s} (expected all|simd|hnsw|serde|rabitq|vsearch|filtered|mt)\n", .{val});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--section")) {
            const val = args_it.next() orelse return error.InvalidArgs;
            section = parseSection(val) orelse {
                std.debug.print("unknown --section {s}\n", .{val});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("Usage: vector_ab_bench [--section=all|simd|hnsw|serde|rabitq|vsearch|filtered|mt] [--json]\n", .{});
            return;
        } else {
            std.debug.print("unknown arg: {s}\n", .{arg});
            return error.InvalidArgs;
        }
    }

    var rep = try Reporter.init(alloc, json_mode, @tagName(section));
    defer rep.deinit();

    if (section == .all or section == .simd) try benchSimd(alloc, &rep);
    if (section == .all or section == .hnsw) try benchHnsw(alloc, &rep);
    if (section == .all or section == .serde) try benchSerde(alloc, &rep);
    if (section == .all or section == .rabitq) try benchRabitq(alloc, &rep);
    if (section == .all or section == .vsearch) try benchVsearch(alloc, &rep);
    if (section == .all or section == .filtered) try benchFiltered(alloc, &rep);
    if (section == .all or section == .mt) try benchMt(alloc, &rep);

    try rep.finish();
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. SIMD Distance & Quantization Kernels (aligned & unaligned align(1))
// ─────────────────────────────────────────────────────────────────────────────
fn benchSimd(alloc: std.mem.Allocator, rep: *Reporter) !void {
    rep.header("1. SIMD DISTANCE & QUANTIZATION KERNELS (d=128..1537, aligned & align(1))");

    const dims = [_]usize{ 128, 384, 768, 1536, 1537 };
    var prng = std.Random.DefaultPrng.init(0x51AD_C0DE);
    const rand = prng.random();

    for (dims) |dim| {
        const bq_size = distance.binaryQuantizedSize(dim);

        // ── Aligned pass (N=50,000, natural f32 alignment) ──
        {
            const N: usize = 50_000;
            const vec_mem = try alloc.alloc(f32, (N + 1) * dim);
            defer alloc.free(vec_mem);
            for (vec_mem) |*f| f.* = rand.floatNorm(f32);

            const bq_mem = try alloc.alloc(u8, (N + 1) * bq_size);
            defer alloc.free(bq_mem);

            const qv: []align(1) const f32 = vec_mem[0..dim];
            const qbq = bq_mem[0..bq_size];

            // Warmup + measure BQ
            for (0..N + 1) |i| distance.binaryQuantize(vec_mem[i * dim ..][0..dim], bq_mem[i * bq_size ..][0..bq_size]);
            const bq0 = nowNs();
            for (0..N + 1) |i| distance.binaryQuantize(vec_mem[i * dim ..][0..dim], bq_mem[i * bq_size ..][0..bq_size]);
            const bq1 = nowNs();

            // Warmup + measure cosine
            var sink_f: f32 = 0;
            for (1..N + 1) |i| sink_f += distance.cosine(qv, vec_mem[i * dim ..][0..dim]);
            const c0 = nowNs();
            for (1..N + 1) |i| sink_f += distance.cosine(qv, vec_mem[i * dim ..][0..dim]);
            const c1 = nowNs();

            // Warmup + measure dot
            for (1..N + 1) |i| sink_f += distance.dot(qv, vec_mem[i * dim ..][0..dim]);
            const d0 = nowNs();
            for (1..N + 1) |i| sink_f += distance.dot(qv, vec_mem[i * dim ..][0..dim]);
            const d1 = nowNs();

            // Warmup + measure l2Squared
            for (1..N + 1) |i| sink_f += distance.l2Squared(qv, vec_mem[i * dim ..][0..dim]);
            const l0 = nowNs();
            for (1..N + 1) |i| sink_f += distance.l2Squared(qv, vec_mem[i * dim ..][0..dim]);
            const l1 = nowNs();
            std.mem.doNotOptimizeAway(sink_f);

            // Warmup + measure hamming
            var sink_u: u32 = 0;
            for (1..N + 1) |i| sink_u +%= distance.hamming(qbq, bq_mem[i * bq_size ..][0..bq_size]);
            const h0 = nowNs();
            for (1..N + 1) |i| sink_u +%= distance.hamming(qbq, bq_mem[i * bq_size ..][0..bq_size]);
            const h1 = nowNs();
            std.mem.doNotOptimizeAway(sink_u);

            const nf: f64 = @floatFromInt(N);
            const cos_ns = @as(f64, @floatFromInt(c1 - c0)) / nf;
            const dot_ns = @as(f64, @floatFromInt(d1 - d0)) / nf;
            const l2_ns = @as(f64, @floatFromInt(l1 - l0)) / nf;
            const bq_ns = @as(f64, @floatFromInt(bq1 - bq0)) / @as(f64, @floatFromInt(N + 1));
            const ham_ns = @as(f64, @floatFromInt(h1 - h0)) / nf;

            rep.line("  simd aligned   d={d:>4} | cos={d:>6.2}ns | dot={d:>6.2}ns | l2sq={d:>6.2}ns | bq={d:>6.2}ns | ham={d:>5.2}ns\n", .{
                dim, cos_ns, dot_ns, l2_ns, bq_ns, ham_ns,
            });
            try rep.emitJsonObj(
                "{{\"section\":\"simd\",\"name\":\"simd_aligned_d{d}\",\"dim\":{d},\"aligned\":true,\"n\":{d},\"cosine_ns\":{d:.3},\"dot_ns\":{d:.3},\"l2sq_ns\":{d:.3},\"bq_ns\":{d:.3},\"hamming_ns\":{d:.3}}}",
                .{ dim, dim, N, cos_ns, dot_ns, l2_ns, bq_ns, ham_ns },
            );
        }

        // ── Unaligned align(1) pass (+1 byte offset, simulating raw KV value slices, N=25,000) ──
        {
            const N: usize = 25_000;
            const raw_src = try alloc.alloc(f32, (N + 1) * dim);
            defer alloc.free(raw_src);
            for (raw_src) |*f| f.* = rand.floatNorm(f32);

            const byte_len = (N + 1) * dim * 4;
            const unaligned_buf = try alloc.alloc(u8, byte_len + 4);
            defer alloc.free(unaligned_buf);
            const shifted_bytes = unaligned_buf[1 .. 1 + byte_len];
            @memcpy(shifted_bytes, std.mem.sliceAsBytes(raw_src));
            const vec_u1: []align(1) const f32 = distance.bytesToF32(shifted_bytes).?;

            const bq_unaligned = try alloc.alloc(u8, (N + 1) * bq_size + 4);
            defer alloc.free(bq_unaligned);
            const bq_shifted = bq_unaligned[1 .. 1 + (N + 1) * bq_size];

            const qv = vec_u1[0..dim];
            const qbq = bq_shifted[0..bq_size];

            for (0..N + 1) |i| distance.binaryQuantize(vec_u1[i * dim ..][0..dim], bq_shifted[i * bq_size ..][0..bq_size]);
            const bq0 = nowNs();
            for (0..N + 1) |i| distance.binaryQuantize(vec_u1[i * dim ..][0..dim], bq_shifted[i * bq_size ..][0..bq_size]);
            const bq1 = nowNs();

            var sink_f: f32 = 0;
            for (1..N + 1) |i| sink_f += distance.cosine(qv, vec_u1[i * dim ..][0..dim]);
            const c0 = nowNs();
            for (1..N + 1) |i| sink_f += distance.cosine(qv, vec_u1[i * dim ..][0..dim]);
            const c1 = nowNs();

            for (1..N + 1) |i| sink_f += distance.dot(qv, vec_u1[i * dim ..][0..dim]);
            const d0 = nowNs();
            for (1..N + 1) |i| sink_f += distance.dot(qv, vec_u1[i * dim ..][0..dim]);
            const d1 = nowNs();

            for (1..N + 1) |i| sink_f += distance.l2Squared(qv, vec_u1[i * dim ..][0..dim]);
            const l0 = nowNs();
            for (1..N + 1) |i| sink_f += distance.l2Squared(qv, vec_u1[i * dim ..][0..dim]);
            const l1 = nowNs();
            std.mem.doNotOptimizeAway(sink_f);

            var sink_u: u32 = 0;
            for (1..N + 1) |i| sink_u +%= distance.hamming(qbq, bq_shifted[i * bq_size ..][0..bq_size]);
            const h0 = nowNs();
            for (1..N + 1) |i| sink_u +%= distance.hamming(qbq, bq_shifted[i * bq_size ..][0..bq_size]);
            const h1 = nowNs();
            std.mem.doNotOptimizeAway(sink_u);

            const nf: f64 = @floatFromInt(N);
            const cos_ns = @as(f64, @floatFromInt(c1 - c0)) / nf;
            const dot_ns = @as(f64, @floatFromInt(d1 - d0)) / nf;
            const l2_ns = @as(f64, @floatFromInt(l1 - l0)) / nf;
            const bq_ns = @as(f64, @floatFromInt(bq1 - bq0)) / @as(f64, @floatFromInt(N + 1));
            const ham_ns = @as(f64, @floatFromInt(h1 - h0)) / nf;

            rep.line("  simd align(1)  d={d:>4} | cos={d:>6.2}ns | dot={d:>6.2}ns | l2sq={d:>6.2}ns | bq={d:>6.2}ns | ham={d:>5.2}ns\n", .{
                dim, cos_ns, dot_ns, l2_ns, bq_ns, ham_ns,
            });
            try rep.emitJsonObj(
                "{{\"section\":\"simd\",\"name\":\"simd_unaligned_d{d}\",\"dim\":{d},\"aligned\":false,\"n\":{d},\"cosine_ns\":{d:.3},\"dot_ns\":{d:.3},\"l2sq_ns\":{d:.3},\"bq_ns\":{d:.3},\"hamming_ns\":{d:.3}}}",
                .{ dim, dim, N, cos_ns, dot_ns, l2_ns, bq_ns, ham_ns },
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. HNSW Build, Query QPS/Latency, Held-Out Recall@10, Memory & Tombstones
// ─────────────────────────────────────────────────────────────────────────────
fn benchHnsw(alloc: std.mem.Allocator, rep: *Reporter) !void {
    rep.header("2. HNSW BUILD, QUERY QPS/LATENCY, HELD-OUT RECALL@10, HEAP & 30% TOMBSTONES");

    const Case = struct {
        n: usize,
        dim: usize,
        q: usize,
        clustered: bool,
        tag: []const u8,
        tombstone_pct: usize = 0,
    };
    const cases = [_]Case{
        .{ .n = 10_000, .dim = 128, .q = 200, .clustered = false, .tag = "10k_d128_iso" },
        .{ .n = 10_000, .dim = 128, .q = 200, .clustered = true, .tag = "10k_d128_clust" },
        .{ .n = 10_000, .dim = 384, .q = 200, .clustered = true, .tag = "10k_d384_clust" },
        .{ .n = 10_000, .dim = 768, .q = 200, .clustered = true, .tag = "10k_d768_clust" },
        .{ .n = 50_000, .dim = 128, .q = 200, .clustered = true, .tag = "50k_d128_clust" },
        .{ .n = 50_000, .dim = 128, .q = 200, .clustered = false, .tag = "50k_d128_iso" },
        .{ .n = 10_000, .dim = 128, .q = 200, .clustered = true, .tag = "10k_d128_clust_tomb30", .tombstone_pct = 30 },
    };

    for (cases, 0..) |c, ci| {
        const data = try genDataset(alloc, c.n, c.q, c.dim, c.clustered, 100, 0.30, 0xA115_0000 + ci * 997 + c.n + c.dim);
        defer alloc.free(data.corpus);
        defer alloc.free(data.queries);

        var skip_bs = try std.bit_set.Dynamic.initEmpty(alloc, c.n);
        defer skip_bs.deinit(alloc);
        const skip_ptr: ?*const std.bit_set.Dynamic = if (c.tombstone_pct > 0) blk: {
            var prng = std.Random.DefaultPrng.init(0x70AB_570E);
            const r = prng.random();
            var marked: usize = 0;
            const target = (c.n * c.tombstone_pct) / 100;
            while (marked < target) {
                const idx = r.uintLessThan(usize, c.n);
                if (!skip_bs.isSet(idx)) {
                    skip_bs.set(idx);
                    marked += 1;
                }
            }
            break :blk &skip_bs;
        } else null;

        const gt = try alloc.alloc([10]u32, c.q);
        defer alloc.free(gt);
        computeExactTop10Cosine(data.corpus, data.queries, c.n, c.q, c.dim, skip_ptr, gt);

        var ca = CountingAllocator{ .child = alloc };
        var hnsw = Hnsw.init(ca.allocator(), .{ .m = 16, .m_max0 = 32, .ef_construction = 100 });
        defer hnsw.deinit();

        const b0 = nowNs();
        for (0..c.n) |i| {
            _ = try hnsw.insert(data.corpus[i * c.dim ..][0..c.dim]);
        }
        const b1 = nowNs();

        const build_ms = @as(f64, @floatFromInt(b1 - b0)) / 1e6;
        const build_vps = @as(f64, @floatFromInt(c.n)) / (build_ms / 1000.0);
        const live_mib = @as(f64, @floatFromInt(ca.live_bytes)) / (1024.0 * 1024.0);
        const bytes_per_vec = @as(f64, @floatFromInt(ca.live_bytes)) / @as(f64, @floatFromInt(c.n));
        const raw_bytes: usize = c.dim * 4;
        const build_allocs = ca.alloc_count;

        if (c.tombstone_pct == 0) {
            rep.line("  build {s:<22} | {d:>7.1} ms ({d:>6.0} vec/s) | heap={d:>5.2} MiB ({d:>5.0} B/vec vs {d}B raw, allocs={d})\n", .{
                c.tag, build_ms, build_vps, live_mib, bytes_per_vec, raw_bytes, build_allocs,
            });
            try rep.emitJsonObj(
                "{{\"section\":\"hnsw\",\"name\":\"hnsw_build_{s}\",\"n\":{d},\"dim\":{d},\"clustered\":{},\"build_ms\":{d:.3},\"build_vps\":{d:.1},\"heap_mib\":{d:.3},\"bytes_per_vec\":{d:.1},\"raw_bytes_per_vec\":{d},\"build_allocs\":{d}}}",
                .{ c.tag, c.n, c.dim, c.clustered, build_ms, build_vps, live_mib, bytes_per_vec, raw_bytes, build_allocs },
            );
        }

        const lats = try alloc.alloc(u64, c.q);
        defer alloc.free(lats);
        var out_buf: [10]HnswSearchResult = undefined;

        for ([_]usize{ 64, 128, 200 }) |ef| {
            // Warmup 20 queries
            for (0..20) |qi| {
                _ = try hnsw.search(data.queries[qi * c.dim ..][0..c.dim], 10, ef, &out_buf, skip_ptr);
            }
            const allocs_before = ca.alloc_count;
            var hits: usize = 0;
            var tomb_leaks: usize = 0;
            const s0 = nowNs();
            for (0..c.q) |qi| {
                const qt0 = nowNs();
                const n_res = try hnsw.search(data.queries[qi * c.dim ..][0..c.dim], 10, ef, &out_buf, skip_ptr);
                lats[qi] = nowNs() - qt0;
                var ids: [10]u32 = undefined;
                for (0..n_res) |k| {
                    ids[k] = out_buf[k].id;
                    if (skip_ptr) |sk| {
                        if (sk.isSet(out_buf[k].id)) tomb_leaks += 1;
                    }
                }
                hits += countRecall10(gt[qi], ids[0..n_res]);
            }
            const s1 = nowNs();

            if (tomb_leaks != 0) return error.TombstoneLeakDetected;

            const allocs_per_q = @as(f64, @floatFromInt(ca.alloc_count - allocs_before)) / @as(f64, @floatFromInt(c.q));
            sortU64(lats);
            const total_us = @as(f64, @floatFromInt(s1 - s0)) / 1000.0;
            const qps = @as(f64, @floatFromInt(c.q)) * 1e6 / total_us;
            const p50 = @as(f64, @floatFromInt(lats[c.q / 2])) / 1000.0;
            const p95 = @as(f64, @floatFromInt(lats[(c.q * 95) / 100])) / 1000.0;
            const p99 = @as(f64, @floatFromInt(lats[(c.q * 99) / 100])) / 1000.0;
            const rec = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(c.q * 10));

            rep.line("  query {s:<22} ef={d:>3} | {d:>7.0} QPS | p50={d:>6.1}us p95={d:>6.1}us p99={d:>6.1}us | r@10={d:.4} | allocs/q={d:.1}\n", .{
                c.tag, ef, qps, p50, p95, p99, rec, allocs_per_q,
            });
            try rep.emitJsonObj(
                "{{\"section\":\"hnsw\",\"name\":\"hnsw_query_{s}_ef{d}\",\"n\":{d},\"dim\":{d},\"clustered\":{},\"tombstone_pct\":{d},\"ef\":{d},\"qps\":{d:.1},\"p50_us\":{d:.2},\"p95_us\":{d:.2},\"p99_us\":{d:.2},\"recall10\":{d:.4},\"allocs_per_q\":{d:.2},\"tombstone_leaks\":{d}}}",
                .{ c.tag, ef, c.n, c.dim, c.clustered, c.tombstone_pct, ef, qps, p50, p95, p99, rec, allocs_per_q, tomb_leaks },
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. WDBHNSW2 Snapshot Serde (Save/Load ms + Post-Reload Recall@10 Parity)
// ─────────────────────────────────────────────────────────────────────────────
fn benchSerde(alloc: std.mem.Allocator, rep: *Reporter) !void {
    rep.header("3. WDBHNSW2 SNAPSHOT SAVE / LOAD & POST-RELOAD RECALL@10 PARITY (N=10k, d=128)");

    const tmp_dir = ".zig-cache/vector_ab_serde";
    try compat.Dir.makePath(compat.cwd(), tmp_dir);

    const N: usize = 10_000;
    const Q: usize = 100;
    const dim: usize = 128;

    const data = try genDataset(alloc, N, Q, dim, true, 100, 0.30, 0x5E2D_E128);
    defer alloc.free(data.corpus);
    defer alloc.free(data.queries);

    const gt = try alloc.alloc([10]u32, Q);
    defer alloc.free(gt);
    computeExactTop10Cosine(data.corpus, data.queries, N, Q, dim, null, gt);

    const keys = try alloc.alloc([]u8, N);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    const items = try alloc.alloc(wormdb.core.types.Command.VbulkinsertParams.BulkItem, N);
    defer alloc.free(items);
    for (0..N) |i| {
        keys[i] = try std.fmt.allocPrint(alloc, "vec:serde:{d}", .{i});
        const bp: [*]const u8 = @ptrCast(data.corpus[i * dim ..].ptr);
        items[i] = .{ .key = keys[i], .vector = bp[0 .. dim * 4], .timestamp = 1700000000 };
    }

    const qkeys = try alloc.alloc([]u8, Q);
    defer {
        for (qkeys) |k| alloc.free(k);
        alloc.free(qkeys);
    }
    for (0..Q) |qi| {
        qkeys[qi] = try std.fmt.allocPrint(alloc, "qry:serde:{d}", .{qi});
    }

    for ([_]bool{ false, true }) |with_rabitq| {
        const tag = if (with_rabitq) "with_rabitq" else "no_rabitq";
        const run_id = nowNs();
        const wal_path = try std.fmt.allocPrint(alloc, "{s}/serde_{s}_{d}.wal", .{ tmp_dir, tag, run_id });
        defer alloc.free(wal_path);
        const snap_path = try std.fmt.allocPrint(alloc, "{s}/serde_{s}_{d}.snapshot", .{ tmp_dir, tag, run_id });
        defer alloc.free(snap_path);
        defer {
            const io = std.Io.Threaded.global_single_threaded.io();
            compat.cwd().deleteFile(io, wal_path) catch {};
            compat.cwd().deleteFile(io, snap_path) catch {};
        }

        const cfg = wormdb.core.config.Config{
            .wal_path = wal_path,
            .snapshot_path = snap_path,
            .persistence = .snapshot,
            .sync_writes = false,
            .max_wal_size = 0,
        };

        var recall_before: f64 = 0.0;
        var save_ms: f64 = 0.0;

        // Build, optionally vrabitq, measure pre-save recall, and time Store.save()
        {
            var reg = NamespaceRegistry.init(alloc, .{});
            defer reg.deinit();
            var store = try Store.initWithRegistry(alloc, cfg, &reg);
            defer store.deinit();
            var bus = EventBus.init(alloc);
            defer bus.deinit();

            const base_ctx = executor.ExecContext{
                .allocator = alloc,
                .store = &store,
                .event_bus = &bus,
                .cluster = null,
                .vector_registry = &reg,
            };
            _ = try executor.execute(base_ctx, .{ .vbulkinsert = .{
                .namespace = "vec:serde:",
                .metric = "cosine",
                .worm = false,
                .is_async = false,
                .items = items,
            } });

            if (with_rabitq) {
                const vr_args = [_][]const u8{"vec:serde:"};
                _ = try executor.execute(base_ctx, .{ .exec = .{ .procedure = "vrabitq", .args = &vr_args } });
            }

            // Pre-save HNSW recall@10
            const ns_idx = reg.get("vec:serde:").?;
            var out_buf: [10]IndexSearchResult = undefined;
            var scratch: [10]HnswSearchResult = undefined;
            var hits: usize = 0;
            ns_idx.lock.lockShared();
            for (0..Q) |qi| {
                const n_res = try ns_idx.searchLocked(data.queries[qi * dim ..][0..dim], 10, 128, &out_buf, &scratch);
                var ids: [10]u32 = undefined;
                for (0..n_res) |k| ids[k] = std.fmt.parseInt(u32, out_buf[k].key["vec:serde:".len..], 10) catch 0;
                hits += countRecall10(gt[qi], ids[0..n_res]);
            }
            ns_idx.lock.unlockShared();
            recall_before = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(Q * 10));

            const s0 = nowNs();
            try store.save();
            const s1 = nowNs();
            save_ms = @as(f64, @floatFromInt(s1 - s0)) / 1e6;
        }

        // Reload via Store.initWithRegistry and verify parity
        var load_ms: f64 = 0.0;
        var recall_after: f64 = 0.0;
        var rabitq_restored = false;
        var rbq_recall_after: f64 = 0.0;
        {
            var reg2 = NamespaceRegistry.init(alloc, .{});
            defer reg2.deinit();

            const l0 = nowNs();
            var store2 = try Store.initWithRegistry(alloc, cfg, &reg2);
            const l1 = nowNs();
            defer store2.deinit();
            load_ms = @as(f64, @floatFromInt(l1 - l0)) / 1e6;

            const ns_idx2 = reg2.get("vec:serde:") orelse return error.SerdeNamespaceMissing;
            var out_buf: [10]IndexSearchResult = undefined;
            var scratch: [10]HnswSearchResult = undefined;
            var hits: usize = 0;
            ns_idx2.lock.lockShared();
            rabitq_restored = (ns_idx2.getRabitqParams() != null);
            for (0..Q) |qi| {
                const n_res = try ns_idx2.searchLocked(data.queries[qi * dim ..][0..dim], 10, 128, &out_buf, &scratch);
                var ids: [10]u32 = undefined;
                for (0..n_res) |k| ids[k] = std.fmt.parseInt(u32, out_buf[k].key["vec:serde:".len..], 10) catch 0;
                hits += countRecall10(gt[qi], ids[0..n_res]);
            }
            ns_idx2.lock.unlockShared();
            recall_after = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(Q * 10));

            if (with_rabitq) {
                if (!rabitq_restored) return error.SerdeRabitqParamsMissing;
                var bus2 = EventBus.init(alloc);
                defer bus2.deinit();
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();
                for (0..Q) |qi| {
                    const bp: [*]const u8 = @ptrCast(data.queries[qi * dim ..].ptr);
                    try store2.setWithTimestampNoVectorSync(qkeys[qi], bp[0 .. dim * 4], false, 1700000000);
                }
                var rhits: usize = 0;
                for (0..Q) |qi| {
                    _ = arena.reset(.retain_capacity);
                    const qctx = executor.ExecContext{
                        .allocator = arena.allocator(),
                        .store = &store2,
                        .event_bus = &bus2,
                        .cluster = null,
                        .vector_registry = &reg2,
                    };
                    const args = [_][]const u8{ qkeys[qi], "10", "vec:serde:", "cosine", "0", "bq_rerank" };
                    const resp = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
                    var ids: [10]u32 = undefined;
                    const cnt = extractJsonIds(resp.value.?, "vec:serde:", &ids);
                    rhits += countRecall10(gt[qi], ids[0..cnt]);
                }
                rbq_recall_after = @as(f64, @floatFromInt(rhits)) / @as(f64, @floatFromInt(Q * 10));
            }
        }

        const delta = @abs(recall_after - recall_before);
        rep.line("  serde {s:<12} | save={d:>6.2} ms | load={d:>6.2} ms | r@10 before={d:.4} after={d:.4} (delta={d:.4}) | rbq_ok={} rbq_r@10={d:.4}\n", .{
            tag, save_ms, load_ms, recall_before, recall_after, delta, rabitq_restored, rbq_recall_after,
        });
        try rep.emitJsonObj(
            "{{\"section\":\"serde\",\"name\":\"serde_{s}\",\"n\":{d},\"dim\":{d},\"with_rabitq\":{},\"save_ms\":{d:.3},\"load_ms\":{d:.3},\"recall_before\":{d:.4},\"recall_after\":{d:.4},\"recall_delta\":{d:.4},\"rabitq_restored\":{},\"rabitq_rerank_recall10\":{d:.4}}}",
            .{ tag, N, dim, with_rabitq, save_ms, load_ms, recall_before, recall_after, delta, rabitq_restored, rbq_recall_after },
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. RaBitQ Encode, Query, Pure vs Rerank-200 & Held-Out Recall@10
// ─────────────────────────────────────────────────────────────────────────────
fn benchRabitq(alloc: std.mem.Allocator, rep: *Reporter) !void {
    rep.header("4. RABITQ ENCODE, PREPARE, PURE TOP-10 vs RERANK-200 (N=10k, Q=100, clustered L2)");

    const N: usize = 10_000;
    const Q: usize = 100;
    const TOP_K: usize = 10;
    const M_RERANK: usize = 200;

    for ([_]usize{ 128, 384, 768, 1536 }) |dim| {
        const data = try genDataset(alloc, N, Q, dim, true, 100, 0.30, 0x2AB1_0000 + dim);
        defer alloc.free(data.corpus);
        defer alloc.free(data.queries);

        const gt = try alloc.alloc([10]u32, Q);
        defer alloc.free(gt);
        computeExactTop10L2(data.corpus, data.queries, N, Q, dim, gt);

        // Real corpus centroid
        const centroid = try alloc.alloc(f32, dim);
        defer alloc.free(centroid);
        @memset(centroid, 0.0);
        for (0..N) |i| {
            const v = data.corpus[i * dim ..][0..dim];
            for (0..dim) |d| centroid[d] += v[d];
        }
        const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(N));
        for (centroid) |*c| c.* *= inv_n;

        // Warmup small rotation for d<=384, then time real rotation
        const r0 = nowNs();
        const rot = try rabitq.generateRotation(alloc, dim, 0xBEEF);
        const r1 = nowNs();
        defer alloc.free(rot);

        const params = rabitq.RabitqParams{
            .allocator = alloc,
            .centroid = centroid,
            .rotation = rot,
            .dim = @intCast(dim),
            .seed = 0xBEEF,
        };

        const enc_size = rabitq.encodedSize(dim);
        const cb = rabitq.codeBytes(dim);
        const enc_mem = try alloc.alloc(u8, N * enc_size);
        defer alloc.free(enc_mem);
        const residual = try alloc.alloc(f32, dim);
        defer alloc.free(residual);
        const rotated = try alloc.alloc(f32, dim);
        defer alloc.free(rotated);

        // Warmup 100 encodes
        for (0..100) |i| {
            const out_s = enc_mem[i * enc_size ..][0..enc_size];
            const enc = rabitq.encode(data.corpus[i * dim ..][0..dim], &params, residual, rotated, out_s[0..cb]);
            rabitq.serialize(enc, out_s);
        }

        const e0 = nowNs();
        for (0..N) |i| {
            const out_s = enc_mem[i * enc_size ..][0..enc_size];
            const enc = rabitq.encode(data.corpus[i * dim ..][0..dim], &params, residual, rotated, out_s[0..cb]);
            rabitq.serialize(enc, out_s);
        }
        const e1 = nowNs();

        const q_rot = try alloc.alloc(f32, dim);
        defer alloc.free(q_rot);

        // Warmup + measure prepareQuery
        var prep_sink: f32 = 0;
        for (0..10) |qi| prep_sink += rabitq.prepareQuery(data.queries[qi * dim ..][0..dim], &params, residual, q_rot);
        const p0 = nowNs();
        for (0..Q) |qi| prep_sink += rabitq.prepareQuery(data.queries[qi * dim ..][0..dim], &params, residual, q_rot);
        const p1 = nowNs();
        std.mem.doNotOptimizeAway(prep_sink);

        // Tight estimateL2Sq scan microbench
        const ql2_0 = rabitq.prepareQuery(data.queries[0..dim], &params, residual, q_rot);
        var est_sink: f32 = 0;
        for (0..N) |i| {
            const enc = rabitq.parse(enc_mem[i * enc_size ..][0..enc_size], dim).?;
            est_sink += rabitq.estimateL2Sq(q_rot, ql2_0, enc.code, enc.l2_norm, enc.corr);
        }
        const es0 = nowNs();
        for (0..N) |i| {
            const enc = rabitq.parse(enc_mem[i * enc_size ..][0..enc_size], dim).?;
            est_sink += rabitq.estimateL2Sq(q_rot, ql2_0, enc.code, enc.l2_norm, enc.corr);
        }
        const es1 = nowNs();
        std.mem.doNotOptimizeAway(est_sink);

        // Pure RaBitQ top-10 search (prepareQuery + scan + TopK(10))
        var pure_hits: usize = 0;
        const ps0 = nowNs();
        for (0..Q) |qi| {
            const qv: []align(1) const f32 = data.queries[qi * dim ..][0..dim];
            const ql2 = rabitq.prepareQuery(qv, &params, residual, q_rot);
            var hbuf: [TOP_K]Cand = undefined;
            var heap = TopKCand.init(&hbuf);
            for (0..N) |i| {
                const enc = rabitq.parse(enc_mem[i * enc_size ..][0..enc_size], dim).?;
                const score = -rabitq.estimateL2Sq(q_rot, ql2, enc.code, enc.l2_norm, enc.corr);
                if (score > heap.thresholdScore()) heap.push(.{ .id = @intCast(i), .score = score });
            }
            const res = heap.sortedDesc();
            var ids: [TOP_K]u32 = undefined;
            for (res, 0..) |c, k| ids[k] = c.id;
            pure_hits += countRecall10(gt[qi], ids[0..res.len]);
        }
        const ps1 = nowNs();

        // RaBitQ top-200 + exact L2 rerank
        const s1_buf = try alloc.alloc(Cand, M_RERANK);
        defer alloc.free(s1_buf);
        var rr_hits: usize = 0;
        var stage2_ns: u64 = 0;
        const rs0 = nowNs();
        for (0..Q) |qi| {
            const qv: []align(1) const f32 = data.queries[qi * dim ..][0..dim];
            const ql2 = rabitq.prepareQuery(qv, &params, residual, q_rot);
            var s1 = TopKCand.init(s1_buf);
            for (0..N) |i| {
                const enc = rabitq.parse(enc_mem[i * enc_size ..][0..enc_size], dim).?;
                const score = -rabitq.estimateL2Sq(q_rot, ql2, enc.code, enc.l2_norm, enc.corr);
                if (score > s1.thresholdScore()) s1.push(.{ .id = @intCast(i), .score = score });
            }
            const cands = s1.sortedDesc();

            const s2_t0 = nowNs();
            var hbuf: [TOP_K]Cand = undefined;
            var heap = TopKCand.init(&hbuf);
            for (cands) |c| {
                const v: []align(1) const f32 = data.corpus[c.id * dim ..][0..dim];
                const score = -distance.l2Squared(qv, v);
                if (score > heap.thresholdScore()) heap.push(.{ .id = c.id, .score = score });
            }
            const res = heap.sortedDesc();
            stage2_ns += (nowNs() - s2_t0);

            var ids: [TOP_K]u32 = undefined;
            for (res, 0..) |c, k| ids[k] = c.id;
            rr_hits += countRecall10(gt[qi], ids[0..res.len]);
        }
        const rs1 = nowNs();

        const rot_ms = @as(f64, @floatFromInt(r1 - r0)) / 1e6;
        const enc_ns = @as(f64, @floatFromInt(e1 - e0)) / @as(f64, @floatFromInt(N));
        const prep_ns = @as(f64, @floatFromInt(p1 - p0)) / @as(f64, @floatFromInt(Q));
        const est_ns = @as(f64, @floatFromInt(es1 - es0)) / @as(f64, @floatFromInt(N));
        const pure_us = @as(f64, @floatFromInt(ps1 - ps0)) / (@as(f64, @floatFromInt(Q)) * 1000.0);
        const pure_qps = 1e6 / pure_us;
        const pure_rec = @as(f64, @floatFromInt(pure_hits)) / @as(f64, @floatFromInt(Q * TOP_K));
        const rr_us = @as(f64, @floatFromInt(rs1 - rs0)) / (@as(f64, @floatFromInt(Q)) * 1000.0);
        const rr_qps = 1e6 / rr_us;
        const rr_rec = @as(f64, @floatFromInt(rr_hits)) / @as(f64, @floatFromInt(Q * TOP_K));
        const s2_us = @as(f64, @floatFromInt(stage2_ns)) / (@as(f64, @floatFromInt(Q)) * 1000.0);
        const delta_us = rr_us - pure_us;

        rep.line("  rabitq d={d:>4} | rot={d:>6.2}ms enc={d:>6.0}ns prep={d:>5.0}ns est={d:>5.2}ns | pure={d:>6.1}us({d:>6.0}QPS r={d:.3}) | rr200={d:>6.1}us({d:>5.0}QPS r={d:.3} s2={d:>4.1}us d={d:>4.1}us)\n", .{
            dim, rot_ms, enc_ns, prep_ns, est_ns, pure_us, pure_qps, pure_rec, rr_us, rr_qps, rr_rec, s2_us, delta_us,
        });
        try rep.emitJsonObj(
            "{{\"section\":\"rabitq\",\"name\":\"rabitq_d{d}\",\"n\":{d},\"dim\":{d},\"gen_rot_ms\":{d:.3},\"encode_ns\":{d:.1},\"prep_query_ns\":{d:.1},\"estimate_ns\":{d:.3},\"pure_us\":{d:.2},\"pure_qps\":{d:.1},\"pure_recall10\":{d:.4},\"rerank200_us\":{d:.2},\"rerank200_qps\":{d:.1},\"rerank200_recall10\":{d:.4},\"stage2_us\":{d:.2},\"rerank_delta_us\":{d:.2}}}",
            .{ dim, N, dim, rot_ms, enc_ns, prep_ns, est_ns, pure_us, pure_qps, pure_rec, rr_us, rr_qps, rr_rec, s2_us, delta_us },
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. NamespaceIndex Direct vs EXEC vsearch E2E, VBULKINSERT, vrabitq, vreindex
// ─────────────────────────────────────────────────────────────────────────────
fn benchVsearch(alloc: std.mem.Allocator, rep: *Reporter) !void {
    rep.header("5. NAMESPACE_INDEX vs EXEC VSEARCH E2E, VBULKINSERT, VRABITQ & VREINDEX (N=10k)");

    const N: usize = 10_000;
    const Q: usize = 100;

    for ([_]usize{ 128, 384 }) |dim| {
        const data = try genDataset(alloc, N, Q, dim, true, 100, 0.30, 0xFACE_0000 + dim);
        defer alloc.free(data.corpus);
        defer alloc.free(data.queries);

        const gt = try alloc.alloc([10]u32, Q);
        defer alloc.free(gt);
        computeExactTop10Cosine(data.corpus, data.queries, N, Q, dim, null, gt);

        var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
        defer store.deinit();
        var reg = NamespaceRegistry.init(alloc, .{});
        defer reg.deinit();
        store.vector_registry = &reg;
        var bus = EventBus.init(alloc);
        defer bus.deinit();

        const keys = try alloc.alloc([]u8, N);
        defer {
            for (keys) |k| alloc.free(k);
            alloc.free(keys);
        }
        const items = try alloc.alloc(wormdb.core.types.Command.VbulkinsertParams.BulkItem, N);
        defer alloc.free(items);
        for (0..N) |i| {
            keys[i] = try std.fmt.allocPrint(alloc, "vec:vs:{d}", .{i});
            const bp: [*]const u8 = @ptrCast(data.corpus[i * dim ..].ptr);
            items[i] = .{ .key = keys[i], .vector = bp[0 .. dim * 4], .timestamp = 1700000000 };
        }

        const base_ctx = executor.ExecContext{
            .allocator = alloc,
            .store = &store,
            .event_bus = &bus,
            .cluster = null,
            .vector_registry = &reg,
        };

        // VBULKINSERT
        const ins0 = nowNs();
        _ = try executor.execute(base_ctx, .{ .vbulkinsert = .{
            .namespace = "vec:vs:",
            .metric = "cosine",
            .worm = false,
            .is_async = false,
            .items = items,
        } });
        const ins1 = nowNs();
        const ins_ms = @as(f64, @floatFromInt(ins1 - ins0)) / 1e6;
        const ins_vps = @as(f64, @floatFromInt(N)) / (ins_ms / 1000.0);
        rep.line("  vbulkinsert    d={d:>3} N={d} | {d:>7.1} ms ({d:>6.0} vec/s)\n", .{ dim, N, ins_ms, ins_vps });
        try rep.emitJsonObj(
            "{{\"section\":\"vsearch\",\"name\":\"vbulkinsert_d{d}\",\"n\":{d},\"dim\":{d},\"ms\":{d:.2},\"vps\":{d:.1}}}",
            .{ dim, N, dim, ins_ms, ins_vps },
        );

        // Held-out queries stored under separate prefix (not in corpus HNSW)
        const qkeys = try alloc.alloc([]u8, Q);
        defer {
            for (qkeys) |k| alloc.free(k);
            alloc.free(qkeys);
        }
        for (0..Q) |qi| {
            qkeys[qi] = try std.fmt.allocPrint(alloc, "qry:vs:{d}", .{qi});
            const bp: [*]const u8 = @ptrCast(data.queries[qi * dim ..].ptr);
            try store.setWithTimestampNoVectorSync(qkeys[qi], bp[0 .. dim * 4], false, 1700000000);
        }

        // Direct NamespaceIndex.searchLocked
        {
            const ns_idx = reg.get("vec:vs:").?;
            var out_buf: [18]IndexSearchResult = undefined;
            var scratch: [18]HnswSearchResult = undefined;
            ns_idx.lock.lockShared();
            for (0..10) |qi| _ = try ns_idx.searchLocked(data.queries[qi * dim ..][0..dim], 10, 128, &out_buf, &scratch);
            ns_idx.lock.unlockShared();

            var hits: usize = 0;
            const t0 = nowNs();
            for (0..Q) |qi| {
                ns_idx.lock.lockShared();
                const n_res = try ns_idx.searchLocked(data.queries[qi * dim ..][0..dim], 10, 128, &out_buf, &scratch);
                var ids: [10]u32 = undefined;
                for (0..n_res) |k| ids[k] = std.fmt.parseInt(u32, out_buf[k].key["vec:vs:".len..], 10) catch 0;
                ns_idx.lock.unlockShared();
                hits += countRecall10(gt[qi], ids[0..n_res]);
            }
            const t1 = nowNs();
            const us = @as(f64, @floatFromInt(t1 - t0)) / (@as(f64, @floatFromInt(Q)) * 1000.0);
            const qps = 1e6 / us;
            const rec = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(Q * 10));
            rep.line("  ns_idx_direct  d={d:>3} ef=128    | {d:>7.0} QPS | {d:>7.1} us/q | r@10={d:.4}\n", .{ dim, qps, us, rec });
            try rep.emitJsonObj(
                "{{\"section\":\"vsearch\",\"name\":\"ns_idx_direct_d{d}\",\"n\":{d},\"dim\":{d},\"ef\":128,\"qps\":{d:.1},\"us_per_q\":{d:.2},\"recall10\":{d:.4}}}",
                .{ dim, N, dim, qps, us, rec },
            );
        }

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        // EXEC vsearch pre-vrabitq
        for ([_][]const u8{ "auto", "bq", "bq_rerank", "exact" }) |mode_str| {
            for (0..5) |qi| {
                _ = arena.reset(.retain_capacity);
                const qctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null, .vector_registry = &reg };
                const args = [_][]const u8{ qkeys[qi], "10", "vec:vs:", "cosine", "0", mode_str, "168", "128" };
                _ = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
            }
            var hits: usize = 0;
            const t0 = nowNs();
            for (0..Q) |qi| {
                _ = arena.reset(.retain_capacity);
                const qctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null, .vector_registry = &reg };
                const args = [_][]const u8{ qkeys[qi], "10", "vec:vs:", "cosine", "0", mode_str, "168", "128" };
                const resp = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
                var ids: [10]u32 = undefined;
                const cnt = extractJsonIds(resp.value.?, "vec:vs:", &ids);
                hits += countRecall10(gt[qi], ids[0..cnt]);
            }
            const t1 = nowNs();
            const us = @as(f64, @floatFromInt(t1 - t0)) / (@as(f64, @floatFromInt(Q)) * 1000.0);
            const qps = 1e6 / us;
            const rec = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(Q * 10));
            rep.line("  vsearch_e2e    d={d:>3} {s:<9} | {d:>7.0} QPS | {d:>7.1} us/q | r@10={d:.4}\n", .{ dim, mode_str, qps, us, rec });
            try rep.emitJsonObj(
                "{{\"section\":\"vsearch\",\"name\":\"vsearch_{s}_d{d}\",\"n\":{d},\"dim\":{d},\"mode\":\"{s}\",\"rabitq\":false,\"qps\":{d:.1},\"us_per_q\":{d:.2},\"recall10\":{d:.4}}}",
                .{ mode_str, dim, N, dim, mode_str, qps, us, rec },
            );
        }

        // EXEC vreindex
        {
            const ri0 = nowNs();
            const ri_args = [_][]const u8{ "vec:vs:", "cosine" };
            _ = try executor.execute(base_ctx, .{ .exec = .{ .procedure = "vreindex", .args = &ri_args } });
            const ri1 = nowNs();
            const ri_ms = @as(f64, @floatFromInt(ri1 - ri0)) / 1e6;
            const ri_vps = @as(f64, @floatFromInt(N)) / (ri_ms / 1000.0);
            rep.line("  vreindex       d={d:>3} N={d} | {d:>7.1} ms ({d:>6.0} vec/s)\n", .{ dim, N, ri_ms, ri_vps });
            try rep.emitJsonObj(
                "{{\"section\":\"vsearch\",\"name\":\"vreindex_d{d}\",\"n\":{d},\"dim\":{d},\"ms\":{d:.2},\"vps\":{d:.1}}}",
                .{ dim, N, dim, ri_ms, ri_vps },
            );
        }

        // EXEC vrabitq
        {
            const vr0 = nowNs();
            const vr_args = [_][]const u8{"vec:vs:"};
            _ = try executor.execute(base_ctx, .{ .exec = .{ .procedure = "vrabitq", .args = &vr_args } });
            const vr1 = nowNs();
            const vr_ms = @as(f64, @floatFromInt(vr1 - vr0)) / 1e6;
            rep.line("  vrabitq_build  d={d:>3} N={d} | {d:>7.1} ms\n", .{ dim, N, vr_ms });
            try rep.emitJsonObj(
                "{{\"section\":\"vsearch\",\"name\":\"vrabitq_build_d{d}\",\"n\":{d},\"dim\":{d},\"ms\":{d:.2}}}",
                .{ dim, N, dim, vr_ms },
            );
        }

        // EXEC vsearch post-vrabitq
        for ([_][]const u8{ "bq", "bq_rerank" }) |mode_str| {
            for (0..5) |qi| {
                _ = arena.reset(.retain_capacity);
                const qctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null, .vector_registry = &reg };
                const args = [_][]const u8{ qkeys[qi], "10", "vec:vs:", "cosine", "0", mode_str };
                _ = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
            }
            var hits: usize = 0;
            const t0 = nowNs();
            for (0..Q) |qi| {
                _ = arena.reset(.retain_capacity);
                const qctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null, .vector_registry = &reg };
                const args = [_][]const u8{ qkeys[qi], "10", "vec:vs:", "cosine", "0", mode_str };
                const resp = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
                var ids: [10]u32 = undefined;
                const cnt = extractJsonIds(resp.value.?, "vec:vs:", &ids);
                hits += countRecall10(gt[qi], ids[0..cnt]);
            }
            const t1 = nowNs();
            const us = @as(f64, @floatFromInt(t1 - t0)) / (@as(f64, @floatFromInt(Q)) * 1000.0);
            const qps = 1e6 / us;
            const rec = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(Q * 10));
            rep.line("  vsearch_rbq    d={d:>3} {s:<9} | {d:>7.0} QPS | {d:>7.1} us/q | r@10={d:.4}\n", .{ dim, mode_str, qps, us, rec });
            try rep.emitJsonObj(
                "{{\"section\":\"vsearch\",\"name\":\"vsearch_rbq_{s}_d{d}\",\"n\":{d},\"dim\":{d},\"mode\":\"{s}\",\"rabitq\":true,\"qps\":{d:.1},\"us_per_q\":{d:.2},\"recall10\":{d:.4}}}",
                .{ mode_str, dim, N, dim, mode_str, qps, us, rec },
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. EXEC vsearch_filtered (HNSW + Brute-Force Fallback, eq/min/max/prefix/dedup/meta)
// ─────────────────────────────────────────────────────────────────────────────
fn benchFiltered(alloc: std.mem.Allocator, rep: *Reporter) !void {
    rep.header("6. EXEC VSEARCH_FILTERED (N=10k, d=128, HNSW & brute-force fallback)");

    const N: usize = 10_000;
    const Q_HNSW: usize = 100;
    const Q_BF: usize = 20;
    const dim: usize = 128;

    const data = try genDataset(alloc, N, Q_HNSW, dim, true, 100, 0.30, 0xF117_E2ED);
    defer alloc.free(data.corpus);
    defer alloc.free(data.queries);

    var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
    defer store.deinit();
    var reg = NamespaceRegistry.init(alloc, .{});
    defer reg.deinit();
    store.vector_registry = &reg;
    var bus = EventBus.init(alloc);
    defer bus.deinit();

    const keys = try alloc.alloc([]u8, N);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    const items = try alloc.alloc(wormdb.core.types.Command.VbulkinsertParams.BulkItem, N);
    defer alloc.free(items);

    var mkey_buf: [64]u8 = undefined;
    var mval_buf: [256]u8 = undefined;
    var bfkey_buf: [64]u8 = undefined;

    for (0..N) |i| {
        keys[i] = try std.fmt.allocPrint(alloc, "vec:filt:{d}", .{i});
        const bp: [*]const u8 = @ptrCast(data.corpus[i * dim ..].ptr);
        const vbytes = bp[0 .. dim * 4];
        items[i] = .{ .key = keys[i], .vector = vbytes, .timestamp = 1700000000 };

        // Unindexed copy for brute-force fallback test (no NamespaceIndex entry for "vec:filtbf:")
        const bf_key = try std.fmt.bufPrint(&bfkey_buf, "vec:filtbf:{d}", .{i});
        try store.setWithTimestampNoVectorSync(bf_key, vbytes, false, 1700000000);

        // Companion JSON metadata at "meta:<id>"
        const media = if ((i % 2) == 0) "image" else "video";
        const trashed = if ((i % 10) == 0) "true" else "false";
        const path = if ((i % 3) != 0) "portraits/shot.jpg" else "landscapes/shot.jpg";
        const sharp: f64 = @floatFromInt((i * 17) % 100);
        const nsfw: f64 = @as(f64, @floatFromInt((i * 7) % 100)) / 100.0;
        const mkey = try std.fmt.bufPrint(&mkey_buf, "meta:{d}", .{i});
        const mval = try std.fmt.bufPrint(
            &mval_buf,
            "{{\"mediaType\":\"{s}\",\"trashed\":{s},\"relPath\":\"{s}\",\"sharpness\":{d:.1},\"nsfwScore\":{d:.2},\"stackId\":\"stk_{d}\"}}",
            .{ media, trashed, path, sharp, nsfw, i / 3 },
        );
        try store.setWithTimestampNoVectorSync(mkey, mval, false, 1700000000);
    }

    const base_ctx = executor.ExecContext{
        .allocator = alloc,
        .store = &store,
        .event_bus = &bus,
        .cluster = null,
        .vector_registry = &reg,
    };
    _ = try executor.execute(base_ctx, .{ .vbulkinsert = .{
        .namespace = "vec:filt:",
        .metric = "cosine",
        .worm = false,
        .is_async = false,
        .items = items,
    } });

    // Pre-encode held-out queries to base64
    const b64_len = std.base64.standard.Encoder.calcSize(dim * 4);
    const q_b64 = try alloc.alloc([]u8, Q_HNSW);
    defer {
        for (q_b64) |b| alloc.free(b);
        alloc.free(q_b64);
    }
    for (0..Q_HNSW) |qi| {
        q_b64[qi] = try alloc.alloc(u8, b64_len);
        const bp: [*]const u8 = @ptrCast(data.queries[qi * dim ..].ptr);
        _ = std.base64.standard.Encoder.encode(q_b64[qi], bp[0 .. dim * 4]);
    }

    const opts_no_meta =
        "{\"metric\":\"cosine\",\"ef\":128,\"oversample\":16,\"eq\":{\"mediaType\":\"image\"},\"neq\":{\"trashed\":true},\"prefix\":{\"relPath\":\"portraits/\"},\"min\":{\"sharpness\":20},\"max\":{\"nsfwScore\":0.85},\"dedup_field\":\"stackId\",\"include_meta\":false}";
    const opts_with_meta =
        "{\"metric\":\"cosine\",\"ef\":128,\"oversample\":16,\"eq\":{\"mediaType\":\"image\"},\"neq\":{\"trashed\":true},\"prefix\":{\"relPath\":\"portraits/\"},\"min\":{\"sharpness\":20},\"max\":{\"nsfwScore\":0.85},\"dedup_field\":\"stackId\",\"include_meta\":true}";

    const FCase = struct {
        name: []const u8,
        ns: []const u8,
        opts: []const u8,
        q_count: usize,
        include_meta: bool,
        hnsw_path: bool,
    };
    const fcases = [_]FCase{
        .{ .name = "filtered_hnsw_nometa", .ns = "vec:filt:", .opts = opts_no_meta, .q_count = Q_HNSW, .include_meta = false, .hnsw_path = true },
        .{ .name = "filtered_hnsw_meta", .ns = "vec:filt:", .opts = opts_with_meta, .q_count = Q_HNSW, .include_meta = true, .hnsw_path = true },
        .{ .name = "filtered_bf_nometa", .ns = "vec:filtbf:", .opts = opts_no_meta, .q_count = Q_BF, .include_meta = false, .hnsw_path = false },
    };

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    for (fcases) |fc| {
        const lats = try alloc.alloc(u64, fc.q_count);
        defer alloc.free(lats);

        // Warmup 3 queries
        for (0..3) |qi| {
            _ = arena.reset(.retain_capacity);
            const qctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null, .vector_registry = &reg };
            const args = [_][]const u8{ q_b64[qi], "10", fc.ns, "meta:", fc.opts };
            _ = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch_filtered", .args = &args } });
        }

        var total_hits: usize = 0;
        var total_bytes: usize = 0;
        const t0 = nowNs();
        for (0..fc.q_count) |qi| {
            _ = arena.reset(.retain_capacity);
            const qctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null, .vector_registry = &reg };
            const args = [_][]const u8{ q_b64[qi], "10", fc.ns, "meta:", fc.opts };
            const qt0 = nowNs();
            const resp = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch_filtered", .args = &args } });
            lats[qi] = nowNs() - qt0;
            const body = resp.value.?;
            total_bytes += body.len;
            var ids: [10]u32 = undefined;
            total_hits += extractJsonIds(body, fc.ns, &ids);
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(total_bytes);

        sortU64(lats);
        const total_us = @as(f64, @floatFromInt(t1 - t0)) / 1000.0;
        const qps = @as(f64, @floatFromInt(fc.q_count)) * 1e6 / total_us;
        const p50 = @as(f64, @floatFromInt(lats[fc.q_count / 2])) / 1000.0;
        const p99 = @as(f64, @floatFromInt(lats[(fc.q_count * 99) / 100])) / 1000.0;
        const avg_hits = @as(f64, @floatFromInt(total_hits)) / @as(f64, @floatFromInt(fc.q_count));

        rep.line("  {s:<22} | {d:>7.1} QPS | p50={d:>7.1}us p99={d:>7.1}us | avg_hits={d:.2}\n", .{
            fc.name, qps, p50, p99, avg_hits,
        });
        try rep.emitJsonObj(
            "{{\"section\":\"filtered\",\"name\":\"{s}\",\"n\":{d},\"dim\":{d},\"hnsw_path\":{},\"include_meta\":{},\"qps\":{d:.1},\"p50_us\":{d:.2},\"p99_us\":{d:.2},\"avg_hits\":{d:.2}}}",
            .{ fc.name, N, dim, fc.hnsw_path, fc.include_meta, qps, p50, p99, avg_hits },
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Multi-Threaded Scaling (1/2/4/8/16 Threads, N=10k, d=128)
// ─────────────────────────────────────────────────────────────────────────────
fn benchMt(alloc: std.mem.Allocator, rep: *Reporter) !void {
    rep.header("7. MULTI-THREADED VSEARCH SCALING (N=10k, d=128, ef=128, 1/2/4/8/16 threads)");

    const N: usize = 10_000;
    const Q: usize = 256;
    const dim: usize = 128;

    const data = try genDataset(alloc, N, Q, dim, true, 100, 0.30, 0x7777_1280);
    defer alloc.free(data.corpus);
    defer alloc.free(data.queries);

    var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
    defer store.deinit();
    var reg = NamespaceRegistry.init(alloc, .{});
    defer reg.deinit();
    store.vector_registry = &reg;
    var bus = EventBus.init(alloc);
    defer bus.deinit();

    const keys = try alloc.alloc([]u8, N);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    const items = try alloc.alloc(wormdb.core.types.Command.VbulkinsertParams.BulkItem, N);
    defer alloc.free(items);
    for (0..N) |i| {
        keys[i] = try std.fmt.allocPrint(alloc, "vec:mt:{d}", .{i});
        const bp: [*]const u8 = @ptrCast(data.corpus[i * dim ..].ptr);
        items[i] = .{ .key = keys[i], .vector = bp[0 .. dim * 4], .timestamp = 1700000000 };
    }

    const base_ctx = executor.ExecContext{
        .allocator = alloc,
        .store = &store,
        .event_bus = &bus,
        .cluster = null,
        .vector_registry = &reg,
    };
    _ = try executor.execute(base_ctx, .{ .vbulkinsert = .{
        .namespace = "vec:mt:",
        .metric = "cosine",
        .worm = false,
        .is_async = false,
        .items = items,
    } });

    const qkeys = try alloc.alloc([]u8, Q);
    defer {
        for (qkeys) |k| alloc.free(k);
        alloc.free(qkeys);
    }
    for (0..Q) |qi| {
        qkeys[qi] = try std.fmt.allocPrint(alloc, "qry:mt:{d}", .{qi});
        const bp: [*]const u8 = @ptrCast(data.queries[qi * dim ..].ptr);
        try store.setWithTimestampNoVectorSync(qkeys[qi], bp[0 .. dim * 4], false, 1700000000);
    }

    const ns_idx = reg.get("vec:mt:").?;
    const thread_counts = [_]usize{ 1, 2, 4, 8, 16 };
    const TOTAL_HNSW_Q: usize = 3200;

    // 7a. Direct NamespaceIndex.searchLocked scaling
    var base_qps: f64 = 1.0;
    for (thread_counts) |tc| {
        const per_t = TOTAL_HNSW_Q / tc;
        const Worker = struct {
            fn run(idx: *wormdb.vector.NamespaceIndex, qs: []const f32, count: usize, tid: usize) void {
                var out_buf: [18]IndexSearchResult = undefined;
                var scratch: [18]HnswSearchResult = undefined;
                var sink: usize = 0;
                for (0..count) |i| {
                    const qi = (tid * 31 + i) & (Q - 1);
                    idx.lock.lockShared();
                    const n_res = idx.searchLocked(qs[qi * dim ..][0..dim], 10, 128, &out_buf, &scratch) catch 0;
                    sink +%= n_res;
                    idx.lock.unlockShared();
                }
                std.mem.doNotOptimizeAway(sink);
            }
        };
        const threads = try alloc.alloc(std.Thread, tc);
        defer alloc.free(threads);
        const t0 = nowNs();
        for (0..tc) |t| threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ ns_idx, data.queries, per_t, t });
        for (threads) |th| th.join();
        const t1 = nowNs();
        const ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
        const qps = @as(f64, @floatFromInt(per_t * tc)) * 1e9 / @as(f64, @floatFromInt(t1 - t0));
        if (tc == 1) base_qps = qps;
        const scale = qps / base_qps;
        rep.line("  mt_ns_idx_hnsw  thr={d:>2} | {d:>9.0} QPS ({d:>5.2}x) | {d:>6.1} ms\n", .{ tc, qps, scale, ms });
        try rep.emitJsonObj(
            "{{\"section\":\"mt\",\"name\":\"mt_ns_idx_hnsw_t{d}\",\"threads\":{d},\"qps\":{d:.1},\"scaling\":{d:.2},\"ms\":{d:.2}}}",
            .{ tc, tc, qps, scale, ms },
        );
    }

    // 7b. EXEC vsearch mode=auto scaling
    for (thread_counts) |tc| {
        const per_t = TOTAL_HNSW_Q / tc;
        const Worker = struct {
            fn run(s: *Store, b: *EventBus, r: *NamespaceRegistry, qks: []const []u8, count: usize, tid: usize, backing: std.mem.Allocator) void {
                var arena = std.heap.ArenaAllocator.init(backing);
                defer arena.deinit();
                var sink: usize = 0;
                for (0..count) |i| {
                    _ = arena.reset(.retain_capacity);
                    const qi = (tid * 31 + i) & (Q - 1);
                    const qctx = executor.ExecContext{ .allocator = arena.allocator(), .store = s, .event_bus = b, .cluster = null, .vector_registry = r };
                    const args = [_][]const u8{ qks[qi], "10", "vec:mt:", "cosine", "0", "auto", "168", "128" };
                    const resp = executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } }) catch continue;
                    if (resp == .value) if (resp.value) |v| {
                        sink +%= v.len;
                    };
                }
                std.mem.doNotOptimizeAway(sink);
            }
        };
        const threads = try alloc.alloc(std.Thread, tc);
        defer alloc.free(threads);
        const t0 = nowNs();
        for (0..tc) |t| threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &store, &bus, &reg, qkeys, per_t, t, alloc });
        for (threads) |th| th.join();
        const t1 = nowNs();
        const ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
        const qps = @as(f64, @floatFromInt(per_t * tc)) * 1e9 / @as(f64, @floatFromInt(t1 - t0));
        if (tc == 1) base_qps = qps;
        const scale = qps / base_qps;
        rep.line("  mt_vsearch_auto thr={d:>2} | {d:>9.0} QPS ({d:>5.2}x) | {d:>6.1} ms\n", .{ tc, qps, scale, ms });
        try rep.emitJsonObj(
            "{{\"section\":\"mt\",\"name\":\"mt_vsearch_auto_t{d}\",\"threads\":{d},\"qps\":{d:.1},\"scaling\":{d:.2},\"ms\":{d:.2}}}",
            .{ tc, tc, qps, scale, ms },
        );
    }

    // 7c. EXEC vsearch mode=bq_rerank (with RaBitQ) scaling
    const vr_args = [_][]const u8{"vec:mt:"};
    _ = try executor.execute(base_ctx, .{ .exec = .{ .procedure = "vrabitq", .args = &vr_args } });
    const TOTAL_RBQ_Q: usize = 640;

    for (thread_counts) |tc| {
        const per_t = TOTAL_RBQ_Q / tc;
        const Worker = struct {
            fn run(s: *Store, b: *EventBus, r: *NamespaceRegistry, qks: []const []u8, count: usize, tid: usize, backing: std.mem.Allocator) void {
                var arena = std.heap.ArenaAllocator.init(backing);
                defer arena.deinit();
                var sink: usize = 0;
                for (0..count) |i| {
                    _ = arena.reset(.retain_capacity);
                    const qi = (tid * 31 + i) & (Q - 1);
                    const qctx = executor.ExecContext{ .allocator = arena.allocator(), .store = s, .event_bus = b, .cluster = null, .vector_registry = r };
                    const args = [_][]const u8{ qks[qi], "10", "vec:mt:", "cosine", "0", "bq_rerank" };
                    const resp = executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } }) catch continue;
                    if (resp == .value) if (resp.value) |v| {
                        sink +%= v.len;
                    };
                }
                std.mem.doNotOptimizeAway(sink);
            }
        };
        const threads = try alloc.alloc(std.Thread, tc);
        defer alloc.free(threads);
        const t0 = nowNs();
        for (0..tc) |t| threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &store, &bus, &reg, qkeys, per_t, t, alloc });
        for (threads) |th| th.join();
        const t1 = nowNs();
        const ms = @as(f64, @floatFromInt(t1 - t0)) / 1e6;
        const qps = @as(f64, @floatFromInt(per_t * tc)) * 1e9 / @as(f64, @floatFromInt(t1 - t0));
        if (tc == 1) base_qps = qps;
        const scale = qps / base_qps;
        rep.line("  mt_vsearch_rbq  thr={d:>2} | {d:>9.0} QPS ({d:>5.2}x) | {d:>6.1} ms\n", .{ tc, qps, scale, ms });
        try rep.emitJsonObj(
            "{{\"section\":\"mt\",\"name\":\"mt_vsearch_rbq_rerank_t{d}\",\"threads\":{d},\"qps\":{d:.1},\"scaling\":{d:.2},\"ms\":{d:.2}}}",
            .{ tc, tc, qps, scale, ms },
        );
    }
}
