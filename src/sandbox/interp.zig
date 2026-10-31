//! Runs one call into a decoded module.
//!
//! Each call gets a fresh instance (memory from the data segments, globals from their initial
//! values), so nothing survives between calls except what the procedure wrote through the host.
//! Every instruction costs one unit of fuel; the value, label, frame and locals stacks are bounded;
//! every memory access is bounds-checked. Out of fuel, out of bounds, a bad division or an
//! `unreachable` all end the call with a trap, never with the host's memory touched.
//!
//! The arithmetic is wasm's integer semantics exactly (wrapping add/sub/mul, traps on division by
//! zero and on signed overflow), so the same call on the same inputs gives the same result on every
//! machine. The module has already been walked by `module.decode`; this file trusts its block map
//! and index checks but not its operand types.

const std = @import("std");
const module = @import("module.zig");
const Module = module.Module;
const Reader = module.Reader;

pub const Trap = error{
    Unreachable,
    OutOfFuel,
    StackOverflow,
    StackUnderflow,
    CallDepthExceeded,
    MemoryOutOfBounds,
    DivideByZero,
    IntegerOverflow,
    UndefinedElement,
    IndirectCallTypeMismatch,
    NoSuchExport,
    BadEntrySignature,
    TooMuchMemory,
    /// The procedure called the host's `fail`.
    LawFailed,
} || module.Error;

/// The host side of the imports. `call` gets the import, its arguments and the instance memory,
/// and charges its own fuel through `fuel` (see `charge`).
pub const Host = struct {
    ptr: *anyopaque,
    call: *const fn (ptr: *anyopaque, f: module.HostFn, args: []const u64, mem: []u8, fuel: *u64) Trap!u64,
};

pub const Limits = struct {
    fuel: u64 = 10_000_000,
    max_pages: u32 = 64,
    max_values: u32 = 1 << 14,
    max_labels: u32 = 1 << 12,
    max_frames: u32 = 256,
    max_locals: u32 = 1 << 15,
};

pub const Outcome = struct { fuel_used: u64 };

/// Take `n` units from `fuel`, or trap when there are not that many left.
pub fn charge(fuel: *u64, n: u64) Trap!void {
    if (fuel.* < n) {
        fuel.* = 0;
        return error.OutOfFuel;
    }
    fuel.* -= n;
}

/// Run the exported function `name` (no parameters; any results are discarded).
pub fn call(gpa: std.mem.Allocator, m: *const Module, name: []const u8, host: Host, limits: Limits) Trap!Outcome {
    const idx = m.exportedFunc(name) orelse return error.NoSuchExport;
    if (idx < m.imports.len or m.funcType(idx).params.len != 0) return error.BadEntrySignature;
    var vm = try Vm.init(gpa, m, limits);
    defer vm.deinit();
    try vm.enter(idx);
    try vm.run(host);
    return .{ .fuel_used = limits.fuel - vm.fuel };
}

const page = 65536;

const Label = struct { height: u32, arity: u32, cont: u32, is_loop: bool };
const Frame = struct { func: u32, pc: u32, locals: u32, labels: u32, base: u32 };

