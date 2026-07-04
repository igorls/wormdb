//! Org-certificate authorization for the WormWire replication channel (#63).
//!
//! Binds a MeshGuard org certificate to WormDB namespace grants: a replication
//! peer proves membership in an org (org-signed NodeCertificate + fresh
//! challenge signature with the cert's node key), and every replicated write is
//! then checked against the prefixes granted to that org.
//!
//! Everything here is pure crypto/data — no sockets, no OS branching — so it
//! compiles on every platform (the meshguard `identity.Org` module is
//! platform-neutral) and the handshake verification is unit-testable.

const std = @import("std");
const meshguard = @import("meshguard");
const core = @import("../core/mod.zig");

pub const Org = meshguard.identity.Org;
const Ed25519 = std.crypto.sign.Ed25519;

/// Server-generated nonce length for the W2 handshake.
pub const CHALLENGE_LEN = 32;
/// Serialized NodeCertificate length (meshguard wire format).
pub const CERT_WIRE_LEN = Org.NodeCertificate.WIRE_SIZE; // 186
/// Ed25519 detached signature length.
pub const SIG_LEN = 64;
/// The peer's full handshake reply: [186B cert][64B signature].
pub const HANDSHAKE_REPLY_LEN = CERT_WIRE_LEN + SIG_LEN; // 250

/// One org → namespace grant: nodes certified by `org_pubkey` may replicate
/// keys starting with any of `prefixes`.
pub const Grant = struct {
    org_pubkey: [32]u8,
    /// Human-readable label for logs only; carries no authorization meaning.
    name: []const u8 = "",
    prefixes: []const []const u8 = &.{},
};

/// The identity proven by a successful W2 handshake.
pub const PeerOrg = struct {
    org_pubkey: [32]u8,
    node_pubkey: [32]u8,
};

pub const HandshakeError = error{
    /// Org signature over the certificate does not verify.
    BadCertSignature,
    /// Certificate version unsupported or past its expiry.
    CertExpired,
    /// Certificate is genuine but issued by an org we have no grants for.
    OrgNotTrusted,
    /// Peer failed to prove possession of the certified node key.
    BadChallengeSignature,
};

/// Runtime org-trust state, built once at startup from `OrgTrustConfig` and
/// shared (read-only) by the TCP replication handler and the cluster's
/// outbound connections.
pub const OrgTrust = struct {
    /// True iff grants are configured (or config explicitly set enforce).
    /// When true: inbound legacy "WR" connections are rejected and every
    /// replicated key is checked against the peer org's grants.
    enforce: bool = false,
    grants: []const Grant = &.{},
    /// Our own org-signed certificate — required to answer a W2 challenge
    /// on outbound connections. Null means we can only speak legacy "WR".
    node_cert: ?Org.NodeCertificate = null,
    /// `node_cert` pre-serialized, sent verbatim in the handshake reply.
    node_cert_wire: ?[CERT_WIRE_LEN]u8 = null,

    pub fn orgTrusted(self: *const OrgTrust, org_pubkey: [32]u8) bool {
        for (self.grants) |g| {
            if (std.mem.eql(u8, &g.org_pubkey, &org_pubkey)) return true;
        }
        return false;
    }

    /// Deny-by-default: a key is authorized only if the org has a grant and
    /// one of its prefixes matches. An empty grant list authorizes nothing.
    pub fn keyAuthorized(self: *const OrgTrust, org_pubkey: [32]u8, key: []const u8) bool {
        for (self.grants) |g| {
            if (!std.mem.eql(u8, &g.org_pubkey, &org_pubkey)) continue;
            for (g.prefixes) |prefix| {
                if (std.mem.startsWith(u8, key, prefix)) return true;
            }
        }
        return false;
    }

    /// Build runtime trust from the JSON config section. Grant strings are
    /// referenced, not copied — `loadFromFile` keeps the config buffer alive
    /// for the process lifetime. Non-empty grants force `enforce` on
    /// (configuring trust and silently not enforcing it would be a trap).
    pub fn fromConfig(allocator: std.mem.Allocator, cfg: core.config.OrgTrustConfig) !OrgTrust {
        var out = OrgTrust{
            .enforce = cfg.enforce or cfg.grants.len > 0,
        };

        if (cfg.grants.len > 0) {
            const grants = try allocator.alloc(Grant, cfg.grants.len);
            errdefer allocator.free(grants);
            for (cfg.grants, 0..) |gc, i| {
                var pk: [32]u8 = undefined;
                const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(gc.org_pubkey) catch
                    return error.InvalidOrgPubkey;
                if (decoded_len != 32) return error.InvalidOrgPubkey;
                std.base64.standard.Decoder.decode(&pk, gc.org_pubkey) catch
                    return error.InvalidOrgPubkey;
                grants[i] = .{
                    .org_pubkey = pk,
                    .name = gc.name,
                    .prefixes = gc.prefixes,
                };
            }
            out.grants = grants;
        }

        if (cfg.node_cert_path) |path| {
            const cert = try Org.loadCertificate(allocator, path);
            var wire_buf: [CERT_WIRE_LEN]u8 = undefined;
            cert.serialize(&wire_buf);
            out.node_cert = cert;
            out.node_cert_wire = wire_buf;
        }

        return out;
    }
};

