const std = @import("std");
const wormdb = @import("wormdb");

const compat = wormdb.core.compat;
const Store = wormdb.storage.Store;
const EventBus = wormdb.event.EventBus;
const executor = wormdb.server.executor;
const NamespaceRegistry = wormdb.vector.NamespaceRegistry;

fn nowNs() u64 {
    return @intCast(compat.nowNs());
}

fn printHeader(title: []const u8) void {
    std.debug.print("\n================================================================================\n", .{});
    std.debug.print("  {s}\n", .{title});
    std.debug.print("================================================================================\n", .{});
}

fn printRow(name: []const u8, ops: usize, elapsed_ns: u64, extra: []const u8) void {
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ops));
    const ops_per_sec = (@as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(elapsed_ns))) * 1_000_000_000.0;
    std.debug.print("  {s:<44} | {d:>10.1} ops/s | {d:>8.1} ns/op | {d:>7.2} ms {s}\n", .{
        name,
        ops_per_sec,
        ns_per_op,
        elapsed_ms,
        extra,
    });
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;

    var only_ns_sync = false;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--only-ns-sync")) only_ns_sync = true;
    }

    try benchMtNamespaceSync(alloc);
    if (only_ns_sync) return;
    try benchMtWalContention(alloc);
    try benchVsearchModes(alloc);
    try benchVsearchRecallAndEf(alloc);
    try benchProceduresSuite(alloc);
}

fn benchMtNamespaceSync(alloc: std.mem.Allocator) !void {
    printHeader("7b. MULTI-THREADED NON-MATCHING KV SET vs REGISTERED NAMESPACES (1/8/16 thr x 0/1/50 ns)");

    const KEYSPACE: usize = 65_536;
    const OPS_PER_THREAD: usize = 200_000;
    const val_64: []const u8 = &@as([64]u8, @splat('x'));

    const keys = try alloc.alloc([]u8, KEYSPACE);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    for (0..KEYSPACE) |i| {
        keys[i] = try std.fmt.allocPrint(alloc, "kv:key:{d:0>8}", .{i});
    }

    for ([_]usize{ 0, 1, 50 }) |ns_count| {
        var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
        defer store.deinit();
        var reg = NamespaceRegistry.init(alloc, .{});
        defer reg.deinit();
        store.vector_registry = &reg;

        for (0..ns_count) |n| {
            var ns_buf: [32]u8 = undefined;
            const ns_name = try std.fmt.bufPrint(&ns_buf, "vec:ns{d:0>2}:", .{n});
            _ = try reg.getOrCreate(ns_name, .cosine);
        }

        // Pre-populate keys so threads measure steady-state in-place overwrites
        for (keys) |k| {
            try store.setWithTimestampNoVectorSync(k, val_64, false, 100);
        }

        const Worker = struct {
            fn run(s: *Store, ks: []const []u8, count: usize, tid: usize) void {
                var idx: usize = tid * 4099;
                for (0..count) |_| {
                    const k = ks[idx & (KEYSPACE - 1)];
                    s.setWithTimestamp(k, val_64, false, 100) catch {};
                    idx +%= 7919;
                }
            }
        };

        for ([_]usize{ 1, 8, 16 }) |tc| {
            const threads = try alloc.alloc(std.Thread, tc);
            defer alloc.free(threads);

            const t0 = nowNs();
            for (0..tc) |t| {
                threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &store, keys, OPS_PER_THREAD, t });
            }
            for (threads) |th| th.join();
            const t1 = nowNs();

            var label_buf: [64]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "MT Store.set non-vec ({d:>2} thr, {d:>2} namespaces)", .{ tc, ns_count });
            printRow(label, OPS_PER_THREAD * tc, t1 - t0, "[syncRawSet filter]");
        }
    }
}

