//! Signed Capability Token (SCT) — authentication and authorization for browser-direct access.
//!
//! Binary token format (lowest overhead — no JSON parsing in hot path):
//!
//!   SCT = [payload][64B Ed25519 signature]
//!
//!   payload = [8B iat][8B exp][4B sub_len][sub][4B jti][1B cap_count][cap0][cap1]...
//!   cap     = [1B op_code][1B match_type][4B pattern_len][pattern]
//!
//! Verification:
//!   1. Slice off last 64 bytes as signature
//!   2. crypto_sign_ed25519_verify_detached(sig, payload, pubkey)
//!   3. Check exp > now, iat <= now
//!   4. Parse capabilities from payload
//!
//! Capability enforcement:
//!   Before executing any command, check if the operation is permitted by
//!   the connection's authenticated capabilities.

const std = @import("std");
const compat = @import("../core/compat.zig");

/// libsodium bindings via `extern "c"` declarations rather than `@cImport`,
/// so the build needs only the link library — no system `sodium.h` header.
/// (Headers are not vendored for the Windows MinGW build.) Mirrors the binding
/// style meshguard uses in its crypto module.
const c = struct {
    extern "c" fn sodium_init() c_int;
    extern "c" fn crypto_sign_ed25519_verify_detached(
        sig: [*c]const u8,
        m: [*c]const u8,
        mlen: c_ulonglong,
        pk: [*c]const u8,
    ) c_int;
    extern "c" fn crypto_sign_ed25519_detached(
        sig: [*c]u8,
        siglen_p: [*c]c_ulonglong,
        m: [*c]const u8,
        mlen: c_ulonglong,
        sk: [*c]const u8,
    ) c_int;
    extern "c" fn crypto_sign_ed25519_keypair(pk: [*c]u8, sk: [*c]u8) c_int;
};

/// Operation types that can be authorized by a capability.
pub const Operation = enum(u8) {
    get = 0x01,
    set = 0x02,
    delete = 0x03,
    subscribe = 0x04,
    publish = 0x05,
    exec = 0x06,
    /// Wildcard — permits all operations.
    all = 0xFF,
};

/// How the pattern in a capability matches against the target.
pub const MatchType = enum(u8) {
    /// Exact match: pattern must equal the key/proc/channel exactly.
    exact = 0x01,
    /// Prefix match: key must start with pattern.
    prefix = 0x02,
    /// Wildcard: matches everything (pattern is empty).
    wildcard = 0xFF,
};

/// A single capability granting a specific operation on matching keys/procs/channels.
pub const Capability = struct {
    op: Operation,
    match_type: MatchType,
    pattern: []const u8,
};

/// Parsed and verified token state, stored per-connection.
pub const TokenState = struct {
    /// Authenticated subject (user identity).
    subject: []const u8,
    /// Issued-at timestamp (seconds since epoch).
    iat: u64,
    /// Expiration timestamp (seconds since epoch).
    exp: u64,
    /// Token identifier (anti-replay).
    jti: u32,
    /// Authorized capabilities.
    capabilities: []const Capability,

    /// Check if this token permits a given operation on a target key/proc/channel.
    pub fn permits(self: *const TokenState, op: Operation, target: []const u8) bool {
        for (self.capabilities) |cap| {
            if (cap.op != .all and cap.op != op) continue;

            switch (cap.match_type) {
                .wildcard => return true,
                .exact => {
                    if (std.mem.eql(u8, cap.pattern, target)) return true;
                },
                .prefix => {
                    if (std.mem.startsWith(u8, target, cap.pattern)) return true;
                },
            }
        }
        return false;
    }

    /// Check if the token is expired based on current time.
    pub fn isExpired(self: *const TokenState) bool {
        const now: u64 = @intCast(@divFloor(compat.nowMs(), 1000));
        return now >= self.exp;
    }
};

/// Ed25519 public key (32 bytes).
pub const PublicKey = [32]u8;