/// The message signed by the peer's node key: challenge ++ serialized cert.
/// Including the cert binds the signature to this identity claim; including
/// the fresh server challenge prevents replay.
pub fn handshakeMessage(
    challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
) [CHALLENGE_LEN + CERT_WIRE_LEN]u8 {
    var msg: [CHALLENGE_LEN + CERT_WIRE_LEN]u8 = undefined;
    @memcpy(msg[0..CHALLENGE_LEN], challenge);
    @memcpy(msg[CHALLENGE_LEN..], cert_wire);
    return msg;
}

/// Pure server-side verification of a W2 handshake reply. Checks, in order:
///   (a) org signature over the certificate (Org.verifyCertificate)
///   (b) certificate validity window (isValid: version + expiry)
///   (c) the issuing org is one we have grants for
///   (d) possession: Ed25519 verify of sig over (challenge ++ cert_wire)
///       against the certified node key
pub fn verifyPeerHandshake(
    trust: *const OrgTrust,
    challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
    sig: *const [SIG_LEN]u8,
) HandshakeError!PeerOrg {
    const cert = Org.NodeCertificate.deserialize(cert_wire);
    if (!Org.verifyCertificate(&cert)) return error.BadCertSignature;
    if (!cert.isValid()) return error.CertExpired;
    if (!trust.orgTrusted(cert.org_pubkey)) return error.OrgNotTrusted;

    const msg = handshakeMessage(challenge, cert_wire);
    const node_pk = Ed25519.PublicKey.fromBytes(cert.node_pubkey) catch
        return error.BadChallengeSignature;
    const signature = Ed25519.Signature.fromBytes(sig.*);
    signature.verify(&msg, node_pk) catch return error.BadChallengeSignature;

    return .{
        .org_pubkey = cert.org_pubkey,
        .node_pubkey = cert.node_pubkey,
    };
}

// ─── Tests ───

