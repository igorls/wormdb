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
//!   2. Ed25519 verify (std.crypto) of sig over payload against pubkey
//!   3. Check exp > now, iat <= now
//!   4. Parse capabilities from payload
//!
//! Capability enforcement:
//!   Before executing any command, check if the operation is permitted by
//!   the connection's authenticated capabilities.

const std = @import("std");
const compat = @import("../core/compat.zig");

/// Ed25519 signing/verification uses Zig's std.crypto — no libsodium dependency.
/// (SCT auth was migrated off libsodium so the basic build path is sodium-free;
/// see meshguard#102.)
const Ed25519 = std.crypto.sign.Ed25519;

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

    /// Bind a blocking socket read to this token's absolute expiry. Socket
    /// deadlines use the monotonic clock; SCT timestamps use wall-clock seconds.
    pub fn readDeadlineNs(self: *const TokenState) i128 {
        const remaining = @as(i128, self.exp) * 1_000_000_000 - @as(i128, compat.nowMs()) * 1_000_000;
        return compat.nowNs() + @max(remaining, 0);
    }
};

/// Ed25519 public key (32 bytes).
pub const PublicKey = [32]u8;

/// Ed25519 signature (64 bytes).
pub const Signature = [64]u8;

const SIGNATURE_LEN = 64;
pub const SECRET_KEY_LEN = 64;

fn verifyDetached(sig_bytes: [64]u8, payload: []const u8, public_key_bytes: *const PublicKey) bool {
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    const public_key = Ed25519.PublicKey.fromBytes(public_key_bytes.*) catch return false;
    sig.verify(payload, public_key) catch return false;
    return true;
}

fn signDetached(sig_dest: *[SIGNATURE_LEN]u8, payload: []const u8, secret_key_bytes: *const [64]u8) !void {
    const secret_key = try Ed25519.SecretKey.fromBytes(secret_key_bytes.*);
    const key_pair = try Ed25519.KeyPair.fromSecretKey(secret_key);
    const sig = try key_pair.sign(payload, null);
    sig_dest.* = sig.toBytes();
}

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
    const sig_bytes = sig.*;

    // Verify signature against any of the configured public keys
    var verified = false;
    for (public_keys) |pk| {
        if (verifyDetached(sig_bytes, payload, &pk)) {
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
    try signDetached(sig_dest, payload, secret_key);

    return buf;
}

/// Generate an Ed25519 keypair.
pub fn generateKeypair() struct { public_key: PublicKey, secret_key: [64]u8 } {
    const kp = Ed25519.KeyPair.generate(std.Io.Threaded.global_single_threaded.io());
    return .{ .public_key = kp.public_key.toBytes(), .secret_key = kp.secret_key.toBytes() };
}

/// Decode a base64-encoded public key into a 32-byte Ed25519 public key.
pub fn decodePublicKey(b64: []const u8) !PublicKey {
    var pk: PublicKey = undefined;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.InvalidPublicKey;
    if (decoded_len != 32) return error.InvalidPublicKey;
    std.base64.standard.Decoder.decode(&pk, b64) catch return error.InvalidPublicKey;
    return pk;
}

/// Decode a base64-encoded Ed25519 secret key into the 64-byte std.crypto form.
pub fn decodeSecretKey(b64: []const u8) ![SECRET_KEY_LEN]u8 {
    var sk: [SECRET_KEY_LEN]u8 = undefined;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return error.InvalidSecretKey;
    if (decoded_len != SECRET_KEY_LEN) return error.InvalidSecretKey;
    std.base64.standard.Decoder.decode(&sk, b64) catch return error.InvalidSecretKey;
    return sk;
}

pub const NamespaceMode = enum {
    read,
    write,
    readwrite,
};

pub fn namespaceModeFromStr(s: []const u8) ?NamespaceMode {
    if (std.mem.eql(u8, s, "read")) return .read;
    if (std.mem.eql(u8, s, "write")) return .write;
    if (std.mem.eql(u8, s, "readwrite")) return .readwrite;
    return null;
}

pub fn namespaceCapabilityCount(mode: NamespaceMode) usize {
    return switch (mode) {
        .read => 6,
        .write => 10,
        .readwrite => 16,
    };
}

pub fn appendNamespaceCapabilities(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Capability),
    namespace: []const u8,
    mode: NamespaceMode,
) !void {
    if (mode == .read or mode == .readwrite) {
        try appendCap(allocator, list, .get, "mem:{s}:", .{namespace});
        try appendCap(allocator, list, .get, "vec:mem:{s}:", .{namespace});
        try appendCap(allocator, list, .get, "bq:vec:mem:{s}:", .{namespace});
        try appendCap(allocator, list, .get, "__meta:mem:{s}:", .{namespace});
        try appendCapLiteral(allocator, list, .exec, .prefix, "mem_");
        try appendCap(allocator, list, .subscribe, "mem:{s}:", .{namespace});
    }

    if (mode == .write or mode == .readwrite) {
        try appendCap(allocator, list, .set, "mem:{s}:", .{namespace});
        try appendCap(allocator, list, .set, "vec:mem:{s}:", .{namespace});
        try appendCap(allocator, list, .set, "bq:vec:mem:{s}:", .{namespace});
        try appendCap(allocator, list, .set, "__meta:mem:{s}:", .{namespace});
        try appendCap(allocator, list, .delete, "mem:{s}:", .{namespace});
        try appendCap(allocator, list, .delete, "vec:mem:{s}:", .{namespace});
        try appendCap(allocator, list, .delete, "bq:vec:mem:{s}:", .{namespace});
        try appendCap(allocator, list, .delete, "__meta:mem:{s}:", .{namespace});
        try appendCap(allocator, list, .publish, "mem:{s}:", .{namespace});
        try appendCapLiteral(allocator, list, .exec, .prefix, "mem_");
    }
}

