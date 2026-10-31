//! Decodes and checks a sandboxed procedure's wasm module.
//!
//! Accepted: the integer subset of wasm 1.0 (i32/i64 only), the sign-extension operators and the
//! bulk-memory operators, one memory, one funcref table, and function imports from the host module
//! "wormdb" with the exact signatures in `host_signatures`. Refused: floats (so every result is
//! bit-for-bit the same on every machine), a start function, and any other import.
//!
//! Every instruction is walked once here, so the interpreter can trust what it reads: opcodes are
//! known, indices are in range, branch depths reach an open block, and each block's `else` and `end`
//! positions are precomputed. Operand types are NOT checked; the interpreter bounds-checks its stacks
//! and memory instead, so a badly typed module can compute garbage but never escape the sandbox.

const std = @import("std");

pub const ValType = enum(u8) { i32 = 0x7F, i64 = 0x7E };

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,

    pub fn eql(a: FuncType, b: FuncType) bool {
        return std.mem.eql(ValType, a.params, b.params) and std.mem.eql(ValType, a.results, b.results);
    }
};

/// The calls a procedure may make into the host. See `host_signatures` and examples/laws/law.zig.
pub const HostFn = enum { arg_count, arg, get, set, del, ret, fail };

const I = ValType.i32;
pub const host_signatures = std.enums.EnumArray(HostFn, FuncType).init(.{
    .arg_count = .{ .params = &.{}, .results = &.{I} },
    .arg = .{ .params = &.{ I, I, I }, .results = &.{I} },
    .get = .{ .params = &.{ I, I, I, I }, .results = &.{I} },
    .set = .{ .params = &.{ I, I, I, I }, .results = &.{I} },
    .del = .{ .params = &.{ I, I }, .results = &.{I} },
    .ret = .{ .params = &.{ I, I }, .results = &.{} },
    .fail = .{ .params = &.{ I, I }, .results = &.{} },
});

pub const Import = struct { host: HostFn, type_idx: u32 };

/// Where a block, loop or if ends, and where an if's else sits (0 = none; an else is never at 0).
pub const Ctrl = struct { else_pc: u32 = 0, end_pc: u32 = 0 };

pub const Func = struct {
    type_idx: u32,
    /// Declared locals, not counting parameters.
    local_count: u32,
    /// The function's instructions, ending with its final `end`.
    code: []const u8,
    /// Keyed by the position of each block/loop/if opcode in `code`.
    ctrl: std.AutoHashMapUnmanaged(u32, Ctrl),
};

pub const Global = struct { mutable: bool, init: u64 };

pub const DataSegment = struct {
    /// Null for a passive segment (copied in only by memory.init).
    offset: ?u32,
    bytes: []const u8,
};

pub const Export = struct { name: []const u8, func_idx: u32 };

pub const Limits = struct {
    max_pages: u32 = 64,
    max_funcs: u32 = 10_000,
    max_locals: u32 = 50_000,
    max_table: u32 = 10_000,
    max_br_table: u32 = 100_000,
};

pub const Error = error{
    InvalidModule,
    FloatsNotAllowed,
    UnsupportedFeature,
    UnknownImport,
    ImportSignatureMismatch,
    TooLarge,
    OutOfMemory,
};

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    types: []const FuncType = &.{},
    imports: []const Import = &.{},
    funcs: []Func = &.{},
    table: []?u32 = &.{},
    has_table: bool = false,
    has_memory: bool = false,
    mem_min: u32 = 0,
    mem_max: ?u32 = null,
    globals: []Global = &.{},
    exports: []const Export = &.{},
    data: []const DataSegment = &.{},

    pub fn deinit(self: *Module) void {
        self.arena.deinit();
    }

    pub fn funcCount(self: *const Module) usize {
        return self.imports.len + self.funcs.len;
    }

    /// The type of function `idx` in the shared index space (imports first).
    pub fn funcType(self: *const Module, idx: u32) FuncType {
        if (idx < self.imports.len) return self.types[self.imports[idx].type_idx];
        return self.types[self.funcs[idx - self.imports.len].type_idx];
    }

    pub fn exportedFunc(self: *const Module, name: []const u8) ?u32 {
        for (self.exports) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.func_idx;
        }
        return null;
    }
};