const Vm = struct {
    gpa: std.mem.Allocator,
    m: *const Module,
    limits: Limits,
    fuel: u64,
    mem: []u8,
    globals: []u64,
    dropped: []bool,
    values: []u64,
    sp: u32 = 0,
    labels: []Label,
    lp: u32 = 0,
    frames: []Frame,
    fp: u32 = 0,
    locals: []u64,
    lcount: u32 = 0,

    fn init(gpa: std.mem.Allocator, m: *const Module, limits: Limits) Trap!Vm {
        if (m.mem_min > limits.max_pages) return error.TooMuchMemory;
        const mem = try gpa.alloc(u8, @as(usize, m.mem_min) * page);
        errdefer gpa.free(mem);
        @memset(mem, 0);
        const globals = try gpa.alloc(u64, m.globals.len);
        errdefer gpa.free(globals);
        for (globals, m.globals) |*g, mg| g.* = mg.init;
        const dropped = try gpa.alloc(bool, m.data.len);
        errdefer gpa.free(dropped);
        for (dropped, m.data) |*d, seg| {
            d.* = false;
            const off = seg.offset orelse continue;
            if (@as(u64, off) + seg.bytes.len > mem.len) return error.MemoryOutOfBounds;
            @memcpy(mem[off..][0..seg.bytes.len], seg.bytes);
            d.* = true; // an active segment is dropped once it is copied in
        }
        const values = try gpa.alloc(u64, limits.max_values);
        errdefer gpa.free(values);
        const labels = try gpa.alloc(Label, limits.max_labels);
        errdefer gpa.free(labels);
        const frames = try gpa.alloc(Frame, limits.max_frames);
        errdefer gpa.free(frames);
        const locals = try gpa.alloc(u64, limits.max_locals);
        return .{
            .gpa = gpa,
            .m = m,
            .limits = limits,
            .fuel = limits.fuel,
            .mem = mem,
            .globals = globals,
            .dropped = dropped,
            .values = values,
            .labels = labels,
            .frames = frames,
            .locals = locals,
        };
    }

    fn deinit(vm: *Vm) void {
        vm.gpa.free(vm.mem);
        vm.gpa.free(vm.globals);
        vm.gpa.free(vm.dropped);
        vm.gpa.free(vm.values);
        vm.gpa.free(vm.labels);
        vm.gpa.free(vm.frames);
        vm.gpa.free(vm.locals);
    }

    fn push(vm: *Vm, v: u64) Trap!void {
        if (vm.sp == vm.values.len) return error.StackOverflow;
        vm.values[vm.sp] = v;
        vm.sp += 1;
    }

    fn pop(vm: *Vm) Trap!u64 {
        if (vm.sp == 0) return error.StackUnderflow;
        vm.sp -= 1;
        return vm.values[vm.sp];
    }

    fn pop32(vm: *Vm) Trap!u32 {
        return @truncate(try vm.pop());
    }

    fn pushBool(vm: *Vm, b: bool) Trap!void {
        try vm.push(@intFromBool(b));
    }

    fn pushLabel(vm: *Vm, l: Label) Trap!void {
        if (vm.lp == vm.labels.len) return error.StackOverflow;
        vm.labels[vm.lp] = l;
        vm.lp += 1;
    }

    /// Pops a base address and returns base + offset, checked against memory.
    fn addr(vm: *Vm, offset: u32, size: u32) Trap!usize {
        const ea = @as(u64, try vm.pop32()) + offset;
        if (ea + size > vm.mem.len) return error.MemoryOutOfBounds;
        return @intCast(ea);
    }

    fn range(vm: *Vm, start: u32, len: u32) Trap![]u8 {
        if (@as(u64, start) + len > vm.mem.len) return error.MemoryOutOfBounds;
        return vm.mem[start..][0..len];
    }

    /// Call a defined (non-imported) function: its parameters come off the value stack.
    fn enter(vm: *Vm, idx: u32) Trap!void {
        const f = &vm.m.funcs[idx - vm.m.imports.len];
        const ty = vm.m.types[f.type_idx];
        const np: u32 = @intCast(ty.params.len);
        if (vm.fp == vm.frames.len) return error.CallDepthExceeded;
        if (vm.sp < np) return error.StackUnderflow;
        if (@as(u64, vm.lcount) + np + f.local_count > vm.locals.len) return error.StackOverflow;
        const lbase = vm.lcount;
        @memcpy(vm.locals[lbase..][0..np], vm.values[vm.sp - np .. vm.sp]);
        @memset(vm.locals[lbase + np ..][0..f.local_count], 0);
        vm.sp -= np;
        vm.lcount += np + f.local_count;
        vm.frames[vm.fp] = .{ .func = idx, .pc = 0, .locals = lbase, .labels = vm.lp, .base = vm.sp };
        vm.fp += 1;
        // The function body is the outermost block: a branch to it lands on its final `end`.
        try vm.pushLabel(.{ .height = vm.sp, .arity = @intCast(ty.results.len), .cont = @intCast(f.code.len - 1), .is_loop = false });
    }

    fn callFunc(vm: *Vm, idx: u32, host: Host) Trap!void {
        if (idx >= vm.m.imports.len) return vm.enter(idx);
        const imp = vm.m.imports[idx];
        const ty = vm.m.types[imp.type_idx];
        const np = ty.params.len;
        if (vm.sp < np) return error.StackUnderflow;
        var args: [4]u64 = undefined;
        @memcpy(args[0..np], vm.values[vm.sp - np .. vm.sp]);
        vm.sp -= @intCast(np);
        const result = try host.call(host.ptr, imp.host, args[0..np], vm.mem, &vm.fuel);
        if (ty.results.len == 1) try vm.push(result);
    }

    fn ret(vm: *Vm) Trap!void {
        const fr = vm.frames[vm.fp - 1];
        const nres: u32 = @intCast(vm.m.funcType(fr.func).results.len);
        if (vm.sp < fr.base + nres) return error.StackUnderflow;
        std.mem.copyForwards(u64, vm.values[fr.base..][0..nres], vm.values[vm.sp - nres .. vm.sp]);
        vm.sp = fr.base + nres;
        vm.lp = fr.labels;
        vm.lcount = fr.locals;
        vm.fp -= 1;
    }

    /// Branch to the label `depth` levels out; returns the pc to continue at.
    fn br(vm: *Vm, depth: u32) Trap!u32 {
        const fr = vm.frames[vm.fp - 1];
        if (depth >= vm.lp - fr.labels) return error.StackUnderflow;
        const li = vm.lp - 1 - depth;
        const l = vm.labels[li];
        if (vm.sp < l.height + l.arity) return error.StackUnderflow;
        std.mem.copyForwards(u64, vm.values[l.height..][0..l.arity], vm.values[vm.sp - l.arity .. vm.sp]);
        vm.sp = l.height + l.arity;
        if (l.is_loop) {
            vm.lp = li + 1;
            return l.cont;
        }
        vm.lp = li;
        return l.cont + 1;
    }

    fn run(vm: *Vm, host: Host) Trap!void {
        const m = vm.m;
        while (vm.fp > 0) {
            const fr = &vm.frames[vm.fp - 1];
            const f = &m.funcs[fr.func - m.imports.len];
            if (fr.pc >= f.code.len) {
                try vm.ret();
                continue;
            }
            try charge(&vm.fuel, 1);
            const at = fr.pc;
            var r = Reader{ .bytes = f.code, .pos = at + 1 };
            const op = f.code[at];
            switch (op) {
                0x00 => return error.Unreachable,
                0x01 => {},
                0x02, 0x03, 0x04 => {
                    const bt = try module.readBlockType(&r, m.types);
                    if (op == 0x04 and try vm.pop32() == 0) {
                        const c = f.ctrl.get(at).?;
                        if (c.else_pc == 0) {
                            fr.pc = c.end_pc + 1;
                            continue;
                        }
                        r.pos = c.else_pc + 1;
                    }
                    if (vm.sp < bt.params) return error.StackUnderflow;
                    try vm.pushLabel(if (op == 0x03)
                        .{ .height = vm.sp - bt.params, .arity = bt.params, .cont = @intCast(r.pos), .is_loop = true }
                    else
                        .{ .height = vm.sp - bt.params, .arity = bt.results, .cont = f.ctrl.get(at).?.end_pc, .is_loop = false });
                },
                0x05 => {
                    fr.pc = try vm.br(0); // the end of an if's then-branch: skip the else
                    continue;
                },
                0x0B => {
                    if (vm.lp == fr.labels) return error.StackUnderflow;
                    vm.lp -= 1;
                },
                0x0C => {
                    fr.pc = try vm.br(try r.uleb(u32));
                    continue;
                },
                0x0D => {
                    const depth = try r.uleb(u32);
                    if (try vm.pop32() != 0) {
                        fr.pc = try vm.br(depth);
                        continue;
                    }
                },
                0x0E => {
                    const n = try r.uleb(u32);
                    try charge(&vm.fuel, n / 4); // the targets are read one by one below
                    const i = @min(try vm.pop32(), n);
                    var target: u32 = 0;
                    for (0..n + 1) |k| {
                        const t = try r.uleb(u32);
                        if (k == i) target = t;
                    }
                    fr.pc = try vm.br(target);
                    continue;
                },
                0x0F => {
                    try vm.ret();
                    continue;
                },
                0x10 => {
                    const idx = try r.uleb(u32);
                    fr.pc = @intCast(r.pos);
                    try vm.callFunc(idx, host);
                    continue;
                },
                0x11 => {
                    const ty = m.types[try r.uleb(u32)];
                    _ = try r.byte();
                    const ei = try vm.pop32();
                    if (ei >= m.table.len) return error.UndefinedElement;
                    const fi = m.table[ei] orelse return error.UndefinedElement;
                    if (!m.funcType(fi).eql(ty)) return error.IndirectCallTypeMismatch;
                    fr.pc = @intCast(r.pos);
                    try vm.callFunc(fi, host);
                    continue;
                },
                0x1A => _ = try vm.pop(),
                0x1B, 0x1C => {
                    if (op == 0x1C) {
                        _ = try r.uleb(u32);
                        _ = try r.byte();
                    }
                    const c = try vm.pop32();
                    const b = try vm.pop();
                    const a = try vm.pop();
                    try vm.push(if (c != 0) a else b);
                },
                0x20 => try vm.push(vm.locals[fr.locals + try r.uleb(u32)]),
                0x21 => vm.locals[fr.locals + try r.uleb(u32)] = try vm.pop(),
                0x22 => {
                    const v = try vm.pop();
                    vm.locals[fr.locals + try r.uleb(u32)] = v;
                    try vm.push(v);
                },
                0x23 => try vm.push(vm.globals[try r.uleb(u32)]),
                0x24 => vm.globals[try r.uleb(u32)] = try vm.pop(),
                0x28, 0x29, 0x2C...0x35 => {
                    _ = try r.uleb(u32);
                    const off = try r.uleb(u32);
                    const size: u32 = switch (op) {
                        0x2C, 0x2D, 0x30, 0x31 => 1,
                        0x2E, 0x2F, 0x32, 0x33 => 2,
                        0x28, 0x34, 0x35 => 4,
                        else => 8,
                    };
                    const ea = try vm.addr(off, size);
                    const raw: u64 = switch (size) {
                        1 => vm.mem[ea],
                        2 => std.mem.readInt(u16, vm.mem[ea..][0..2], .little),
                        4 => std.mem.readInt(u32, vm.mem[ea..][0..4], .little),
                        else => std.mem.readInt(u64, vm.mem[ea..][0..8], .little),
                    };
                    try vm.push(switch (op) {
                        0x2C => @as(u32, @bitCast(@as(i32, sx(i8, raw)))),
                        0x2E => @as(u32, @bitCast(@as(i32, sx(i16, raw)))),
                        0x30 => @bitCast(@as(i64, sx(i8, raw))),
                        0x32 => @bitCast(@as(i64, sx(i16, raw))),
                        0x34 => @bitCast(@as(i64, sx(i32, raw))),
                        else => raw,
                    });
                },
                0x36, 0x37, 0x3A...0x3E => {
                    _ = try r.uleb(u32);
                    const off = try r.uleb(u32);
                    const v = try vm.pop();
                    const size: u32 = switch (op) {
                        0x3A, 0x3C => 1,
                        0x3B, 0x3D => 2,
                        0x36, 0x3E => 4,
                        else => 8,
                    };
                    const ea = try vm.addr(off, size);
                    switch (size) {
                        1 => vm.mem[ea] = @truncate(v),
                        2 => std.mem.writeInt(u16, vm.mem[ea..][0..2], @truncate(v), .little),
                        4 => std.mem.writeInt(u32, vm.mem[ea..][0..4], @truncate(v), .little),
                        else => std.mem.writeInt(u64, vm.mem[ea..][0..8], v, .little),
                    }
                },
                0x3F => {
                    _ = try r.byte();
                    try vm.push(vm.mem.len / page);
                },
                0x40 => {
                    _ = try r.byte();
                    const delta = try vm.pop32();
                    const old: u32 = @intCast(vm.mem.len / page);
                    const cap = @min(vm.limits.max_pages, m.mem_max orelse vm.limits.max_pages);
                    if (@as(u64, old) + delta > cap) {
                        try vm.push(0xFFFF_FFFF);
                    } else {
                        try charge(&vm.fuel, @as(u64, delta) * 64);
                        const old_len = vm.mem.len;
                        vm.mem = try vm.gpa.realloc(vm.mem, old_len + @as(usize, delta) * page);
                        @memset(vm.mem[old_len..], 0);
                        try vm.push(old);
                    }
                },
                0x41 => try vm.push(@as(u32, @bitCast(try r.sleb(i32)))),
                0x42 => try vm.push(@bitCast(try r.sleb(i64))),
                0x45 => try vm.pushBool(try vm.pop32() == 0),
                0x46...0x4F => {
                    const b = try vm.pop32();
                    const a = try vm.pop32();
                    try vm.pushBool(compare(u32, op - 0x46, a, b));
                },
                0x50 => try vm.pushBool(try vm.pop() == 0),
                0x51...0x5A => {
                    const b = try vm.pop();
                    const a = try vm.pop();
                    try vm.pushBool(compare(u64, op - 0x51, a, b));
                },
                0x67...0x69 => try vm.push(unary(u32, op - 0x67, try vm.pop32())),
                0x6A...0x78 => {
                    const b = try vm.pop32();
                    const a = try vm.pop32();
                    try vm.push(try binary(u32, op - 0x6A, a, b));
                },
                0x79...0x7B => try vm.push(unary(u64, op - 0x79, try vm.pop())),
                0x7C...0x8A => {
                    const b = try vm.pop();
                    const a = try vm.pop();
                    try vm.push(try binary(u64, op - 0x7C, a, b));
                },
                0xA7 => try vm.push(try vm.pop32()),
                0xAC => try vm.push(@bitCast(@as(i64, sx(i32, try vm.pop())))),
                0xAD => try vm.push(try vm.pop32()),
                0xC0 => try vm.push(@as(u32, @bitCast(@as(i32, sx(i8, try vm.pop()))))),
                0xC1 => try vm.push(@as(u32, @bitCast(@as(i32, sx(i16, try vm.pop()))))),
                0xC2 => try vm.push(@bitCast(@as(i64, sx(i8, try vm.pop())))),
                0xC3 => try vm.push(@bitCast(@as(i64, sx(i16, try vm.pop())))),
                0xC4 => try vm.push(@bitCast(@as(i64, sx(i32, try vm.pop())))),
                0xFC => switch (try r.uleb(u32)) {
                    8 => {
                        const seg = try r.uleb(u32);
                        _ = try r.byte();
                        const n = try vm.pop32();
                        const src = try vm.pop32();
                        const dst = try vm.range(try vm.pop32(), n);
                        const bytes = if (vm.dropped[seg]) "" else m.data[seg].bytes;
                        if (@as(u64, src) + n > bytes.len) return error.MemoryOutOfBounds;
                        try charge(&vm.fuel, n / 64);
                        @memcpy(dst, bytes[src..][0..n]);
                    },
                    9 => vm.dropped[try r.uleb(u32)] = true,
                    10 => {
                        _ = try r.byte();
                        _ = try r.byte();
                        const n = try vm.pop32();
                        const src = try vm.range(try vm.pop32(), n);
                        const dst_at = try vm.pop32();
                        const dst = try vm.range(dst_at, n);
                        try charge(&vm.fuel, n / 64);
                        if (@intFromPtr(dst.ptr) <= @intFromPtr(src.ptr)) {
                            std.mem.copyForwards(u8, dst, src);
                        } else {
                            std.mem.copyBackwards(u8, dst, src);
                        }
                    },
                    11 => {
                        _ = try r.byte();
                        const n = try vm.pop32();
                        const val = try vm.pop32();
                        const dst = try vm.range(try vm.pop32(), n);
                        try charge(&vm.fuel, n / 64);
                        @memset(dst, @truncate(val));
                    },
                    else => return error.UnsupportedFeature,
                },
                else => return error.UnsupportedFeature,
            }
            fr.pc = @intCast(r.pos);
        }
    }
};