fn benchMtWalContention(alloc: std.mem.Allocator) !void {
    printHeader("8. MULTI-THREADED WAL CONTENTION (.full + bg writer, 1..16 threads)");

    const tmp_dir = ".zig-cache/bench_data";
    try compat.Dir.makePath(compat.cwd(), tmp_dir);

    const KEYSPACE: usize = 20_000;
    const OPS_TOTAL: usize = 40_000;
    const val_128: []const u8 = &@as([128]u8, @splat('v'));

    const keys = try alloc.alloc([]u8, KEYSPACE);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    for (0..KEYSPACE) |i| {
        keys[i] = try std.fmt.allocPrint(alloc, "mtwal:key:{d:0>8}", .{i});
    }

    const thread_counts = [_]usize{ 1, 2, 4, 8, 16 };
    for (thread_counts) |tc| {
        const run_id = nowNs();
        const wal_path = try std.fmt.allocPrint(alloc, "{s}/mtwal_{d}_{d}.wal", .{ tmp_dir, tc, run_id });
        defer alloc.free(wal_path);
        const snap_path = try std.fmt.allocPrint(alloc, "{s}.snapshot", .{wal_path});
        defer alloc.free(snap_path);

        var store = try Store.init(alloc, .{
            .wal_path = wal_path,
            .snapshot_path = snap_path,
            .persistence = .full,
            .sync_writes = true,
            .max_wal_size = 0,
        });
        defer store.deinit();
        try store.startBackgroundTasks();

        const ops_per_thread = OPS_TOTAL / tc;
        const Worker = struct {
            fn run(s: *Store, ks: []const []u8, count: usize, tid: usize) void {
                var idx: usize = tid * 997;
                for (0..count) |_| {
                    const k = ks[idx % ks.len];
                    s.set(k, val_128, false) catch {};
                    idx +%= 7919;
                }
            }
        };

        const threads = try alloc.alloc(std.Thread, tc);
        defer alloc.free(threads);

        const t0 = nowNs();
        for (0..tc) |t| {
            threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &store, keys, ops_per_thread, t });
        }
        for (threads) |th| th.join();
        const t1 = nowNs();

        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "MT Store.set .full bg-WAL ({d} threads)", .{tc});
        printRow(label, ops_per_thread * tc, t1 - t0, "[wal_enqueue_mutex]");
    }
}