/// Ed25519 signature (64 bytes).
pub const Signature = [64]u8;

const SIGNATURE_LEN = 64;

/// Verify and parse a binary SCT token.
///
/// Returns the parsed token state on success, or an error describing the failure.
/// The returned TokenState contains slices allocated from `allocator`.
pub fn verifyAndParse(
    token: []const u8,
    public_keys: []const PublicKey,
    allocator: std.mem.Allocator,
    max_age_s: u64,
) !TokenState {
    if (token.len < SIGNATURE_LEN + 21) {
        // Minimum: 8 (iat) + 8 (exp) + 4 (sub_len) + 0 (sub) + 4 (jti) + 1 (cap_count) = 25, + 64 sig = 89
        // But sub can be 0 length, so min = 25 + 64 = 89
        return error.TokenTooShort;
    }

    const payload = token[0 .. token.len - SIGNATURE_LEN];
    const sig = token[token.len - SIGNATURE_LEN ..][0..SIGNATURE_LEN];

    // Verify signature against any of the configured public keys
    var verified = false;
    for (public_keys) |pk| {
        if (c.crypto_sign_ed25519_verify_detached(sig, payload.ptr, payload.len, &pk) == 0) {
            verified = true;
            break;
        }
    }
    if (!verified) return error.InvalidSignature;

    // Parse payload
    var pos: usize = 0;

    // iat (8 bytes, big-endian)
    if (pos + 8 > payload.len) return error.MalformedToken;
    const iat = std.mem.readInt(u64, payload[pos..][0..8], .big);
    pos += 8;

    // exp (8 bytes, big-endian)
    if (pos + 8 > payload.len) return error.MalformedToken;
    const exp = std.mem.readInt(u64, payload[pos..][0..8], .big);
    pos += 8;

    // Check expiration
    const now: u64 = @intCast(@divFloor(compat.nowMs(), 1000));
    if (now >= exp) return error.TokenExpired;
    if (iat > now + 60) return error.TokenNotYetValid; // 60s clock skew tolerance

    // Check max age
    if (max_age_s > 0 and (exp - iat) > max_age_s) return error.TokenTooLongLived;

    // sub (4B len + bytes)
    if (pos + 4 > payload.len) return error.MalformedToken;
    const sub_len = std.mem.readInt(u32, payload[pos..][0..4], .big);
    pos += 4;
    if (pos + sub_len > payload.len) return error.MalformedToken;
    const subject = try allocator.dupe(u8, payload[pos .. pos + sub_len]);
    errdefer allocator.free(subject);
    pos += sub_len;

    // jti (4 bytes)
    if (pos + 4 > payload.len) return error.MalformedToken;
    const jti = std.mem.readInt(u32, payload[pos..][0..4], .big);
    pos += 4;

    // capabilities (1B count + repeated [1B op][1B match][4B pattern_len][pattern])
    if (pos + 1 > payload.len) return error.MalformedToken;
    const cap_count: usize = payload[pos];
    pos += 1;

    const caps = try allocator.alloc(Capability, cap_count);
    errdefer allocator.free(caps);
    var cap_i: usize = 0;
    errdefer {
        for (caps[0..cap_i]) |cap| {
            allocator.free(cap.pattern);
        }
    }

    for (0..cap_count) |i| {
        if (pos + 2 > payload.len) return error.MalformedToken;
        const op = compat.intToEnum(Operation, payload[pos]) catch return error.MalformedToken;
        const match_type = compat.intToEnum(MatchType, payload[pos + 1]) catch return error.MalformedToken;
        pos += 2;

        if (pos + 4 > payload.len) return error.MalformedToken;
        const pat_len = std.mem.readInt(u32, payload[pos..][0..4], .big);
        pos += 4;

        if (pos + pat_len > payload.len) return error.MalformedToken;
        const pattern = try allocator.dupe(u8, payload[pos .. pos + pat_len]);
        pos += pat_len;

        caps[i] = .{ .op = op, .match_type = match_type, .pattern = pattern };
        cap_i += 1;
    }

    return .{
        .subject = subject,
        .iat = iat,
        .exp = exp,
        .jti = jti,
        .capabilities = caps,
    };
}

