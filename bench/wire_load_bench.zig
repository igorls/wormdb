//! Native WormWire load generator for end-to-end server benchmarking.
//!
//! Speaks the WormWire binary protocol (`WIRE_MAGIC` 0x57 0x57, frames
//! `[1B code][4B BE len][payload]`), reusing `wormdb.protocol.wire`.
//!
//! Supports N persistent TCP connections, M requests in flight per connection,
//! and GET / SET / EXEC transfer / mixed / STATUS workloads. Reports ops/s and
//! latency percentiles (p50, p95, p99).

const std = @import("std");
const wormdb = @import("wormdb");

const compat = wormdb.core.compat;
const wire = wormdb.protocol.wire;
const Command = wormdb.core.types.Command;
const Response = wormdb.core.types.Response;

const Workload = enum {
    read,
    write,
    mixed,
    status,
    exec_transfer,

    pub fn fromName(name: []const u8) ?Workload {
        if (std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "get")) return .read;
        if (std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "set")) return .write;
        if (std.mem.eql(u8, name, "mixed")) return .mixed;
        if (std.mem.eql(u8, name, "status")) return .status;
        if (std.mem.eql(u8, name, "exec-transfer") or std.mem.eql(u8, name, "exec_transfer") or std.mem.eql(u8, name, "transfer")) return .exec_transfer;
        return null;
    }

    pub fn label(self: Workload) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .mixed => "mixed",
            .status => "status",
            .exec_transfer => "exec-transfer",
        };
    }

    pub fn needsSeed(self: Workload) bool {
        return switch (self) {
            .read, .mixed, .exec_transfer => true,
            .write, .status => false,
        };
    }
};

const BenchOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6389,
    connections: usize = 8,
    inflight: usize = 16,
    total_ops: usize = 100_000,
    warmup_ops: usize = 5_000,
    keyspace: usize = 1_000,
    value_size: usize = 128,
    read_ratio: f64 = 0.8,
    key_prefix: []const u8 = "bench",
    bank_initial_balance: i64 = 100_000,
    bank_min_amount: i64 = 1,
    bank_max_amount: i64 = 1_000,
    timeout_ms: usize = 5_000,
};

fn nowNs() u64 {
    return @intCast(compat.nowNs());
}

const BufferedReader = struct {
    stream: *compat.net.Stream,
    timeout_ms: usize,
    buf: [16384]u8 = undefined,
    pos: usize = 0,
    end: usize = 0,

    pub fn read(self: *BufferedReader, dest: []u8) !usize {
        if (self.pos < self.end) {
            const avail = self.end - self.pos;
            const n = @min(avail, dest.len);
            @memcpy(dest[0..n], self.buf[self.pos .. self.pos + n]);
            self.pos += n;
            if (self.pos == self.end) {
                self.pos = 0;
                self.end = 0;
            }
            return n;
        }
        if (dest.len >= self.buf.len) {
            self.stream.beginRead(self.timeout_ms, false);
            return self.stream.read(dest);
        }
        self.stream.beginRead(self.timeout_ms, false);
        const n_read = try self.stream.read(&self.buf);
        if (n_read == 0) return 0;
        const n = @min(n_read, dest.len);
        @memcpy(dest[0..n], self.buf[0..n]);
        if (n < n_read) {
            self.pos = n;
            self.end = n_read;
        }
        return n;
    }
};

const BufferedWriter = struct {
    stream: *compat.net.Stream,
    buf: [16384]u8 = undefined,
    end: usize = 0,

    pub fn writeAll(self: *BufferedWriter, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            const space = self.buf.len - self.end;
            if (remaining.len >= space) {
                @memcpy(self.buf[self.end..][0..space], remaining[0..space]);
                self.end = self.buf.len;
                try self.flush();
                remaining = remaining[space..];
            } else {
                @memcpy(self.buf[self.end..][0..remaining.len], remaining);
                self.end += remaining.len;
                break;
            }
        }
    }

    pub fn flush(self: *BufferedWriter) !void {
        if (self.end > 0) {
            try self.stream.writeAll(self.buf[0..self.end]);
            self.end = 0;
        }
    }
};

