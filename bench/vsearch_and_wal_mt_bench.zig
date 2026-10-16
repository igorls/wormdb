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

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    try benchMtWalContention(alloc);
    try benchVsearchModes(alloc);
    try benchProceduresSuite(alloc);
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
