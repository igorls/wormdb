//! Signed checkpoint records for verifiable append-only logs.
//!
//! A checkpoint commits to a contiguous sequence range and an accumulator root.
//! The signature input is a canonical binary payload over every field except
//! `signature`; the checkpoint hash includes both that payload and the signature.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

pub const VERSION: u8 = 1;
pub const HASH_LEN = 32;
pub const PUBLIC_KEY_LEN = 32;
pub const SIGNATURE_LEN = 64;

pub const Hash = [HASH_LEN]u8;
pub const PublicKey = [PUBLIC_KEY_LEN]u8;
pub const Signature = [SIGNATURE_LEN]u8;

pub const ZERO_HASH: Hash = [_]u8{0} ** HASH_LEN;
pub const ZERO_SIGNATURE: Signature = [_]u8{0} ** SIGNATURE_LEN;

const CHECKPOINT_SIGNING_DOMAIN = "wormdb.checkpoint.sign.v1";
const CHECKPOINT_RECORD_DOMAIN = "wormdb.checkpoint.record.v1";

/// Which accumulator produced `accumulator_root`.
///
/// The proof module treats accumulator roots as opaque commitments. Worker C's
/// Merkle/MMR implementation can add concrete construction and path codecs
/// without changing checkpoint signing semantics.
pub const AccumulatorKind = enum(u8) {
    opaque_root = 0,
    merkle_sha256_v1 = 1,
    mmr_sha256_v1 = 2,
};

/// Signature algorithm used by the checkpoint creator.
pub const SignatureScheme = enum(u8) {
    ed25519 = 1,
};

/// A signed commitment to a contiguous append-log range.
///
/// Slices are borrowed; callers own their lifetime. `extension_bytes` are
/// canonical, signed claim bytes. Apps can preserve device clock readings, GPS
/// fixes, signer roles, supervisor notes, or domain-specific policy claims here
/// without WormDB needing to understand those claims.
pub const CheckpointRecord = struct {
    version: u8 = VERSION,
    log_id: []const u8,
    from_seq: u64,
    to_seq: u64,
    accumulator_kind: AccumulatorKind = .opaque_root,
    accumulator_root: Hash,
    previous_checkpoint_hash: ?Hash = null,
    creator_identity: []const u8,
    signature_scheme: SignatureScheme = .ed25519,
    signature: Signature = ZERO_SIGNATURE,
    created_at_ms: u64,
    ingested_at_ms: u64,
    extension_bytes: []const u8 = &.{},

    pub fn validateShape(self: *const CheckpointRecord) !void {
        if (self.version != VERSION) return error.UnsupportedCheckpointVersion;
        if (self.log_id.len == 0) return error.EmptyLogId;
        if (self.from_seq > self.to_seq) return error.InvalidSequenceRange;
        try ensureU32Len(self.log_id);
        try ensureU32Len(self.creator_identity);
        try ensureU32Len(self.extension_bytes);

        switch (self.signature_scheme) {
            .ed25519 => if (self.creator_identity.len != PUBLIC_KEY_LEN) {
                return error.InvalidPublicKeyLength;
            },
        }
    }

    /// Encode the exact bytes that are signed by `signature`.
    ///
    /// Caller owns the returned slice.
    pub fn encodeSigningPayload(self: *const CheckpointRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validateShape();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendBytes(&out, allocator, CHECKPOINT_SIGNING_DOMAIN);
        try appendU8(&out, allocator, self.version);
        try appendLenBytes(&out, allocator, self.log_id);
        try appendU64(&out, allocator, self.from_seq);
        try appendU64(&out, allocator, self.to_seq);
        try appendU8(&out, allocator, @intFromEnum(self.accumulator_kind));
        try appendFixed(&out, allocator, self.accumulator_root[0..]);
        if (self.previous_checkpoint_hash) |prev| {
            try appendU8(&out, allocator, 1);
            try appendFixed(&out, allocator, prev[0..]);
        } else {
            try appendU8(&out, allocator, 0);
        }
        try appendLenBytes(&out, allocator, self.creator_identity);
        try appendU8(&out, allocator, @intFromEnum(self.signature_scheme));
        try appendU64(&out, allocator, self.created_at_ms);
        try appendU64(&out, allocator, self.ingested_at_ms);
        try appendLenBytes(&out, allocator, self.extension_bytes);

        return try out.toOwnedSlice(allocator);
    }

    /// Encode a canonical checkpoint record, including the signature.
    ///
    /// Caller owns the returned slice.
    pub fn encodeCanonical(self: *const CheckpointRecord, allocator: std.mem.Allocator) ![]u8 {
        const signing_payload = try self.encodeSigningPayload(allocator);
        defer allocator.free(signing_payload);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendBytes(&out, allocator, CHECKPOINT_RECORD_DOMAIN);
        try appendLenBytes(&out, allocator, signing_payload);
        try appendFixed(&out, allocator, self.signature[0..]);

        return try out.toOwnedSlice(allocator);
    }

    pub fn signingPayloadHash(self: *const CheckpointRecord, allocator: std.mem.Allocator) !Hash {
        const payload = try self.encodeSigningPayload(allocator);
        defer allocator.free(payload);
        return hashBytes(payload);
    }

    pub fn recordHash(self: *const CheckpointRecord, allocator: std.mem.Allocator) !Hash {
        const payload = try self.encodeCanonical(allocator);
        defer allocator.free(payload);
        return hashBytes(payload);
    }

    pub fn verifySignature(self: *const CheckpointRecord, allocator: std.mem.Allocator) !bool {
        try self.validateShape();

        const payload = try self.encodeSigningPayload(allocator);
        defer allocator.free(payload);

        switch (self.signature_scheme) {
            .ed25519 => {
                const public_key_bytes: PublicKey = self.creator_identity[0..PUBLIC_KEY_LEN].*;
                const sig = Ed25519.Signature.fromBytes(self.signature);
                const public_key = Ed25519.PublicKey.fromBytes(public_key_bytes) catch return false;
                sig.verify(payload, public_key) catch return false;
                return true;
            },
        }
    }

    pub fn signEd25519(self: *const CheckpointRecord, allocator: std.mem.Allocator, secret_key_bytes: *const [SIGNATURE_LEN]u8) !Signature {
        const payload = try self.encodeSigningPayload(allocator);
        defer allocator.free(payload);

        const secret_key = try Ed25519.SecretKey.fromBytes(secret_key_bytes.*);
        const key_pair = try Ed25519.KeyPair.fromSecretKey(secret_key);
        const sig = try key_pair.sign(payload, null);
        return sig.toBytes();
    }

    pub fn coversSeq(self: *const CheckpointRecord, seq: u64) bool {
        return seq >= self.from_seq and seq <= self.to_seq;
    }
};