/// Fast non-allocating response frame consumer using `wire.ResponseCode`.
/// Returns true if the operation succeeded (including business-level
/// `insufficient_funds` on `exec_transfer`), false on error response.
fn consumeResponse(reader: *BufferedReader, workload: Workload) !bool {
    var header: [5]u8 = undefined;
    try readExact(reader, &header);

    const code = try compat.intToEnum(wire.ResponseCode, header[0]);
    const payload_len: usize = @intCast(std.mem.readInt(u32, header[1..5], .big));
    if (payload_len > wormdb.core.types.MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

    switch (code) {
        .ok, .null_value => {
            if (payload_len != 0) return error.Corruption;
            return true;
        },
        .value => {
            try discardBytes(reader, payload_len);
            return true;
        },
        .err => {
            if (workload == .exec_transfer and payload_len == "insufficient_funds".len) {
                var msg_buf: ["insufficient_funds".len]u8 = undefined;
                try readExact(reader, &msg_buf);
                if (std.mem.eql(u8, &msg_buf, "insufficient_funds")) return true;
                return false;
            }
            try discardBytes(reader, payload_len);
            return false;
        },
        .event => {
            try discardBytes(reader, payload_len);
            return true;
        },
    }
}

fn readExact(reader: *BufferedReader, dest: []u8) !void {
    var off: usize = 0;
    while (off < dest.len) {
        const n = try reader.read(dest[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

fn discardBytes(reader: *BufferedReader, count: usize) !void {
    var remaining = count;
    var scratch: [1024]u8 = undefined;
    while (remaining > 0) {
        const chunk = @min(remaining, scratch.len);
        try readExact(reader, scratch[0..chunk]);
        remaining -= chunk;
    }
}

fn connectClient(addr: compat.net.Address, timeout_ms: usize) !compat.net.Stream {
    var stream = try compat.net.tcpConnectToAddress(addr);
    errdefer stream.close();
    compat.setNoDelay(stream.getHandle());
    compat.setSendTimeoutMs(stream.getHandle(), @intCast(@min(timeout_ms, std.math.maxInt(u32))));
    stream.write_timeout_ms = timeout_ms;
    try stream.writeAll(&wire.WIRE_MAGIC);
    return stream;
}

fn seedKeyspace(
    addr: compat.net.Address,
    opts: *const BenchOptions,
    keys: []const []const u8,
    val_payload: []const u8,
    workload: Workload,
) !void {
    var stream = try connectClient(addr, opts.timeout_ms);
    defer stream.close();

    var writer = BufferedWriter{ .stream = &stream };
    var reader = BufferedReader{ .stream = &stream, .timeout_ms = opts.timeout_ms };

    var bal_buf: [32]u8 = undefined;
    const seed_val: []const u8 = if (workload == .exec_transfer)
        try std.fmt.bufPrint(&bal_buf, "{d}", .{opts.bank_initial_balance})
    else
        val_payload;

    const batch_size: usize = 64;
    var i: usize = 0;
    while (i < keys.len) {
        const end = @min(i + batch_size, keys.len);
        for (keys[i..end]) |k| {
            try wire.writeCommand(&writer, .{ .set = .{
                .key = k,
                .value = seed_val,
                .worm = false,
            } });
        }
        try writer.flush();
        for (i..end) |_| {
            const ok = try consumeResponse(&reader, .write);
            if (!ok) return error.SeedFailed;
        }
        i = end;
    }
}

const WorkerShared = struct {
    opts: *const BenchOptions,
    workload: Workload,
    keys: []const []const u8,
    val_payload: []const u8,
    op_counter: std.atomic.Value(usize),
    total_ops: usize,
    measure_latency: bool,
    latencies_ns: []u64,
    succeeded: std.atomic.Value(usize),
    failed: std.atomic.Value(usize),
    /// Set when a connection hit a transport error. Its stream position is
    /// unknown afterwards, so the run cannot continue on it.
    broken: std.atomic.Value(bool),
};

const WorkerArgs = struct {
    worker_id: usize,
    stream: *compat.net.Stream,
    shared: *WorkerShared,
};

fn writeWorkloadCommand(
    writer: *BufferedWriter,
    rng: std.Random,
    shared: *const WorkerShared,
    amt_buf: *[32]u8,
) !void {
    const keys = shared.keys;
    const ks = keys.len;
    switch (shared.workload) {
        .read => {
            const k = keys[rng.uintLessThan(usize, ks)];
            try wire.writeCommand(writer, .{ .get = k });
        },
        .write => {
            const k = keys[rng.uintLessThan(usize, ks)];
            try wire.writeCommand(writer, .{ .set = .{
                .key = k,
                .value = shared.val_payload,
                .worm = false,
            } });
        },
        .mixed => {
            const k = keys[rng.uintLessThan(usize, ks)];
            const is_read = rng.float(f64) < shared.opts.read_ratio;
            if (is_read) {
                try wire.writeCommand(writer, .{ .get = k });
            } else {
                try wire.writeCommand(writer, .{ .set = .{
                    .key = k,
                    .value = shared.val_payload,
                    .worm = false,
                } });
            }
        },
        .status => {
            try wire.writeCommand(writer, .{ .status = {} });
        },
        .exec_transfer => {
            const from_idx = rng.uintLessThan(usize, ks);
            var to_idx = rng.uintLessThan(usize, ks);
            if (to_idx == from_idx and ks > 1) {
                to_idx = (from_idx + 1 + rng.uintLessThan(usize, ks - 1)) % ks;
            }
            const min_amt = shared.opts.bank_min_amount;
            const max_amt = shared.opts.bank_max_amount;
            const amt: i64 = if (max_amt <= min_amt)
                min_amt
            else
                min_amt + @as(i64, @intCast(rng.uintLessThan(u64, @intCast(max_amt - min_amt + 1))));

            const amt_str = try std.fmt.bufPrint(amt_buf, "{d}", .{amt});
            const args = [_][]const u8{ keys[from_idx], keys[to_idx], amt_str };
            try wire.writeCommand(writer, .{ .exec = .{
                .procedure = "transfer",
                .args = &args,
            } });
        },
    }
}

fn workerMain(wargs: WorkerArgs) void {
    const shared = wargs.shared;
    const inflight = @max(@as(usize, 1), shared.opts.inflight);

    var writer = BufferedWriter{ .stream = wargs.stream };
    var reader = BufferedReader{ .stream = wargs.stream, .timeout_ms = shared.opts.timeout_ms };

    var prng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15 ^ (@as(u64, wargs.worker_id) *% 0xBF58476D1CE4E5B9) ^ nowNs());
    const rng = prng.random();

    var ring_buf_stack: [256]struct { op_idx: usize, start_ns: u64 } = undefined;
    const ring_cap = @min(inflight, ring_buf_stack.len);
    var ring_head: usize = 0;
    var ring_tail: usize = 0;
    var ring_count: usize = 0;

    var local_succeeded: usize = 0;
    var local_failed: usize = 0;
    var amt_buf: [32]u8 = undefined;

    // Fill initial pipeline up to `ring_cap`
    while (ring_count < ring_cap) {
        const op_idx = shared.op_counter.fetchAdd(1, .monotonic);
        if (op_idx >= shared.total_ops) break;

        const t_start = if (shared.measure_latency) nowNs() else 0;
        writeWorkloadCommand(&writer, rng, shared, &amt_buf) catch {
            local_failed += 1;
            break;
        };
        ring_buf_stack[ring_tail] = .{ .op_idx = op_idx, .start_ns = t_start };
        ring_tail = (ring_tail + 1) % ring_cap;
        ring_count += 1;
    }
    writer.flush() catch {
        local_failed += ring_count;
        ring_count = 0;
        shared.broken.store(true, .monotonic);
    };

    while (ring_count > 0) {
        const slot = ring_buf_stack[ring_head];
        ring_head = (ring_head + 1) % ring_cap;
        ring_count -= 1;

        const ok = consumeResponse(&reader, shared.workload) catch {
            // Transport or framing error: the stream is out of sync, so every
            // request still in flight on it is lost.
            local_failed += ring_count + 1;
            shared.broken.store(true, .monotonic);
            break;
        };
        if (shared.measure_latency) {
            const elapsed = nowNs() -| slot.start_ns;
            shared.latencies_ns[slot.op_idx] = elapsed;
        }
        if (ok) {
            local_succeeded += 1;
        } else {
            local_failed += 1;
        }

        // Issue replacement request to keep pipeline full
        const next_idx = shared.op_counter.fetchAdd(1, .monotonic);
        if (next_idx < shared.total_ops) {
            const t_start = if (shared.measure_latency) nowNs() else 0;
            if (writeWorkloadCommand(&writer, rng, shared, &amt_buf)) |_| {
                writer.flush() catch {
                    local_failed += ring_count + 1;
                    shared.broken.store(true, .monotonic);
                    break;
                };
                ring_buf_stack[ring_tail] = .{ .op_idx = next_idx, .start_ns = t_start };
                ring_tail = (ring_tail + 1) % ring_cap;
                ring_count += 1;
            } else |_| {
                local_failed += 1;
            }
        }
    }

    _ = shared.succeeded.fetchAdd(local_succeeded, .monotonic);
    _ = shared.failed.fetchAdd(local_failed, .monotonic);
}

fn runPhase(
    alloc: std.mem.Allocator,
    streams: []compat.net.Stream,
    opts: *const BenchOptions,
    workload: Workload,
    keys: []const []const u8,
    val_payload: []const u8,
    op_count: usize,
    measure_latency: bool,
    latencies_ns: []u64,
) !struct { succeeded: usize, failed: usize, elapsed_ns: u64, broken: bool } {
    var shared = WorkerShared{
        .opts = opts,
        .workload = workload,
        .keys = keys,
        .val_payload = val_payload,
        .op_counter = std.atomic.Value(usize).init(0),
        .total_ops = op_count,
        .measure_latency = measure_latency,
        .latencies_ns = latencies_ns,
        .succeeded = std.atomic.Value(usize).init(0),
        .failed = std.atomic.Value(usize).init(0),
        .broken = std.atomic.Value(bool).init(false),
    };

    const threads = try alloc.alloc(std.Thread, streams.len);
    defer alloc.free(threads);

    const t0 = nowNs();
    for (streams, 0..) |*s, idx| {
        threads[idx] = try std.Thread.spawn(.{}, workerMain, .{WorkerArgs{
            .worker_id = idx,
            .stream = s,
            .shared = &shared,
        }});
    }
    for (threads) |t| t.join();
    const t1 = nowNs();

    return .{
        .succeeded = shared.succeeded.load(.monotonic),
        .failed = shared.failed.load(.monotonic),
        .elapsed_ns = t1 -| t0,
        .broken = shared.broken.load(.monotonic),
    };
}

fn percentileNs(sorted_ns: []const u64, p: f64) f64 {
    if (sorted_ns.len == 0) return 0.0;
    const f_idx = @ceil((p / 100.0) * @as(f64, @floatFromInt(sorted_ns.len))) - 1.0;
    const idx: usize = if (f_idx <= 0.0) 0 else @min(sorted_ns.len - 1, @as(usize, @intFromFloat(f_idx)));
    return @as(f64, @floatFromInt(sorted_ns[idx])) / 1_000_000.0;
}

fn printStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    compat.File.writeAll(compat.File.stdout(), slice) catch {};
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.c_allocator;

    var opts = BenchOptions{};
    var workloads_buf: [16]Workload = undefined;
    var workloads_len: usize = 0;

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.host = argv[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.port = try std.fmt.parseInt(u16, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--connections") or std.mem.eql(u8, arg, "--concurrency") or std.mem.eql(u8, arg, "--pool-size")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.connections = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--inflight")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.inflight = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--ops")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.total_ops = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--warmup-ops")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.warmup_ops = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--keyspace")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.keyspace = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--value-size")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.value_size = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--read-ratio")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.read_ratio = try std.fmt.parseFloat(f64, argv[i]);
        } else if (std.mem.eql(u8, arg, "--key-prefix")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.key_prefix = argv[i];
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            opts.timeout_ms = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, arg, "--tests") or std.mem.eql(u8, arg, "--test")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgs;
            var it = std.mem.splitScalar(u8, argv[i], ',');
            while (it.next()) |raw| {
                const trimmed = std.mem.trim(u8, raw, " \t");
                if (trimmed.len == 0) continue;
                const wl = Workload.fromName(trimmed) orelse return error.UnknownWorkload;
                if (workloads_len < workloads_buf.len) {
                    workloads_buf[workloads_len] = wl;
                    workloads_len += 1;
                }
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printStdout(
                \\WormDB Native WormWire Load Generator
                \\
                \\Usage:
                \\  wire_load_bench [options]
                \\
                \\Options:
                \\  --host <ip>           Target host (default: 127.0.0.1)
                \\  --port <port>         Target port (default: 6389)
                \\  --connections <n>     Number of TCP connections (alias: --concurrency, --pool-size)
                \\  --inflight <m>        Max in-flight requests per connection (default: 16)
                \\  --ops <n>             Total measured operations per test (default: 100000)
                \\  --warmup-ops <n>      Warmup operations per test (default: 5000)
                \\  --keyspace <n>        Keyspace size (default: 1000)
                \\  --value-size <bytes>  Value size for SET (default: 128)
                \\  --tests <a,b,c>       Comma-separated tests: read,write,mixed,status,exec-transfer
                \\  --timeout-ms <ms>     Per-read and per-write socket timeout (default: 5000)
                \\
            , .{});
            return;
        }
    }

    if (workloads_len == 0) {
        workloads_buf[0] = .read;
        workloads_buf[1] = .write;
        workloads_buf[2] = .exec_transfer;
        workloads_len = 3;
    }
    const workloads = workloads_buf[0..workloads_len];

    const addr = try compat.net.Address.parseIp(opts.host, opts.port);

    // Pre-allocate keyspace strings
    const keys = try alloc.alloc([]u8, opts.keyspace);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }
    for (0..opts.keyspace) |k_idx| {
        keys[k_idx] = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ opts.key_prefix, k_idx });
    }

    const val_payload = try alloc.alloc(u8, opts.value_size);
    defer alloc.free(val_payload);
    @memset(val_payload, 'v');

    // Open persistent connections
    const streams = try alloc.alloc(compat.net.Stream, opts.connections);
    var opened: usize = 0;
    defer {
        for (streams[0..opened]) |*s| s.close();
        alloc.free(streams);
    }
    for (0..opts.connections) |c_idx| {
        streams[c_idx] = try connectClient(addr, opts.timeout_ms);
        opened += 1;
    }

    const latencies_ns = try alloc.alloc(u64, opts.total_ops);
    defer alloc.free(latencies_ns);

    printStdout("WormDB native WormWire load generator\n", .{});
    printStdout("target        : {s}:{d}\n", .{ opts.host, opts.port });
    printStdout("connections   : {d}\n", .{opts.connections});
    printStdout("inflight      : {d}\n", .{opts.inflight});
    printStdout("ops/test      : {d}\n", .{opts.total_ops});

    var total_failed: usize = 0;
    for (workloads) |wl| {
        if (wl.needsSeed()) {
            try seedKeyspace(addr, &opts, keys, val_payload, wl);
        }

        if (opts.warmup_ops > 0) {
            const warm = try runPhase(alloc, streams, &opts, wl, keys, val_payload, opts.warmup_ops, false, &.{});
            if (warm.broken) return error.ConnectionBroken;
        }

        @memset(latencies_ns, 0);
        const res = try runPhase(alloc, streams, &opts, wl, keys, val_payload, opts.total_ops, true, latencies_ns);

        const elapsed_ms = @as(f64, @floatFromInt(res.elapsed_ns)) / 1_000_000.0;
        const ops_per_sec = if (res.elapsed_ns > 0)
            (@as(f64, @floatFromInt(res.succeeded)) / @as(f64, @floatFromInt(res.elapsed_ns))) * 1_000_000_000.0
        else
            0.0;

        var sum_ns: u128 = 0;
        for (latencies_ns) |l| sum_ns += l;
        const avg_ms = if (latencies_ns.len > 0)
            (@as(f64, @floatFromInt(sum_ns)) / @as(f64, @floatFromInt(latencies_ns.len))) / 1_000_000.0
        else
            0.0;

        std.mem.sort(u64, latencies_ns, {}, std.sort.asc(u64));
        const p50_ms = percentileNs(latencies_ns, 50.0);
        const p95_ms = percentileNs(latencies_ns, 95.0);
        const p99_ms = percentileNs(latencies_ns, 99.0);

        printStdout("\nResults\n", .{});
        printStdout("test          : {s}\n", .{wl.label()});
        printStdout("attempted     : {d}\n", .{opts.total_ops});
        printStdout("succeeded     : {d}\n", .{res.succeeded});
        printStdout("failed        : {d}\n", .{res.failed});
        printStdout("elapsed_ms    : {d:.2}\n", .{elapsed_ms});
        printStdout("ops/sec       : {d:.2}\n", .{ops_per_sec});
        printStdout("lat_avg_ms    : {d:.3}\n", .{avg_ms});
        printStdout("lat_p50_ms    : {d:.3}\n", .{p50_ms});
        printStdout("lat_p95_ms    : {d:.3}\n", .{p95_ms});
        printStdout("lat_p99_ms    : {d:.3}\n", .{p99_ms});

        total_failed += res.failed;
        if (res.broken) return error.ConnectionBroken;
    }

    // A run with failures is not comparable to a clean one; make that visible
    // to scripts that only check the exit status.
    if (total_failed > 0) return error.OperationsFailed;
}
