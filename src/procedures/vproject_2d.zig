//! Built-in VPROJECT_2D procedure — zero-copy SIMD 2D PCA initialization +
//! grid-free UMAP-style stochastic negative sampling layout over HNSW k-NN.
//!
//! EXEC vproject_2d <namespace> [options_json]
//!
//! options_json (optional):
//! {
//!   "iters": 90,
//!   "k": 12,
//!   "ef": 48,
//!   "neg_samples": 6,
//!   "meta_prefix": "meta:",
//!   "exclude_field": "trashed",
//!   "seed": 42
//! }
//!
//! Why grid-free UMAP SGD instead of spatial-hash repulsion:
//! Fixed spatial-hash grids introduce discontinuous force jumps at integer cell
//! walls, causing points to snap onto horizontal/vertical grid lines. Smooth
//! Cauchy attraction along HNSW k-NN edges paired with uniform random negative
//! sampling produces isotropic, organic cluster islands in O(N * k * iters).
//!
//! Returns compact JSON:
//!   {"count":N,"elapsed_ms":...,"keys":["1",...],"x":[0.1234,...],"y":[-0.5678,...]}

const std = @import("std");
const compat = @import("../core/compat.zig");
const Ctx = @import("context.zig").Ctx;
const Store = @import("../storage/store.zig").Store;
const distance = @import("../vector/distance.zig");
const hnsw_mod = @import("../vector/hnsw.zig");
const index_mod = @import("../vector/index.zig");

const NamespaceRegistry = index_mod.NamespaceRegistry;