/// Sign-extend the low bits of `v` that make up an `S`.
fn sx(comptime S: type, v: u64) S {
    const U = @Int(.unsigned, @bitSizeOf(S));
    return @bitCast(@as(U, @truncate(v)));
}

/// eq, ne, lt_s, lt_u, gt_s, gt_u, le_s, le_u, ge_s, ge_u, in wasm's opcode order.
fn compare(comptime T: type, k: u8, a: T, b: T) bool {
    const S = @Int(.signed, @bitSizeOf(T));
    const sa: S = @bitCast(a);
    const sb: S = @bitCast(b);
    return switch (k) {
        0 => a == b,
        1 => a != b,
        2 => sa < sb,
        3 => a < b,
        4 => sa > sb,
        5 => a > b,
        6 => sa <= sb,
        7 => a <= b,
        8 => sa >= sb,
        else => a >= b,
    };
}

/// clz, ctz, popcnt.
fn unary(comptime T: type, k: u8, a: T) T {
    return switch (k) {
        0 => @clz(a),
        1 => @ctz(a),
        else => @popCount(a),
    };
}

/// add, sub, mul, div_s, div_u, rem_s, rem_u, and, or, xor, shl, shr_s, shr_u, rotl, rotr.
fn binary(comptime T: type, k: u8, a: T, b: T) Trap!T {
    const S = @Int(.signed, @bitSizeOf(T));
    const sa: S = @bitCast(a);
    const sb: S = @bitCast(b);
    const sh: std.math.Log2Int(T) = @truncate(b);
    switch (k) {
        0 => return a +% b,
        1 => return a -% b,
        2 => return a *% b,
        3 => {
            if (b == 0) return error.DivideByZero;
            if (sa == std.math.minInt(S) and sb == -1) return error.IntegerOverflow;
            return @bitCast(@divTrunc(sa, sb));
        },
        4 => {
            if (b == 0) return error.DivideByZero;
            return a / b;
        },
        5 => {
            if (b == 0) return error.DivideByZero;
            if (sb == -1) return 0;
            return @bitCast(@rem(sa, sb));
        },
        6 => {
            if (b == 0) return error.DivideByZero;
            return a % b;
        },
        7 => return a & b,
        8 => return a | b,
        9 => return a ^ b,
        10 => return a << sh,
        11 => return @bitCast(sa >> sh),
        12 => return a >> sh,
        13 => return std.math.rotl(T, a, sh),
        else => return std.math.rotr(T, a, sh),
    }
}

