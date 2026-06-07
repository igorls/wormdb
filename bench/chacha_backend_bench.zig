//! ChaCha20-Poly1305 backend benchmark — std.crypto vs libsodium.
//!
//! Answers the "benchmark gate" of meshguard#102: should Linux default to
//! libsodium (AVX2 8-block assembly) or to std.crypto (Zig software AEAD)?
//!
//! Self-contained and dependency-light by design:
//!   * std.crypto path: always benched (the primitive meshguard's tunnel uses
//!     when not on the libsodium path — std.crypto.aead.chacha_poly).
//!   * libsodium path: loaded at RUNTIME via dlopen, so there is NO link-time
//!     dependency. If libsodium is not present, the sodium rows are skipped and
//!     only the std baseline is printed. This lets the SAME binary run on a
//!     no-sodium host and on a sodium host unchanged.
//!
//! Run:
//!   zig run bench/chacha_backend_bench.zig -lc
//!
//! On Linux x86_64 (the decisive AVX2 row), point it at the vendored .so or a
//! system install via the loader path, e.g.:
//!   LD_LIBRARY_PATH=deps/lib zig run bench/chacha_backend_bench.zig -lc
//!   # or just install libsodium-dev and run the same command.
//!
//! Workloads mirror the issue's matrix: raw AEAD encrypt + decrypt across
//! gossip-sized, MTU-sized, and GSO-batch-sized payloads.

const std = @import("std");

const StdAead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

const TAG_LEN = 16;
const NONCE_LEN = 12;
const KEY_LEN = 32;

// ─── monotonic clock (same idiom as meshguard tunnel.zig) ───
fn zio() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn nowNs() u64 {
    return @intCast(std.Io.Timestamp.now(zio(), .awake).toNanoseconds());
}

// ─── libsodium, loaded at runtime (no link-time dependency) ───
const EncFn = *const fn (
    c: [*]u8,
    mac: [*]u8,
    maclen_p: ?*c_ulonglong,
    m: [*]const u8,
    mlen: c_ulonglong,
    ad: ?[*]const u8,
    adlen: c_ulonglong,
    nsec: ?*const u8,
    npub: [*]const u8,
    k: [*]const u8,
) callconv(.c) c_int;

const DecFn = *const fn (
    m: [*]u8,
    nsec: ?*u8,
    c: [*]const u8,
    clen: c_ulonglong,
    mac: [*]const u8,
    ad: ?[*]const u8,
    adlen: c_ulonglong,
    npub: [*]const u8,
    k: [*]const u8,
) callconv(.c) c_int;

const InitFn = *const fn () callconv(.c) c_int;

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
const RTLD_NOW = 2;

const Sodium = struct {
    encrypt: EncFn,
    decrypt: DecFn,
    name: []const u8,

    fn load() ?Sodium {
        // Try the common runtime names across platforms; dlopen walks the
        // loader search path (honours LD_LIBRARY_PATH / DYLD_LIBRARY_PATH).
        const candidates = [_][:0]const u8{
            "libsodium.so",
            "libsodium.so.26",
            "libsodium.so.23",
            "libsodium.dylib",
            "libsodium.26.dylib",
            "sodium.dll",
            "libsodium.dll",
        };
        for (candidates) |name| {
            const h = dlopen(name.ptr, RTLD_NOW) orelse continue;
            const enc = dlsym(h, "crypto_aead_chacha20poly1305_ietf_encrypt_detached") orelse continue;
            const dec = dlsym(h, "crypto_aead_chacha20poly1305_ietf_decrypt_detached") orelse continue;
            if (dlsym(h, "sodium_init")) |init_ptr| {
                _ = @as(InitFn, @ptrCast(@alignCast(init_ptr)))();
            }
            return .{
                .encrypt = @ptrCast(@alignCast(enc)),
                .decrypt = @ptrCast(@alignCast(dec)),
                .name = name,
            };
        }
        return null;
    }
};

// Payload sizes from the issue matrix: gossip/control, MTU, GSO batch buffers.
const SIZES = [_]usize{ 64, 256, 1400, 8192, 65536 };

// Target ~1 GiB processed per (size, backend, op); bounded iteration count.
const TARGET_BYTES: u64 = 1 << 30;
const MIN_ITERS: u64 = 2000;
const ROUNDS = 5; // take the best round (min time) to reduce scheduler noise.

fn itersFor(size: usize) u64 {
    const n = TARGET_BYTES / @as(u64, size);
    return @max(n, MIN_ITERS);
}

var sink: u64 = 0; // defeat dead-code elimination

const Result = struct { mbps: f64, ns_per_op: f64 };

fn benchStdEncrypt(pt: []const u8, ct: []u8, tag: *[TAG_LEN]u8, key: [32]u8, nonce: [12]u8, iters: u64) u64 {
    const start = nowNs();
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        StdAead.encrypt(ct[0..pt.len], tag, pt, "", nonce, key);
        sink +%= tag[0];
    }
    return nowNs() - start;
}

fn benchStdDecrypt(out: []u8, ct: []const u8, tag: [TAG_LEN]u8, key: [32]u8, nonce: [12]u8, iters: u64) u64 {
    const start = nowNs();
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        StdAead.decrypt(out[0..ct.len], ct, tag, "", nonce, key) catch unreachable;
        sink +%= out[0];
    }
    return nowNs() - start;
}