/// Encode a binary SCT token (primarily for testing and auth provider tooling).
/// Signs the payload with the given secret key.
pub fn encode(
    subject: []const u8,
    iat: u64,
    exp: u64,
    jti: u32,
    caps: []const Capability,
    secret_key: *const [64]u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Calculate payload size
    var payload_len: usize = 8 + 8 + 4 + subject.len + 4 + 1; // iat + exp + sub + jti + cap_count
    for (caps) |cap| {
        payload_len += 2 + 4 + cap.pattern.len; // op + match + pattern
    }

    const total_len = payload_len + SIGNATURE_LEN;
    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    var pos: usize = 0;

    // iat
    std.mem.writeInt(u64, buf[pos..][0..8], iat, .big);
    pos += 8;

    // exp
    std.mem.writeInt(u64, buf[pos..][0..8], exp, .big);
    pos += 8;

    // subject
    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(subject.len), .big);
    pos += 4;
    @memcpy(buf[pos .. pos + subject.len], subject);
    pos += subject.len;

    // jti
    std.mem.writeInt(u32, buf[pos..][0..4], jti, .big);
    pos += 4;

    // capabilities
    buf[pos] = @intCast(caps.len);
    pos += 1;

    for (caps) |cap| {
        buf[pos] = @intFromEnum(cap.op);
        buf[pos + 1] = @intFromEnum(cap.match_type);
        pos += 2;
        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(cap.pattern.len), .big);
        pos += 4;
        @memcpy(buf[pos .. pos + cap.pattern.len], cap.pattern);
        pos += cap.pattern.len;
    }

    // Sign payload → write signature at end
    const payload = buf[0..payload_len];
    const sig_dest: *[SIGNATURE_LEN]u8 = buf[payload_len..][0..SIGNATURE_LEN];
    _ = c.crypto_sign_ed25519_detached(sig_dest, null, payload.ptr, payload.len, secret_key);

    return buf;
}

/// Generate an Ed25519 keypair using libsodium.
pub fn generateKeypair() struct { public_key: PublicKey, secret_key: [64]u8 } {
    var pk: PublicKey = undefined;
    var sk: [64]u8 = undefined;
    _ = c.crypto_sign_ed25519_keypair(&pk, &sk);
    return .{ .public_key = pk, .secret_key = sk };
}

/// Decode a base64-encoded public key into a 32-byte Ed25519 public key.
pub fn decodePublicKey(b64: []const u8) !PublicKey {
    var pk: PublicKey = undefined;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.InvalidPublicKey;
    if (decoded_len != 32) return error.InvalidPublicKey;
    std.base64.standard.Decoder.decode(&pk, b64) catch return error.InvalidPublicKey;
    return pk;
}

// ╔═══════════════════════════════════════════════╗
// ║  Command-level capability enforcement          ║
// ╚═══════════════════════════════════════════════╝

/// Map a CommandId to an auth Operation for capability checking.
pub fn commandToOperation(cmd_id: u8) ?Operation {
    return switch (cmd_id) {
        0x01 => .get,
        0x02 => .set,
        0x03 => .delete,
        0x06 => .subscribe,
        0x07 => .subscribe, // UNSUB uses same permission as SUB
        0x08 => .publish,
        0x09 => .exec,
        0x0D => .set, // VINSERT writes a vector key.
        0x0E => .delete, // VDELETE deletes a vector key.
        0x0F => .set, // VBULKINSERT writes every item key.
        else => null, // STATUS, CLUSTER_STATUS, SAVE, AUTH, etc. — always permitted
    };
}

const Command = @import("../core/types.zig").Command;

