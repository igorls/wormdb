//! Org↔org trust delegation on the verifiable append-log (#66).
//!
//! A GRANTING org publishes capability grants (and later revocations) for
//! DELEGATED orgs as ordinary JSON events on its own well-known append-log:
//!
//!   log id convention: "trust:<granting_org_hex64>"
//!
//! Event JSON payloads (same style as coordination.zig events):
//!
//!   {"t":"trust.grant","from_org":"<hex64>","to_org":"<hex64>",
//!    "caps":["read","write","append"],"prefixes":["mem:acme:",...],
//!    "expires_at_ms":N,"granted_at_ms":N,"sig":"<hex128>"}
//!   {"t":"trust.revoke","from_org":"<hex64>","to_org":"<hex64>",
//!    "grant_seq":N,"revoked_at_ms":N,"sig":"<hex128>"}
//!
//! `sig` is a plain Ed25519 detached signature (64 bytes, hex128) by the
//! GRANTING org's ORG key over deterministic, versioned canonical bytes
//! (see `encodeGrantBytes` / `encodeRevokeBytes`). Because the events ride
//! the existing append-log primitive they are hash-chained, WORM, and
//! covered by the existing checkpoint/witness/proof-bundle EXECs — a
//! "witnessed grant" is simply a checkpoint whose range covers the grant's
//! seq plus a peer countersignature obtained via `append_log_witness_request`.
//!
//! `foldTrust` is the pure verifier: it re-verifies EVERY event signature
//! against the event's own canonical bytes (skipping + counting invalid
//! events) and applies grants − revocations − expiry at a given time, so any
//! peer holding the log can independently derive the active capability set.

const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const append_log = @import("append_log.zig");

const Ed25519 = std.crypto.sign.Ed25519;

/// Canonical signing context for grant events (version-bumped on change).
pub const GRANT_CONTEXT: []const u8 = "wormdb.trust.grant.v1\x00";
/// Canonical signing context for revoke events.
pub const REVOKE_CONTEXT: []const u8 = "wormdb.trust.revoke.v1\x00";

pub const ORG_KEY_LEN = 32;
pub const SIG_LEN = 64;

/// Capability bits. Replication write ops (set/vinsert/delete) require WRITE.
pub const CAP_READ: u8 = 1;
pub const CAP_WRITE: u8 = 2;
pub const CAP_APPEND: u8 = 4;
pub const CAP_ALL: u8 = CAP_READ | CAP_WRITE | CAP_APPEND;

/// Log id prefix — the full id is "trust:" ++ lowercase hex of the granting
/// org's 32-byte Ed25519 public key.
pub const LOG_ID_PREFIX: []const u8 = "trust:";

/// Global fold-cache generation. `trust_revoke` bumps it so any cached fold
/// (see cluster/org_trust.zig DynamicTrust) is invalidated immediately
/// instead of waiting out the ≤5s TTL — a locally-observed revocation takes
/// effect on the very next authorization check.
pub var fold_generation = std.atomic.Value(u64).init(0);

pub fn foldGeneration() u64 {
    return fold_generation.load(.acquire);
}

pub fn bumpFoldGeneration() void {
    _ = fold_generation.fetchAdd(1, .release);
}

// ╔═══════════════════════════════════════════════╗
// ║  Canonical signed bytes                        ║
// ╚═══════════════════════════════════════════════╝

pub const GrantBody = struct {
    from_org: [ORG_KEY_LEN]u8,
    to_org: [ORG_KEY_LEN]u8,
    cap_bits: u8,
    prefixes: []const []const u8,
    /// 0 = never expires.
    expires_at_ms: u64,
    granted_at_ms: u64,
};

pub const RevokeBody = struct {
    from_org: [ORG_KEY_LEN]u8,
    to_org: [ORG_KEY_LEN]u8,
    /// Append-log seq of the grant event being revoked.
    grant_seq: u64,
    revoked_at_ms: u64,
};