fn benchVsearchModes(alloc: std.mem.Allocator) !void {
    printHeader("9. VSEARCH PROCEDURE END-TO-END DISPATCH (N=5,000, dim=128 & 384)");

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    for ([_]usize{ 128, 384 }) |dim| {
        const N: usize = 5_000;
        var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
        defer store.deinit();
        var reg = NamespaceRegistry.init(alloc, .{});
        defer reg.deinit();
        var bus = EventBus.init(alloc);
        defer bus.deinit();

        const vec_floats = try alloc.alloc(f32, N * dim);
        defer alloc.free(vec_floats);
        for (vec_floats) |*f| f.* = rand.floatNorm(f32);

        const items = try alloc.alloc(wormdb.core.types.Command.VbulkinsertParams.BulkItem, N);
        defer alloc.free(items);
        const keys = try alloc.alloc([]u8, N);
        defer {
            for (keys) |k| alloc.free(k);
            alloc.free(keys);
        }
        for (0..N) |i| {
            keys[i] = try std.fmt.allocPrint(alloc, "vec:ns:{d}", .{i});
            const byte_ptr: [*]const u8 = @ptrCast(vec_floats[i * dim ..].ptr);
            items[i] = .{
                .key = keys[i],
                .vector = byte_ptr[0 .. dim * 4],
                .timestamp = 1700000000,
            };
        }

        const base_ctx = executor.ExecContext{
            .allocator = alloc,
            .store = &store,
            .event_bus = &bus,
            .cluster = null,
            .vector_registry = &reg,
        };

        _ = try executor.execute(base_ctx, .{ .vbulkinsert = .{
            .namespace = "vec:ns:",
            .metric = "cosine",
            .worm = false,
            .is_async = false,
            .items = items,
        } });

        const n_queries: usize = 100;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        for ([_][]const u8{ "auto", "bq", "bq_rerank", "exact" }) |mode_str| {
            var sink: usize = 0;
            const t0 = nowNs();
            for (0..n_queries) |q| {
                _ = arena.reset(.retain_capacity);
                const qctx = executor.ExecContext{
                    .allocator = arena.allocator(),
                    .store = &store,
                    .event_bus = &bus,
                    .cluster = null,
                    .vector_registry = &reg,
                };
                const args = [_][]const u8{ keys[q], "10", "vec:ns:", "cosine", "0", mode_str };
                const resp = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
                if (resp == .value) {
                    if (resp.value) |v| sink +%= v.len;
                }
            }
            const t1 = nowNs();
            std.mem.doNotOptimizeAway(sink);
            var label_buf: [64]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "EXEC vsearch mode={s} (N=5k, dim={d})", .{ mode_str, dim });
            printRow(label, n_queries, t1 - t0, "");
        }

        // Also test after EXEC vrabitq (installs RaBitQ rotation + re-encodes all bq:* entries)
        {
            const vr_t0 = nowNs();
            const vr_args = [_][]const u8{"vec:ns:"};
            _ = try executor.execute(base_ctx, .{ .exec = .{ .procedure = "vrabitq", .args = &vr_args } });
            const vr_t1 = nowNs();
            var vr_label: [64]u8 = undefined;
            printRow(try std.fmt.bufPrint(&vr_label, "EXEC vrabitq build (N=5k, dim={d})", .{dim}), 1, vr_t1 - vr_t0, "[centroid+rot+reencode]");

            for ([_][]const u8{ "bq", "bq_rerank" }) |mode_str| {
                var sink: usize = 0;
                const t0 = nowNs();
                for (0..n_queries) |q| {
                    _ = arena.reset(.retain_capacity);
                    const qctx = executor.ExecContext{
                        .allocator = arena.allocator(),
                        .store = &store,
                        .event_bus = &bus,
                        .cluster = null,
                        .vector_registry = &reg,
                    };
                    const args = [_][]const u8{ keys[q], "10", "vec:ns:", "cosine", "0", mode_str };
                    const resp = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
                    if (resp == .value) {
                        if (resp.value) |v| sink +%= v.len;
                    }
                }
                const t1 = nowNs();
                std.mem.doNotOptimizeAway(sink);
                var label_buf: [64]u8 = undefined;
                const label = try std.fmt.bufPrint(&label_buf, "EXEC vsearch+RaBitQ mode={s} (N=5k, d={d})", .{ mode_str, dim });
                printRow(label, n_queries, t1 - t0, "");
            }
        }
    }
}

fn extractJsonKeys(json: []const u8, out: *[10][]const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    const needle = "\"k\":\"";
    while (count < out.len) {
        const rel = std.mem.indexOfPos(u8, json, pos, needle) orelse break;
        const start = rel + needle.len;
        const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse break;
        out[count] = json[start..end];
        count += 1;
        pos = end + 1;
    }
    return count;
}