/// Extract the target key/channel/procedure from a command for capability checking.
pub fn commandTarget(cmd: Command) ?[]const u8 {
    return switch (cmd) {
        .get => |key| key,
        .set => |p| p.key,
        .delete => |key| key,
        .subscribe => |ch| ch,
        .unsubscribe => |ch| ch,
        .publish => |p| p.channel,
        .exec => |p| p.procedure,
        .vinsert => |p| p.key,
        .vdelete => |p| p.key,
        .vbulkinsert => null, // Multi-target; use commandPermitted.
        else => null,
    };
}

/// Check whether a parsed command is permitted by the token's capabilities.
///
/// Single-target commands use `commandTarget`; VBULKINSERT must authorize every
/// item key because the frame can write many arbitrary keys. Commands that map
/// to no protected operation are public. Commands that map to an operation but
/// do not expose a target are denied by default.
pub fn commandPermitted(state: *const TokenState, cmd_id: u8, cmd: Command) bool {
    const op = commandToOperation(cmd_id) orelse return true;

    switch (cmd) {
        .vbulkinsert => |params| {
            for (params.items) |item| {
                if (!state.permits(op, item.key)) return false;
            }
            return true;
        },
        else => {
            const target = commandTarget(cmd) orelse return false;
            return state.permits(op, target);
        },
    }
}

// ╔═══════════════════════════════════════════════╗
// ║  Tests                                         ║
// ╚═══════════════════════════════════════════════╝

test "encode, verify, and parse roundtrip" {
    const testing = std.testing;

    // Initialize libsodium (required for first use)
    if (c.sodium_init() < -1) return error.SodiumInitFailed;

    const kp = generateKeypair();

    const now: u64 = @intCast(@divFloor(compat.nowMs(), 1000));
    const caps = &[_]Capability{
        .{ .op = .exec, .match_type = .exact, .pattern = "increment" },
        .{ .op = .get, .match_type = .prefix, .pattern = "user:alice:" },
        .{ .op = .all, .match_type = .wildcard, .pattern = "" },
    };

    const token = try encode("alice", now, now + 3600, 42, caps, &kp.secret_key, testing.allocator);
    defer testing.allocator.free(token);

    const pks = &[_]PublicKey{kp.public_key};
    const state = try verifyAndParse(token, pks, testing.allocator, 7200);
    defer {
        testing.allocator.free(state.subject);
        for (state.capabilities) |cap| {
            testing.allocator.free(cap.pattern);
        }
        testing.allocator.free(state.capabilities);
    }

    try testing.expectEqualStrings("alice", state.subject);
    try testing.expectEqual(@as(u64, now), state.iat);
    try testing.expectEqual(@as(u64, now + 3600), state.exp);
    try testing.expectEqual(@as(u32, 42), state.jti);
    try testing.expectEqual(@as(usize, 3), state.capabilities.len);
}

test "reject expired token" {
    const testing = std.testing;
    if (c.sodium_init() < -1) return error.SodiumInitFailed;

    const kp = generateKeypair();
    const now: u64 = @intCast(@divFloor(compat.nowMs(), 1000));

    // Token expired 10 seconds ago
    const token = try encode("bob", now - 100, now - 10, 1, &.{}, &kp.secret_key, testing.allocator);
    defer testing.allocator.free(token);

    const pks = &[_]PublicKey{kp.public_key};
    try testing.expectError(error.TokenExpired, verifyAndParse(token, pks, testing.allocator, 3600));
}

test "reject bad signature" {
    const testing = std.testing;
    if (c.sodium_init() < -1) return error.SodiumInitFailed;

    const kp1 = generateKeypair();
    const kp2 = generateKeypair(); // Different key

    const now: u64 = @intCast(@divFloor(compat.nowMs(), 1000));
    const token = try encode("carol", now, now + 3600, 1, &.{}, &kp1.secret_key, testing.allocator);
    defer testing.allocator.free(token);

    // Verify with wrong public key
    const pks = &[_]PublicKey{kp2.public_key};
    try testing.expectError(error.InvalidSignature, verifyAndParse(token, pks, testing.allocator, 3600));
}