fn appendCap(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Capability),
    op: Operation,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const pattern = try std.fmt.allocPrint(allocator, fmt, args);
    try list.append(allocator, .{ .op = op, .match_type = .prefix, .pattern = pattern });
}

fn appendCapLiteral(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Capability),
    op: Operation,
    match_type: MatchType,
    pattern: []const u8,
) !void {
    try list.append(allocator, .{
        .op = op,
        .match_type = match_type,
        .pattern = try allocator.dupe(u8, pattern),
    });
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
        0x0B => .all, // SAVE requires universal administrative authority
        0x0D => .set, // VINSERT writes a vector key
        0x0E => .delete, // VDELETE deletes a vector key
        0x0F => .set, // VBULKINSERT writes every item key
        0x10 => .set, // VRABITQ_INSTALL mutates vector namespace state
        else => null, // STATUS, CLUSTER_STATUS, AUTH, etc. — always permitted
    };
}

const Command = @import("../core/types.zig").Command;

/// Extract the target key/channel/procedure from a command for capability checking.
/// VBULKINSERT is multi-target (returns null) and must be authorized per-item via
/// `commandPermittedUnion`.
pub fn commandTarget(cmd: Command) ?[]const u8 {
    return switch (cmd) {
        .get => |key| key,
        .set => |p| p.key,
        .delete => |key| key,
        .subscribe => |p| p.channel,
        .unsubscribe => |ch| ch,
        .publish => |p| p.channel,
        .exec => |p| p.procedure,
        .save => "", // global operation; commandPermittedUnion checks universal scope
        .vinsert => |p| p.key,
        .vdelete => |p| p.key,
        .vbulkinsert => null, // multi-target; authorized per-item in commandPermittedUnion
        .vrabitq_install => |p| p.namespace,
        else => null,
    };
}

/// Map a parsed `Command` (union tag) to its auth `Operation`. The executor's gate keys on
/// this instead of the wire `cmd_id` byte (the executor only has the parsed command). `null`
/// ⇒ a public command (STATUS / CLUSTER_STATUS / CLUSTER_PEERS / AUTH).
pub fn operationForCommand(cmd: Command) ?Operation {
    return switch (cmd) {
        .get => .get,
        .set => .set,
        .delete => .delete,
        .subscribe, .unsubscribe => .subscribe,
        .publish => .publish,
        .exec => .exec,
        .vinsert, .vbulkinsert, .vrabitq_install => .set,
        .vdelete => .delete,
        .save => .all,
        else => null, // status, cluster_status, cluster_peers, auth
    };
}

