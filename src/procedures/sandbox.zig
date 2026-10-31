//! Sandboxed procedures: EXEC entry points that run a scope's law, a wasm module installed at
//! runtime, instead of code compiled into the binary.
//!
//!   EXEC sandbox_install <scope> <module>          install the scope's law; returns its sha256
//!   EXEC sandbox_call    <scope> <entry> [args...]  run one of the law's exports
//!   EXEC sandbox_replay  <scope>                    re-run the scope's call log and compare
//!
//! A scope is a key prefix. A law reads and writes only keys under it: every key it names is
//! relative and the host prepends the scope. Scopes may not nest and may not start with `sbx:`.
//!
//! A call's writes go to an overlay and are committed only when the call ends cleanly; a trap,
//! running out of fuel or the law's own `fail` leaves the store as it was. Each committed call
//! appends a WORM record to the scope's log (module hash, entry, args, digest of its writes) and
//! moves a hash chain forward. `sandbox_replay` re-runs the log against an empty scratch store and
//! checks every call's writes, the chain, and finally that the live scope holds exactly what the
//! law produced — naming the first call or key where it does not.
//!
//! Spike limits, by design for now: calls are serialized by one process-wide lock (one total order,
//! which replay needs anyway); a scope is assumed empty before its first call; the log record, the
//! writes and the head are separate durable writes, so a crash between them shows up as a replay
//! mismatch rather than being prevented; modules are decoded on every call.
//!
//! Keys (id = hex of the first 16 bytes of sha256(scope)):
//!   sbx:mod:<sha256>      the module bytes, WORM, content-addressed
//!   sbx:scope:<id>        the scope
//!   sbx:law:<id>          hex sha256 of the scope's current law
//!   sbx:log:<id>:<seq>    one WORM record per committed call, seq zero-padded, from 1
//!   sbx:head:<id>         "<seq> <chain hex>"

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const compat = @import("../core/compat.zig");
const Config = @import("../core/config.zig").Config;
const Store = @import("../storage/store.zig").Store;
const sandbox = @import("../sandbox/mod.zig");
const module = sandbox.module;
const interp = sandbox.interp;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const fuel_per_call: u64 = 10_000_000;
const max_key = 512;
const max_value = 64 * 1024;
const max_writes = 4096;
const max_log = 1_000_000;
const max_state = 1_000_000;
const minus_one: u64 = 0xFFFF_FFFF; // -1 as an i32
/// Host calls cost 100 fuel plus one per this many bytes they move, so a call can make the host
/// read or copy at most fuel_per_call * bytes_per_fuel bytes.
const bytes_per_fuel = 2;

/// One order for every sandboxed call in the process.
var lock: compat.Mutex = .{};

/// The VM's memory and stacks are big and short-lived; everything else lives in a per-call arena.
const vm_allocator = std.heap.page_allocator;

pub fn installExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const scope = ctx.arg(0) orelse return ctx.err("usage: sandbox_install <scope> <module>");
    const raw = ctx.arg(1) orelse return ctx.err("usage: sandbox_install <scope> <module>");
    if (scopeProblem(scope)) |msg| return ctx.err(msg);
    if (!ctx.permits(.set, scope)) return ctx.err("permission denied: installing a law needs write access to its scope");

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = if (std.mem.startsWith(u8, raw, "\x00asm")) raw else hexDecode(arena, raw) orelse
        return ctx.err("module must be wasm bytes or their hex");
    var m = module.decode(vm_allocator, bytes, .{}) catch |e|
        return ctx.err(try std.fmt.allocPrint(arena, "invalid module: {s}", .{@errorName(e)}));
    m.deinit();
    var hash: [32]u8 = undefined;
    Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    const id = scopeId(scope);

    lock.lock();
    defer lock.unlock();
    for (try ctx.store.scanPrefixFirst("sbx:scope:", max_state, arena)) |other| {
        if (std.mem.eql(u8, other.value, scope)) continue;
        if (std.mem.startsWith(u8, other.value, scope) or std.mem.startsWith(u8, scope, other.value))
            return ctx.err(try std.fmt.allocPrint(arena, "scope overlaps the scope '{s}'", .{other.value}));
    }
    const mod_key = try std.fmt.allocPrint(arena, "sbx:mod:{s}", .{&hex});
    if (try ctx.store.getValueDupe(mod_key, arena) == null) try ctx.setDurableWorm(mod_key, bytes);
    try ctx.setDurable(try std.fmt.allocPrint(arena, "sbx:scope:{s}", .{&id}), scope);
    try ctx.setDurable(try std.fmt.allocPrint(arena, "sbx:law:{s}", .{&id}), &hex);
    return ctx.value(&hex);
}