const testing = std.testing;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "keyAuthorized: prefix hit/miss, multiple orgs, untrusted org" {
    const org_a: [32]u8 = @splat(0xAA);
    const org_b: [32]u8 = @splat(0xBB);
    const org_c: [32]u8 = @splat(0xCC);

    const a_prefixes = [_][]const u8{ "acme:", "vec:acme:" };
    const b_prefixes = [_][]const u8{"globex:"};
    const grants = [_]Grant{
        .{ .org_pubkey = org_a, .name = "acme", .prefixes = a_prefixes[0..] },
        .{ .org_pubkey = org_b, .name = "globex", .prefixes = b_prefixes[0..] },
    };
    const trust = OrgTrust{ .enforce = true, .grants = grants[0..] };

    // Prefix hits
    try testing.expect(trust.keyAuthorized(org_a, "acme:users:1"));
    try testing.expect(trust.keyAuthorized(org_a, "vec:acme:emb:1"));
    try testing.expect(trust.keyAuthorized(org_b, "globex:orders:9"));

    // Prefix misses — wrong namespace, cross-org access
    try testing.expect(!trust.keyAuthorized(org_a, "globex:orders:9"));
    try testing.expect(!trust.keyAuthorized(org_b, "acme:users:1"));
    try testing.expect(!trust.keyAuthorized(org_a, "acm")); // shorter than prefix
    try testing.expect(!trust.keyAuthorized(org_a, "other:key"));

    // Untrusted org: genuine key, no grants at all
    try testing.expect(!trust.keyAuthorized(org_c, "acme:users:1"));
    try testing.expect(trust.orgTrusted(org_a));
    try testing.expect(trust.orgTrusted(org_b));
    try testing.expect(!trust.orgTrusted(org_c));

    // Empty trust authorizes nothing (deny-by-default)
    const empty = OrgTrust{};
    try testing.expect(!empty.keyAuthorized(org_a, "acme:users:1"));
    try testing.expect(!empty.orgTrusted(org_a));
}

test "verifyPeerHandshake: cert roundtrip accept path" {
    const org_kp = Org.generateOrgKeyPair();
    const node_kp = Ed25519.KeyPair.generate(testIo());

    const cert = try Org.issueCertificate(org_kp, node_kp.public_key.toBytes(), "node-1", 0);
    var cert_wire: [CERT_WIRE_LEN]u8 = undefined;
    cert.serialize(&cert_wire);

    const prefixes = [_][]const u8{"acme:"};
    const grants = [_]Grant{.{
        .org_pubkey = org_kp.public_key.toBytes(),
        .prefixes = prefixes[0..],
    }};
    const trust = OrgTrust{ .enforce = true, .grants = grants[0..] };

    var challenge: [CHALLENGE_LEN]u8 = @splat(0x42);
    const msg = handshakeMessage(&challenge, &cert_wire);
    const sig = (try node_kp.sign(&msg, null)).toBytes();

    const peer = try verifyPeerHandshake(&trust, &challenge, &cert_wire, &sig);
    try testing.expectEqualSlices(u8, &org_kp.public_key.toBytes(), &peer.org_pubkey);
    try testing.expectEqualSlices(u8, &node_kp.public_key.toBytes(), &peer.node_pubkey);

    // The proven org is then usable for grant checks
    try testing.expect(trust.keyAuthorized(peer.org_pubkey, "acme:k"));
    try testing.expect(!trust.keyAuthorized(peer.org_pubkey, "other:k"));
}