pub fn decode(gpa: std.mem.Allocator, bytes_in: []const u8, limits: Limits) Error!Module {
    var m = Module{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer m.deinit();
    const a = m.arena.allocator();
    const bytes = try a.dupe(u8, bytes_in);

    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x00asm\x01\x00\x00\x00")) return error.InvalidModule;
    var r = Reader{ .bytes = bytes, .pos = 8 };

    var func_types: []u32 = &.{};
    var bodies_seen = false;
    var data_count: ?u32 = null;
    var seen: u32 = 0;
    while (r.pos < bytes.len) {
        const id = try r.byte();
        const size = try r.uleb(u32);
        const body = try r.take(size);
        var s = Reader{ .bytes = body };
        if (id != 0) {
            if (id > 12) return error.InvalidModule;
            const bit = @as(u32, 1) << @intCast(id);
            if (seen & bit != 0) return error.InvalidModule;
            seen |= bit;
        }
        switch (id) {
            0 => {}, // custom: names, producers; ignored
            1 => m.types = try readTypes(a, &s),
            2 => m.imports = try readImports(a, &s, m.types),
            3 => {
                const n = try s.uleb(u32);
                if (n > limits.max_funcs) return error.TooLarge;
                func_types = try a.alloc(u32, n);
                for (func_types) |*t| {
                    t.* = try s.uleb(u32);
                    if (t.* >= m.types.len) return error.InvalidModule;
                }
            },
            4 => {
                const n = try s.uleb(u32);
                if (n > 1) return error.UnsupportedFeature;
                if (n == 1) {
                    if (try s.byte() != 0x70) return error.UnsupportedFeature;
                    const lim = try readLimits(&s);
                    if (lim.min > limits.max_table) return error.TooLarge;
                    m.table = try a.alloc(?u32, lim.min);
                    @memset(m.table, null);
                    m.has_table = true;
                }
            },
            5 => {
                const n = try s.uleb(u32);
                if (n > 1) return error.UnsupportedFeature;
                if (n == 1) {
                    const lim = try readLimits(&s);
                    if (lim.min > limits.max_pages) return error.TooLarge;
                    m.has_memory = true;
                    m.mem_min = lim.min;
                    m.mem_max = lim.max;
                }
            },
            6 => {
                const n = try s.uleb(u32);
                if (n > limits.max_funcs) return error.TooLarge;
                m.globals = try a.alloc(Global, n);
                for (m.globals) |*g| {
                    const ty = try readValType(&s);
                    const mut = try s.byte();
                    if (mut > 1) return error.InvalidModule;
                    g.* = .{ .mutable = mut == 1, .init = try readConstExpr(&s, ty) };
                }
            },
            7 => m.exports = try readExports(a, &s),
            8 => return error.UnsupportedFeature, // start function: a procedure only runs when called
            9 => try readElems(&s, &m),
            10 => {
                const n = try s.uleb(u32);
                if (n != func_types.len) return error.InvalidModule;
                m.funcs = try a.alloc(Func, n);
                for (m.funcs, func_types) |*f, t| {
                    const len = try s.uleb(u32);
                    var fr = Reader{ .bytes = try s.take(len) };
                    f.* = .{ .type_idx = t, .local_count = try readLocals(&fr, limits), .code = fr.bytes[fr.pos..], .ctrl = .empty };
                }
                bodies_seen = true;
            },
            11 => m.data = try readData(a, &s),
            12 => data_count = try s.uleb(u32),
            else => unreachable,
        }
        if (id != 0 and s.pos != s.bytes.len) return error.InvalidModule;
    }
    if (func_types.len > 0 and !bodies_seen) return error.InvalidModule;
    if (data_count) |dc| {
        if (dc != m.data.len) return error.InvalidModule;
    }

    for (m.exports) |e| {
        if (e.func_idx >= m.funcCount()) return error.InvalidModule;
    }
    for (m.table) |entry| {
        if (entry) |fi| if (fi >= m.funcCount()) return error.InvalidModule;
    }
    for (m.funcs) |*f| try scanCode(a, &m, f, data_count, limits);
    return m;
}

fn readTypes(a: std.mem.Allocator, s: *Reader) Error![]const FuncType {
    const n = try s.uleb(u32);
    if (n > 10_000) return error.TooLarge;
    const types = try a.alloc(FuncType, n);
    for (types) |*t| {
        if (try s.byte() != 0x60) return error.InvalidModule;
        t.params = try readValTypes(a, s);
        t.results = try readValTypes(a, s);
    }
    return types;
}

fn readValTypes(a: std.mem.Allocator, s: *Reader) Error![]const ValType {
    const n = try s.uleb(u32);
    if (n > 1000) return error.TooLarge;
    const out = try a.alloc(ValType, n);
    for (out) |*v| v.* = try readValType(s);
    return out;
}

fn readValType(s: *Reader) Error!ValType {
    return switch (try s.byte()) {
        0x7F => .i32,
        0x7E => .i64,
        0x7D, 0x7C => error.FloatsNotAllowed,
        else => error.UnsupportedFeature,
    };
}

fn readImports(a: std.mem.Allocator, s: *Reader, types: []const FuncType) Error![]const Import {
    const n = try s.uleb(u32);
    if (n > 64) return error.TooLarge;
    const imports = try a.alloc(Import, n);
    for (imports) |*imp| {
        const mod_name = try s.name();
        const field = try s.name();
        if (try s.byte() != 0x00) return error.UnknownImport; // only functions may be imported
        const type_idx = try s.uleb(u32);
        if (type_idx >= types.len) return error.InvalidModule;
        if (!std.mem.eql(u8, mod_name, "wormdb")) return error.UnknownImport;
        const host = std.meta.stringToEnum(HostFn, field) orelse return error.UnknownImport;
        if (!host_signatures.get(host).eql(types[type_idx])) return error.ImportSignatureMismatch;
        imp.* = .{ .host = host, .type_idx = type_idx };
    }
    return imports;
}

fn readExports(a: std.mem.Allocator, s: *Reader) Error![]const Export {
    const n = try s.uleb(u32);
    if (n > 10_000) return error.TooLarge;
    var out: std.ArrayListUnmanaged(Export) = .empty;
    for (0..n) |_| {
        const name = try s.name();
        const kind = try s.byte();
        const idx = try s.uleb(u32);
        if (kind > 3) return error.InvalidModule;
        if (kind == 0) try out.append(a, .{ .name = name, .func_idx = idx });
    }
    return out.items;
}

fn readElems(s: *Reader, m: *Module) Error!void {
    const n = try s.uleb(u32);
    for (0..n) |_| {
        if (try s.uleb(u32) != 0) return error.UnsupportedFeature; // only active segments on table 0
        if (!m.has_table) return error.InvalidModule;
        const offset: u32 = @truncate(try readConstExpr(s, .i32));
        const count = try s.uleb(u32);
        if (@as(u64, offset) + count > m.table.len) return error.InvalidModule;
        for (0..count) |i| m.table[offset + i] = try s.uleb(u32);
    }
}

fn readLocals(r: *Reader, limits: Limits) Error!u32 {
    const groups = try r.uleb(u32);
    var total: u64 = 0;
    for (0..groups) |_| {
        total += try r.uleb(u32);
        if (total > limits.max_locals) return error.TooLarge;
        _ = try readValType(r);
    }
    return @intCast(total);
}

fn readData(a: std.mem.Allocator, s: *Reader) Error![]const DataSegment {
    const n = try s.uleb(u32);
    if (n > 10_000) return error.TooLarge;
    const segs = try a.alloc(DataSegment, n);
    for (segs) |*seg| {
        const flag = try s.uleb(u32);
        const offset: ?u32 = switch (flag) {
            0 => @truncate(try readConstExpr(s, .i32)),
            1 => null,
            2 => blk: {
                if (try s.uleb(u32) != 0) return error.InvalidModule;
                break :blk @truncate(try readConstExpr(s, .i32));
            },
            else => return error.InvalidModule,
        };
        seg.* = .{ .offset = offset, .bytes = try s.take(try s.uleb(u32)) };
    }
    return segs;
}

const Lim = struct { min: u32, max: ?u32 };

fn readLimits(s: *Reader) Error!Lim {
    return switch (try s.byte()) {
        0 => .{ .min = try s.uleb(u32), .max = null },
        1 => .{ .min = try s.uleb(u32), .max = try s.uleb(u32) },
        else => error.UnsupportedFeature, // shared or 64-bit memories
    };
}

fn readConstExpr(s: *Reader, ty: ValType) Error!u64 {
    const v: u64 = switch (try s.byte()) {
        0x41 => if (ty == .i32) @as(u32, @bitCast(try s.sleb(i32))) else return error.InvalidModule,
        0x42 => if (ty == .i64) @bitCast(try s.sleb(i64)) else return error.InvalidModule,
        0x43, 0x44 => return error.FloatsNotAllowed,
        else => return error.UnsupportedFeature,
    };
    if (try s.byte() != 0x0B) return error.InvalidModule;
    return v;
}

/// Block type of a block/loop/if: how many values it takes and leaves.
pub const BlockArity = struct { params: u32, results: u32 };

pub fn readBlockType(s: *Reader, types: []const FuncType) Error!BlockArity {
    const first = s.bytes[s.pos..];
    if (first.len == 0) return error.InvalidModule;
    switch (first[0]) {
        0x40 => {
            s.pos += 1;
            return .{ .params = 0, .results = 0 };
        },
        0x7F, 0x7E => {
            s.pos += 1;
            return .{ .params = 0, .results = 1 };
        },
        0x7D, 0x7C => return error.FloatsNotAllowed,
        else => {
            const idx = try s.sleb(i64);
            if (idx < 0 or idx >= types.len) return error.InvalidModule;
            const t = types[@intCast(idx)];
            return .{ .params = @intCast(t.params.len), .results = @intCast(t.results.len) };
        },
    }
}

fn scanCode(a: std.mem.Allocator, m: *Module, f: *Func, data_count: ?u32, limits: Limits) Error!void {
    const ty = m.types[f.type_idx];
    const nlocals: u64 = ty.params.len + f.local_count;
    var open: std.ArrayListUnmanaged(u32) = .empty;
    var s = Reader{ .bytes = f.code };
    var ended = false;
    while (s.pos < f.code.len) {
        if (ended) return error.InvalidModule; // bytes after the function's final end
        const at: u32 = @intCast(s.pos);
        const op = try s.byte();
        switch (op) {
            0x00, 0x01, 0x0F, 0x1A, 0x1B => {},
            0x02, 0x03, 0x04 => {
                _ = try readBlockType(&s, m.types);
                try open.append(a, at);
                try f.ctrl.put(a, at, .{});
            },
            0x05 => {
                const start = open.getLastOrNull() orelse return error.InvalidModule;
                if (f.code[start] != 0x04) return error.InvalidModule;
                const c = f.ctrl.getPtr(start).?;
                if (c.else_pc != 0) return error.InvalidModule;
                c.else_pc = at;
            },
            0x0B => {
                if (open.pop()) |start| {
                    f.ctrl.getPtr(start).?.end_pc = at;
                } else {
                    ended = true;
                }
            },
            0x0C, 0x0D => if (try s.uleb(u32) > open.items.len) return error.InvalidModule,
            0x0E => {
                const n = try s.uleb(u32);
                if (n > limits.max_br_table) return error.TooLarge;
                for (0..n + 1) |_| {
                    if (try s.uleb(u32) > open.items.len) return error.InvalidModule;
                }
            },
            0x10 => if (try s.uleb(u32) >= m.funcCount()) return error.InvalidModule,
            0x11 => {
                if (try s.uleb(u32) >= m.types.len) return error.InvalidModule;
                if (try s.byte() != 0 or !m.has_table) return error.InvalidModule;
            },
            0x1C => {
                if (try s.uleb(u32) != 1) return error.InvalidModule;
                _ = try readValType(&s);
            },
            0x20, 0x21, 0x22 => if (try s.uleb(u32) >= nlocals) return error.InvalidModule,
            0x23 => if (try s.uleb(u32) >= m.globals.len) return error.InvalidModule,
            0x24 => {
                const g = try s.uleb(u32);
                if (g >= m.globals.len or !m.globals[g].mutable) return error.InvalidModule;
            },
            0x2A, 0x2B, 0x38, 0x39 => return error.FloatsNotAllowed,
            0x28, 0x29, 0x2C...0x37, 0x3A...0x3E => {
                if (!m.has_memory) return error.InvalidModule;
                _ = try s.uleb(u32); // alignment hint
                _ = try s.uleb(u32); // offset
            },
            0x3F, 0x40 => {
                if (!m.has_memory or try s.byte() != 0) return error.InvalidModule;
            },
            0x41 => _ = try s.sleb(i32),
            0x42 => _ = try s.sleb(i64),
            0x43, 0x44 => return error.FloatsNotAllowed,
            0x45...0x5A, 0x67...0x8A, 0xA7, 0xAC, 0xAD, 0xC0...0xC4 => {},
            0x5B...0x66, 0x8B...0xA6, 0xA8...0xAB, 0xAE...0xBF => return error.FloatsNotAllowed,
            0xFC => switch (try s.uleb(u32)) {
                0...7 => return error.FloatsNotAllowed, // saturating float-to-int
                8 => {
                    const seg = try s.uleb(u32);
                    if (data_count == null or seg >= m.data.len) return error.InvalidModule;
                    if (!m.has_memory or try s.byte() != 0) return error.InvalidModule;
                },
                9 => {
                    if (data_count == null or try s.uleb(u32) >= m.data.len) return error.InvalidModule;
                },
                10 => {
                    if (!m.has_memory or try s.byte() != 0 or try s.byte() != 0) return error.InvalidModule;
                },
                11 => {
                    if (!m.has_memory or try s.byte() != 0) return error.InvalidModule;
                },
                else => return error.UnsupportedFeature,
            },
            else => return error.UnsupportedFeature,
        }
    }
    if (!ended or open.items.len != 0) return error.InvalidModule;
}

/// A cursor over wasm bytes. Every read is bounds-checked; LEB128 reads cap their length.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.bytes.len) return error.InvalidModule;
        defer r.pos += 1;
        return r.bytes[r.pos];
    }

    pub fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.bytes.len - r.pos) return error.InvalidModule;
        defer r.pos += n;
        return r.bytes[r.pos..][0..n];
    }

    pub fn name(r: *Reader) Error![]const u8 {
        return r.take(try r.uleb(u32));
    }

    pub fn uleb(r: *Reader, comptime T: type) Error!T {
        const max_bytes = (@bitSizeOf(T) + 6) / 7;
        var result: u64 = 0;
        var i: u32 = 0;
        while (true) : (i += 1) {
            if (i == max_bytes) return error.InvalidModule;
            const b = try r.byte();
            result |= @as(u64, b & 0x7F) << @intCast(i * 7);
            if (b & 0x80 == 0) break;
        }
        return std.math.cast(T, result) orelse error.InvalidModule;
    }

    pub fn sleb(r: *Reader, comptime T: type) Error!T {
        const max_bytes = (@bitSizeOf(T) + 6) / 7;
        var result: u64 = 0;
        var shift: u32 = 0;
        var i: u32 = 0;
        var b: u8 = 0;
        while (true) : (i += 1) {
            if (i == max_bytes) return error.InvalidModule;
            b = try r.byte();
            result |= @as(u64, b & 0x7F) << @intCast(shift);
            shift += 7;
            if (b & 0x80 == 0) break;
        }
        if (shift < 64 and b & 0x40 != 0) result |= ~@as(u64, 0) << @intCast(shift);
        return std.math.cast(T, @as(i64, @bitCast(result))) orelse error.InvalidModule;
    }
};