/// Deterministic canonical bytes signed by the granting org for a grant:
///   "wormdb.trust.grant.v1\0" ++ from_org(32) ++ to_org(32) ++ u8 cap_bits
///   ++ u32 prefix_count ++ (u32 len ++ prefix)* ++ u64 expires_at_ms
///   ++ u64 granted_at_ms
/// All integers big-endian (repo wire convention).
pub fn encodeGrantBytes(allocator: std.mem.Allocator, g: GrantBody) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, GRANT_CONTEXT);
    try out.appendSlice(allocator, g.from_org[0..]);
    try out.appendSlice(allocator, g.to_org[0..]);
    try out.append(allocator, g.cap_bits);
    try appendU32(&out, allocator, @intCast(g.prefixes.len));
    for (g.prefixes) |prefix| {
        try appendU32(&out, allocator, @intCast(prefix.len));
        try out.appendSlice(allocator, prefix);
    }
    try appendU64(&out, allocator, g.expires_at_ms);
    try appendU64(&out, allocator, g.granted_at_ms);
    return out.toOwnedSlice(allocator);
}

/// Deterministic canonical bytes signed by the granting org for a revocation:
///   "wormdb.trust.revoke.v1\0" ++ from_org(32) ++ to_org(32)
///   ++ u64 grant_seq ++ u64 revoked_at_ms
pub fn encodeRevokeBytes(allocator: std.mem.Allocator, r: RevokeBody) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, REVOKE_CONTEXT);
    try out.appendSlice(allocator, r.from_org[0..]);
    try out.appendSlice(allocator, r.to_org[0..]);
    try appendU64(&out, allocator, r.grant_seq);
    try appendU64(&out, allocator, r.revoked_at_ms);
    return out.toOwnedSlice(allocator);
}

/// Ed25519 detached signature over canonical bytes with a 64-byte secret key
/// (same key material shape as meshguard org keys).
pub fn signBytes(msg: []const u8, secret_key: [SIG_LEN]u8) ![SIG_LEN]u8 {
    const sk = try Ed25519.SecretKey.fromBytes(secret_key);
    const kp = try Ed25519.KeyPair.fromSecretKey(sk);
    const sig = try kp.sign(msg, null);
    return sig.toBytes();
}

/// Verify a detached Ed25519 signature against a 32-byte org public key.
pub fn verifyBytes(msg: []const u8, sig_bytes: [SIG_LEN]u8, org_pubkey: [ORG_KEY_LEN]u8) bool {
    const pk = Ed25519.PublicKey.fromBytes(org_pubkey) catch return false;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(msg, pk) catch return false;
    return true;
}

/// "trust:<lowercase hex64 of org pubkey>" — the org's well-known trust log.
pub fn logIdForOrg(allocator: std.mem.Allocator, org_pubkey: [ORG_KEY_LEN]u8) ![]u8 {
    const hex = std.fmt.bytesToHex(org_pubkey, .lower);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ LOG_ID_PREFIX, hex[0..] });
}

// ╔═══════════════════════════════════════════════╗
// ║  Pure fold                                     ║
// ╚═══════════════════════════════════════════════╝

/// One decoded trust event from the log (fields parsed from the JSON payload,
/// `seq` from the append-log envelope).
pub const TrustEvent = struct {
    seq: u64,
    kind: Kind,
    from_org: [ORG_KEY_LEN]u8,
    to_org: [ORG_KEY_LEN]u8,
    /// grant only.
    cap_bits: u8 = 0,
    prefixes: []const []const u8 = &.{},
    expires_at_ms: u64 = 0,
    granted_at_ms: u64 = 0,
    /// revoke only: seq of the grant being revoked.
    grant_seq: u64 = 0,
    revoked_at_ms: u64 = 0,
    sig: [SIG_LEN]u8,

    pub const Kind = enum { grant, revoke };
};

/// One active delegated capability produced by the fold.
pub const Capability = struct {
    to_org: [ORG_KEY_LEN]u8,
    cap_bits: u8,
    prefixes: []const []const u8,
    /// Seq of the grant event on the log — the handle for revocation and
    /// checkpoint/witness coverage.
    grant_seq: u64,
    expires_at_ms: u64,
    granted_at_ms: u64,
};