pub fn callExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const scope = ctx.arg(0) orelse return ctx.err("usage: sandbox_call <scope> <entry> [args...]");
    const entry = ctx.arg(1) orelse return ctx.err("usage: sandbox_call <scope> <entry> [args...]");
    const args = ctx.args[2..];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = scopeId(scope);

    lock.lock();
    defer lock.unlock();
    const law_hex = try ctx.store.getValueDupe(try std.fmt.allocPrint(arena, "sbx:law:{s}", .{&id}), arena) orelse
        return ctx.err("no law is installed for this scope");
    var law_hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&law_hash, law_hex) catch return ctx.err("corrupt law pointer");
    var m = try loadModule(ctx.store, arena, law_hex) orelse return ctx.err("the scope's law module is missing or invalid");
    defer m.deinit();

    var run = Run{ .arena = arena, .store = ctx.store, .scope = scope, .args = args };
    _ = interp.call(vm_allocator, &m, entry, run.host(), .{ .fuel = fuel_per_call }) catch |e| return switch (e) {
        error.LawFailed => ctx.err(try std.fmt.allocPrint(arena, "law_failed: {s}", .{run.fail_msg})),
        else => ctx.err(try std.fmt.allocPrint(arena, "law_trapped: {s}", .{@errorName(e)})),
    };

    // Committed in this order: the log record, the writes, the head. See the file comment.
    const writes = try run.sortedWrites();
    const record = try encodeRecord(arena, law_hash, entry, args, digestWrites(writes));
    const head = try readHead(ctx.store, arena, &id);
    const chain = nextChain(head.chain, record);
    const seq = head.seq + 1;
    try ctx.setDurableWorm(try logKey(arena, &id, seq), try std.mem.concat(arena, u8, &.{ record, &chain }));
    for (writes) |w| {
        if (w.value) |v| try ctx.setDurable(w.key, v) else try ctx.deleteDurable(w.key);
    }
    const chain_hex = std.fmt.bytesToHex(chain, .lower);
    try ctx.setDurable(try std.fmt.allocPrint(arena, "sbx:head:{s}", .{&id}), try std.fmt.allocPrint(arena, "{d} {s}", .{ seq, &chain_hex }));
    return ctx.value(run.ret);
}

