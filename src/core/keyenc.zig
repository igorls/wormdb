//! base58 (Bitcoin alphabet) encoder — the only crypto the binary accinfo format needs at render time.
//!
//! Antelope public keys render as `"EOS" + base58(point33 ‖ ripemd160(point)[..4])` (legacy) and
//! `"PUB_K1_" + base58(point33 ‖ ripemd160(point‖"K1")[..4])` (modern). The frozen segment stores the
//! 33-byte point plus the two precomputed 4-byte checksums (the builder computes the ripemd160s once,
//! offline), so serving only needs to base58-encode a 37-byte payload — no ripemd160 in the hot path.

const std = @import("std");

const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// base58-encode `input` into `out`, returning the written slice. `out` must hold at least
/// `input.len * 138 / 100 + 1` bytes (ceil of log(256)/log(58) ≈ 1.366 per byte, plus leading-zero
/// '1's). For a 37-byte key payload, 64 bytes is ample.
pub fn encode(input: []const u8, out: []u8) []const u8 {
    // Leading zero bytes map 1:1 to leading '1's.
    var zeros: usize = 0;
    while (zeros < input.len and input[zeros] == 0) : (zeros += 1) {}

    // Big-endian base-256 → base-58 via repeated "multiply the accumulator by 256, add byte".
    // b58[] holds base-58 digits, most-significant last; we fill from the high end.
    const cap = out.len;
    var b58 = out; // scratch in the caller's buffer
    @memset(b58[0..cap], 0);
    var high: usize = cap; // index just past the most-significant written digit

    for (input) |byte| {
        var carry: usize = byte;
        var i: usize = cap;
        while (i > 0) {
            i -= 1;
            if (i >= high or carry != 0) {
                carry += 256 * @as(usize, b58[i]);
                b58[i] = @intCast(carry % 58);
                carry /= 58;
                if (b58[i] != 0 and i < high) high = i;
            }
        }
    }

    // Skip leading zero digits in the computed region (they're not significant), then the result is
    // `zeros` × '1' followed by the significant base-58 digits mapped through the alphabet.
    var first_nonzero = high;
    while (first_nonzero < cap and b58[first_nonzero] == 0) : (first_nonzero += 1) {}

    // Build the final string in place from the end of `out` backwards, then move to the front.
    var tmp: [256]u8 = undefined;
    var n: usize = 0;
    var z: usize = 0;
    while (z < zeros) : (z += 1) {
        tmp[n] = '1';
        n += 1;
    }
    var k = first_nonzero;
    while (k < cap) : (k += 1) {
        tmp[n] = ALPHABET[b58[k]];
        n += 1;
    }
    @memcpy(out[0..n], tmp[0..n]);
    return out[0..n];
}

test "base58 known vectors" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", encode("", &buf));
    try std.testing.expectEqualStrings("2g", encode("a", &buf));
    try std.testing.expectEqualStrings("1", encode(&[_]u8{0}, &buf));
    try std.testing.expectEqualStrings("11", encode(&[_]u8{ 0, 0 }, &buf));
    // leading zero then 'a': "1" + "2g"
    try std.testing.expectEqualStrings("12g", encode(&[_]u8{ 0, 'a' }, &buf));
    // documented vector: "bbb" -> "a3gV"
    try std.testing.expectEqualStrings("a3gV", encode("bbb", &buf));
    // "Hello World!" -> "2NEpo7TZRRrLZSi2U"
    try std.testing.expectEqualStrings("2NEpo7TZRRrLZSi2U", encode("Hello World!", &buf));
}

test {
    std.testing.refAllDecls(@This());
}