pub const FoldResult = struct {
    /// Active capabilities at `at_ms`, in grant-seq order. Prefix slices
    /// reference the input events (no copies).
    capabilities: []Capability,
    /// Events skipped because their signature did not verify, their
    /// `from_org` was not the log's granting org, or (revoke) they were
    /// otherwise unusable. Invalid events NEVER change the capability set.
    invalid_events: usize,

    pub fn deinit(self: *FoldResult, allocator: std.mem.Allocator) void {
        allocator.free(self.capabilities);
        self.* = undefined;
    }
};

/// Pure fold of a granting org's trust events (seq-ascending) into the active
/// capability set at time `at_ms`.
///
/// Rules:
/// - EVERY event's signature is re-verified against its canonical bytes and
///   the event's `from_org`; additionally `from_org` must equal
///   `granting_org` (the log owner) — a validly self-signed grant by some
///   OTHER org smuggled onto this log confers nothing. Failures are skipped
///   and counted in `invalid_events`.
/// - A valid grant activates a capability keyed by its own log seq.
/// - A valid revoke deactivates the capability whose grant seq matches
///   `grant_seq` AND whose to_org matches — a revoke of a nonexistent or
///   mismatched grant is a signed no-op (not counted invalid).
/// - Expiry: a grant with `expires_at_ms != 0 and expires_at_ms <= at_ms`
///   is not active.
pub fn foldTrust(
    allocator: std.mem.Allocator,
    granting_org: [ORG_KEY_LEN]u8,
    events: []const TrustEvent,
    at_ms: u64,
) !FoldResult {
    var active: std.ArrayListUnmanaged(Capability) = .empty;
    errdefer active.deinit(allocator);
    var invalid: usize = 0;

    for (events) |ev| {
        if (!std.mem.eql(u8, ev.from_org[0..], granting_org[0..])) {
            invalid += 1;
            continue;
        }
        switch (ev.kind) {
            .grant => {
                const canonical = try encodeGrantBytes(allocator, .{
                    .from_org = ev.from_org,
                    .to_org = ev.to_org,
                    .cap_bits = ev.cap_bits,
                    .prefixes = ev.prefixes,
                    .expires_at_ms = ev.expires_at_ms,
                    .granted_at_ms = ev.granted_at_ms,
                });
                defer allocator.free(canonical);
                if (!verifyBytes(canonical, ev.sig, ev.from_org)) {
                    invalid += 1;
                    continue;
                }
                try active.append(allocator, .{
                    .to_org = ev.to_org,
                    .cap_bits = ev.cap_bits,
                    .prefixes = ev.prefixes,
                    .grant_seq = ev.seq,
                    .expires_at_ms = ev.expires_at_ms,
                    .granted_at_ms = ev.granted_at_ms,
                });
            },
            .revoke => {
                const canonical = try encodeRevokeBytes(allocator, .{
                    .from_org = ev.from_org,
                    .to_org = ev.to_org,
                    .grant_seq = ev.grant_seq,
                    .revoked_at_ms = ev.revoked_at_ms,
                });
                defer allocator.free(canonical);
                if (!verifyBytes(canonical, ev.sig, ev.from_org)) {
                    invalid += 1;
                    continue;
                }
                var i: usize = 0;
                while (i < active.items.len) : (i += 1) {
                    const cap = active.items[i];
                    if (cap.grant_seq == ev.grant_seq and
                        std.mem.eql(u8, cap.to_org[0..], ev.to_org[0..]))
                    {
                        _ = active.orderedRemove(i);
                        break;
                    }
                }
            },
        }
    }

    // Expiry pass at at_ms.
    var i: usize = 0;
    while (i < active.items.len) {
        const cap = active.items[i];
        if (cap.expires_at_ms != 0 and cap.expires_at_ms <= at_ms) {
            _ = active.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    return .{
        .capabilities = try active.toOwnedSlice(allocator),
        .invalid_events = invalid,
    };
}

// ╔═══════════════════════════════════════════════╗
// ║  Log access (JSON decode)                      ║
// ╚═══════════════════════════════════════════════╝

const TrustEventJson = struct {
    t: []const u8 = "",
    from_org: []const u8 = "",
    to_org: []const u8 = "",
    caps: []const []const u8 = &.{},
    prefixes: []const []const u8 = &.{},
    expires_at_ms: u64 = 0,
    granted_at_ms: u64 = 0,
    grant_seq: u64 = 0,
    revoked_at_ms: u64 = 0,
    sig: []const u8 = "",
};

pub const LoadedEvents = struct {
    events: []TrustEvent,
    /// Envelopes/payloads on the log that could not be decoded as trust
    /// events (bad envelope, non-JSON, unknown type, malformed hex fields).
    /// Reported alongside foldTrust's `invalid_events`.
    malformed: usize,
};

/// Scan a trust log's event prefix (scanPrefix locks each shard internally —
/// the caller must hold NO shard locks; same contract as coordination.zig's
/// loadTaskEvents) and decode the trust events in seq order. All returned
/// slices are owned by `allocator` (callers pass an arena).
pub fn loadTrustEvents(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
) !LoadedEvents {
    const prefix = try append_log.eventKeyPrefix(allocator, log_id);
    const results = try store.scanPrefix(prefix, 0, allocator);

    var list: std.ArrayListUnmanaged(TrustEvent) = .empty;
    errdefer list.deinit(allocator);
    var malformed: usize = 0;

    for (results) |r| {
        const view = append_log.decodeEnvelope(r.value) catch {
            malformed += 1;
            continue;
        };
        const parsed = std.json.parseFromSliceLeaky(TrustEventJson, allocator, view.payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            malformed += 1;
            continue;
        };

        const kind: TrustEvent.Kind = if (std.mem.eql(u8, parsed.t, "trust.grant"))
            .grant
        else if (std.mem.eql(u8, parsed.t, "trust.revoke"))
            .revoke
        else {
            malformed += 1;
            continue;
        };

        const from_org = parseOrgHex(parsed.from_org) orelse {
            malformed += 1;
            continue;
        };
        const to_org = parseOrgHex(parsed.to_org) orelse {
            malformed += 1;
            continue;
        };
        const sig = parseSigHex(parsed.sig) orelse {
            malformed += 1;
            continue;
        };
        const cap_bits: u8 = if (kind == .grant) capBitsFromNames(parsed.caps) orelse {
            malformed += 1;
            continue;
        } else 0;

        try list.append(allocator, .{
            .seq = view.seq,
            .kind = kind,
            .from_org = from_org,
            .to_org = to_org,
            .cap_bits = cap_bits,
            .prefixes = parsed.prefixes,
            .expires_at_ms = parsed.expires_at_ms,
            .granted_at_ms = parsed.granted_at_ms,
            .grant_seq = parsed.grant_seq,
            .revoked_at_ms = parsed.revoked_at_ms,
            .sig = sig,
        });
    }

    return .{
        .events = try list.toOwnedSlice(allocator),
        .malformed = malformed,
    };
}

// ╔═══════════════════════════════════════════════╗
// ║  Small helpers                                 ║
// ╚═══════════════════════════════════════════════╝

pub fn parseOrgHex(hex: []const u8) ?[ORG_KEY_LEN]u8 {
    if (hex.len != ORG_KEY_LEN * 2) return null;
    var out: [ORG_KEY_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

pub fn parseSigHex(hex: []const u8) ?[SIG_LEN]u8 {
    if (hex.len != SIG_LEN * 2) return null;
    var out: [SIG_LEN]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// Map cap names to bits. Null on an unknown name or an empty/zero set.
pub fn capBitsFromNames(names: []const []const u8) ?u8 {
    var bits: u8 = 0;
    for (names) |name| {
        if (std.mem.eql(u8, name, "read")) {
            bits |= CAP_READ;
        } else if (std.mem.eql(u8, name, "write")) {
            bits |= CAP_WRITE;
        } else if (std.mem.eql(u8, name, "append")) {
            bits |= CAP_APPEND;
        } else {
            return null;
        }
    }
    if (bits == 0) return null;
    return bits;
}

pub const CAP_NAMES = [_]struct { bit: u8, name: []const u8 }{
    .{ .bit = CAP_READ, .name = "read" },
    .{ .bit = CAP_WRITE, .name = "write" },
    .{ .bit = CAP_APPEND, .name = "append" },
};

fn appendU32(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], value, .big);
    try out.appendSlice(allocator, buf[0..]);
}

fn appendU64(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], value, .big);
    try out.appendSlice(allocator, buf[0..]);
}

// ╔═══════════════════════════════════════════════╗
// ║  Tests                                         ║
// ╚═══════════════════════════════════════════════╝

const testing = std.testing;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn testKeyPair() Ed25519.KeyPair {
    return Ed25519.KeyPair.generate(testIo());
}

fn hexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

/// Build a fully-signed grant event for fold tests.
fn signedGrantEvent(kp: Ed25519.KeyPair, seq: u64, to_org: [32]u8, cap_bits: u8, prefixes: []const []const u8, expires_at_ms: u64, granted_at_ms: u64) !TrustEvent {
    const from_org = kp.public_key.toBytes();
    const canonical = try encodeGrantBytes(testing.allocator, .{
        .from_org = from_org,
        .to_org = to_org,
        .cap_bits = cap_bits,
        .prefixes = prefixes,
        .expires_at_ms = expires_at_ms,
        .granted_at_ms = granted_at_ms,
    });
    defer testing.allocator.free(canonical);
    return .{
        .seq = seq,
        .kind = .grant,
        .from_org = from_org,
        .to_org = to_org,
        .cap_bits = cap_bits,
        .prefixes = prefixes,
        .expires_at_ms = expires_at_ms,
        .granted_at_ms = granted_at_ms,
        .sig = try signBytes(canonical, kp.secret_key.toBytes()),
    };
}

fn signedRevokeEvent(kp: Ed25519.KeyPair, seq: u64, to_org: [32]u8, grant_seq: u64, revoked_at_ms: u64) !TrustEvent {
    const from_org = kp.public_key.toBytes();
    const canonical = try encodeRevokeBytes(testing.allocator, .{
        .from_org = from_org,
        .to_org = to_org,
        .grant_seq = grant_seq,
        .revoked_at_ms = revoked_at_ms,
    });
    defer testing.allocator.free(canonical);
    return .{
        .seq = seq,
        .kind = .revoke,
        .from_org = from_org,
        .to_org = to_org,
        .grant_seq = grant_seq,
        .revoked_at_ms = revoked_at_ms,
        .sig = try signBytes(canonical, kp.secret_key.toBytes()),
    };
}

test "canonical grant/revoke bytes: golden encoding" {
    const from: [32]u8 = @splat(0xAA);
    const to: [32]u8 = @splat(0xBB);
    const prefixes = [_][]const u8{ "mem:acme:", "vec:" };

    const grant = try encodeGrantBytes(testing.allocator, .{
        .from_org = from,
        .to_org = to,
        .cap_bits = CAP_READ | CAP_WRITE,
        .prefixes = prefixes[0..],
        .expires_at_ms = 1_700_000_000_000,
        .granted_at_ms = 1_600_000_000_000,
    });
    defer testing.allocator.free(grant);

    // Layout check: context(22) + from(32) + to(32) + cap(1) + count(4)
    //   + (4+9) + (4+4) + expires(8) + granted(8) = 128 bytes.
    try testing.expectEqual(@as(usize, 128), grant.len);
    const grant_hex = try hexAlloc(testing.allocator, grant);
    defer testing.allocator.free(grant_hex);
    try testing.expectEqualStrings(
        "776f726d64622e74727573742e6772616e742e763100" ++ // "wormdb.trust.grant.v1\0"
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "03" ++ // cap_bits read|write
            "00000002" ++ // prefix_count
            "00000009" ++ "6d656d3a61636d653a" ++ // "mem:acme:"
            "00000004" ++ "7665633a" ++ // "vec:"
            "0000018bcfe56800" ++ // expires_at_ms 1_700_000_000_000
            "00000174876e8000", // granted_at_ms 1_600_000_000_000
        grant_hex,
    );

    const revoke = try encodeRevokeBytes(testing.allocator, .{
        .from_org = from,
        .to_org = to,
        .grant_seq = 7,
        .revoked_at_ms = 1_700_000_000_001,
    });
    defer testing.allocator.free(revoke);

    // context(23) + from(32) + to(32) + grant_seq(8) + revoked(8) = 103 bytes.
    try testing.expectEqual(@as(usize, 103), revoke.len);
    const revoke_hex = try hexAlloc(testing.allocator, revoke);
    defer testing.allocator.free(revoke_hex);
    try testing.expectEqualStrings(
        "776f726d64622e74727573742e7265766f6b652e763100" ++ // "wormdb.trust.revoke.v1\0"
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
            "0000000000000007" ++
            "0000018bcfe56801",
        revoke_hex,
    );
}

test "sign/verify roundtrip and tamper detection" {
    const kp = testKeyPair();
    const to: [32]u8 = @splat(0x22);
    const prefixes = [_][]const u8{"mem:acme:"};

    const msg = try encodeGrantBytes(testing.allocator, .{
        .from_org = kp.public_key.toBytes(),
        .to_org = to,
        .cap_bits = CAP_WRITE,
        .prefixes = prefixes[0..],
        .expires_at_ms = 0,
        .granted_at_ms = 42,
    });
    defer testing.allocator.free(msg);

    const sig = try signBytes(msg, kp.secret_key.toBytes());
    try testing.expect(verifyBytes(msg, sig, kp.public_key.toBytes()));

    // Tampered message fails.
    const tampered = try testing.allocator.dupe(u8, msg);
    defer testing.allocator.free(tampered);
    tampered[GRANT_CONTEXT.len + 70] ^= 0x01; // inside cap/prefix region
    try testing.expect(!verifyBytes(tampered, sig, kp.public_key.toBytes()));

    // Tampered signature fails.
    var bad_sig = sig;
    bad_sig[10] ^= 0xFF;
    try testing.expect(!verifyBytes(msg, bad_sig, kp.public_key.toBytes()));

    // Wrong org key fails.
    const other = testKeyPair();
    try testing.expect(!verifyBytes(msg, sig, other.public_key.toBytes()));
}

test "foldTrust: grant active, revoke removes, expiry honored" {
    const kp = testKeyPair();
    const granting = kp.public_key.toBytes();
    const to: [32]u8 = @splat(0x22);
    const prefixes = [_][]const u8{"mem:acme:"};

    const grant = try signedGrantEvent(kp, 1, to, CAP_WRITE, prefixes[0..], 5000, 100);

    // Grant alone: active before expiry, gone at/after expiry.
    {
        var fold = try foldTrust(testing.allocator, granting, &.{grant}, 1000);
        defer fold.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), fold.capabilities.len);
        try testing.expectEqual(@as(usize, 0), fold.invalid_events);
        try testing.expectEqual(@as(u64, 1), fold.capabilities[0].grant_seq);
        try testing.expectEqual(CAP_WRITE, fold.capabilities[0].cap_bits);
        try testing.expectEqualStrings("mem:acme:", fold.capabilities[0].prefixes[0]);
    }
    {
        var fold = try foldTrust(testing.allocator, granting, &.{grant}, 5000);
        defer fold.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), fold.capabilities.len);
    }

    // Grant + revoke: gone even before expiry.
    const revoke = try signedRevokeEvent(kp, 2, to, 1, 200);
    {
        var fold = try foldTrust(testing.allocator, granting, &.{ grant, revoke }, 1000);
        defer fold.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), fold.capabilities.len);
        try testing.expectEqual(@as(usize, 0), fold.invalid_events);
    }

    // Revoke of a nonexistent grant is a signed no-op.
    const stray_revoke = try signedRevokeEvent(kp, 2, to, 99, 200);
    {
        var fold = try foldTrust(testing.allocator, granting, &.{ grant, stray_revoke }, 1000);
        defer fold.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), fold.capabilities.len);
    }
}