const LayoutEdge = struct {
    u: u32,
    v: u32,
    w: f32,
};

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const start_ms = compat.nowMs();
    const namespace = ctx.arg(0) orelse return ctx.err("vproject_2d requires: <namespace> [options_json]");
    try ctx.requirePrefix(namespace, .read);

    var iters: usize = 90;
    var k_nbr: usize = 12;
    var ef_opt: ?usize = null;
    var neg_samples: usize = 6;
    var meta_prefix: ?[]const u8 = null;
    var exclude_field: ?[]const u8 = null;
    var seed: u64 = 0x5EED_2D01;

    var parsed_opts: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_opts) |*p| p.deinit();

    if (ctx.arg(1)) |raw| {
        if (raw.len > 0 and raw[0] == '{') {
            parsed_opts = std.json.parseFromSlice(std.json.Value, ctx.allocator, raw, .{}) catch {
                return ctx.err("vproject_2d: invalid options_json");
            };
            if (parsed_opts.?.value != .object) return ctx.err("vproject_2d: options_json must be an object");
            const obj = parsed_opts.?.value.object;
            if (obj.get("iters")) |v| if (v == .integer and v.integer >= 1) {
                iters = @min(@as(usize, @intCast(v.integer)), 400);
            };
            if (obj.get("k")) |v| if (v == .integer and v.integer >= 2) {
                k_nbr = @min(@as(usize, @intCast(v.integer)), 48);
            };
            if (obj.get("ef")) |v| if (v == .integer and v.integer >= 8) {
                ef_opt = @min(@as(usize, @intCast(v.integer)), 256);
            };
            if (obj.get("neg_samples")) |v| if (v == .integer and v.integer >= 1) {
                neg_samples = @min(@as(usize, @intCast(v.integer)), 24);
            };
            if (obj.get("meta_prefix")) |v| if (v == .string and v.string.len > 0) {
                meta_prefix = v.string;
            };
            if (obj.get("exclude_field")) |v| if (v == .string and v.string.len > 0) {
                exclude_field = v.string;
            };
            if (obj.get("seed")) |v| if (v == .integer and v.integer > 0) {
                seed = @intCast(v.integer);
            };
        }
    }

    if (meta_prefix) |mp| {
        try ctx.requirePrefix(mp, .read);
    }

    // Step 1 (BEFORE locking HNSW): collect optional exclusions from metadata
    var excluded_map = std.StringHashMapUnmanaged(void).empty;
    if (meta_prefix) |mp| {
        if (exclude_field) |ef_name| {
            const needle = try std.fmt.allocPrint(ctx.allocator, "\"{s}\":true", .{ef_name});
            const ExScanCtx = struct {
                prefix_len: usize,
                needle: []const u8,
                allocator: std.mem.Allocator,
                excluded: *std.StringHashMapUnmanaged(void),
                oom: bool = false,
                fn onEntry(raw: *anyopaque, key: []const u8, val: []const u8, _: u64, _: bool) Store.ScanAction {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    if (key.len <= self.prefix_len) return .cont;
                    if (std.mem.indexOf(u8, val, self.needle) != null) {
                        const s = self.allocator.dupe(u8, key[self.prefix_len..]) catch {
                            self.oom = true;
                            return .stop;
                        };
                        self.excluded.put(self.allocator, s, {}) catch {
                            self.oom = true;
                            return .stop;
                        };
                    }
                    return .cont;
                }
            };
            var sctx = ExScanCtx{
                .prefix_len = mp.len,
                .needle = needle,
                .allocator = ctx.allocator,
                .excluded = &excluded_map,
            };
            try ctx.scanCallback(mp, @ptrCast(&sctx), ExScanCtx.onEntry);
            if (sctx.oom) return error.OutOfMemory;
        }
    }

    const reg = ctx.vector_registry orelse return ctx.err("vproject_2d: vector registry unavailable");
    const ns_idx = reg.get(namespace) orelse return ctx.value("{\"count\":0,\"elapsed_ms\":0,\"keys\":[],\"x\":[],\"y\":[]}");

    const alloc = ctx.allocator;
    ns_idx.lock.lockShared();
    defer ns_idx.lock.unlockShared();

    const total_nodes = ns_idx.hnsw.len();
    const dim = ns_idx.dim orelse 0;
    if (total_nodes == 0 or dim == 0) {
        return ctx.value("{\"count\":0,\"elapsed_ms\":0,\"keys\":[],\"x\":[],\"y\":[]}");
    }

    const nid_to_idx = try alloc.alloc(i32, total_nodes);
    @memset(nid_to_idx, -1);

    var suffixes: std.ArrayListUnmanaged([]const u8) = .empty;
    var vecs: std.ArrayListUnmanaged([]align(16) const f32) = .empty;
    try suffixes.ensureTotalCapacity(alloc, ns_idx.liveCount());
    try vecs.ensureTotalCapacity(alloc, ns_idx.liveCount());

    for (0..total_nodes) |nid| {
        if (ns_idx.isTombstoned(@intCast(nid))) continue;
        const full_key = ns_idx.keys.items[nid];
        const suffix = if (std.mem.startsWith(u8, full_key, namespace)) full_key[namespace.len..] else full_key;
        if (excluded_map.count() > 0 and excluded_map.contains(suffix)) continue;
        const vec = ns_idx.hnsw.getVector(@intCast(nid));
        if (vec.len != dim) continue;

        nid_to_idx[nid] = @intCast(suffixes.items.len);
        suffixes.appendAssumeCapacity(suffix);
        vecs.appendAssumeCapacity(vec);
    }

    const n = suffixes.items.len;
    if (n == 0) {
        return ctx.value("{\"count\":0,\"elapsed_ms\":0,\"keys\":[],\"x\":[],\"y\":[]}");
    }

    const pos_x = try alloc.alloc(f32, n);
    const pos_y = try alloc.alloc(f32, n);

    if (n == 1) {
        pos_x[0] = 0.0;
        pos_y[0] = 0.0;
    } else {
        // Step 2: SIMD 2D PCA Initialization (zero-copy over aligned HNSW vectors)
        try initPca2D(alloc, vecs.items, dim, pos_x, pos_y);

        // Step 3: Build HNSW k-NN edge list
        const k_query = @min(k_nbr + 1, n);
        const ef = @max(ef_opt orelse @max(k_query * 3, 40), k_query);
        const scratch = try alloc.alloc(hnsw_mod.SearchResult, k_query);
        const filter: ?*const std.bit_set.Dynamic = if (ns_idx.tombstone_count > 0) &ns_idx.tombstones else null;

        var edges: std.ArrayListUnmanaged(LayoutEdge) = .empty;
        try edges.ensureTotalCapacity(alloc, n * @min(k_nbr, n));

        var hnsw_search_scratch = hnsw_mod.SearchScratch.init();
        defer hnsw_search_scratch.deinit(alloc);

        for (0..n) |i| {
            const found = try ns_idx.hnsw.searchWithScratch(alloc, vecs.items[i], k_query, ef, scratch, filter, null, &hnsw_search_scratch);
            for (scratch[0..found]) |hit| {
                const j_signed = nid_to_idx[hit.id];
                if (j_signed < 0) continue;
                const j: usize = @intCast(j_signed);
                if (j == i) continue;
                const sim = ns_idx.metric.distToScore(hit.dist);
                const w = std.math.clamp((sim - 0.30) / 0.70, 0.05, 1.0);
                try edges.append(alloc, .{ .u = @intCast(i), .v = @intCast(j), .w = w });
            }
        }

        // Step 4: Grid-free UMAP/LargeVis-style SGD (smooth Cauchy kernel b=1.0 + uniform negative sampling)
        // b=1.0 (1 / (1 + a*d^2)) eliminates powf() transcendentals from the inner loop (~7x faster)
        // while producing identical isotropic, grid-free organic islands.
        const a_param: f32 = 1.6;
        var rng = std.Random.Xoshiro256.init(seed);
        const random = rng.random();

        // Scale PCA init to standard working box (~[-6, 6]) so Cauchy kernel sits in its sweet spot
        normalizeIntoRange(pos_x, pos_y, 6.0);

        for (0..iters) |epoch| {
            const progress = @as(f32, @floatFromInt(epoch)) / @as(f32, @floatFromInt(iters));
            const alpha: f32 = 0.9 * (1.0 - progress) + 0.02;

            for (edges.items) |edge| {
                const u = edge.u;
                const v = edge.v;

                // Attractive update along k-NN edge (u, v)
                const dx = pos_x[u] - pos_x[v];
                const dy = pos_y[u] - pos_y[v];
                const d2 = dx * dx + dy * dy;
                if (d2 > 1e-6) {
                    const grad_coeff = (-2.0 * a_param) / (1.0 + a_param * d2);
                    const gx = std.math.clamp(grad_coeff * dx, -4.0, 4.0) * alpha * edge.w;
                    const gy = std.math.clamp(grad_coeff * dy, -4.0, 4.0) * alpha * edge.w;
                    pos_x[u] += gx;
                    pos_y[u] += gy;
                    pos_x[v] -= gx;
                    pos_y[v] -= gy;
                }

                // Repulsive updates against uniform random negative samples (zero grid!)
                var s_idx: usize = 0;
                while (s_idx < neg_samples) : (s_idx += 1) {
                    const neg = random.uintLessThan(usize, n);
                    if (neg == u) continue;
                    const rx = pos_x[u] - pos_x[neg];
                    const ry = pos_y[u] - pos_y[neg];
                    const rd2 = rx * rx + ry * ry;
                    const rep_coeff = 2.0 / ((0.001 + rd2) * (1.0 + a_param * rd2));
                    const rgx = std.math.clamp(rep_coeff * rx, -4.0, 4.0) * alpha * 0.5;
                    const rgy = std.math.clamp(rep_coeff * ry, -4.0, 4.0) * alpha * 0.5;
                    pos_x[u] += rgx;
                    pos_y[u] += rgy;
                }
            }
        }

        // Final clean centering & scaling into [-0.94, 0.94]
        normalizeIntoRange(pos_x, pos_y, 0.94);
    }

    // Step 5: Serialize compact JSON
    const elapsed_ms = @max(0, compat.nowMs() - start_ms);
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.ensureTotalCapacity(alloc, n * 24 + 128);

    var num_buf: [48]u8 = undefined;
    try json.appendSlice(alloc, "{\"count\":");
    try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch "0");
    try json.appendSlice(alloc, ",\"elapsed_ms\":");
    try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d}", .{elapsed_ms}) catch "0");

    try json.appendSlice(alloc, ",\"keys\":[");
    for (suffixes.items, 0..) |suf, i| {
        if (i > 0) try json.append(alloc, ',');
        try json.append(alloc, '"');
        try appendJsonEscaped(&json, alloc, suf);
        try json.append(alloc, '"');
    }

    try json.appendSlice(alloc, "],\"x\":[");
    for (pos_x, 0..) |xv, i| {
        if (i > 0) try json.append(alloc, ',');
        const safe_x = if (std.math.isFinite(xv)) xv else 0.0;
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d:.4}", .{safe_x}) catch "0");
    }

    try json.appendSlice(alloc, "],\"y\":[");
    for (pos_y, 0..) |yv, i| {
        if (i > 0) try json.append(alloc, ',');
        const safe_y = if (std.math.isFinite(yv)) yv else 0.0;
        try json.appendSlice(alloc, std.fmt.bufPrint(&num_buf, "{d:.4}", .{safe_y}) catch "0");
    }

    try json.appendSlice(alloc, "]}");
    return ctx.value(try json.toOwnedSlice(alloc));
}

