const std = @import("std");
const wormdb = @import("wormdb");

const compat = wormdb.core.compat;
const Store = wormdb.storage.Store;
const Config = wormdb.core.config.Config;
const Sst = wormdb.storage.Sst;
const EventBus = wormdb.event.EventBus;
const wire = wormdb.protocol.wire;
const executor = wormdb.server.executor;
const distance = wormdb.vector.distance;
const rabitq = wormdb.vector.rabitq;
const Hnsw = wormdb.vector.Hnsw;
const NamespaceRegistry = wormdb.vector.NamespaceRegistry;
const Metric = wormdb.vector.Metric;
const topk_mod = wormdb.vector.topk;
const append_log = wormdb.proof.append_log;

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
    std.debug.print("  {s:<42} | {d:>10.1} ops/s | {d:>8.1} ns/op | {d:>7.2} ms {s}\n", .{
        name,
        ops_per_sec,
        ns_per_op,
        elapsed_ms,
        extra,
    });
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    std.debug.print("╔══════════════════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║                WormDB Comprehensive Engine Benchmark Suite                   ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════════════════════╝\n", .{});

    try benchKvStore(alloc);
    try benchMultiThreadedStore(alloc);
    try benchWalAndSnapshot(alloc);
    try benchWireAndExecutor(alloc);
    try benchEventBus(alloc);
    try benchVectorEngine(alloc);
    try benchProofAppendLog(alloc);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. KV Store Microbenchmarks (Sequential vs Random Insert, Overwrite, Read, Scan)
