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
const trust_log = @import("../proof/trust_log.zig");
const Store = @import("../storage/store.zig").Store;
const secure_channel = @import("secure_channel.zig");

pub const Org = meshguard.identity.Org;
const Ed25519 = std.crypto.sign.Ed25519;

/// Capability bits shared with the trust-log fold (#66).
pub const CAP_READ = trust_log.CAP_READ;
pub const CAP_WRITE = trust_log.CAP_WRITE;
pub const CAP_APPEND = trust_log.CAP_APPEND;

/// Server-generated nonce length for the W2 handshake.
pub const CHALLENGE_LEN = 32;
/// Serialized NodeCertificate length (meshguard wire format).
pub const CERT_WIRE_LEN = Org.NodeCertificate.WIRE_SIZE; // 186
/// Ed25519 detached signature length.
pub const SIG_LEN = 64;
/// The peer's full handshake reply: [186B cert][64B signature].
pub const HANDSHAKE_REPLY_LEN = CERT_WIRE_LEN + SIG_LEN; // 250
/// Server hello of the mutual "W3" handshake: [32B server challenge][186B server
/// cert][64B sig over client_challenge ++ server cert].
pub const SERVER_HELLO_LEN = CHALLENGE_LEN + CERT_WIRE_LEN + SIG_LEN; // 282

/// One org → namespace grant: nodes certified by `org_pubkey` may replicate
/// keys starting with any of `prefixes`.
pub const Grant = struct {
    org_pubkey: [32]u8,
    /// Human-readable label for logs only; carries no authorization meaning.
    name: []const u8 = "",
    prefixes: []const []const u8 = &.{},
};

/// The identity proven by a successful W2/W3 handshake.
pub const PeerOrg = struct {
    org_pubkey: [32]u8,
    node_pubkey: [32]u8,
};