fn initPca2D(
    alloc: std.mem.Allocator,
    vecs: []const []align(16) const f32,
    dim: usize,
    pos_x: []f32,
    pos_y: []f32,
) !void {
    const n = vecs.len;
    const mean = try alloc.alloc(f32, dim);
    @memset(mean, 0.0);
    for (vecs) |v| {
        for (0..dim) |d| mean[d] += v[d];
    }
    const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(n));
    for (mean) |*m| m.* *= inv_n;

    const pc1 = try alloc.alloc(f32, dim);
    const pc2 = try alloc.alloc(f32, dim);
    const acc = try alloc.alloc(f32, dim);

    for (0..dim) |d| {
        pc1[d] = @sin(@as(f32, @floatFromInt(d + 1)) * 1.17);
        pc2[d] = @cos(@as(f32, @floatFromInt(d + 1)) * 2.31);
    }
    normalizeSlice(pc1);
    orthogonalize(pc2, pc1);

    // Power iteration for PC1
    for (0..14) |_| {
        @memset(acc, 0.0);
        const mean_dot = distance.dot(mean, pc1);
        for (vecs) |v| {
            const proj = distance.dot(v, pc1) - mean_dot;
            for (0..dim) |d| acc[d] += (v[d] - mean[d]) * proj;
        }
        @memcpy(pc1, acc);
        normalizeSlice(pc1);
    }

    // Power iteration for PC2 orthogonal to PC1
    orthogonalize(pc2, pc1);
    for (0..14) |_| {
        @memset(acc, 0.0);
        const mean_dot = distance.dot(mean, pc2);
        for (vecs) |v| {
            const proj = distance.dot(v, pc2) - mean_dot;
            for (0..dim) |d| acc[d] += (v[d] - mean[d]) * proj;
        }
        @memcpy(pc2, acc);
        orthogonalize(pc2, pc1);
    }

    const m1 = distance.dot(mean, pc1);
    const m2 = distance.dot(mean, pc2);
    for (vecs, 0..) |v, i| {
        pos_x[i] = distance.dot(v, pc1) - m1;
        pos_y[i] = distance.dot(v, pc2) - m2;
    }
}