test "foldTrust: invalid signature and foreign from_org are skipped and counted" {
    const kp = testKeyPair();
    const granting = kp.public_key.toBytes();
    const to: [32]u8 = @splat(0x22);
    const prefixes = [_][]const u8{"mem:acme:"};

    var forged = try signedGrantEvent(kp, 1, to, CAP_WRITE, prefixes[0..], 0, 100);
    forged.cap_bits = CAP_ALL; // field mutated after signing → sig invalid

    // A grant validly self-signed by a DIFFERENT org, smuggled onto our log.
    const attacker = testKeyPair();
    const smuggled = try signedGrantEvent(attacker, 2, to, CAP_WRITE, prefixes[0..], 0, 100);

    const good = try signedGrantEvent(kp, 3, to, CAP_READ, prefixes[0..], 0, 100);

    var fold = try foldTrust(testing.allocator, granting, &.{ forged, smuggled, good }, 1000);
    defer fold.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), fold.invalid_events);
    try testing.expectEqual(@as(usize, 1), fold.capabilities.len);
    try testing.expectEqual(CAP_READ, fold.capabilities[0].cap_bits);
    try testing.expectEqual(@as(u64, 3), fold.capabilities[0].grant_seq);

    // A revoke whose signature does not verify must NOT remove the grant.
    var bad_revoke = try signedRevokeEvent(kp, 4, to, 3, 200);
    bad_revoke.grant_seq = 3;
    bad_revoke.sig[0] ^= 0xFF;
    var fold2 = try foldTrust(testing.allocator, granting, &.{ good, bad_revoke }, 1000);
    defer fold2.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), fold2.capabilities.len);
    try testing.expectEqual(@as(usize, 1), fold2.invalid_events);
}