pub fn replayExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const scope = ctx.arg(0) orelse return ctx.err("usage: sandbox_replay <scope>");
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const id = scopeId(scope);

    lock.lock();
    defer lock.unlock();
    var scratch = try Store.init(arena, Config{ .persistence = .none });
    defer scratch.deinit();

    var modules: std.StringHashMapUnmanaged(module.Module) = .empty;
    defer {
        var it = modules.valueIterator();
        while (it.next()) |m| m.deinit();
    }

    const log_prefix = try std.fmt.allocPrint(arena, "sbx:log:{s}:", .{&id});
    const records = try ctx.store.scanPrefixFirst(log_prefix, max_log, arena);
    var chain: [32]u8 = @splat(0);
    for (records, 1..) |stored, seq| {
        if (!std.mem.eql(u8, stored.key, try logKey(arena, &id, seq)))
            return ctx.err(try std.fmt.allocPrint(arena, "log broken at {d}: a record is missing", .{seq}));
        const rec = parseRecord(arena, stored.value) orelse
            return ctx.err(try std.fmt.allocPrint(arena, "log broken at {d}: unreadable record", .{seq}));
        const law_hex = std.fmt.bytesToHex(rec.law_hash, .lower);
        const gop = try modules.getOrPut(arena, try arena.dupe(u8, &law_hex));
        if (!gop.found_existing) {
            gop.value_ptr.* = try loadModule(ctx.store, arena, &law_hex) orelse {
                _ = modules.remove(&law_hex);
                return ctx.err(try std.fmt.allocPrint(arena, "log broken at {d}: its law module is missing", .{seq}));
            };
        }

        var run = Run{ .arena = arena, .store = &scratch, .scope = scope, .args = rec.args };
        _ = interp.call(vm_allocator, gop.value_ptr, rec.entry, run.host(), .{ .fuel = fuel_per_call }) catch |e|
            return ctx.err(try std.fmt.allocPrint(arena, "diverged at {d}: the call now ends in {s}", .{ seq, @errorName(e) }));
        const writes = try run.sortedWrites();
        if (!std.mem.eql(u8, &digestWrites(writes), &rec.writes_digest))
            return ctx.err(try std.fmt.allocPrint(arena, "diverged at {d}: the call writes something else", .{seq}));
        for (writes) |w| {
            if (w.value) |v| try scratch.set(w.key, v, false) else try scratch.delete(w.key);
        }
        chain = nextChain(chain, rec.body);
        if (!std.mem.eql(u8, &chain, &rec.chain))
            return ctx.err(try std.fmt.allocPrint(arena, "log broken at {d}: the hash chain does not link", .{seq}));
    }

    const head = try readHead(ctx.store, arena, &id);
    if (head.seq != records.len or !std.mem.eql(u8, &head.chain, &chain))
        return ctx.err("the head does not match the log");

    const live = try ctx.store.scanPrefixFirst(scope, max_state, arena);
    const replayed = try scratch.scanPrefixFirst(scope, max_state, arena);
    for (0..@max(live.len, replayed.len)) |i| {
        const a: ?Store.ScanResult = if (i < live.len) live[i] else null;
        const b: ?Store.ScanResult = if (i < replayed.len) replayed[i] else null;
        if (a != null and b != null and std.mem.eql(u8, a.?.key, b.?.key) and std.mem.eql(u8, a.?.value, b.?.value)) continue;
        const key = if (a != null and (b == null or std.mem.order(u8, a.?.key, b.?.key) != .gt)) a.?.key else b.?.key;
        return ctx.err(try std.fmt.allocPrint(arena, "state differs from the law at '{s}'", .{key}));
    }
    const chain_hex = std.fmt.bytesToHex(chain, .lower);
    return ctx.value(try std.fmt.allocPrint(arena, "ok {d} {s}", .{ records.len, &chain_hex }));
}