fn benchSodiumEncrypt(s: Sodium, pt: []const u8, ct: []u8, tag: *[TAG_LEN]u8, key: [32]u8, nonce: [12]u8, iters: u64) u64 {
    const start = nowNs();
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        _ = s.encrypt(ct.ptr, tag, null, pt.ptr, @intCast(pt.len), null, 0, null, &nonce, &key);
        sink +%= tag[0];
    }
    return nowNs() - start;
}

fn benchSodiumDecrypt(s: Sodium, out: []u8, ct: []const u8, tag: *const [TAG_LEN]u8, key: [32]u8, nonce: [12]u8, iters: u64) u64 {
    const start = nowNs();
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        _ = s.decrypt(out.ptr, null, ct.ptr, @intCast(ct.len), tag, null, 0, &nonce, &key);
        sink +%= out[0];
    }
    return nowNs() - start;
}

fn report(ns: u64, iters: u64, size: usize) Result {
    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    const total_bytes: f64 = @floatFromInt(iters * size);
    return .{
        .mbps = (total_bytes / (1024.0 * 1024.0)) / secs,
        .ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iters)),
    };
}

fn p(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.stdout().writeStreamingAll(zio(), msg);
}

pub fn main() !void {
    const sodium = Sodium.load();

    try p("ChaCha20-Poly1305 backend benchmark\n", .{});
    try p("  arch={s}  os={s}\n", .{ @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
    if (sodium) |s| {
        try p("  libsodium: LOADED ({s})\n", .{s.name});
    } else {
        try p("  libsodium: not found (std.crypto baseline only — set LD_LIBRARY_PATH/install libsodium to compare)\n", .{});
    }
    try p("  {d} rounds/measurement, best taken; ~{d} MiB processed per cell\n\n", .{ ROUNDS, TARGET_BYTES >> 20 });

    try p("{s:>8}  {s:>4}  {s:>12}  {s:>12}  {s:>9}\n", .{ "size", "op", "std MB/s", "sodium MB/s", "sodium/std" });
    try p("{s:->8}  {s:->4}  {s:->12}  {s:->12}  {s:->9}\n", .{ "", "", "", "", "" });

    const gpa = std.heap.page_allocator;
    const key: [32]u8 = .{0x42} ** 32;
    const nonce: [12]u8 = .{0x11} ** 12;

    for (SIZES) |size| {
        const pt = try gpa.alloc(u8, size);
        defer gpa.free(pt);
        const ct = try gpa.alloc(u8, size);
        defer gpa.free(ct);
        const out = try gpa.alloc(u8, size);
        defer gpa.free(out);
        for (pt, 0..) |*b, i| b.* = @truncate(i);

        var tag: [TAG_LEN]u8 = undefined;
        const iters = itersFor(size);

        // ── encrypt ──
        var std_enc_best: u64 = std.math.maxInt(u64);
        for (0..ROUNDS) |_| std_enc_best = @min(std_enc_best, benchStdEncrypt(pt, ct, &tag, key, nonce, iters));
        const std_enc = report(std_enc_best, iters, size);

        // produce a valid (ct, tag) for the std decrypt bench
        StdAead.encrypt(ct[0..size], &tag, pt, "", nonce, key);
        var std_dec_best: u64 = std.math.maxInt(u64);
        for (0..ROUNDS) |_| std_dec_best = @min(std_dec_best, benchStdDecrypt(out, ct, tag, key, nonce, iters));
        const std_dec = report(std_dec_best, iters, size);

        if (sodium) |s| {
            var s_enc_best: u64 = std.math.maxInt(u64);
            for (0..ROUNDS) |_| s_enc_best = @min(s_enc_best, benchSodiumEncrypt(s, pt, ct, &tag, key, nonce, iters));
            const s_enc = report(s_enc_best, iters, size);

            // sodium-produced (ct, tag) for the sodium decrypt bench
            _ = s.encrypt(ct.ptr, &tag, null, pt.ptr, @intCast(size), null, 0, null, &nonce, &key);
            var s_dec_best: u64 = std.math.maxInt(u64);
            for (0..ROUNDS) |_| s_dec_best = @min(s_dec_best, benchSodiumDecrypt(s, out, ct, &tag, key, nonce, iters));
            const s_dec = report(s_dec_best, iters, size);

            try p("{d:>8}  {s:>4}  {d:>12.1}  {d:>12.1}  {d:>8.2}x\n", .{ size, "enc", std_enc.mbps, s_enc.mbps, s_enc.mbps / std_enc.mbps });
            try p("{d:>8}  {s:>4}  {d:>12.1}  {d:>12.1}  {d:>8.2}x\n", .{ size, "dec", std_dec.mbps, s_dec.mbps, s_dec.mbps / std_dec.mbps });
        } else {
            try p("{d:>8}  {s:>4}  {d:>12.1}  {s:>12}  {s:>9}\n", .{ size, "enc", std_enc.mbps, "-", "-" });
            try p("{d:>8}  {s:>4}  {d:>12.1}  {s:>12}  {s:>9}\n", .{ size, "dec", std_dec.mbps, "-", "-" });
        }
    }

    try p("\n(sink={d})\n", .{sink});
}