test "foldTrust: multiple delegated orgs, revocation is per-grant" {
    const kp = testKeyPair();
    const granting = kp.public_key.toBytes();
    const org_b: [32]u8 = @splat(0x22);
    const org_c: [32]u8 = @splat(0x33);
    const p_b = [_][]const u8{"mem:acme:"};
    const p_c = [_][]const u8{ "globex:", "vec:globex:" };

    const g_b = try signedGrantEvent(kp, 1, org_b, CAP_WRITE, p_b[0..], 0, 100);
    const g_c = try signedGrantEvent(kp, 2, org_c, CAP_READ | CAP_APPEND, p_c[0..], 0, 100);
    const r_b = try signedRevokeEvent(kp, 3, org_b, 1, 200);

    var fold = try foldTrust(testing.allocator, granting, &.{ g_b, g_c, r_b }, 1000);
    defer fold.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), fold.capabilities.len);
    try testing.expectEqualSlices(u8, org_c[0..], fold.capabilities[0].to_org[0..]);
    try testing.expectEqual(@as(usize, 2), fold.capabilities[0].prefixes.len);
    try testing.expectEqual(CAP_READ | CAP_APPEND, fold.capabilities[0].cap_bits);
}

test "capBitsFromNames and logIdForOrg helpers" {
    const names_ok = [_][]const u8{ "read", "write" };
    try testing.expectEqual(@as(u8, 3), capBitsFromNames(names_ok[0..]).?);
    const names_bad = [_][]const u8{"admin"};
    try testing.expect(capBitsFromNames(names_bad[0..]) == null);
    try testing.expect(capBitsFromNames(&.{}) == null);

    const org: [32]u8 = @splat(0xAB);
    const log_id = try logIdForOrg(testing.allocator, org);
    defer testing.allocator.free(log_id);
    try testing.expectEqualStrings(
        "trust:abababababababababababababababababababababababababababababababab",
        log_id,
    );

    try testing.expect(parseOrgHex(log_id[LOG_ID_PREFIX.len..]) != null);
    try testing.expect(parseOrgHex("abcd") == null);
}