/// The host side of one call: reads see the call's own writes first, then the store.
const Run = struct {
    arena: std.mem.Allocator,
    store: *Store,
    scope: []const u8,
    args: []const []const u8,
    writes: std.StringHashMapUnmanaged(?[]const u8) = .empty,
    ret: []const u8 = "",
    fail_msg: []const u8 = "",
    /// Keys for reads are built here, so reading in a loop allocates nothing.
    key_buf: [256 + max_key]u8 = undefined,

    const Write = struct { key: []const u8, value: ?[]const u8 };

    fn host(self: *Run) interp.Host {
        return .{ .ptr = self, .call = call };
    }

    fn call(ptr: *anyopaque, f: module.HostFn, a: []const u64, mem: []u8, fuel: *u64) interp.Trap!u64 {
        const self: *Run = @ptrCast(@alignCast(ptr));
        try interp.charge(fuel, 100);
        switch (f) {
            .arg_count => return self.args.len,
            .arg => {
                if (a[0] >= self.args.len) return minus_one;
                return copyOut(self.args[@intCast(a[0])], mem, a[1], a[2], fuel);
            },
            .get => {
                const key = try self.readKey(mem, a[0], a[1]) orelse return minus_one;
                const val = try self.read(key) orelse return minus_one;
                return copyOut(val, mem, a[2], a[3], fuel);
            },
            .set => {
                const key = try self.readKey(mem, a[0], a[1]) orelse return minus_one;
                const val = try slice(mem, a[2], a[3]);
                if (val.len > max_value) return minus_one;
                if (self.writes.count() >= max_writes and !self.writes.contains(key)) return minus_one;
                try interp.charge(fuel, (key.len + val.len) / bytes_per_fuel);
                try self.writes.put(self.arena, try self.arena.dupe(u8, key), try self.arena.dupe(u8, val));
                return 0;
            },
            .del => {
                const key = try self.readKey(mem, a[0], a[1]) orelse return minus_one;
                if (self.writes.count() >= max_writes and !self.writes.contains(key)) return minus_one;
                try interp.charge(fuel, key.len / bytes_per_fuel);
                try self.writes.put(self.arena, try self.arena.dupe(u8, key), null);
                return 0;
            },
            .ret => {
                const val = try slice(mem, a[0], a[1]);
                if (val.len > max_value) return error.LawFailed;
                try interp.charge(fuel, val.len / bytes_per_fuel);
                self.ret = try self.arena.dupe(u8, val);
                return 0;
            },
            .fail => {
                const msg = try slice(mem, a[0], a[1]);
                self.fail_msg = try self.arena.dupe(u8, msg[0..@min(msg.len, 256)]);
                return error.LawFailed;
            },
        }
    }

    /// The scope plus the key the law named, in `key_buf` (valid until the next host call), or
    /// null when that key is too long.
    fn readKey(self: *Run, mem: []u8, ptr: u64, len: u64) interp.Trap!?[]const u8 {
        const rel = try slice(mem, ptr, len);
        if (rel.len > max_key or self.scope.len + rel.len > self.key_buf.len) return null;
        @memcpy(self.key_buf[0..self.scope.len], self.scope);
        @memcpy(self.key_buf[self.scope.len..][0..rel.len], rel);
        return self.key_buf[0 .. self.scope.len + rel.len];
    }

    fn read(self: *Run, key: []const u8) interp.Trap!?[]const u8 {
        if (self.writes.get(key)) |pending| return pending;
        return self.store.getValueDupe(key, self.arena) catch return error.OutOfMemory;
    }

    fn sortedWrites(self: *Run) ![]Write {
        const out = try self.arena.alloc(Write, self.writes.count());
        var it = self.writes.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) out[i] = .{ .key = e.key_ptr.*, .value = e.value_ptr.* };
        std.mem.sort(Write, out, {}, struct {
            fn lessThan(_: void, x: Write, y: Write) bool {
                return std.mem.order(u8, x.key, y.key) == .lt;
            }
        }.lessThan);
        return out;
    }
};

fn slice(mem: []u8, ptr: u64, len: u64) interp.Trap![]u8 {
    const p: u32 = @truncate(ptr);
    const n: u32 = @truncate(len);
    if (@as(u64, p) + n > mem.len) return error.MemoryOutOfBounds;
    return mem[p..][0..n];
}

/// Copy as much of `val` as fits into the law's buffer; returns the full length, so a law can
/// tell that its buffer was too small. Charged for the whole value, which the host has already read.
fn copyOut(val: []const u8, mem: []u8, out: u64, cap: u64, fuel: *u64) interp.Trap!u64 {
    const dst = try slice(mem, out, cap);
    const n = @min(val.len, dst.len);
    try interp.charge(fuel, val.len / bytes_per_fuel);
    @memcpy(dst[0..n], val[0..n]);
    return val.len;
}

fn digestWrites(writes: []const Run.Write) [32]u8 {
    var h = Sha256.init(.{});
    for (writes) |w| {
        hashBytes(&h, w.key);
        if (w.value) |v| {
            h.update(&.{1});
            hashBytes(&h, v);
        } else h.update(&.{0});
    }
    return h.finalResult();
}

fn hashBytes(h: *Sha256, bytes: []const u8) void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(bytes.len), .big);
    h.update(&len);
    h.update(bytes);
}

fn nextChain(prev: [32]u8, record: []const u8) [32]u8 {
    var h = Sha256.init(.{});
    h.update(&prev);
    h.update(record);
    return h.finalResult();
}