test "a module with floats is refused" {
    // (module (func (result f32) f32.const 0))
    const bytes = "\x00asm\x01\x00\x00\x00" ++ "\x01\x05\x01\x60\x00\x01\x7d" ++ "\x03\x02\x01\x00" ++ "\x0a\x09\x01\x07\x00\x43\x00\x00\x00\x00\x0b";
    try std.testing.expectError(error.FloatsNotAllowed, decode(std.testing.allocator, bytes, .{}));
}

test "an import outside the host module is refused" {
    // (module (import "env" "get" (func)))
    const bytes = "\x00asm\x01\x00\x00\x00" ++ "\x01\x04\x01\x60\x00\x00" ++ "\x02\x0b\x01\x03env\x03get\x00\x00";
    try std.testing.expectError(error.UnknownImport, decode(std.testing.allocator, bytes, .{}));
}

test "LEB128 reads cap their length" {
    var r = Reader{ .bytes = "\xff\xff\xff\xff\xff\x01" };
    try std.testing.expectError(error.InvalidModule, r.uleb(u32));
    var r2 = Reader{ .bytes = "\x7f" };
    try std.testing.expectEqual(@as(i32, -1), try r2.sleb(i32));
    var r3 = Reader{ .bytes = "\x80\x80\xc0\x00" };
    try std.testing.expectEqual(@as(u32, 1048576), try r3.uleb(u32));
}