/// Verify signatures and included previous-checkpoint links for an ordered
/// checkpoint slice. A single checkpoint may still carry a previous hash anchor
/// whose full predecessor is not bundled; that anchor is preserved but cannot be
/// validated without the prior record.
pub fn verifyIncludedCheckpointChain(allocator: std.mem.Allocator, checkpoints: []const CheckpointRecord) !void {
    if (checkpoints.len == 0) return error.MissingCheckpoint;

    for (checkpoints, 0..) |*checkpoint, i| {
        if (!try checkpoint.verifySignature(allocator)) return error.InvalidCheckpointSignature;
        if (i == 0) continue;

        const expected_prev_hash = checkpoints[i - 1].recordHash(allocator) catch return error.CheckpointHashFailed;
        const actual_prev_hash = checkpoint.previous_checkpoint_hash orelse return error.CheckpointLinkMismatch;
        if (!eqlHash(expected_prev_hash, actual_prev_hash)) return error.CheckpointLinkMismatch;
    }
}

pub fn hashBytes(bytes: []const u8) Hash {
    var out: Hash = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

pub fn eqlHash(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, a[0..], b[0..]);
}

fn ensureU32Len(bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) return error.FieldTooLarge;
}

fn appendU8(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u8) !void {
    try out.append(allocator, value);
}

fn appendU64(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendFixed(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
}

fn appendBytes(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
    try appendU8(out, allocator, 0);
}

fn appendLenBytes(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try ensureU32Len(bytes);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, len_buf[0..4], @intCast(bytes.len), .big);
    try out.appendSlice(allocator, &len_buf);
    try out.appendSlice(allocator, bytes);
}

