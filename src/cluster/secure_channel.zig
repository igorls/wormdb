//! Encrypted, authenticated replication channel ("W3").
//!
//! After the mutual org handshake both peers hold each other's certified node
//! key and the two fresh challenges. Each side derives the same pair of
//! ChaCha20-Poly1305 keys (one per direction) from an X25519 agreement between
//! the node identities, salted with both challenges, and every byte of the
//! WormWire replication stream after the handshake travels in authenticated
//! records:
//!
//!   [4B BE record_len][ciphertext (record_len - 16)][16B Poly1305 tag]
//!
//! Nonces are 96-bit: 4 zero bytes ++ a 64-bit big-endian per-direction
//! counter, so a record can be neither replayed nor reordered within a
//! session, and the keys are bound to the handshake transcript (both
//! challenges), so a captured handshake cannot be replayed to re-derive them.
//!
//! The channel is plumbing, not policy: who may connect is decided by the
//! org-trust handshake (`org_trust.verifyPeerHandshake`); what a peer may
//! read or write by `Cluster.peerMayReceive` and the server's
//! `replicationKeyAuthorized`. This file only guarantees that bytes between
//! two authenticated peers are confidential and tamper-evident regardless of
//! the route (WireGuard tunnel, Docker bridge, plain LAN).

const std = @import("std");
const core = @import("../core/mod.zig");
const compat = core.compat;

const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;

pub const KEY_LEN = Aead.key_length;
pub const TAG_LEN = Aead.tag_length;
pub const NONCE_LEN = Aead.nonce_length;
pub const CHALLENGE_LEN = 32;

/// Plaintext bytes per record. Large frames (a 16 MiB SET, a multi-MiB
/// VRABITQ_INSTALL) are split so neither side needs the whole frame in
/// memory twice; the reader rejects anything larger.
pub const MAX_PLAINTEXT: usize = 1024 * 1024;
pub const MAX_RECORD: usize = MAX_PLAINTEXT + TAG_LEN;
/// Queued plaintext is sealed into a record once it reaches this size, or
/// when the caller flushes at a message boundary.
const FLUSH_THRESHOLD: usize = 64 * 1024;

pub const Role = enum { client, server };

pub const SessionKeys = struct {
    send: [KEY_LEN]u8,
    recv: [KEY_LEN]u8,

    pub fn wipe(self: *SessionKeys) void {
        std.crypto.secureZero(u8, &self.send);
        std.crypto.secureZero(u8, &self.recv);
    }
};

pub const DeriveError = error{InvalidKey};

/// Derive the per-direction keys for one session. Both peers call this with
/// their own role; `client.send == server.recv` and vice versa.
pub fn deriveSessionKeys(
    role: Role,
    our_secret: Ed25519.SecretKey,
    peer_public: [32]u8,
    client_challenge: *const [CHALLENGE_LEN]u8,
    server_challenge: *const [CHALLENGE_LEN]u8,
) DeriveError!SessionKeys {
    const our_ed = Ed25519.KeyPair.fromSecretKey(our_secret) catch return error.InvalidKey;
    const our_x = X25519.KeyPair.fromEd25519(our_ed) catch return error.InvalidKey;
    const peer_ed = Ed25519.PublicKey.fromBytes(peer_public) catch return error.InvalidKey;
    const peer_x = X25519.publicKeyFromEd25519(peer_ed) catch return error.InvalidKey;
    var shared = X25519.scalarmult(our_x.secret_key, peer_x) catch return error.InvalidKey;
    defer std.crypto.secureZero(u8, &shared);

    var salt: [CHALLENGE_LEN * 2]u8 = undefined;
    @memcpy(salt[0..CHALLENGE_LEN], client_challenge);
    @memcpy(salt[CHALLENGE_LEN..], server_challenge);
    const prk = Hkdf.extract(&salt, &shared);

    var c2s: [KEY_LEN]u8 = undefined;
    var s2c: [KEY_LEN]u8 = undefined;
    Hkdf.expand(&c2s, "wormdb replication v3 client->server", prk);
    Hkdf.expand(&s2c, "wormdb replication v3 server->client", prk);
    return switch (role) {
        .client => .{ .send = c2s, .recv = s2c },
        .server => .{ .send = s2c, .recv = c2s },
    };
}