/// A fully authenticated replication peer (W3) plus the session keys agreed
/// with it. Null on a legacy link.
pub const PeerSession = struct {
    org: PeerOrg,
    keys: secure_channel.SessionKeys,
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
    /// Accept inbound legacy "W2" handshakes (one-way authenticated,
    /// plaintext) while enforcing. Needed only during a rolling upgrade of
    /// peers that predate W3; set false afterwards so the plaintext path is
    /// closed. Outbound always speaks W3 when this node has a certificate.
    accept_w2: bool = true,
    /// Our own org-signed certificate — required to answer a W2 challenge
    /// on outbound connections. Null means we can only speak legacy "WR".
    node_cert: ?Org.NodeCertificate = null,
    /// `node_cert` pre-serialized, sent verbatim in the handshake reply.
    node_cert_wire: ?[CERT_WIRE_LEN]u8 = null,
    /// Dynamic delegated-org authorization (#66): a cached fold of OUR org's
    /// outbound trust log ("trust:<our_org_hex>"). Consulted by the WR frame
    /// loop only after the static `keyAuthorized` fails. Wired by the
    /// composition root only when enforcement is on AND this node has a cert
    /// (so "our org" is known); null everywhere else keeps #63 semantics.
    dynamic: ?*DynamicTrust = null,

    pub fn orgTrusted(self: *const OrgTrust, org_pubkey: [32]u8) bool {
        for (self.grants) |g| {
            if (std.mem.eql(u8, &g.org_pubkey, &org_pubkey)) return true;
        }
        return false;
    }

    /// True when `org_pubkey` is the org that certified THIS node. Members of
    /// our own org are full peers: they pass the handshake in both directions
    /// and replicate every key, with no grant entry needed.
    pub fn sameOrg(self: *const OrgTrust, org_pubkey: [32]u8) bool {
        const cert = self.node_cert orelse return false;
        return std.mem.eql(u8, &cert.org_pubkey, &org_pubkey);
    }

    /// Orgs whose certified nodes may complete a replication handshake with
    /// us, inbound or outbound: our own org, or any org with a configured
    /// grant. List a delegated org with `"prefixes": []` to admit it while its
    /// key scope comes from the trust log.
    pub fn peerOrgTrusted(self: *const OrgTrust, org_pubkey: [32]u8) bool {
        return self.sameOrg(org_pubkey) or self.orgTrusted(org_pubkey);
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
            .accept_w2 = cfg.accept_w2,
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

/// Dynamic delegated-org authorization from the trust log (#66).
///
/// The enforcement node folds its OWN org's trust log
/// ("trust:<our_org_hex>"): our org's outbound grants say which OTHER
/// (delegated) orgs may touch which key prefixes with which capability.
/// Static grants (#63 config) authorize member orgs; this authorizes
/// delegated orgs. The fold is cached:
///
///   - TTL: a fold older than `ttl_ms` (default 5000) is recomputed lazily
///     on the next check — a revocation replicated from a peer is therefore
///     effective within ≤5s + next op.
///   - Generation: the local `trust_revoke` EXEC bumps
///     `trust_log.fold_generation`; a cached fold from an older generation
///     is discarded immediately, so a locally-appended revocation fails the
///     very next op regardless of TTL.
///
/// Thread-safe: replication connections are separate threads; all cache
/// state is guarded by `mutex` and the generation is an atomic. Fold errors
/// fail closed (deny).
pub const DynamicTrust = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    /// Our org pubkey (from this node's certificate) — the granting org.
    our_org: [32]u8,
    /// Max cache age before a lazy re-fold, in milliseconds.
    ttl_ms: u64 = 5000,
    mutex: core.compat.Mutex = .{},
    cache: ?Cache = null,

    const Cache = struct {
        /// Owns every slice in `caps` (events, prefixes, capabilities).
        arena: *std.heap.ArenaAllocator,
        caps: []trust_log.Capability,
        folded_at_ms: u64,
        generation: u64,
    };

    pub fn init(allocator: std.mem.Allocator, store: *Store, our_org: [32]u8) DynamicTrust {
        return .{ .allocator = allocator, .store = store, .our_org = our_org };
    }

    pub fn deinit(self: *DynamicTrust) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.dropCacheLocked();
    }

    /// True when `to_org` holds an active delegated capability covering
    /// `key` with ALL of `cap_bits` (replication write ops pass CAP_WRITE).
    /// The caller must hold NO store shard locks (a re-fold scans the log).
    pub fn authorized(self: *DynamicTrust, to_org: [32]u8, key: []const u8, cap_bits: u8) bool {
        const now: u64 = @intCast(core.compat.nowMs());
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refreshLocked(now) catch |err| {
            std.log.warn("org trust: dynamic fold failed (deny): {s}", .{@errorName(err)});
            return false;
        };
        return self.matchLocked(to_org, key, cap_bits, now);
    }

    /// Warm the fold cache. Call outside any store shard lock (a re-fold scans
    /// the log) before work that may only consult the cache, such as a
    /// full-state sync whose store iteration holds shard locks.
    pub fn refresh(self: *DynamicTrust) void {
        const now: u64 = @intCast(core.compat.nowMs());
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refreshLocked(now) catch |err| {
            std.log.warn("org trust: dynamic fold refresh failed: {s}", .{@errorName(err)});
        };
    }

    /// Like `authorized`, but never re-folds: consults the cache as-is and
    /// denies when there is none. Safe to call while holding store shard locks.
    pub fn authorizedCached(self: *DynamicTrust, to_org: [32]u8, key: []const u8, cap_bits: u8) bool {
        const now: u64 = @intCast(core.compat.nowMs());
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.matchLocked(to_org, key, cap_bits, now);
    }

    fn matchLocked(self: *DynamicTrust, to_org: [32]u8, key: []const u8, cap_bits: u8, now: u64) bool {
        const cache = self.cache orelse return false;
        for (cache.caps) |cap| {
            if (!std.mem.eql(u8, cap.to_org[0..], to_org[0..])) continue;
            if ((cap.cap_bits & cap_bits) != cap_bits) continue;
            // Re-check expiry at op time — the fold may be up to ttl_ms old.
            if (cap.expires_at_ms != 0 and cap.expires_at_ms <= now) continue;
            for (cap.prefixes) |prefix| {
                if (prefix.len > 0 and std.mem.startsWith(u8, key, prefix)) return true;
            }
        }
        return false;
    }

    fn refreshLocked(self: *DynamicTrust, now: u64) !void {
        const generation = trust_log.foldGeneration();
        if (self.cache) |c| {
            if (c.generation == generation and now < c.folded_at_ms + self.ttl_ms) return;
        }

        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const log_id = try trust_log.logIdForOrg(a, self.our_org);
        const loaded = try trust_log.loadTrustEvents(a, self.store, log_id);
        const fold = try trust_log.foldTrust(a, self.our_org, loaded.events, now);

        self.dropCacheLocked();
        self.cache = .{
            .arena = arena,
            .caps = fold.capabilities,
            .folded_at_ms = now,
            .generation = generation,
        };
    }

    fn dropCacheLocked(self: *DynamicTrust) void {
        if (self.cache) |c| {
            c.arena.deinit();
            self.allocator.destroy(c.arena);
            self.cache = null;
        }
    }
};