fn testKeypair() struct { public_key: PublicKey, secret_key: [SIGNATURE_LEN]u8 } {
    const kp = Ed25519.KeyPair.generate(std.Io.Threaded.global_single_threaded.io());
    return .{ .public_key = kp.public_key.toBytes(), .secret_key = kp.secret_key.toBytes() };
}

test "checkpoint signs and verifies canonical payload" {
    const testing = std.testing;
    const kp = testKeypair();

    const unsigned = CheckpointRecord{
        .log_id = "fieldbook:north-yard",
        .from_seq = 1,
        .to_seq = 8,
        .accumulator_kind = .merkle_sha256_v1,
        .accumulator_root = hashBytes("root"),
        .creator_identity = kp.public_key[0..],
        .created_at_ms = 1_777_777_000,
        .ingested_at_ms = 1_777_777_123,
        .extension_bytes = "device-time+gps-claims",
    };

    const sig = try unsigned.signEd25519(testing.allocator, &kp.secret_key);
    const signed = CheckpointRecord{
        .log_id = unsigned.log_id,
        .from_seq = unsigned.from_seq,
        .to_seq = unsigned.to_seq,
        .accumulator_kind = unsigned.accumulator_kind,
        .accumulator_root = unsigned.accumulator_root,
        .creator_identity = unsigned.creator_identity,
        .signature = sig,
        .created_at_ms = unsigned.created_at_ms,
        .ingested_at_ms = unsigned.ingested_at_ms,
        .extension_bytes = unsigned.extension_bytes,
    };

    try testing.expect(try signed.verifySignature(testing.allocator));

    const payload_hash = try signed.signingPayloadHash(testing.allocator);
    const payload_hash_again = try signed.signingPayloadHash(testing.allocator);
    try testing.expect(eqlHash(payload_hash, payload_hash_again));
}

test "checkpoint signature covers extension claim bytes" {
    const testing = std.testing;
    const kp = testKeypair();

    const unsigned = CheckpointRecord{
        .log_id = "fieldbook:north-yard",
        .from_seq = 4,
        .to_seq = 4,
        .accumulator_root = hashBytes("root"),
        .creator_identity = kp.public_key[0..],
        .created_at_ms = 10,
        .ingested_at_ms = 20,
        .extension_bytes = "gps:lat=1",
    };

    const sig = try unsigned.signEd25519(testing.allocator, &kp.secret_key);
    const tampered = CheckpointRecord{
        .log_id = unsigned.log_id,
        .from_seq = unsigned.from_seq,
        .to_seq = unsigned.to_seq,
        .accumulator_root = unsigned.accumulator_root,
        .creator_identity = unsigned.creator_identity,
        .signature = sig,
        .created_at_ms = unsigned.created_at_ms,
        .ingested_at_ms = unsigned.ingested_at_ms,
        .extension_bytes = "gps:lat=2",
    };

    try testing.expect(!try tampered.verifySignature(testing.allocator));
}

test "included checkpoint chain validates previous checkpoint hash" {
    const testing = std.testing;
    const kp = testKeypair();

    var first = CheckpointRecord{
        .log_id = "log",
        .from_seq = 1,
        .to_seq = 2,
        .accumulator_root = hashBytes("root-1"),
        .creator_identity = kp.public_key[0..],
        .created_at_ms = 1,
        .ingested_at_ms = 2,
    };
    first.signature = try first.signEd25519(testing.allocator, &kp.secret_key);

    var second = CheckpointRecord{
        .log_id = "log",
        .from_seq = 3,
        .to_seq = 4,
        .accumulator_root = hashBytes("root-2"),
        .previous_checkpoint_hash = try first.recordHash(testing.allocator),
        .creator_identity = kp.public_key[0..],
        .created_at_ms = 3,
        .ingested_at_ms = 4,
    };
    second.signature = try second.signEd25519(testing.allocator, &kp.secret_key);

    try verifyIncludedCheckpointChain(testing.allocator, &.{ first, second });

    second.previous_checkpoint_hash = hashBytes("wrong");
    second.signature = try second.signEd25519(testing.allocator, &kp.secret_key);
    try testing.expectError(error.CheckpointLinkMismatch, verifyIncludedCheckpointChain(testing.allocator, &.{ first, second }));
}
