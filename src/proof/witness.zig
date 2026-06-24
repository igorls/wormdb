//! Signed witness records for checkpoint roots.
//!
//! A witness countersigns a checkpoint root and hash. It does not author the
//! append-log records; it only says this identity observed the checkpoint.

const std = @import("std");
const checkpoint = @import("checkpoint.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

pub const VERSION: u8 = 1;
pub const HASH_LEN = checkpoint.HASH_LEN;
pub const PUBLIC_KEY_LEN = checkpoint.PUBLIC_KEY_LEN;
pub const SIGNATURE_LEN = checkpoint.SIGNATURE_LEN;

pub const Hash = checkpoint.Hash;
pub const PublicKey = checkpoint.PublicKey;
pub const Signature = checkpoint.Signature;

pub const ZERO_SIGNATURE = checkpoint.ZERO_SIGNATURE;

const WITNESS_SIGNING_DOMAIN = "wormdb.witness.sign.v1";
const WITNESS_RECORD_DOMAIN = "wormdb.witness.record.v1";

pub const SignatureScheme = checkpoint.SignatureScheme;

pub const WitnessRecord = struct {
    version: u8 = VERSION,
    log_id: []const u8,
    from_seq: u64,
    to_seq: u64,
    accumulator_kind: checkpoint.AccumulatorKind = .opaque_root,
    accumulator_root: Hash,
    checkpoint_hash: Hash,
    witness_identity: []const u8,
    signature_scheme: SignatureScheme = .ed25519,
    signature: Signature = ZERO_SIGNATURE,
    observed_at_ms: u64,
    extension_bytes: []const u8 = &.{},

    pub fn validateShape(self: *const WitnessRecord) !void {
        if (self.version != VERSION) return error.UnsupportedWitnessVersion;
        if (self.log_id.len == 0) return error.EmptyLogId;
        if (self.from_seq > self.to_seq) return error.InvalidSequenceRange;
        try ensureU32Len(self.log_id);
        try ensureU32Len(self.witness_identity);
        try ensureU32Len(self.extension_bytes);

        switch (self.signature_scheme) {
            .ed25519 => if (self.witness_identity.len != PUBLIC_KEY_LEN) {
                return error.InvalidPublicKeyLength;
            },
        }
    }

    pub fn fromCheckpoint(
        cp: checkpoint.CheckpointRecord,
        cp_hash: Hash,
        witness_identity: []const u8,
        observed_at_ms: u64,
        extension_bytes: []const u8,
    ) WitnessRecord {
        return .{
            .log_id = cp.log_id,
            .from_seq = cp.from_seq,
            .to_seq = cp.to_seq,
            .accumulator_kind = cp.accumulator_kind,
            .accumulator_root = cp.accumulator_root,
            .checkpoint_hash = cp_hash,
            .witness_identity = witness_identity,
            .observed_at_ms = observed_at_ms,
            .extension_bytes = extension_bytes,
        };
    }

    pub fn matchesCheckpoint(self: *const WitnessRecord, cp: checkpoint.CheckpointRecord, cp_hash: Hash) bool {
        return std.mem.eql(u8, self.log_id, cp.log_id) and
            self.from_seq == cp.from_seq and
            self.to_seq == cp.to_seq and
            self.accumulator_kind == cp.accumulator_kind and
            checkpoint.eqlHash(self.accumulator_root, cp.accumulator_root) and
            checkpoint.eqlHash(self.checkpoint_hash, cp_hash);
    }

    pub fn encodeSigningPayload(self: *const WitnessRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validateShape();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendBytes(&out, allocator, WITNESS_SIGNING_DOMAIN);
        try appendU8(&out, allocator, self.version);
        try appendLenBytes(&out, allocator, self.log_id);
        try appendU64(&out, allocator, self.from_seq);
        try appendU64(&out, allocator, self.to_seq);
        try appendU8(&out, allocator, @intFromEnum(self.accumulator_kind));
        try appendFixed(&out, allocator, self.accumulator_root[0..]);
        try appendFixed(&out, allocator, self.checkpoint_hash[0..]);
        try appendLenBytes(&out, allocator, self.witness_identity);
        try appendU8(&out, allocator, @intFromEnum(self.signature_scheme));
        try appendU64(&out, allocator, self.observed_at_ms);
        try appendLenBytes(&out, allocator, self.extension_bytes);

        return try out.toOwnedSlice(allocator);
    }

    pub fn encodeCanonical(self: *const WitnessRecord, allocator: std.mem.Allocator) ![]u8 {
        const signing_payload = try self.encodeSigningPayload(allocator);
        defer allocator.free(signing_payload);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendBytes(&out, allocator, WITNESS_RECORD_DOMAIN);
        try appendLenBytes(&out, allocator, signing_payload);
        try appendFixed(&out, allocator, self.signature[0..]);

        return try out.toOwnedSlice(allocator);
    }

    pub fn signingPayloadHash(self: *const WitnessRecord, allocator: std.mem.Allocator) !Hash {
        const payload = try self.encodeSigningPayload(allocator);
        defer allocator.free(payload);
        return hashBytes(payload);
    }

    pub fn recordHash(self: *const WitnessRecord, allocator: std.mem.Allocator) !Hash {
        const payload = try self.encodeCanonical(allocator);
        defer allocator.free(payload);
        return hashBytes(payload);
    }

    pub fn verifySignature(self: *const WitnessRecord, allocator: std.mem.Allocator) !bool {
        try self.validateShape();

        const payload = try self.encodeSigningPayload(allocator);
        defer allocator.free(payload);

        switch (self.signature_scheme) {
            .ed25519 => {
                const public_key_bytes: PublicKey = self.witness_identity[0..PUBLIC_KEY_LEN].*;
                const sig = Ed25519.Signature.fromBytes(self.signature);
                const public_key = Ed25519.PublicKey.fromBytes(public_key_bytes) catch return false;
                sig.verify(payload, public_key) catch return false;
                return true;
            },
        }
    }

    pub fn signEd25519(self: *const WitnessRecord, allocator: std.mem.Allocator, secret_key_bytes: *const [SIGNATURE_LEN]u8) !Signature {
        const payload = try self.encodeSigningPayload(allocator);
        defer allocator.free(payload);

        const secret_key = try Ed25519.SecretKey.fromBytes(secret_key_bytes.*);
        const key_pair = try Ed25519.KeyPair.fromSecretKey(secret_key);
        const sig = try key_pair.sign(payload, null);
        return sig.toBytes();
    }
};

pub fn hashBytes(bytes: []const u8) Hash {
    var out: Hash = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

pub fn decodeCanonical(bytes: []const u8) !WitnessRecord {
    var pos: usize = 0;
    try readTerminatedDomain(bytes, &pos, WITNESS_RECORD_DOMAIN);
    const signing_payload = try readLenBytes(bytes, &pos);
    const signature_bytes = try readFixed(bytes, &pos, SIGNATURE_LEN);
    if (pos != bytes.len) return error.InvalidWitnessRecord;

    var record = try decodeSigningPayload(signing_payload);
    record.signature = signature_bytes[0..SIGNATURE_LEN].*;
    try record.validateShape();
    return record;
}

fn decodeSigningPayload(bytes: []const u8) !WitnessRecord {
    var pos: usize = 0;
    try readTerminatedDomain(bytes, &pos, WITNESS_SIGNING_DOMAIN);

    const version = try readU8(bytes, &pos);
    const log_id = try readLenBytes(bytes, &pos);
    const from_seq = try readU64(bytes, &pos);
    const to_seq = try readU64(bytes, &pos);
    const accumulator_kind: checkpoint.AccumulatorKind = switch (try readU8(bytes, &pos)) {
        0 => .opaque_root,
        1 => .merkle_sha256_v1,
        2 => .mmr_sha256_v1,
        else => return error.UnsupportedAccumulatorKind,
    };
    const accumulator_root = try readHash(bytes, &pos);
    const checkpoint_hash = try readHash(bytes, &pos);
    const witness_identity = try readLenBytes(bytes, &pos);
    const signature_scheme: SignatureScheme = switch (try readU8(bytes, &pos)) {
        1 => .ed25519,
        else => return error.UnsupportedSignatureScheme,
    };
    const observed_at_ms = try readU64(bytes, &pos);
    const extension_bytes = try readLenBytes(bytes, &pos);
    if (pos != bytes.len) return error.InvalidWitnessRecord;

    return .{
        .version = version,
        .log_id = log_id,
        .from_seq = from_seq,
        .to_seq = to_seq,
        .accumulator_kind = accumulator_kind,
        .accumulator_root = accumulator_root,
        .checkpoint_hash = checkpoint_hash,
        .witness_identity = witness_identity,
        .signature_scheme = signature_scheme,
        .observed_at_ms = observed_at_ms,
        .extension_bytes = extension_bytes,
    };
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

fn readTerminatedDomain(bytes: []const u8, pos: *usize, domain: []const u8) !void {
    const got = try readFixed(bytes, pos, domain.len);
    if (!std.mem.eql(u8, got, domain)) return error.InvalidWitnessRecord;
    if (try readU8(bytes, pos) != 0) return error.InvalidWitnessRecord;
}

fn readU8(bytes: []const u8, pos: *usize) !u8 {
    const out = try readFixed(bytes, pos, 1);
    return out[0];
}

fn readU64(bytes: []const u8, pos: *usize) !u64 {
    const out = try readFixed(bytes, pos, 8);
    return std.mem.readInt(u64, out[0..8], .big);
}

fn readHash(bytes: []const u8, pos: *usize) !Hash {
    const out = try readFixed(bytes, pos, HASH_LEN);
    return out[0..HASH_LEN].*;
}

fn readLenBytes(bytes: []const u8, pos: *usize) ![]const u8 {
    const len_bytes = try readFixed(bytes, pos, 4);
    const len = std.mem.readInt(u32, len_bytes[0..4], .big);
    return try readFixed(bytes, pos, len);
}

fn readFixed(bytes: []const u8, pos: *usize, len: usize) ![]const u8 {
    if (pos.* > bytes.len) return error.InvalidWitnessRecord;
    if (len > bytes.len - pos.*) return error.InvalidWitnessRecord;
    const out = bytes[pos.* .. pos.* + len];
    pos.* += len;
    return out;
}

fn testKeypair() struct { public_key: PublicKey, secret_key: [SIGNATURE_LEN]u8 } {
    const kp = Ed25519.KeyPair.generate(std.Io.Threaded.global_single_threaded.io());
    return .{ .public_key = kp.public_key.toBytes(), .secret_key = kp.secret_key.toBytes() };
}

test "witness signs and verifies checkpoint identity" {
    const testing = std.testing;
    const creator = testKeypair();
    const signer = testKeypair();

    var cp = checkpoint.CheckpointRecord{
        .log_id = "fieldbook:north-yard",
        .from_seq = 1,
        .to_seq = 8,
        .accumulator_kind = .mmr_sha256_v1,
        .accumulator_root = checkpoint.hashBytes("root"),
        .creator_identity = creator.public_key[0..],
        .created_at_ms = 10,
        .ingested_at_ms = 20,
    };
    cp.signature = try cp.signEd25519(testing.allocator, &creator.secret_key);
    const cp_hash = try cp.recordHash(testing.allocator);

    var wr = WitnessRecord.fromCheckpoint(cp, cp_hash, signer.public_key[0..], 30, "device-time");
    wr.signature = try wr.signEd25519(testing.allocator, &signer.secret_key);

    try testing.expect(wr.matchesCheckpoint(cp, cp_hash));
    try testing.expect(try wr.verifySignature(testing.allocator));

    const canonical = try wr.encodeCanonical(testing.allocator);
    defer testing.allocator.free(canonical);
    const decoded = try decodeCanonical(canonical);
    try testing.expect(decoded.matchesCheckpoint(cp, cp_hash));
    try testing.expectEqualStrings(signer.public_key[0..], decoded.witness_identity);
    try testing.expectEqualStrings("device-time", decoded.extension_bytes);
    try testing.expect(try decoded.verifySignature(testing.allocator));
}

test "witness signature covers extension claim bytes" {
    const testing = std.testing;
    const signer = testKeypair();
    var wr = WitnessRecord{
        .log_id = "log",
        .from_seq = 1,
        .to_seq = 1,
        .accumulator_root = checkpoint.hashBytes("root"),
        .checkpoint_hash = checkpoint.hashBytes("checkpoint"),
        .witness_identity = signer.public_key[0..],
        .observed_at_ms = 30,
        .extension_bytes = "gps:lat=1",
    };
    wr.signature = try wr.signEd25519(testing.allocator, &signer.secret_key);

    var tampered = wr;
    tampered.extension_bytes = "gps:lat=2";
    try testing.expect(!try tampered.verifySignature(testing.allocator));
}