// ─────────────────────────────────────────────────────────────────────────────
fn benchKvStore(alloc: std.mem.Allocator) !void {
    printHeader("1. KV STORE (In-Memory .none Persistence, 256 Shards)");

    const N: usize = 50_000;
    const val_64: []const u8 = &@as([64]u8, @splat('v'));
    const val_512: []const u8 = &@as([512]u8, @splat('v'));
    const val_4096: []const u8 = &@as([4096]u8, @splat('v'));

    // Pre-generate sequential and random keys
    const seq_keys = try alloc.alloc([]u8, N);
    defer {
        for (seq_keys) |k| alloc.free(k);
        alloc.free(seq_keys);
    }
    const rand_keys = try alloc.alloc([]u8, N);
    defer {
        for (rand_keys) |k| alloc.free(k);
        alloc.free(rand_keys);
    }

    var prng = std.Random.DefaultPrng.init(0x12345678);
    const rand = prng.random();

    for (0..N) |i| {
        seq_keys[i] = try std.fmt.allocPrint(alloc, "key:seq:{d:0>8}", .{i});
        rand_keys[i] = try std.fmt.allocPrint(alloc, "key:rnd:{x:0>16}", .{rand.int(u64)});
    }

    // 1a. Sequential key insert (64B)
    {
        var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
        defer store.deinit();

        const t0 = nowNs();
        for (seq_keys) |k| {
            try store.set(k, val_64, false);
        }
        const t1 = nowNs();
        printRow("Store.set sequential keys (50k, 64B)", N, t1 - t0, "[tail append in shard.sorted]");
    }

    // 1b. Random key insert (64B) — exercises binary search + memmove in shard.sorted
    var store_rnd = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
    defer store_rnd.deinit();
    {
        const t0 = nowNs();
        for (rand_keys) |k| {
            try store_rnd.set(k, val_64, false);
        }
        const t1 = nowNs();
        printRow("Store.set random keys (50k, 64B)", N, t1 - t0, "[ordered insert in shard.sorted]");
    }

    // 1c. Overwrite existing keys (64B, 512B, 4096B)
    {
        const t0 = nowNs();
        for (rand_keys) |k| {
            try store_rnd.set(k, val_64, false);
        }
        const t1 = nowNs();
        printRow("Store.set overwrite existing (50k, 64B)", N, t1 - t0, "[alloc+replace+destroy old]");
    }
    {
        const t0 = nowNs();
        for (rand_keys) |k| {
            try store_rnd.set(k, val_512, false);
        }
        const t1 = nowNs();
        printRow("Store.set overwrite existing (50k, 512B)", N, t1 - t0, "");
    }
    {
        const t0 = nowNs();
        for (rand_keys) |k| {
            try store_rnd.set(k, val_4096, false);
        }
        const t1 = nowNs();
        printRow("Store.set overwrite existing (50k, 4KB)", N, t1 - t0, "");
    }

    // Restore 64B for read tests
    for (rand_keys) |k| try store_rnd.set(k, val_64, false);

    // 1d. Store.get (borrowed) vs Store.getValueDupe (allocated copy)
    {
        var sink: usize = 0;
        const t0 = nowNs();
        for (rand_keys) |k| {
            if (store_rnd.get(k)) |e| sink +%= e.value.len;
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Store.get hit (50k, 64B, zero-copy)", N, t1 - t0, "");
    }
    {
        var sink: usize = 0;
        const t0 = nowNs();
        for (rand_keys) |k| {
            if (try store_rnd.getValueDupe(k, alloc)) |v| {
                sink +%= v.len;
                alloc.free(v);
            }
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Store.getValueDupe hit (50k, 64B, heap)", N, t1 - t0, "");
    }
    {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var sink: usize = 0;
        const t0 = nowNs();
        for (rand_keys) |k| {
            _ = arena.reset(.retain_capacity);
            if (try store_rnd.getValueDupe(k, arena.allocator())) |v| {
                sink +%= v.len;
            }
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Store.getValueDupe hit (50k, 64B, arena)", N, t1 - t0, "");
    }
    {
        var sink: usize = 0;
        const t0 = nowNs();
        for (seq_keys) |k| { // seq_keys are not in store_rnd
            if (store_rnd.get(k)) |e| sink +%= e.value.len;
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Store.get miss (50k)", N, t1 - t0, "");
    }

    // 1e. Prefix scans on 50k store
    // Add 1,000 keys under "scan:1k:"
    for (0..1000) |i| {
        const k = try std.fmt.allocPrint(alloc, "scan:1k:{d:0>6}", .{i});
        defer alloc.free(k);
        try store_rnd.set(k, val_64, false);
    }

    {
        const iters: usize = 1000;
        var sink: usize = 0;
        const t0 = nowNs();
        for (0..iters) |_| {
            sink +%= store_rnd.countPrefix("scan:1k:");
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Store.countPrefix (1k matches / 51k keys)", iters, t1 - t0, "[256 shards binary search]");
    }
    {
        const iters: usize = 500;
        var sink: usize = 0;
        const Cb = struct {
            fn onMatch(ctx: *anyopaque, _: []const u8, val: []const u8, _: u64, _: bool) Store.ScanAction {
                const s: *usize = @ptrCast(@alignCast(ctx));
                s.* +%= val.len;
                return .cont;
            }
        };
        const t0 = nowNs();
        for (0..iters) |_| {
            store_rnd.scanPrefixCallback("scan:1k:", @ptrCast(&sink), Cb.onMatch);
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Store.scanPrefixCallback (1k matches)", iters, t1 - t0, "[zero-copy callback]");
    }
    {
        const iters: usize = 500;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var sink: usize = 0;
        const t0 = nowNs();
        for (0..iters) |_| {
            _ = arena.reset(.retain_capacity);
            const res = try store_rnd.scanPrefix("scan:1k:", 0, arena.allocator());
            sink +%= res.len;
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Store.scanPrefix alloc+sort (1k, limit=0)", iters, t1 - t0, "[dupe + heapsort 1k]");
    }
    {
        const iters: usize = 500;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var sink: usize = 0;
        const t0 = nowNs();
        for (0..iters) |_| {
            _ = arena.reset(.retain_capacity);
            const res = try store_rnd.scanPrefixFirst("scan:1k:", 20, arena.allocator());
            sink +%= res.len;
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Store.scanPrefixFirst (1k, limit=20)", iters, t1 - t0, "[per-shard cap + heapsort]");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Multi-threaded Concurrency Scaling
// ─────────────────────────────────────────────────────────────────────────────
fn benchMultiThreadedStore(alloc: std.mem.Allocator) !void {
    printHeader("2. MULTI-THREADED STORE SCALING (1, 2, 4, 8, 16 Threads)");

    const KEYSPACE: usize = 50_000;
    const OPS_TOTAL: usize = 200_000;
    const val_64: []const u8 = &@as([64]u8, @splat('v'));

    var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
    defer store.deinit();

    const keys = try alloc.alloc([]u8, KEYSPACE);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    for (0..KEYSPACE) |i| {
        keys[i] = try std.fmt.allocPrint(alloc, "mt:key:{d:0>8}", .{i});
        try store.set(keys[i], val_64, false);
    }

    const thread_counts = [_]usize{ 1, 2, 4, 8, 16 };

    // 2a. Concurrent Read-Only (Store.get)
    for (thread_counts) |tc| {
        const ops_per_thread = OPS_TOTAL / tc;
        const Worker = struct {
            fn run(s: *Store, ks: []const []u8, count: usize, tid: usize) void {
                var sink: usize = 0;
                var idx: usize = tid * 997;
                for (0..count) |_| {
                    const k = ks[idx % ks.len];
                    if (s.get(k)) |e| sink +%= e.value.len;
                    idx +%= 7919;
                }
                std.mem.doNotOptimizeAway(sink);
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
        const label = try std.fmt.bufPrint(&label_buf, "MT Store.get Read-Only ({d} threads)", .{tc});
        printRow(label, ops_per_thread * tc, t1 - t0, "");
    }

    // 2b. Concurrent Write-Only Overwrite (Store.set, 256 shards)
    for (thread_counts) |tc| {
        const ops_per_thread = OPS_TOTAL / tc;
        const Worker = struct {
            fn run(s: *Store, ks: []const []u8, count: usize, tid: usize) void {
                var idx: usize = tid * 997;
                for (0..count) |_| {
                    const k = ks[idx % ks.len];
                    s.set(k, val_64, false) catch {};
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
        const label = try std.fmt.bufPrint(&label_buf, "MT Store.set Overwrite 256-shard ({d} thr)", .{tc});
        printRow(label, ops_per_thread * tc, t1 - t0, "");
    }

    // 2c. Single Hot-Key Write Contention (8 threads all hitting 1 key)
    {
        const tc: usize = 8;
        const ops_per_thread = 50_000 / tc;
        const Worker = struct {
            fn run(s: *Store, k: []const u8, count: usize) void {
                for (0..count) |_| {
                    s.set(k, val_64, false) catch {};
                }
            }
        };
        const threads = try alloc.alloc(std.Thread, tc);
        defer alloc.free(threads);

        const t0 = nowNs();
        for (0..tc) |t| {
            threads[t] = try std.Thread.spawn(.{}, Worker.run, .{ &store, keys[0], ops_per_thread });
        }
        for (threads) |th| th.join();
        const t1 = nowNs();
        printRow("MT Store.set Hot-Key Contention (8 thr)", ops_per_thread * tc, t1 - t0, "[1 shard mutex]");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. WAL, Snapshot & SST Overlay Benchmarks
// ─────────────────────────────────────────────────────────────────────────────
fn benchWalAndSnapshot(alloc: std.mem.Allocator) !void {
    printHeader("3. PERSISTENCE: WAL, SNAPSHOT & SST OVERLAY");

    const tmp_dir = ".zig-cache/bench_data";
    try compat.Dir.makePath(compat.cwd(), tmp_dir);

    const run_id = nowNs();
    const wal_nosync_path = try std.fmt.allocPrint(alloc, "{s}/nosync_{d}.wal", .{ tmp_dir, run_id });
    defer alloc.free(wal_nosync_path);
    const snap_path = try std.fmt.allocPrint(alloc, "{s}.snapshot", .{wal_nosync_path});
    defer alloc.free(snap_path);
    const wal_bg_path = try std.fmt.allocPrint(alloc, "{s}/bg_{d}.wal", .{ tmp_dir, run_id });
    defer alloc.free(wal_bg_path);
    const sst_path = try std.fmt.allocPrint(alloc, "{s}/bench_{d}.wsst", .{ tmp_dir, run_id });
    defer alloc.free(sst_path);

    const N: usize = 20_000;
    const val_128: []const u8 = &@as([128]u8, @splat('v'));
    const keys = try alloc.alloc([]u8, N);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    for (0..N) |i| {
        keys[i] = try std.fmt.allocPrint(alloc, "wal:key:{d:0>8}", .{i});
    }

    const snap_bg_path = try std.fmt.allocPrint(alloc, "{s}.snapshot", .{wal_bg_path});
    defer alloc.free(snap_bg_path);

    // 3a. Full persistence, sync_writes=false (synchronous writeAll per SET, no fsync)
    {
        var store = try Store.init(alloc, .{
            .wal_path = wal_nosync_path,
            .snapshot_path = snap_path,
            .persistence = .full,
            .sync_writes = false,
            .max_wal_size = 0, // disable auto-compaction during bench
        });
        defer store.deinit();

        const t0 = nowNs();
        for (keys) |k| {
            try store.set(k, val_128, false);
        }
        const t1 = nowNs();
        printRow("Store.set (.full, sync=false, 20k, 128B)", N, t1 - t0, "[1 write syscall/op]");

        // 3b. Snapshot write (20k keys)
        const s0 = nowNs();
        try store.save();
        const s1 = nowNs();
        printRow("Store.save() Snapshot Write (20k keys)", N, s1 - s0, "[global sort + buffered write]");
    }

    // 3c. Snapshot + WAL load on startup
    {
        const t0 = nowNs();
        var store = try Store.init(alloc, .{
            .wal_path = wal_nosync_path,
            .snapshot_path = snap_path,
            .persistence = .full,
            .sync_writes = false,
            .max_wal_size = 0,
        });
        const t1 = nowNs();
        defer store.deinit();
        printRow("Store.init Snapshot+WAL Replay (20k)", N, t1 - t0, "[snapshot_arena + WAL replay]");
    }

    // 3d. SST build from snapshot + SST lookup speed
    {
        const b0 = nowNs();
        _ = try wormdb.storage.sst.buildFromSnapshot(alloc, snap_path, sst_path, 1700000000);
        const b1 = nowNs();
        printRow("Sst.buildFromSnapshot (20k keys)", N, b1 - b0, "");

        var sst = try Sst.open(alloc, sst_path);
        defer sst.close(alloc);

        var sink: usize = 0;
        const g0 = nowNs();
        for (keys) |k| {
            if (sst.get(k)) |hit| sink +%= hit.value.len;
        }
        const g1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("Sst.get binary search hit (20k keys)", N, g1 - g0, "[zero-alloc frozen lookup]");
    }

    // 3e. Full persistence, sync_writes=true with background WAL writer queue
    {
        var store = try Store.init(alloc, .{
            .wal_path = wal_bg_path,
            .snapshot_path = snap_bg_path,
            .persistence = .full,
            .sync_writes = true,
            .max_wal_size = 0,
        });
        defer store.deinit();
        try store.startBackgroundTasks();

        const n_bg: usize = 10_000;
        const t0 = nowNs();
        for (keys[0..n_bg]) |k| {
            try store.set(k, val_128, false);
        }
        const t1 = nowNs();
        printRow("Store.set (.full, bg writer, 10k, 128B)", n_bg, t1 - t0, "[ring enqueue + group fsync]");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Wire Protocol & Executor / Stored Procedures
// ─────────────────────────────────────────────────────────────────────────────
fn benchWireAndExecutor(alloc: std.mem.Allocator) !void {
    printHeader("4. PROTOCOL CODEC, EXECUTOR & STORED PROCEDURES");

    var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
    defer store.deinit();
    var bus = EventBus.init(alloc);
    defer bus.deinit();

    const N: usize = 100_000;

    // 4a. Wire encode + decode (readFrameZeroCopy vs readFrameAlloc)
    {
        var frame_buf: [512]u8 = undefined;
        const FixedWriter = struct {
            buf: []u8,
            pos: usize = 0,
            pub fn writeAll(self: *@This(), data: []const u8) !void {
                @memcpy(self.buf[self.pos..][0..data.len], data);
                self.pos += data.len;
            }
        };
        const FixedReader = struct {
            buf: []const u8,
            pos: usize = 0,
            pub fn read(self: *@This(), dest: []u8) !usize {
                const avail = self.buf.len - self.pos;
                const n = @min(avail, dest.len);
                @memcpy(dest[0..n], self.buf[self.pos..][0..n]);
                self.pos += n;
                return n;
            }
        };

        var fw = FixedWriter{ .buf = &frame_buf };
        try wire.writeCommand(&fw, .{ .set = .{ .key = "bench:key:0001", .value = &@as([128]u8, @splat('v')), .worm = false } });
        const encoded = frame_buf[0..fw.pos];

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var sink: usize = 0;

        const t0 = nowNs();
        for (0..N) |_| {
            _ = arena.reset(.retain_capacity);
            var fr = FixedReader{ .buf = encoded };
            const cmd = try wire.readFrameZeroCopy(&fr, arena.allocator());
            sink +%= cmd.set.value.len;
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("wire.readFrameZeroCopy (SET 128B)", N, t1 - t0, "[arena zero-copy slice]");

        const t2 = nowNs();
        for (0..N) |_| {
            var fr = FixedReader{ .buf = encoded };
            const cmd = try wire.readFrameAlloc(&fr, alloc);
            sink +%= cmd.set.value.len;
            wormdb.protocol.deinitCommand(alloc, cmd);
        }
        const t3 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("wire.readFrameAlloc+deinit (SET 128B)", N, t3 - t2, "[per-field heap dupe/free]");
    }

    // 4b. Executor dispatch: SET, GET, STATUS, EXEC increment, EXEC transfer
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    try store.set("acct:1", "10000000", false);
    try store.set("acct:2", "10000000", false);
    try store.set("counter:1", "0", false);

    {
        const t0 = nowNs();
        for (0..N) |_| {
            _ = arena.reset(.retain_capacity);
            const ctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null };
            const resp = try executor.execute(ctx, .{ .get = "acct:1" });
            std.mem.doNotOptimizeAway(resp);
        }
        const t1 = nowNs();
        printRow("executor.execute GET", N, t1 - t0, "");
    }
    {
        const t0 = nowNs();
        for (0..N) |_| {
            _ = arena.reset(.retain_capacity);
            const ctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null };
            const resp = try executor.execute(ctx, .{ .status = {} });
            std.mem.doNotOptimizeAway(resp);
        }
        const t1 = nowNs();
        printRow("executor.execute STATUS", N, t1 - t0, "[allocPrint 22 fields]");
    }
    {
        const args = [_][]const u8{ "counter:1", "1" };
        const t0 = nowNs();
        for (0..N) |_| {
            _ = arena.reset(.retain_capacity);
            const ctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null };
            const resp = try executor.execute(ctx, .{ .exec = .{ .procedure = "increment", .args = &args } });
            std.mem.doNotOptimizeAway(resp);
        }
        const t1 = nowNs();
        printRow("executor.execute EXEC increment", N, t1 - t0, "[1 shard lock + setUnsafe]");
    }
    {
        const args = [_][]const u8{ "acct:1", "acct:2", "1" };
        const t0 = nowNs();
        for (0..N) |_| {
            _ = arena.reset(.retain_capacity);
            const ctx = executor.ExecContext{ .allocator = arena.allocator(), .store = &store, .event_bus = &bus, .cluster = null };
            const resp = try executor.execute(ctx, .{ .exec = .{ .procedure = "transfer", .args = &args } });
            std.mem.doNotOptimizeAway(resp);
        }
        const t1 = nowNs();
        printRow("executor.execute EXEC transfer", N, t1 - t0, "[2 shard locks + 2 setUnsafe]");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. EventBus Pub/Sub Benchmarks
// ─────────────────────────────────────────────────────────────────────────────
fn benchEventBus(alloc: std.mem.Allocator) !void {
    printHeader("5. EVENT BUS PUB/SUB FANOUT & FILTERING");

    const N: usize = 100_000;
    var bus = EventBus.init(alloc);
    defer bus.deinit();

    var sink: usize = 0;
    const SubCb = struct {
        fn onWrite(ctx: *anyopaque, data: []const u8) void {
            const s: *usize = @ptrCast(@alignCast(ctx));
            s.* +%= data.len;
        }
    };

    // 5a. Publish to channel with 0 subscribers
    {
        const t0 = nowNs();
        for (0..N) |_| {
            try bus.publish("empty:chan", "{\"type\":\"tick\",\"ts\":1700000000}");
        }
        const t1 = nowNs();
        printRow("EventBus.publish (0 subscribers)", N, t1 - t0, "[shared lock lookup miss]");
    }

    // 5b. Publish to 1 unfiltered subscriber
    const sub1 = try bus.subscribe("feed:1", SubCb.onWrite, @ptrCast(&sink));
    {
        const t0 = nowNs();
        for (0..N) |_| {
            try bus.publish("feed:1", "{\"type\":\"tick\",\"ts\":1700000000}");
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("EventBus.publish (1 unfiltered sub)", N, t1 - t0, "[allocPrint + 1 delivery]");
    }
    bus.unsubscribe("feed:1", sub1);

    // 5c. Publish to 32 unfiltered subscribers
    var subs32: [32]u64 = undefined;
    for (0..32) |i| {
        subs32[i] = try bus.subscribe("feed:32", SubCb.onWrite, @ptrCast(&sink));
    }
    {
        const n32: usize = 50_000;
        const t0 = nowNs();
        for (0..n32) |_| {
            try bus.publish("feed:32", "{\"type\":\"tick\",\"ts\":1700000000}");
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("EventBus.publish (32 unfiltered subs)", n32, t1 - t0, "[1.6M total deliveries]");
    }
    for (subs32) |sid| bus.unsubscribe("feed:32", sid);

    // 5d. Publish to 16 filtered subscribers (JSON predicate evaluation)
    var subs_filt: [16]u64 = undefined;
    for (0..16) |i| {
        subs_filt[i] = try bus.subscribeFiltered("feed:filt", "type='tick'", SubCb.onWrite, @ptrCast(&sink));
    }
    {
        const n_filt: usize = 50_000;
        const t0 = nowNs();
        for (0..n_filt) |_| {
            try bus.publish("feed:filt", "{\"type\":\"tick\",\"score\":42,\"ts\":1700000000}");
        }
        const t1 = nowNs();
        std.mem.doNotOptimizeAway(sink);
        printRow("EventBus.publish (16 filtered subs)", n_filt, t1 - t0, "[ts scan + 16 predicate evals]");
    }
    for (subs_filt) |sid| bus.unsubscribe("feed:filt", sid);
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Vector Engine Benchmarks (SIMD Distance, BQ, RaBitQ, HNSW, VINSERT)
// ─────────────────────────────────────────────────────────────────────────────
fn benchVectorEngine(alloc: std.mem.Allocator) !void {
    printHeader("6. VECTOR ENGINE: SIMD DISTANCE, BQ, RABITQ & HNSW");

    const N_VEC: usize = 50_000;
    const dims = [_]usize{ 128, 384, 768, 1536 };

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    // 6a. SIMD Distance & Binary Quantization across dimensions
    for (dims) |dim| {
        const vec_mem = try alloc.alloc(f32, (N_VEC + 1) * dim);
        defer alloc.free(vec_mem);
        for (vec_mem) |*f| f.* = rand.floatNorm(f32);

        const bq_size = (dim + 7) / 8;
        const bq_mem = try alloc.alloc(u8, (N_VEC + 1) * bq_size);
        defer alloc.free(bq_mem);

        const q0 = nowNs();
        for (0..N_VEC + 1) |i| {
            const src: []align(1) const f32 = vec_mem[i * dim ..][0..dim];
            distance.binaryQuantize(src, bq_mem[i * bq_size ..][0..bq_size]);
        }
        const q1 = nowNs();

        const query_vec: []align(1) const f32 = vec_mem[0..dim];
        const query_bq = bq_mem[0..bq_size];

        // Cosine
        var sink_f: f32 = 0;
        const c0 = nowNs();
        for (1..N_VEC + 1) |i| {
            const v: []align(1) const f32 = vec_mem[i * dim ..][0..dim];
            sink_f += distance.cosine(query_vec, v);
        }
        const c1 = nowNs();
        std.mem.doNotOptimizeAway(sink_f);

        // L2 Squared
        const l0 = nowNs();
        for (1..N_VEC + 1) |i| {
            const v: []align(1) const f32 = vec_mem[i * dim ..][0..dim];
            sink_f += distance.l2Squared(query_vec, v);
        }
        const l1 = nowNs();
        std.mem.doNotOptimizeAway(sink_f);

        // Hamming
        var sink_u: u32 = 0;
        const h0 = nowNs();
        for (1..N_VEC + 1) |i| {
            const h = bq_mem[i * bq_size ..][0..bq_size];
            sink_u +%= distance.hamming(query_bq, h);
        }
        const h1 = nowNs();
        std.mem.doNotOptimizeAway(sink_u);

        var name_buf: [64]u8 = undefined;
        printRow(try std.fmt.bufPrint(&name_buf, "distance.cosine (dim={d})", .{dim}), N_VEC, c1 - c0, "");
        printRow(try std.fmt.bufPrint(&name_buf, "distance.l2Squared (dim={d})", .{dim}), N_VEC, l1 - l0, "");
        printRow(try std.fmt.bufPrint(&name_buf, "distance.binaryQuantize (dim={d})", .{dim}), N_VEC + 1, q1 - q0, "");
        printRow(try std.fmt.bufPrint(&name_buf, "distance.hamming (dim={d}, {d}B)", .{ dim, bq_size }), N_VEC, h1 - h0, "");
    }

    // 6b. RaBitQ Rotation + Encode + Estimate (dim=128)
    {
        const dim: usize = 128;
        const n_rbq: usize = 10_000;
        const vec_mem = try alloc.alloc(f32, (n_rbq + 1) * dim);
        defer alloc.free(vec_mem);
        for (vec_mem) |*f| f.* = rand.floatNorm(f32);

        const centroid = try alloc.alloc(f32, dim);
        defer alloc.free(centroid);
        @memset(centroid, 0.0);

        const r0 = nowNs();
        const rot = try rabitq.generateRotation(alloc, dim, 0xBEEF);
        const r1 = nowNs();
        defer alloc.free(rot);
        printRow("rabitq.generateRotation (dim=128)", 1, r1 - r0, "[Gram-Schmidt O(d^3)]");

        const params = rabitq.RabitqParams{
            .allocator = alloc,
            .centroid = centroid,
            .rotation = rot,
            .dim = @intCast(dim),
            .seed = 0xBEEF,
        };

        const enc_size = rabitq.encodedSize(dim);
        const enc_mem = try alloc.alloc(u8, n_rbq * enc_size);
        defer alloc.free(enc_mem);
        const residual = try alloc.alloc(f32, dim);
        defer alloc.free(residual);
        const rotated = try alloc.alloc(f32, dim);
        defer alloc.free(rotated);

        const e0 = nowNs();
        for (0..n_rbq) |i| {
            const v: []align(1) const f32 = vec_mem[i * dim ..][0..dim];
            const out_slice = enc_mem[i * enc_size ..][0..enc_size];
            const code_slice = out_slice[0..rabitq.codeBytes(dim)];
            const enc = rabitq.encode(v, &params, residual, rotated, code_slice);
            rabitq.serialize(enc, out_slice);
        }
        const e1 = nowNs();
        printRow("rabitq.encode (dim=128, 10k vecs)", n_rbq, e1 - e0, "[O(d^2) matmul per vec]");

        const q_vec: []align(1) const f32 = vec_mem[n_rbq * dim ..][0..dim];
        const q_rot_unit = try alloc.alloc(f32, dim);
        defer alloc.free(q_rot_unit);
        const q_prep = rabitq.prepareQuery(q_vec, &params, residual, q_rot_unit);

        var sink_est: f32 = 0;
        const s0 = nowNs();
        for (0..n_rbq) |i| {
            const out_slice = enc_mem[i * enc_size ..][0..enc_size];
            const enc = rabitq.parse(out_slice, dim).?;
            sink_est += rabitq.estimateL2Sq(q_rot_unit, q_prep, enc.code, enc.l2_norm, enc.corr);
        }
        const s1 = nowNs();
        std.mem.doNotOptimizeAway(sink_est);
        printRow("rabitq.estimateL2Sq (dim=128, 10k)", n_rbq, s1 - s0, "[inner-loop bit-dot]");
    }

    // 6c. HNSW Graph Build & Search (dim=128, N=5,000)
    {
        const dim: usize = 128;
        const n_hnsw: usize = 5_000;
        const vec_mem = try alloc.alloc(f32, (n_hnsw + 100) * dim);
        defer alloc.free(vec_mem);
        for (vec_mem) |*f| f.* = rand.floatNorm(f32);

        var hnsw = Hnsw.init(alloc, .{ .m = 16, .m_max0 = 32, .ef_construction = 100 });
        defer hnsw.deinit();

        const b0 = nowNs();
        for (0..n_hnsw) |i| {
            const v: []align(1) const f32 = vec_mem[i * dim ..][0..dim];
            _ = try hnsw.insert(v);
        }
        const b1 = nowNs();
        printRow("Hnsw.insert build (5k vecs, dim=128, ef=100)", n_hnsw, b1 - b0, "");

        const n_queries: usize = 100;
        var out_buf: [10]wormdb.vector.hnsw.SearchResult = undefined;
        for ([_]usize{ 50, 100, 200 }) |ef| {
            var sink_id: u32 = 0;
            const s0 = nowNs();
            for (0..n_queries) |q| {
                const qv: []align(1) const f32 = vec_mem[(n_hnsw + q) * dim ..][0..dim];
                const n_res = try hnsw.search(qv, 10, ef, &out_buf, null);
                if (n_res > 0) sink_id +%= out_buf[0].id;
            }
            const s1 = nowNs();
            std.mem.doNotOptimizeAway(sink_id);
            var label_buf: [64]u8 = undefined;
            printRow(try std.fmt.bufPrint(&label_buf, "Hnsw.search (N=5k, dim=128, k=10, ef={d})", .{ef}), n_queries, s1 - s0, "");
        }
    }

    // 6d. End-to-End applyVinsert vs applyVbulkinsert (dim=128, N=2,000)
    {
        const dim: usize = 128;
        const n_ins: usize = 2_000;
        const vec_bytes = try alloc.alloc(u8, n_ins * dim * 4);
        defer alloc.free(vec_bytes);
        rand.bytes(vec_bytes);

        var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
        defer store.deinit();
        var reg = NamespaceRegistry.init(alloc, .{});
        defer reg.deinit();
        var bus = EventBus.init(alloc);
        defer bus.deinit();

        const keys = try alloc.alloc([]u8, n_ins);
        defer {
            for (keys) |k| alloc.free(k);
            alloc.free(keys);
        }
        for (0..n_ins) |i| keys[i] = try std.fmt.allocPrint(alloc, "vec:single:{d}", .{i});

        const ctx = executor.ExecContext{
            .allocator = alloc,
            .store = &store,
            .event_bus = &bus,
            .cluster = null,
            .vector_registry = &reg,
        };

        const t0 = nowNs();
        for (0..n_ins) |i| {
            _ = try executor.execute(ctx, .{ .vinsert = .{
                .key = keys[i],
                .vector = vec_bytes[i * dim * 4 ..][0 .. dim * 4],
                .worm = false,
                .namespace = "vec:single:",
                .metric = "l2",
                .timestamp = 1700000000,
                .is_async = false,
            } });
        }
        const t1 = nowNs();
        printRow("executor VINSERT sync (2k, dim=128)", n_ins, t1 - t0, "[KV + meta + BQ + HNSW]");

        // Bulk insert
        const bulk_keys = try alloc.alloc([]u8, n_ins);
        defer {
            for (bulk_keys) |k| alloc.free(k);
            alloc.free(bulk_keys);
        }
        const bulk_items = try alloc.alloc(wormdb.core.types.Command.VbulkinsertParams.BulkItem, n_ins);
        defer alloc.free(bulk_items);
        for (0..n_ins) |i| {
            bulk_keys[i] = try std.fmt.allocPrint(alloc, "vec:bulk:{d}", .{i});
            bulk_items[i] = .{
                .key = bulk_keys[i],
                .vector = vec_bytes[i * dim * 4 ..][0 .. dim * 4],
                .timestamp = 1700000000,
            };
        }

        const b0 = nowNs();
        _ = try executor.execute(ctx, .{ .vbulkinsert = .{
            .namespace = "vec:bulk:",
            .metric = "l2",
            .worm = false,
            .is_async = false,
            .items = bulk_items,
        } });
        const b1 = nowNs();
        printRow("executor VBULKINSERT sync (2k, dim=128)", n_ins, b1 - b0, "[batched lock]");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Proof / Verifiable Append-Log Benchmarks
// ─────────────────────────────────────────────────────────────────────────────
fn benchProofAppendLog(alloc: std.mem.Allocator) !void {
    printHeader("7. PROOF SPINE: VERIFIABLE WORM APPEND-LOG & MMR");

    var store = try Store.init(alloc, .{ .persistence = .none, .sync_writes = false });
    defer store.deinit();

    const N: usize = 2_000;
    const payload = "audit-event-payload-0123456789abcdef0123456789abcdef";

    const t0 = nowNs();
    for (0..N) |_| {
        var res = try append_log.append(alloc, &store, "bench-log", payload, &.{}, .{ .ingest_time_ms = 1700000000 });
        res.deinit(alloc);
    }
    const t1 = nowNs();
    printRow("append_log.append (2k events, MMR state)", N, t1 - t0, "[state scan + SHA256 + MMR]");

    const v0 = nowNs();
    const report = try append_log.verifyStore(alloc, &store, "bench-log");
    const v1 = nowNs();
    std.mem.doNotOptimizeAway(report);
    printRow("append_log.verifyStore (2k events)", N, v1 - v0, "[scan + SHA256 chain verify]");
}