fn benchVsearchRecallAndEf(alloc: std.mem.Allocator) !void {
    printHeader("9b. VSEARCH HNSW EF vs RECALL@10 & LATENCY (dim=128, N=5k & N=100k)");

    const dim: usize = 128;
    const n_queries: usize = 100;

    const Case = struct {
        n: usize,
        clustered: bool,
        tag: []const u8,
    };
    const cases = [_]Case{
        .{ .n = 5_000, .clustered = false, .tag = "N=5k iso" },
        .{ .n = 100_000, .clustered = false, .tag = "N=100k iso" },
        .{ .n = 100_000, .clustered = true, .tag = "N=100k clust" },
    };

    for (cases) |c| {
        const N = c.n;
        var prng = std.Random.DefaultPrng.init(0xBEEF_0000 + N + @as(u64, @intFromBool(c.clustered)) * 777);
        const rand = prng.random();

        var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
        defer store.deinit();
        var reg = NamespaceRegistry.init(alloc, .{});
        defer reg.deinit();
        store.vector_registry = &reg;
        var bus = EventBus.init(alloc);
        defer bus.deinit();

        const vec_floats = try alloc.alloc(f32, N * dim);
        defer alloc.free(vec_floats);
        if (c.clustered) {
            const n_clusters: usize = 100;
            const centers = try alloc.alloc(f32, n_clusters * dim);
            defer alloc.free(centers);
            for (centers) |*f| f.* = rand.floatNorm(f32);
            for (0..N) |i| {
                const cid = i % n_clusters;
                const center = centers[cid * dim .. (cid + 1) * dim];
                const dst = vec_floats[i * dim .. (i + 1) * dim];
                for (0..dim) |d| {
                    dst[d] = center[d] + 0.30 * rand.floatNorm(f32);
                }
            }
        } else {
            for (vec_floats) |*f| f.* = rand.floatNorm(f32);
        }

        const keys = try alloc.alloc([]u8, N);
        defer {
            for (keys) |k| alloc.free(k);
            alloc.free(keys);
        }

        const ns_idx = try reg.getOrCreate("vec:ns:", .cosine);
        const build_t0 = nowNs();
        for (0..N) |i| {
            keys[i] = try std.fmt.allocPrint(alloc, "vec:ns:{d}", .{i});
            const slice = vec_floats[i * dim .. (i + 1) * dim];
            const byte_ptr: [*]const u8 = @ptrCast(slice.ptr);
            try store.setWithTimestampNoVectorSync(keys[i], byte_ptr[0 .. dim * 4], false, 1_700_000_000_000);
            ns_idx.lock.lock();
            _ = try ns_idx.insertLocked(keys[i], slice, 1_700_000_000_000);
            ns_idx.lock.unlock();
        }
        const build_t1 = nowNs();
        {
            var build_label: [64]u8 = undefined;
            printRow(
                try std.fmt.bufPrint(&build_label, "HNSW+Store populate ({s}, d=128)", .{c.tag}),
                N,
                build_t1 - build_t0,
                "",
            );
        }

        // Ground truth via mode=exact for n_queries distinct query keys
        var gt_arena = std.heap.ArenaAllocator.init(alloc);
        defer gt_arena.deinit();
        const gt_alloc = gt_arena.allocator();
        const gt_top10 = try gt_alloc.alloc([10][]const u8, n_queries);
        const gt_counts = try gt_alloc.alloc(usize, n_queries);

        const exact_t0 = nowNs();
        for (0..n_queries) |q| {
            const qkey = keys[q * (N / n_queries)];
            const qctx = executor.ExecContext{
                .allocator = gt_alloc,
                .store = &store,
                .event_bus = &bus,
                .cluster = null,
                .vector_registry = &reg,
            };
            const args = [_][]const u8{ qkey, "10", "vec:ns:", "cosine", "0", "exact" };
            const resp = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
            gt_counts[q] = extractJsonKeys(resp.value.?, &gt_top10[q]);
        }
        const exact_t1 = nowNs();
        {
            var exact_label: [64]u8 = undefined;
            printRow(
                try std.fmt.bufPrint(&exact_label, "EXEC vsearch exact ({s}, d=128)", .{c.tag}),
                n_queries,
                exact_t1 - exact_t0,
                "[recall@10=1.0000]",
            );
        }

        var query_arena = std.heap.ArenaAllocator.init(alloc);
        defer query_arena.deinit();

        for ([_][]const u8{ "64", "128", "200" }) |ef_str| {
            var hits: usize = 0;
            var total_gt: usize = 0;
            const t0 = nowNs();
            for (0..n_queries) |q| {
                _ = query_arena.reset(.retain_capacity);
                const qkey = keys[q * (N / n_queries)];
                const qctx = executor.ExecContext{
                    .allocator = query_arena.allocator(),
                    .store = &store,
                    .event_bus = &bus,
                    .cluster = null,
                    .vector_registry = &reg,
                };
                const args = [_][]const u8{ qkey, "10", "vec:ns:", "cosine", "0", "auto", "168", ef_str };
                const resp = try executor.execute(qctx, .{ .exec = .{ .procedure = "vsearch", .args = &args } });
                var hnsw_keys: [10][]const u8 = undefined;
                const hnsw_cnt = extractJsonKeys(resp.value.?, &hnsw_keys);
                total_gt += gt_counts[q];
                for (hnsw_keys[0..hnsw_cnt]) |hk| {
                    for (gt_top10[q][0..gt_counts[q]]) |gk| {
                        if (std.mem.eql(u8, hk, gk)) {
                            hits += 1;
                            break;
                        }
                    }
                }
            }
            const t1 = nowNs();
            const recall = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total_gt));
            var label_buf: [64]u8 = undefined;
            var extra_buf: [32]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "EXEC vsearch HNSW ef={s} ({s})", .{ ef_str, c.tag });
            const extra = try std.fmt.bufPrint(&extra_buf, "[recall@10={d:.4}]", .{recall});
            printRow(label, n_queries, t1 - t0, extra);
        }
    }
}