/// The legacy W2 client proof: challenge ++ serialized cert. Including the
/// cert binds the signature to this identity claim; including the fresh
/// server challenge prevents replay.
pub fn handshakeMessage(
    challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
) [CHALLENGE_LEN + CERT_WIRE_LEN]u8 {
    var msg: [CHALLENGE_LEN + CERT_WIRE_LEN]u8 = undefined;
    @memcpy(msg[0..CHALLENGE_LEN], challenge);
    @memcpy(msg[CHALLENGE_LEN..], cert_wire);
    return msg;
}

// ── W3 transcript messages ──────────────────────────────────────────────
//
// Both W3 signatures cover a role label, BOTH challenges and the signer's
// cert. The label is what keeps a node from being a signing oracle: a W3
// server hello the attacker extracts by sending a chosen "client challenge"
// can be verified only as a server hello, never as a W3 client proof nor as a
// legacy W2 proof (whose message is the bare challenge ++ cert). Binding both
// challenges ties each signature to this one connection's transcript.

pub const W3_LABEL_LEN = 22;
pub const W3_SERVER_LABEL: *const [W3_LABEL_LEN]u8 = "wormdb w3 server hello";
pub const W3_CLIENT_LABEL: *const [W3_LABEL_LEN]u8 = "wormdb w3 client proof";
pub const W3_MESSAGE_LEN = W3_LABEL_LEN + 2 * CHALLENGE_LEN + CERT_WIRE_LEN;

fn w3Message(
    label: *const [W3_LABEL_LEN]u8,
    client_challenge: *const [CHALLENGE_LEN]u8,
    server_challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
) [W3_MESSAGE_LEN]u8 {
    var msg: [W3_MESSAGE_LEN]u8 = undefined;
    var pos: usize = 0;
    @memcpy(msg[pos..][0..W3_LABEL_LEN], label);
    pos += W3_LABEL_LEN;
    @memcpy(msg[pos..][0..CHALLENGE_LEN], client_challenge);
    pos += CHALLENGE_LEN;
    @memcpy(msg[pos..][0..CHALLENGE_LEN], server_challenge);
    pos += CHALLENGE_LEN;
    @memcpy(msg[pos..][0..CERT_WIRE_LEN], cert_wire);
    return msg;
}

/// What the W3 SERVER signs in its hello (with its own node key).
pub fn w3ServerMessage(
    client_challenge: *const [CHALLENGE_LEN]u8,
    server_challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
) [W3_MESSAGE_LEN]u8 {
    return w3Message(W3_SERVER_LABEL, client_challenge, server_challenge, cert_wire);
}

/// What the W3 CLIENT signs in its proof (with its own node key).
pub fn w3ClientMessage(
    client_challenge: *const [CHALLENGE_LEN]u8,
    server_challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
) [W3_MESSAGE_LEN]u8 {
    return w3Message(W3_CLIENT_LABEL, client_challenge, server_challenge, cert_wire);
}

/// Shared verification core. Checks, in order:
///   (a) org signature over the certificate (Org.verifyCertificate)
///   (b) certificate validity window (isValid: version + expiry)
///   (c) the issuing org is our own or one we have grants for
///   (d) possession: Ed25519 verify of `sig` over `msg` against the certified
///       node key — `msg` is the role-specific transcript the caller expects
fn verifyProof(
    trust: *const OrgTrust,
    msg: []const u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
    sig: *const [SIG_LEN]u8,
) HandshakeError!PeerOrg {
    const cert = Org.NodeCertificate.deserialize(cert_wire);
    if (!Org.verifyCertificate(&cert)) return error.BadCertSignature;
    if (!cert.isValid()) return error.CertExpired;
    if (!trust.peerOrgTrusted(cert.org_pubkey)) return error.OrgNotTrusted;

    const node_pk = Ed25519.PublicKey.fromBytes(cert.node_pubkey) catch
        return error.BadChallengeSignature;
    const signature = Ed25519.Signature.fromBytes(sig.*);
    signature.verify(msg, node_pk) catch return error.BadChallengeSignature;

    return .{
        .org_pubkey = cert.org_pubkey,
        .node_pubkey = cert.node_pubkey,
    };
}

