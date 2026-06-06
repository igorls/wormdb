//! Antelope `name` <-> u64 codec.
//!
//! An Antelope account / table / permission identifier is a `name`: up to 13
//! characters from the alphabet ".12345abcdefghijklmnopqrstuvwxyz" packed into
//! a u64 — the first 12 characters take 5 bits each (bits 63..4), the optional
//! 13th takes the low 4 bits. This is the canonical eosio encoding (matches
//! abieos `string_to_name` / `name_to_string`), so a frozen segment keyed by
//! these u64s lines up with names decoded straight from a snapshot, and a
//! request's account string maps to the same key the builder used.

const std = @import("std");

/// Map a character to its symbol value. Anything outside the name alphabet maps
/// to 0 (i.e. '.'), exactly like eosio's `char_to_symbol` — callers never error
/// on stray input, they just get a '.' in that position.
fn charToSymbol(c: u8) u64 {
    if (c >= 'a' and c <= 'z') return (c - 'a') + 6;
    if (c >= '1' and c <= '5') return (c - '1') + 1;
    return 0; // '.' and everything else
}

/// Encode a name string to its u64 representation (canonical eosio packing).
/// Strings longer than 13 chars are truncated; invalid chars become '.'.
pub fn encode(str: []const u8) u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < str.len and i < 12) : (i += 1) {
        const shift: u6 = @intCast(64 - 5 * (i + 1));
        value |= (charToSymbol(str[i]) & 0x1f) << shift;
    }
    // 13th character (if present) occupies the low 4 bits.
    if (str.len > 12) {
        value |= charToSymbol(str[12]) & 0x0f;
    }
    return value;
}

const CHARMAP = ".12345abcdefghijklmnopqrstuvwxyz";

/// Decode a u64 name into `buf` (must be >= 13 bytes), returning the trimmed
/// slice (trailing '.' padding removed, like eosio's `name_to_string`).
pub fn decode(value: u64, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 13);
    var tmp = value;
    // Build from the least-significant end: position 12 (the 13th char) is 4
    // bits; positions 11..0 are 5 bits each.
    var i: usize = 0;
    while (i <= 12) : (i += 1) {
        const mask: u64 = if (i == 0) 0x0f else 0x1f;
        buf[12 - i] = CHARMAP[@intCast(tmp & mask)];
        tmp >>= if (i == 0) 4 else 5;
    }
    // Trim trailing '.' padding.
    var end: usize = 13;
    while (end > 0 and buf[end - 1] == '.') : (end -= 1) {}
    return buf[0..end];
}

/// FNV1a-64 of a byte string. Matches the Rust `wseg-build` `fnv1a64`.
pub fn fnv1a64(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |b| {
        h ^= b;
        h = h *% 0x100000001b3;
    }
    return h;
}

/// Stable key for a (contract, symbol) token: FNV1a-64 of "contract:symbol". Must match the Rust
/// `wseg-build` `token_key` so segment lookups line up.
pub fn tokenKey(contract: []const u8, symbol: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const mix = struct {
        fn f(hash: *u64, bytes: []const u8) void {
            for (bytes) |b| {
                hash.* ^= b;
                hash.* = hash.* *% 0x100000001b3;
            }
        }
    }.f;
    mix(&h, contract);
    mix(&h, ":");
    mix(&h, symbol);
    return h;
}

/// Segment key for a public key string (EOS… or PUB_K1_…). Matches Rust `key_hash`.
pub fn keyHash(pubkey: []const u8) u64 {
    return fnv1a64(pubkey);
}

test "tokenKey matches the Rust FNV1a recipe" {
    // FNV1a-64 of "eosio.token:WAX" — cross-checked against the Rust token_key.
    try std.testing.expectEqual(@as(u64, 13053440730298864435), tokenKey("eosio.token", "WAX"));
    try std.testing.expect(tokenKey("eosio.token", "WAX") != tokenKey("eosio.token", "EOS"));
}

test "encode canonical eosio vector" {
    // name("eosio") is the well-known constant 6138663577826885632.
    try std.testing.expectEqual(@as(u64, 6138663577826885632), encode("eosio"));
}

test "round-trip names up to 12 chars" {
    var buf: [13]u8 = undefined;
    const cases = [_][]const u8{
        "eosio",
        "waxupbitcold",
        "eosio.token",
        "a",
        "1",
        "abcdefghijkl", // 12 chars
        "eosio.reserv",
        "...",
    };
    for (cases) |c| {
        var end: usize = c.len;
        while (end > 0 and c[end - 1] == '.') : (end -= 1) {}
        const got = decode(encode(c), &buf);
        try std.testing.expectEqualStrings(c[0..end], got);
    }
}

test "empty string encodes to zero" {
    try std.testing.expectEqual(@as(u64, 0), encode(""));
}

test {
    std.testing.refAllDecls(@This());
}