test "verifyPeerHandshake: reject paths" {
    const org_kp = Org.generateOrgKeyPair();
    const node_kp = Ed25519.KeyPair.generate(testIo());

    const cert = try Org.issueCertificate(org_kp, node_kp.public_key.toBytes(), "node-1", 0);
    var cert_wire: [CERT_WIRE_LEN]u8 = undefined;
    cert.serialize(&cert_wire);

    const prefixes = [_][]const u8{"acme:"};
    const grants = [_]Grant{.{
        .org_pubkey = org_kp.public_key.toBytes(),
        .prefixes = prefixes[0..],
    }};
    const trust = OrgTrust{ .enforce = true, .grants = grants[0..] };

    var challenge: [CHALLENGE_LEN]u8 = @splat(0x42);
    const msg = handshakeMessage(&challenge, &cert_wire);
    const good_sig = (try node_kp.sign(&msg, null)).toBytes();

    // (a) Tampered cert → org signature invalid
    {
        var bad_wire = cert_wire;
        bad_wire[40] ^= 0xFF; // inside node_pubkey field
        try testing.expectError(error.BadCertSignature, verifyPeerHandshake(&trust, &challenge, &bad_wire, &good_sig));
    }

    // (b) Expired cert (properly org-signed, expiry in the past)
    {
        const expired = try Org.issueCertificate(org_kp, node_kp.public_key.toBytes(), "node-1", 1);
        var expired_wire: [CERT_WIRE_LEN]u8 = undefined;
        expired.serialize(&expired_wire);
        const expired_msg = handshakeMessage(&challenge, &expired_wire);
        const expired_sig = (try node_kp.sign(&expired_msg, null)).toBytes();
        try testing.expectError(error.CertExpired, verifyPeerHandshake(&trust, &challenge, &expired_wire, &expired_sig));
    }

    // (c) Genuine cert from an org we have no grants for
    {
        const other_org = Org.generateOrgKeyPair();
        const foreign = try Org.issueCertificate(other_org, node_kp.public_key.toBytes(), "node-x", 0);
        var foreign_wire: [CERT_WIRE_LEN]u8 = undefined;
        foreign.serialize(&foreign_wire);
        const foreign_msg = handshakeMessage(&challenge, &foreign_wire);
        const foreign_sig = (try node_kp.sign(&foreign_msg, null)).toBytes();
        try testing.expectError(error.OrgNotTrusted, verifyPeerHandshake(&trust, &challenge, &foreign_wire, &foreign_sig));
    }

    // (d) Signature by a key other than the certified node key (stolen cert)
    {
        const thief_kp = Ed25519.KeyPair.generate(testIo());
        const thief_sig = (try thief_kp.sign(&msg, null)).toBytes();
        try testing.expectError(error.BadChallengeSignature, verifyPeerHandshake(&trust, &challenge, &cert_wire, &thief_sig));
    }

    // (d) Signature over a different challenge (replay of an old handshake)
    {
        var other_challenge: [CHALLENGE_LEN]u8 = @splat(0x43);
        try testing.expectError(error.BadChallengeSignature, verifyPeerHandshake(&trust, &other_challenge, &cert_wire, &good_sig));
    }

    // Empty trust rejects even a fully valid handshake (deny-by-default)
    {
        const empty = OrgTrust{};
        try testing.expectError(error.OrgNotTrusted, verifyPeerHandshake(&empty, &challenge, &cert_wire, &good_sig));
    }
}

test "OrgTrust.fromConfig: base64 grants, enforce inference, bad pubkey" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const org_pk: [32]u8 = @splat(0x11);
    var b64_buf: [44]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &org_pk);

    const prefixes = [_][]const u8{"acme:"};
    const grants_cfg = [_]core.config.OrgGrantConfig{.{
        .org_pubkey = b64,
        .name = "acme",
        .prefixes = prefixes[0..],
    }};

    // Grants present → enforce inferred even when the flag is false
    const trust = try OrgTrust.fromConfig(alloc, .{
        .enforce = false,
        .grants = grants_cfg[0..],
    });
    try testing.expect(trust.enforce);
    try testing.expect(trust.orgTrusted(org_pk));
    try testing.expect(trust.keyAuthorized(org_pk, "acme:k"));
    try testing.expect(trust.node_cert == null);

    // No grants, explicit enforce → enforce on, nothing authorized
    const strict = try OrgTrust.fromConfig(alloc, .{ .enforce = true });
    try testing.expect(strict.enforce);
    try testing.expect(!strict.keyAuthorized(org_pk, "acme:k"));

    // Default config → open (legacy) behavior
    const open = try OrgTrust.fromConfig(alloc, .{});
    try testing.expect(!open.enforce);

    // Malformed base64 pubkey → error
    const bad = [_]core.config.OrgGrantConfig{.{ .org_pubkey = "not-base64!!", .prefixes = prefixes[0..] }};
    try testing.expectError(error.InvalidOrgPubkey, OrgTrust.fromConfig(alloc, .{ .grants = bad[0..] }));

    // Wrong-length pubkey → error
    var short_buf: [24]u8 = undefined;
    const short_b64 = std.base64.standard.Encoder.encode(&short_buf, org_pk[0..16]);
    const short = [_]core.config.OrgGrantConfig{.{ .org_pubkey = short_b64, .prefixes = prefixes[0..] }};
    try testing.expectError(error.InvalidOrgPubkey, OrgTrust.fromConfig(alloc, .{ .grants = short[0..] }));
}