/// Authorize a parsed command against a token's capabilities. VBULKINSERT authorizes EVERY
/// item key (a bulk frame can write many arbitrary keys); a command that maps to an operation
/// but exposes no target is denied by default. Public commands (no operation) are permitted.
pub fn commandPermittedUnion(state: *const TokenState, cmd: Command) bool {
    const op = operationForCommand(cmd) orelse return true; // public command
    switch (cmd) {
        .save => {
            // Exact-empty authority only names the empty key. It must not
            // become database-wide authority through this targetless command.
            for (state.capabilities) |cap| {
                if (cap.op == .all and (cap.match_type == .wildcard or
                    (cap.match_type == .prefix and cap.pattern.len == 0))) return true;
            }
            return false;
        },
        .vbulkinsert => |p| {
            for (p.items) |item| {
                if (!state.permits(op, item.key)) return false;
            }
            return true;
        },
        else => {
            const target = commandTarget(cmd) orelse return false; // op-mapped, no target ⇒ deny
            return state.permits(op, target);
        },
    }
}

/// The authorization decision a transport hands to `executor.execute`. Secure by default: a
/// client transport that cannot authenticate passes `.enforce(null)`, which rejects every
/// protected command. `.disabled` is an explicit per-transport opt-out (trusted network /
/// max performance); `.trusted` is for internal / replicated / maintenance callers and is the
/// `ExecContext` default so internal callers and existing tests are unaffected.
pub const AuthContext = union(enum) {
    /// Internal / replicated / maintenance caller — skip all capability checks.
    trusted,
    /// Auth explicitly disabled for this listener (logged loudly at startup).
    disabled,
    /// Client call. `null` token ⇒ unauthenticated (only public commands pass).
    enforce: ?*const TokenState,

    /// The authenticated subject, if any (passed to procedures as the identity).
    pub fn identity(self: AuthContext) ?[]const u8 {
        return switch (self) {
            .trusted, .disabled => null,
            .enforce => |ts| if (ts) |s| s.subject else null,
        };
    }
};

/// Free a `TokenState`'s heap allocations (subject + each capability pattern + the slice).
/// Used by every transport that owns a per-connection token (replaces the partial frees that
/// leaked `subject`/`cap.pattern` on the QUIC path).
pub fn freeTokenState(allocator: std.mem.Allocator, state: *const TokenState) void {
    allocator.free(state.subject);
    for (state.capabilities) |cap| allocator.free(cap.pattern);
    allocator.free(state.capabilities);
}

// ╔═══════════════════════════════════════════════╗
// ║  Tests                                         ║
// ╚═══════════════════════════════════════════════╝