/// Seal one record: `[4B len][ciphertext][tag]`, advancing `counter`.
/// Exposed for tests; `SecureStream.flush` is the production path.
pub fn sealRecord(allocator: std.mem.Allocator, key: [KEY_LEN]u8, counter: *u64, plaintext: []const u8) ![]u8 {
    if (plaintext.len > MAX_PLAINTEXT) return error.RecordTooLarge;
    const record_len = plaintext.len + TAG_LEN;
    const buf = try allocator.alloc(u8, 4 + record_len);
    errdefer allocator.free(buf);
    std.mem.writeInt(u32, buf[0..4], @intCast(record_len), .big);
    const nonce = try nextNonce(counter);
    var tag: [TAG_LEN]u8 = undefined;
    Aead.encrypt(buf[4..][0..plaintext.len], &tag, plaintext, "", nonce, key);
    @memcpy(buf[4 + plaintext.len ..][0..TAG_LEN], &tag);
    return buf;
}

fn nextNonce(counter: *u64) ![NONCE_LEN]u8 {
    if (counter.* == std.math.maxInt(u64)) return error.CounterExhausted;
    var nonce: [NONCE_LEN]u8 = @splat(0);
    std.mem.writeInt(u64, nonce[4..12], counter.*, .big);
    counter.* += 1;
    return nonce;
}

fn readExact(stream: *compat.net.Stream, buf: []u8) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = try stream.read(buf[done..]);
        if (n == 0) return error.EndOfStream;
        done += n;
    }
}

/// Per-session cipher state. Holds no socket: callers bind it to a stream
/// per operation (`bind`) because peer connections live inside hash maps
/// whose values may move.
pub const SecureStream = struct {
    allocator: std.mem.Allocator,
    keys: SessionKeys,
    send_counter: u64 = 0,
    recv_counter: u64 = 0,
    /// Plaintext waiting to be sealed into the next record.
    tx: std.ArrayListUnmanaged(u8) = .empty,
    /// Plaintext of the most recently opened record, consumed by `read`.
    rx: []u8 = &.{},
    rx_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, keys: SessionKeys) SecureStream {
        return .{ .allocator = allocator, .keys = keys };
    }

    pub fn deinit(self: *SecureStream) void {
        self.tx.deinit(self.allocator);
        if (self.rx.len > 0) self.allocator.free(self.rx);
        self.rx = &.{};
        self.rx_pos = 0;
        self.keys.wipe();
    }

    pub fn bind(self: *SecureStream, stream: *compat.net.Stream) Bound {
        return .{ .secure = self, .stream = stream };
    }

    /// Queue plaintext; sealed at FLUSH_THRESHOLD or on `flush`.
    pub fn writeAll(self: *SecureStream, stream: *compat.net.Stream, data: []const u8) !void {
        try self.tx.appendSlice(self.allocator, data);
        if (self.tx.items.len >= FLUSH_THRESHOLD) try self.flush(stream);
    }

    /// Seal everything queued so far and write it. Call at message boundaries —
    /// a frame that is never flushed never leaves this process.
    pub fn flush(self: *SecureStream, stream: *compat.net.Stream) !void {
        var offset: usize = 0;
        while (offset < self.tx.items.len) {
            const end = @min(self.tx.items.len, offset + MAX_PLAINTEXT);
            const record = try sealRecord(self.allocator, self.keys.send, &self.send_counter, self.tx.items[offset..end]);
            defer self.allocator.free(record);
            try stream.writeAll(record);
            offset = end;
        }
        self.tx.clearRetainingCapacity();
    }

    /// Read decrypted bytes. Returns 0 only on a clean end of stream at a
    /// record boundary; a truncated or forged record is an error.
    pub fn read(self: *SecureStream, stream: *compat.net.Stream, dest: []u8) !usize {
        if (dest.len == 0) return 0;
        while (self.rx_pos >= self.rx.len) {
            if (!try self.readRecord(stream)) return 0;
        }
        const n = @min(dest.len, self.rx.len - self.rx_pos);
        @memcpy(dest[0..n], self.rx[self.rx_pos..][0..n]);
        self.rx_pos += n;
        return n;
    }

    /// Returns false on a clean EOF before a record header.
    fn readRecord(self: *SecureStream, stream: *compat.net.Stream) !bool {
        var header: [4]u8 = undefined;
        const got = try stream.read(&header);
        if (got == 0) return false;
        if (got < header.len) try readExact(stream, header[got..]);
        const record_len = std.mem.readInt(u32, &header, .big);
        if (record_len < TAG_LEN or record_len > MAX_RECORD) return error.Corruption;

        const ciphertext = try self.allocator.alloc(u8, record_len);
        defer self.allocator.free(ciphertext);
        try readExact(stream, ciphertext);

        const pt_len = record_len - TAG_LEN;
        const plaintext = try self.allocator.alloc(u8, pt_len);
        errdefer self.allocator.free(plaintext);
        const nonce = try nextNonce(&self.recv_counter);
        Aead.decrypt(plaintext, ciphertext[0..pt_len], ciphertext[pt_len..][0..TAG_LEN].*, "", nonce, self.keys.recv) catch
            return error.AuthenticationFailed;

        if (self.rx.len > 0) self.allocator.free(self.rx);
        self.rx = plaintext;
        self.rx_pos = 0;
        return true;
    }
};