const NoHost = struct {
    fn call(_: *anyopaque, _: module.HostFn, _: []const u64, _: []u8, _: *u64) Trap!u64 {
        return 0;
    }
};

test "division by zero traps" {
    // (module (func (export "f") (result i32) i32.const 7 i32.const 0 i32.div_s))
    const bytes = "\x00asm\x01\x00\x00\x00" ++ "\x01\x05\x01\x60\x00\x01\x7f" ++ "\x03\x02\x01\x00" ++
        "\x07\x05\x01\x01f\x00\x00" ++ "\x0a\x09\x01\x07\x00\x41\x07\x41\x00\x6d\x0b";
    var m = try module.decode(std.testing.allocator, bytes, .{});
    defer m.deinit();
    var dummy: u8 = 0;
    const host = Host{ .ptr = &dummy, .call = NoHost.call };
    try std.testing.expectError(error.DivideByZero, call(std.testing.allocator, &m, "f", host, .{}));
}

test "a loop that never ends runs out of fuel" {
    // (module (func (export "f") (loop (br 0))))
    const bytes = "\x00asm\x01\x00\x00\x00" ++ "\x01\x04\x01\x60\x00\x00" ++ "\x03\x02\x01\x00" ++
        "\x07\x05\x01\x01f\x00\x00" ++ "\x0a\x09\x01\x07\x00\x03\x40\x0c\x00\x0b\x0b";
    var m = try module.decode(std.testing.allocator, bytes, .{});
    defer m.deinit();
    var dummy: u8 = 0;
    const host = Host{ .ptr = &dummy, .call = NoHost.call };
    try std.testing.expectError(error.OutOfFuel, call(std.testing.allocator, &m, "f", host, .{ .fuel = 1000 }));
}

test "integer semantics match wasm" {
    try std.testing.expectEqual(@as(u32, 0), try binary(u32, 5, @bitCast(@as(i32, std.math.minInt(i32))), @bitCast(@as(i32, -1))));
    try std.testing.expectError(error.IntegerOverflow, binary(u32, 3, @bitCast(@as(i32, std.math.minInt(i32))), @bitCast(@as(i32, -1))));
    try std.testing.expectEqual(@as(u32, 1), try binary(u32, 10, 1, 32)); // shift counts wrap
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), try binary(u64, 11, 0x8000_0000_0000_0000, 63));
    try std.testing.expectEqual(@as(u32, 32), unary(u32, 0, 0));
}