test "encode, verify, and parse roundtrip" {
    const testing = std.testing;

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

test "operationForCommand agrees with commandToOperation for every Command id" {
    const testing = std.testing;
    const T = @import("../core/types.zig");
    const cases = .{
        .{ T.Command{ .get = "k" }, T.CommandId.get },
        .{ T.Command{ .set = .{ .key = "k", .value = "v" } }, T.CommandId.set },
        .{ T.Command{ .delete = "k" }, T.CommandId.delete },
        .{ T.Command{ .subscribe = .{ .channel = "c" } }, T.CommandId.subscribe },
        .{ T.Command{ .unsubscribe = "c" }, T.CommandId.unsubscribe },
        .{ T.Command{ .publish = .{ .channel = "c", .message = "m" } }, T.CommandId.publish },
        .{ T.Command{ .exec = .{ .procedure = "p", .args = &.{} } }, T.CommandId.exec },
        .{ T.Command.save, T.CommandId.save },
        .{ T.Command{ .vinsert = .{ .key = "vec:n:1", .vector = "\x00\x00\x00\x00", .namespace = "vec:n:", .metric = "l2", .timestamp = 0 } }, T.CommandId.vinsert },
        .{ T.Command{ .vdelete = .{ .key = "vec:n:1", .namespace = "vec:n:" } }, T.CommandId.vdelete },
        .{ T.Command{ .vbulkinsert = .{ .namespace = "vec:n:", .metric = "l2", .items = &.{} } }, T.CommandId.vbulkinsert },
        .{ T.Command{ .vrabitq_install = .{ .namespace = "vec:n:", .dim = 1, .seed = 0, .centroid = "\x00\x00\x00\x00", .rotation = "\x00\x00\x00\x00" } }, T.CommandId.vrabitq_install },
    };
    inline for (cases) |tc| {
        try testing.expectEqual(commandToOperation(@intFromEnum(tc[1])), operationForCommand(tc[0]));
    }
    // Public commands map to no operation on both keyings.
    try testing.expectEqual(@as(?Operation, null), operationForCommand(.status));
    try testing.expectEqual(@as(?Operation, .all), operationForCommand(.save));
    try testing.expectEqual(@as(?Operation, null), operationForCommand(.{ .auth = "x" }));
}

test "commandPermittedUnion: per-item bulk, targetless deny, public pass" {
    const testing = std.testing;
    const T = @import("../core/types.zig");
    const state = TokenState{
        .subject = "writer",
        .iat = 0,
        .exp = 0,
        .jti = 0,
        .capabilities = &[_]Capability{
            .{ .op = .set, .match_type = .prefix, .pattern = "vec:ok:" },
        },
    };

    // Public command — always permitted.
    try testing.expect(commandPermittedUnion(&state, .status));

    // Single vector write: in-prefix allowed, out-of-prefix denied.
    try testing.expect(commandPermittedUnion(&state, .{ .vinsert = .{ .key = "vec:ok:1", .vector = "\x00\x00\x00\x00", .namespace = "vec:ok:", .metric = "l2", .timestamp = 0 } }));
    try testing.expect(!commandPermittedUnion(&state, .{ .vinsert = .{ .key = "vec:no:1", .vector = "\x00\x00\x00\x00", .namespace = "vec:no:", .metric = "l2", .timestamp = 0 } }));

    // Bulk: every item must pass; one stray key denies the whole frame.
    const ok_items = [_]T.Command.VbulkinsertParams.BulkItem{
        .{ .key = "vec:ok:1", .vector = "\x00\x00\x00\x00", .timestamp = 0 },
        .{ .key = "vec:ok:2", .vector = "\x00\x00\x00\x00", .timestamp = 0 },
    };
    try testing.expect(commandPermittedUnion(&state, .{ .vbulkinsert = .{ .namespace = "vec:ok:", .metric = "l2", .items = &ok_items } }));
    const mixed_items = [_]T.Command.VbulkinsertParams.BulkItem{
        .{ .key = "vec:ok:1", .vector = "\x00\x00\x00\x00", .timestamp = 0 },
        .{ .key = "vec:no:2", .vector = "\x00\x00\x00\x00", .timestamp = 0 },
    };
    try testing.expect(!commandPermittedUnion(&state, .{ .vbulkinsert = .{ .namespace = "vec:ok:", .metric = "l2", .items = &mixed_items } }));

    // Op-mapped command whose target the token lacks — denied.
    try testing.expect(!commandPermittedUnion(&state, .{ .set = .{ .key = "other:1", .value = "v" } }));
}

test "namespace capability expansion scopes memory access" {
    const testing = std.testing;

    var caps: std.ArrayListUnmanaged(Capability) = .empty;
    defer {
        for (caps.items) |cap| testing.allocator.free(cap.pattern);
        caps.deinit(testing.allocator);
    }
    try appendNamespaceCapabilities(testing.allocator, &caps, "astrid", .read);
    try testing.expectEqual(namespaceCapabilityCount(.read), caps.items.len);

    const state = TokenState{
        .subject = "mem:astrid",
        .iat = 0,
        .exp = 0,
        .jti = 0,
        .capabilities = caps.items,
    };

    try testing.expect(state.permits(.get, "mem:astrid:doc-1"));
    try testing.expect(state.permits(.get, "vec:mem:astrid:doc-1"));
    try testing.expect(state.permits(.get, "__meta:mem:astrid:config"));
    try testing.expect(state.permits(.subscribe, "mem:astrid:added"));
    try testing.expect(state.permits(.exec, "mem_query"));
    try testing.expect(!state.permits(.get, "mem:raven:doc-1"));
    try testing.expect(!state.permits(.set, "mem:astrid:doc-1"));
    try testing.expect(!state.permits(.exec, "auth:mint:astrid"));
}

test {
    @import("std").testing.refAllDecls(@This());
}