/// A SecureStream bound to one socket — satisfies the `anytype` reader and
/// writer contracts of `wire.readFrameAlloc`, `wire.readResponseAlloc`,
/// `wire.writeCommand` and `wire.writeResponse`.
pub const Bound = struct {
    secure: *SecureStream,
    stream: *compat.net.Stream,

    pub fn read(self: *Bound, dest: []u8) !usize {
        return self.secure.read(self.stream, dest);
    }
    pub fn writeAll(self: *Bound, data: []const u8) !void {
        return self.secure.writeAll(self.stream, data);
    }
    pub fn flush(self: *Bound) !void {
        return self.secure.flush(self.stream);
    }
};

/// Replication transport: a raw stream (legacy WR / W2 sessions) or an
/// encrypted W3 session over it, so one frame loop can serve both.
pub const Transport = struct {
    stream: *compat.net.Stream,
    secure: ?*SecureStream = null,

    pub fn read(self: *Transport, dest: []u8) !usize {
        if (self.secure) |s| return s.read(self.stream, dest);
        return self.stream.read(dest);
    }
    pub fn writeAll(self: *Transport, data: []const u8) !void {
        if (self.secure) |s| return s.writeAll(self.stream, data);
        return self.stream.writeAll(data);
    }
    pub fn flush(self: *Transport) !void {
        if (self.secure) |s| try s.flush(self.stream);
    }
    pub fn beginRead(self: *Transport, timeout_ms: usize, allow_idle: bool) void {
        self.stream.beginRead(timeout_ms, allow_idle);
    }
    pub fn encrypted(self: *const Transport) bool {
        return self.secure != null;
    }
};

// ╔═══════════════════════════════════════════════╗
// ║  Tests                                         ║
// ╚═══════════════════════════════════════════════╝

const testing = std.testing;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "deriveSessionKeys: both roles agree; challenges and identities bind the keys" {
    const a = Ed25519.KeyPair.generate(testIo());
    const b = Ed25519.KeyPair.generate(testIo());
    const cc: [CHALLENGE_LEN]u8 = @splat(0x11);
    const sc: [CHALLENGE_LEN]u8 = @splat(0x22);

    const client = try deriveSessionKeys(.client, a.secret_key, b.public_key.toBytes(), &cc, &sc);
    const server = try deriveSessionKeys(.server, b.secret_key, a.public_key.toBytes(), &cc, &sc);
    try testing.expectEqualSlices(u8, &client.send, &server.recv);
    try testing.expectEqualSlices(u8, &client.recv, &server.send);
    try testing.expect(!std.mem.eql(u8, &client.send, &client.recv));

    // A different challenge or a different peer yields unrelated keys.
    const other_cc: [CHALLENGE_LEN]u8 = @splat(0x33);
    const replayed = try deriveSessionKeys(.client, a.secret_key, b.public_key.toBytes(), &other_cc, &sc);
    try testing.expect(!std.mem.eql(u8, &client.send, &replayed.send));
    const c = Ed25519.KeyPair.generate(testIo());
    const impostor = try deriveSessionKeys(.server, c.secret_key, a.public_key.toBytes(), &cc, &sc);
    try testing.expect(!std.mem.eql(u8, &client.send, &impostor.recv));
}

