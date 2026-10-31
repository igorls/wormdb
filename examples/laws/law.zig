//! The sandbox's side of a law: the host calls a law may make, and small helpers over them.
//!
//! A law is a Zig file compiled to wasm32-freestanding and installed with `EXEC sandbox_install`.
//! Every key it names is relative to its scope: the host prepends the scope prefix, so a law cannot
//! read or write outside it. Laws are integer-only (no floats) and see no clock and no randomness:
//! everything they know comes from their arguments and their scope, so a replay gives the same result.

extern "wormdb" fn arg_count() i32;
extern "wormdb" fn arg(index: i32, out: [*]u8, cap: i32) i32;
extern "wormdb" fn get(key: [*]const u8, key_len: i32, out: [*]u8, cap: i32) i32;
extern "wormdb" fn set(key: [*]const u8, key_len: i32, val: [*]const u8, val_len: i32) i32;
extern "wormdb" fn del(key: [*]const u8, key_len: i32) i32;
extern "wormdb" fn ret(ptr: [*]const u8, len: i32) void;
extern "wormdb" fn fail(ptr: [*]const u8, len: i32) noreturn;

pub fn argCount() usize {
    return @intCast(arg_count());
}

/// Argument `i` copied into `buf`, or null when there is no such argument or it does not fit.
pub fn argBytes(i: usize, buf: []u8) ?[]const u8 {
    const n = arg(@intCast(i), buf.ptr, @intCast(buf.len));
    if (n < 0 or n > buf.len) return null;
    return buf[0..@intCast(n)];
}

pub fn argInt(i: usize) ?i64 {
    var buf: [24]u8 = undefined;
    return parseInt(argBytes(i, &buf) orelse return null);
}

pub fn getBytes(key: []const u8, buf: []u8) ?[]const u8 {
    const n = get(key.ptr, @intCast(key.len), buf.ptr, @intCast(buf.len));
    if (n < 0 or n > buf.len) return null;
    return buf[0..@intCast(n)];
}

pub fn getInt(key: []const u8) ?i64 {
    var buf: [24]u8 = undefined;
    return parseInt(getBytes(key, &buf) orelse return null);
}

pub fn setBytes(key: []const u8, val: []const u8) void {
    if (set(key.ptr, @intCast(key.len), val.ptr, @intCast(val.len)) != 0) failWith("set refused");
}

pub fn setInt(key: []const u8, val: i64) void {
    var buf: [24]u8 = undefined;
    setBytes(key, formatInt(&buf, val));
}

pub fn delete(key: []const u8) void {
    if (del(key.ptr, @intCast(key.len)) != 0) failWith("delete refused");
}

pub fn retBytes(val: []const u8) void {
    ret(val.ptr, @intCast(val.len));
}

pub fn retInt(val: i64) void {
    var buf: [24]u8 = undefined;
    retBytes(formatInt(&buf, val));
}

/// Abort the call: nothing the law wrote during it is kept, and the caller gets `msg` as the error.
pub fn failWith(msg: []const u8) noreturn {
    fail(msg.ptr, @intCast(msg.len));
}

/// `a ++ b` into `buf`; fails the call when it does not fit.
pub fn concat(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    if (a.len + b.len > buf.len) failWith("key too long");
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..b.len], b);
    return buf[0 .. a.len + b.len];
}

fn parseInt(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    const neg = s[0] == '-';
    const digits = if (neg) s[1..] else s;
    if (digits.len == 0 or digits.len > 18) return null;
    var v: i64 = 0;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return if (neg) -v else v;
}

fn formatInt(buf: *[24]u8, val: i64) []const u8 {
    var i: usize = buf.len;
    var v: u64 = @abs(val);
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
    if (val < 0) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}