test "capability enforcement: prefix matching" {
    const testing = std.testing;

    const state = TokenState{
        .subject = "alice",
        .iat = 0,
        .exp = 0,
        .jti = 0,
        .capabilities = &[_]Capability{
            .{ .op = .get, .match_type = .prefix, .pattern = "user:alice:" },
            .{ .op = .exec, .match_type = .exact, .pattern = "increment" },
        },
    };

    // Permitted
    try testing.expect(state.permits(.get, "user:alice:profile"));
    try testing.expect(state.permits(.get, "user:alice:settings"));
    try testing.expect(state.permits(.exec, "increment"));

    // Denied
    try testing.expect(!state.permits(.get, "user:bob:profile")); // wrong prefix
    try testing.expect(!state.permits(.set, "user:alice:profile")); // wrong op
    try testing.expect(!state.permits(.exec, "transfer")); // wrong proc
}

test "command authorization covers vector writes" {
    const testing = std.testing;
    const Types = @import("../core/types.zig");

    const state = TokenState{
        .subject = "writer",
        .iat = 0,
        .exp = 0,
        .jti = 0,
        .capabilities = &[_]Capability{
            .{ .op = .set, .match_type = .prefix, .pattern = "vec:allowed:" },
            .{ .op = .delete, .match_type = .prefix, .pattern = "vec:allowed:" },
        },
    };

    try testing.expectEqual(Operation.set, commandToOperation(0x0D).?);
    try testing.expectEqual(Operation.delete, commandToOperation(0x0E).?);
    try testing.expectEqual(Operation.set, commandToOperation(0x0F).?);

    const vinsert = Types.Command{ .vinsert = .{
        .key = "vec:allowed:1",
        .vector = "\x00\x00\x00\x00",
        .namespace = "allowed",
        .metric = "l2",
        .timestamp = 0,
    } };
    try testing.expect(commandPermitted(&state, 0x0D, vinsert));

    const denied_vinsert = Types.Command{ .vinsert = .{
        .key = "vec:denied:1",
        .vector = "\x00\x00\x00\x00",
        .namespace = "denied",
        .metric = "l2",
        .timestamp = 0,
    } };
    try testing.expect(!commandPermitted(&state, 0x0D, denied_vinsert));

    const vdelete = Types.Command{ .vdelete = .{
        .key = "vec:allowed:1",
        .namespace = "allowed",
    } };
    try testing.expect(commandPermitted(&state, 0x0E, vdelete));

    const allowed_items = [_]Types.Command.VbulkinsertParams.BulkItem{
        .{ .key = "vec:allowed:1", .vector = "\x00\x00\x00\x00", .timestamp = 0 },
        .{ .key = "vec:allowed:2", .vector = "\x00\x00\x00\x00", .timestamp = 0 },
    };
    const allowed_bulk = Types.Command{ .vbulkinsert = .{
        .namespace = "allowed",
        .metric = "l2",
        .items = &allowed_items,
    } };
    try testing.expect(commandPermitted(&state, 0x0F, allowed_bulk));

    const mixed_items = [_]Types.Command.VbulkinsertParams.BulkItem{
        .{ .key = "vec:allowed:1", .vector = "\x00\x00\x00\x00", .timestamp = 0 },
        .{ .key = "vec:denied:2", .vector = "\x00\x00\x00\x00", .timestamp = 0 },
    };
    const mixed_bulk = Types.Command{ .vbulkinsert = .{
        .namespace = "allowed",
        .metric = "l2",
        .items = &mixed_items,
    } };
    try testing.expect(!commandPermitted(&state, 0x0F, mixed_bulk));
}

test {
    @import("std").testing.refAllDecls(@This());
}