test "SecureStream: records roundtrip over a socket pair; forged bytes are rejected" {
    if (comptime compat.wasm_target) return error.SkipZigTest;
    const net = compat.net;

    const a = Ed25519.KeyPair.generate(testIo());
    const b = Ed25519.KeyPair.generate(testIo());
    const cc: [CHALLENGE_LEN]u8 = @splat(0x01);
    const sc: [CHALLENGE_LEN]u8 = @splat(0x02);
    const client_keys = try deriveSessionKeys(.client, a.secret_key, b.public_key.toBytes(), &cc, &sc);
    const server_keys = try deriveSessionKeys(.server, b.secret_key, a.public_key.toBytes(), &cc, &sc);

    const listen_addr = try net.Address.parseIp("127.0.0.1", 0);
    var listener = try listen_addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const port = listener.inner.socket.address.getPort();

    var client_stream = try net.tcpConnectToAddress(net.Address.initIp4(.{ 127, 0, 0, 1 }, port));
    defer client_stream.close();
    var accepted = try listener.accept();
    defer accepted.stream.close();
    client_stream.write_timeout_ms = 5_000;
    client_stream.beginRead(5_000, false);
    accepted.stream.write_timeout_ms = 5_000;
    accepted.stream.beginRead(5_000, false);

    // The payload spans several records; the client writes it while the server
    // (this thread) drains, since loopback buffers are far smaller than 1 MiB.
    const big = try testing.allocator.alloc(u8, 3 * MAX_PLAINTEXT / 2);
    defer testing.allocator.free(big);
    for (big, 0..) |*byte, i| byte.* = @truncate(i *% 31);

    const ClientSide = struct {
        stream: *net.Stream,
        keys: SessionKeys,
        big: []const u8,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.runInner() catch |e| {
                self.err = e;
            };
        }

        fn runInner(self: *@This()) !void {
            var client = SecureStream.init(testing.allocator, self.keys);
            defer client.deinit();
            var w = client.bind(self.stream);
            // Several small writes coalesce into one record.
            try w.writeAll("hello ");
            try w.writeAll("world");
            try w.flush();
            try w.writeAll(self.big);
            try w.flush();

            // Wait for the server's acknowledgement on the other key.
            var ack: [3]u8 = undefined;
            var done: usize = 0;
            while (done < ack.len) done += try w.read(ack[done..]);
            if (!std.mem.eql(u8, &ack, "ack")) return error.TestUnexpectedResult;

            // A record with one flipped ciphertext byte, then a record sealed
            // under an already-used counter (replay). Both must be rejected.
            var forged_counter: u64 = client.send_counter;
            const forged = try sealRecord(testing.allocator, self.keys.send, &forged_counter, "tampered");
            defer testing.allocator.free(forged);
            forged[6] ^= 0x80;
            try self.stream.writeAll(forged);
            var stale_counter: u64 = 0;
            const replay = try sealRecord(testing.allocator, self.keys.send, &stale_counter, "replay");
            defer testing.allocator.free(replay);
            try self.stream.writeAll(replay);
        }
    };
    var client_side = ClientSide{ .stream = &client_stream, .keys = client_keys, .big = big };
    const client_thread = try std.Thread.spawn(.{}, ClientSide.run, .{&client_side});
    var joined = false;
    defer if (!joined) client_thread.join();

    var server = SecureStream.init(testing.allocator, server_keys);
    defer server.deinit();
    var sr = server.bind(&accepted.stream);

    var small: [11]u8 = undefined;
    var done: usize = 0;
    while (done < small.len) {
        const n = try sr.read(small[done..]);
        try testing.expect(n > 0);
        done += n;
    }
    try testing.expectEqualStrings("hello world", &small);

    const echo = try testing.allocator.alloc(u8, big.len);
    defer testing.allocator.free(echo);
    done = 0;
    while (done < echo.len) {
        const n = try sr.read(echo[done..]);
        try testing.expect(n > 0);
        done += n;
    }
    try testing.expectEqualSlices(u8, big, echo);

    // Server → client direction uses the other key.
    try sr.writeAll("ack");
    try sr.flush();

    var sink: [16]u8 = undefined;
    try testing.expectError(error.AuthenticationFailed, sr.read(&sink));
    // The forged record was consumed whole; the replayed one is next.
    try testing.expectError(error.AuthenticationFailed, sr.read(&sink));

    client_thread.join();
    joined = true;
    try testing.expect(client_side.err == null);
}