/// Server-side verification of a legacy W2 client proof (sig over
/// challenge ++ cert_wire).
pub fn verifyPeerHandshake(
    trust: *const OrgTrust,
    challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
    sig: *const [SIG_LEN]u8,
) HandshakeError!PeerOrg {
    const msg = handshakeMessage(challenge, cert_wire);
    return verifyProof(trust, &msg, cert_wire, sig);
}

/// Client-side verification of a W3 server hello.
pub fn verifyW3Server(
    trust: *const OrgTrust,
    client_challenge: *const [CHALLENGE_LEN]u8,
    server_challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
    sig: *const [SIG_LEN]u8,
) HandshakeError!PeerOrg {
    const msg = w3ServerMessage(client_challenge, server_challenge, cert_wire);
    return verifyProof(trust, &msg, cert_wire, sig);
}

/// Server-side verification of a W3 client proof.
pub fn verifyW3Client(
    trust: *const OrgTrust,
    client_challenge: *const [CHALLENGE_LEN]u8,
    server_challenge: *const [CHALLENGE_LEN]u8,
    cert_wire: *const [CERT_WIRE_LEN]u8,
    sig: *const [SIG_LEN]u8,
) HandshakeError!PeerOrg {
    const msg = w3ClientMessage(client_challenge, server_challenge, cert_wire);
    return verifyProof(trust, &msg, cert_wire, sig);
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

test "W3 mutual handshake: both sides verify each other and agree on session keys" {
    const org_kp = Org.generateOrgKeyPair();
    const client_kp = Ed25519.KeyPair.generate(testIo());
    const server_kp = Ed25519.KeyPair.generate(testIo());

    const client_cert = try Org.issueCertificate(org_kp, client_kp.public_key.toBytes(), "client", 0);
    const server_cert = try Org.issueCertificate(org_kp, server_kp.public_key.toBytes(), "server", 0);
    var client_cert_wire: [CERT_WIRE_LEN]u8 = undefined;
    var server_cert_wire: [CERT_WIRE_LEN]u8 = undefined;
    client_cert.serialize(&client_cert_wire);
    server_cert.serialize(&server_cert_wire);

    // Neither side lists the org in grants: same-org membership alone admits a peer.
    const client_trust = OrgTrust{ .enforce = true, .node_cert = client_cert, .node_cert_wire = client_cert_wire };
    const server_trust = OrgTrust{ .enforce = true, .node_cert = server_cert, .node_cert_wire = server_cert_wire };
    try testing.expect(client_trust.sameOrg(org_kp.public_key.toBytes()));
    try testing.expect(client_trust.peerOrgTrusted(org_kp.public_key.toBytes()));
    try testing.expect(!client_trust.orgTrusted(org_kp.public_key.toBytes()));

    // Client → server: challenge. Server → client: challenge + labeled proof.
    const client_challenge: [CHALLENGE_LEN]u8 = @splat(0xC1);
    const server_challenge: [CHALLENGE_LEN]u8 = @splat(0x5E);
    const server_msg = w3ServerMessage(&client_challenge, &server_challenge, &server_cert_wire);
    const server_sig = (try server_kp.sign(&server_msg, null)).toBytes();
    const server_identity = try verifyW3Server(&client_trust, &client_challenge, &server_challenge, &server_cert_wire, &server_sig);
    try testing.expectEqualSlices(u8, &server_kp.public_key.toBytes(), &server_identity.node_pubkey);

    // Client → server: labeled proof over the same transcript.
    const client_msg = w3ClientMessage(&client_challenge, &server_challenge, &client_cert_wire);
    const client_sig = (try client_kp.sign(&client_msg, null)).toBytes();
    const client_identity = try verifyW3Client(&server_trust, &client_challenge, &server_challenge, &client_cert_wire, &client_sig);
    try testing.expectEqualSlices(u8, &client_kp.public_key.toBytes(), &client_identity.node_pubkey);

    // Either challenge differing (replay of an old hello or proof) is rejected.
    const stale: [CHALLENGE_LEN]u8 = @splat(0x00);
    try testing.expectError(error.BadChallengeSignature, verifyW3Server(&client_trust, &stale, &server_challenge, &server_cert_wire, &server_sig));
    try testing.expectError(error.BadChallengeSignature, verifyW3Server(&client_trust, &client_challenge, &stale, &server_cert_wire, &server_sig));
    try testing.expectError(error.BadChallengeSignature, verifyW3Client(&server_trust, &client_challenge, &stale, &client_cert_wire, &client_sig));

    // A server from an unrelated org cannot pass the client's check.
    const other_org = Org.generateOrgKeyPair();
    const rogue = try Org.issueCertificate(other_org, server_kp.public_key.toBytes(), "rogue", 0);
    var rogue_wire: [CERT_WIRE_LEN]u8 = undefined;
    rogue.serialize(&rogue_wire);
    const rogue_sig = (try server_kp.sign(&w3ServerMessage(&client_challenge, &server_challenge, &rogue_wire), null)).toBytes();
    try testing.expectError(error.OrgNotTrusted, verifyW3Server(&client_trust, &client_challenge, &server_challenge, &rogue_wire, &rogue_sig));

    // Both ends derive matching per-direction keys from the transcript.
    const client_keys = try secure_channel.deriveSessionKeys(.client, client_kp.secret_key, server_identity.node_pubkey, &client_challenge, &server_challenge);
    const server_keys = try secure_channel.deriveSessionKeys(.server, server_kp.secret_key, client_identity.node_pubkey, &client_challenge, &server_challenge);
    try testing.expectEqualSlices(u8, &client_keys.send, &server_keys.recv);
    try testing.expectEqualSlices(u8, &client_keys.recv, &server_keys.send);
}

test "W3 signatures are domain-separated: a server hello is never a client proof (W3 or legacy W2)" {
    const org_kp = Org.generateOrgKeyPair();
    const node_kp = Ed25519.KeyPair.generate(testIo());
    const cert = try Org.issueCertificate(org_kp, node_kp.public_key.toBytes(), "node-a", 0);
    var cert_wire: [CERT_WIRE_LEN]u8 = undefined;
    cert.serialize(&cert_wire);
    const trust = OrgTrust{ .enforce = true, .node_cert = cert, .node_cert_wire = cert_wire };

    // The oracle attempt: an attacker reads node A's W2 challenge S on one
    // connection, then opens a W3 connection to A and presents S as the
    // "client challenge". A answers with a signed server hello.
    const s_w2: [CHALLENGE_LEN]u8 = @splat(0x5A);
    const a_server_challenge: [CHALLENGE_LEN]u8 = @splat(0xA7);
    const hello_sig = (try node_kp.sign(&w3ServerMessage(&s_w2, &a_server_challenge, &cert_wire), null)).toBytes();

    // Replayed on the W2 connection as A's own client proof: rejected.
    try testing.expectError(error.BadChallengeSignature, verifyPeerHandshake(&trust, &s_w2, &cert_wire, &hello_sig));
    // Replayed as a W3 client proof on any connection: rejected.
    try testing.expectError(error.BadChallengeSignature, verifyW3Client(&trust, &s_w2, &a_server_challenge, &cert_wire, &hello_sig));
    try testing.expectError(error.BadChallengeSignature, verifyW3Client(&trust, &a_server_challenge, &s_w2, &cert_wire, &hello_sig));
    // And a client proof is never accepted as a server hello.
    const proof_sig = (try node_kp.sign(&w3ClientMessage(&s_w2, &a_server_challenge, &cert_wire), null)).toBytes();
    try testing.expectError(error.BadChallengeSignature, verifyW3Server(&trust, &s_w2, &a_server_challenge, &cert_wire, &proof_sig));
    // Each signature still verifies in its own role.
    _ = try verifyW3Server(&trust, &s_w2, &a_server_challenge, &cert_wire, &hello_sig);
    _ = try verifyW3Client(&trust, &s_w2, &a_server_challenge, &cert_wire, &proof_sig);
}