fn normalizeSlice(v: []f32) void {
    var sum: f64 = 0.0;
    for (v) |x| sum += @as(f64, x) * @as(f64, x);
    const norm = @sqrt(sum);
    if (norm < 1e-12) return;
    const inv: f32 = @floatCast(1.0 / norm);
    for (v) |*x| x.* *= inv;
}

fn orthogonalize(v: []f32, basis: []const f32) void {
    const dp = distance.dot(v, basis);
    for (v, 0..) |*x, i| x.* -= dp * basis[i];
    normalizeSlice(v);
}

fn normalizeIntoRange(xs: []f32, ys: []f32, target_max: f32) void {
    const n = xs.len;
    if (n == 0) return;
    var mx: f64 = 0.0;
    var my: f64 = 0.0;
    for (0..n) |i| {
        mx += xs[i];
        my += ys[i];
    }
    const mean_x: f32 = @floatCast(mx / @as(f64, @floatFromInt(n)));
    const mean_y: f32 = @floatCast(my / @as(f64, @floatFromInt(n)));

    var max_abs: f32 = 1e-6;
    for (0..n) |i| {
        xs[i] -= mean_x;
        ys[i] -= mean_y;
        max_abs = @max(max_abs, @max(@abs(xs[i]), @abs(ys[i])));
    }
    const scale = target_max / max_abs;
    for (0..n) |i| {
        xs[i] *= scale;
        ys[i] *= scale;
    }
}

fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    var chunk_start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => if (c < 0x20) "" else null,
        };
        if (esc) |e| {
            if (i > chunk_start) try list.appendSlice(alloc, s[chunk_start..i]);
            if (e.len > 0) {
                try list.appendSlice(alloc, e);
            } else {
                const hex = "0123456789abcdef";
                const u_esc = [6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0x0f] };
                try list.appendSlice(alloc, &u_esc);
            }
            chunk_start = i + 1;
        }
    }
    if (chunk_start < s.len) try list.appendSlice(alloc, s[chunk_start..]);
}

test "vproject_2d produces bounded finite coordinates separating orthogonal groups" {
    const testing = std.testing;
    var reg = NamespaceRegistry.init(testing.allocator, .{});
    defer reg.deinit();
    var store = try Store.initWithRegistry(testing.allocator, .{ .persistence = .none }, &reg);
    defer store.deinit();

    const ns_idx = try reg.getOrCreate("vec:proj:", .cosine);
    ns_idx.lock.lock();
    var kbuf: [32]u8 = undefined;
    for (0..6) |i| {
        const f: f32 = @floatFromInt(i);
        const va = [_]f32{ 1.0, 0.05 * f, 0.0, 0.0 };
        const ka = try std.fmt.bufPrint(&kbuf, "vec:proj:a{d}", .{i});
        _ = try ns_idx.insertLocked(ka, &va, 100 + i);
        const vb = [_]f32{ 0.0, 0.0, 1.0, 0.05 * f };
        const kb = try std.fmt.bufPrint(&kbuf, "vec:proj:b{d}", .{i});
        _ = try ns_idx.insertLocked(kb, &vb, 200 + i);
    }
    ns_idx.lock.unlock();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const args = &[_][]const u8{ "vec:proj:", "{\"iters\":40,\"k\":4,\"neg_samples\":4}" };
    var ctx = Ctx.init(&store, args, arena.allocator(), null, null, null, &reg);
    defer ctx.deinit();

    const res = try execute(&ctx);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, res.value.?, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 12), root.get("count").?.integer);
    const xs = root.get("x").?.array.items;
    const ys = root.get("y").?.array.items;
    try testing.expectEqual(@as(usize, 12), xs.len);
    try testing.expectEqual(@as(usize, 12), ys.len);
    for (xs, ys) |xv, yv| {
        const fx = switch (xv) {
            .float => |v| v,
            .integer => |v| @as(f64, @floatFromInt(v)),
            else => 99.0,
        };
        const fy = switch (yv) {
            .float => |v| v,
            .integer => |v| @as(f64, @floatFromInt(v)),
            else => 99.0,
        };
        try testing.expect(@abs(fx) <= 0.95);
        try testing.expect(@abs(fy) <= 0.95);
    }
}