fn benchProceduresSuite(alloc: std.mem.Allocator) !void {
    printHeader("10. BUILT-IN STORED PROCEDURES (scan, kv_stats, chat_send, chat_history)");

    var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
    defer store.deinit();
    var bus = EventBus.init(alloc);
    defer bus.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // Seed 2,000 keys under "item:"
    for (0..2000) |i| {
        const k = try std.fmt.allocPrint(alloc, "item:{d:0>6}", .{i});
        defer alloc.free(k);
        try store.set(k, "{\"name\":\"widget\",\"price\":42}", false);
    }

    // Seed 500 chat messages via EXEC chat_send
    {
        const n_chat: usize = 500;
        const t0 = nowNs();
        for (0..n_chat) |_| {
            _ = arena.reset(.retain_capacity);
            const ctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null };
            const args = [_][]const u8{ "general", "alice", "hello world from benchmark" };
            _ = try executor.execute(ctx, .{ .exec = .{ .procedure = "chat_send", .args = &args } });
        }
        const t1 = nowNs();
        printRow("EXEC chat_send (500 msgs)", n_chat, t1 - t0, "");
    }

    // EXEC chat_history (limit 50 out of 500)
    {
        const iters: usize = 500;
        const t0 = nowNs();
        for (0..iters) |_| {
            _ = arena.reset(.retain_capacity);
            const ctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null };
            const args = [_][]const u8{ "general", "50" };
            _ = try executor.execute(ctx, .{ .exec = .{ .procedure = "chat_history", .args = &args } });
        }
        const t1 = nowNs();
        printRow("EXEC chat_history (limit=50 / 500 msgs)", iters, t1 - t0, "[scanPrefix + JSON build]");
    }

    // EXEC scan (limit 50 out of 2,000)
    {
        const iters: usize = 500;
        const t0 = nowNs();
        for (0..iters) |_| {
            _ = arena.reset(.retain_capacity);
            const ctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null };
            const args = [_][]const u8{ "item:", "50" };
            _ = try executor.execute(ctx, .{ .exec = .{ .procedure = "scan", .args = &args } });
        }
        const t1 = nowNs();
        printRow("EXEC scan (prefix='item:', limit=50 / 2k)", iters, t1 - t0, "[scanPrefix + JSON escape]");
    }

    // EXEC kv_stats
    {
        const iters: usize = 1000;
        const t0 = nowNs();
        for (0..iters) |_| {
            _ = arena.reset(.retain_capacity);
            const ctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null };
            const args = [_][]const u8{"item:"};
            _ = try executor.execute(ctx, .{ .exec = .{ .procedure = "kv_stats", .args = &args } });
        }
        const t1 = nowNs();
        printRow("EXEC kv_stats (prefix='item:', 2k keys)", iters, t1 - t0, "[countPrefix]");
    }
}