/// version 1 | law sha256 | u16 entry len, entry | u16 argc, (u32 len, arg)* | writes digest
fn encodeRecord(arena: std.mem.Allocator, law_hash: [32]u8, entry: []const u8, args: []const []const u8, digest: [32]u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(arena, 1);
    try out.appendSlice(arena, &law_hash);
    try appendInt(&out, arena, u16, @intCast(entry.len));
    try out.appendSlice(arena, entry);
    try appendInt(&out, arena, u16, @intCast(args.len));
    for (args) |arg| {
        try appendInt(&out, arena, u32, @intCast(arg.len));
        try out.appendSlice(arena, arg);
    }
    try out.appendSlice(arena, &digest);
    return out.items;
}

fn appendInt(out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, comptime T: type, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .big);
    try out.appendSlice(arena, &buf);
}

const Record = struct {
    body: []const u8,
    law_hash: [32]u8,
    entry: []const u8,
    args: []const []const u8,
    writes_digest: [32]u8,
    chain: [32]u8,
};

fn parseRecord(arena: std.mem.Allocator, stored: []const u8) ?Record {
    if (stored.len < 32) return null;
    const body = stored[0 .. stored.len - 32];
    var r = module.Reader{ .bytes = body };
    if ((r.byte() catch return null) != 1) return null;
    var rec = Record{ .body = body, .law_hash = undefined, .entry = undefined, .args = undefined, .writes_digest = undefined, .chain = stored[stored.len - 32 ..][0..32].* };
    rec.law_hash = (r.take(32) catch return null)[0..32].*;
    rec.entry = r.take(readInt(&r, u16) orelse return null) catch return null;
    const argc = readInt(&r, u16) orelse return null;
    const args = arena.alloc([]const u8, argc) catch return null;
    for (args) |*arg| arg.* = r.take(readInt(&r, u32) orelse return null) catch return null;
    rec.args = args;
    rec.writes_digest = (r.take(32) catch return null)[0..32].*;
    if (r.pos != body.len) return null;
    return rec;
}

fn readInt(r: *module.Reader, comptime T: type) ?T {
    const bytes = r.take(@sizeOf(T)) catch return null;
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}

const Head = struct { seq: u64, chain: [32]u8 };

fn readHead(store: *Store, arena: std.mem.Allocator, id: []const u8) !Head {
    const raw = try store.getValueDupe(try std.fmt.allocPrint(arena, "sbx:head:{s}", .{id}), arena) orelse
        return .{ .seq = 0, .chain = @splat(0) };
    var head = Head{ .seq = 0, .chain = undefined };
    var parts = std.mem.splitScalar(u8, raw, ' ');
    head.seq = std.fmt.parseInt(u64, parts.next() orelse return error.CorruptHead, 10) catch return error.CorruptHead;
    _ = std.fmt.hexToBytes(&head.chain, parts.next() orelse return error.CorruptHead) catch return error.CorruptHead;
    return head;
}

fn logKey(arena: std.mem.Allocator, id: []const u8, seq: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "sbx:log:{s}:{d:0>12}", .{ id, seq });
}

fn loadModule(store: *Store, arena: std.mem.Allocator, law_hex: []const u8) !?module.Module {
    const bytes = try store.getValueDupe(try std.fmt.allocPrint(arena, "sbx:mod:{s}", .{law_hex}), arena) orelse return null;
    return module.decode(vm_allocator, bytes, .{}) catch null;
}

fn scopeId(scope: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    Sha256.hash(scope, &h, .{});
    return std.fmt.bytesToHex(h[0..16].*, .lower);
}

fn scopeProblem(scope: []const u8) ?[]const u8 {
    if (scope.len == 0) return "the scope must not be empty";
    if (scope.len > 256) return "the scope is too long";
    if (std.mem.startsWith(u8, scope, "sbx:")) return "a scope may not start with sbx:";
    return null;
}

fn hexDecode(arena: std.mem.Allocator, hex: []const u8) ?[]u8 {
    if (hex.len % 2 != 0) return null;
    const out = arena.alloc(u8, hex.len / 2) catch return null;
    _ = std.fmt.hexToBytes(out, hex) catch return null;
    return out;
}
