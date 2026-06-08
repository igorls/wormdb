//! Verifier-friendly proof-bundle scaffolding.
//!
//! Proof bundles gather records, accumulator inclusion material, and signed
//! checkpoints into a small packet that can be verified outside a live WormDB
//! node. The concrete accumulator path codec is injected by callback.

const std = @import("std");
const builtin = @import("builtin");
const checkpoint = @import("checkpoint.zig");
const mmr = @import("mmr.zig");

pub const BundleKind = enum(u8) {
    single_event = 1,
    range = 2,
};

/// A record carried by a proof bundle.
///
/// `canonical_record_bytes` are the exact append-log bytes hashed by the log
/// layer. This module does not allocate sequences or define the append-log hash
/// chain; it only validates that carried bytes match the committed hash.
pub const BundleRecord = struct {
    seq: u64,
    canonical_record_bytes: []const u8,
    record_hash: checkpoint.Hash,
    value_bytes: ?[]const u8 = null,
    value_hash: ?checkpoint.Hash = null,
    extension_bytes: []const u8 = &.{},

    pub fn verifyHashes(self: *const BundleRecord) !void {
        if (!checkpoint.eqlHash(checkpoint.hashBytes(self.canonical_record_bytes), self.record_hash)) {
            return error.RecordHashMismatch;
        }

        if (self.value_bytes) |value| {
            const expected_value_hash = self.value_hash orelse return error.MissingValueHash;
            if (!checkpoint.eqlHash(checkpoint.hashBytes(value), expected_value_hash)) {
                return error.ValueHashMismatch;
            }
        }
    }
};

/// Opaque accumulator proof for a leaf. `path_bytes` are interpreted by the
/// accumulator verifier selected by `checkpoint.accumulator_kind`.
pub const InclusionProof = struct {
    seq: u64,
    leaf_hash: checkpoint.Hash,
    checkpoint_hash: checkpoint.Hash,
    path_bytes: []const u8 = &.{},
    extension_bytes: []const u8 = &.{},
};

pub const AccumulatorVerifier = struct {
    ctx: *anyopaque,
    verifyFn: *const fn (
        ctx: *anyopaque,
        kind: checkpoint.AccumulatorKind,
        root: checkpoint.Hash,
        leaf_hash: checkpoint.Hash,
        seq: u64,
        path_bytes: []const u8,
    ) bool,

    pub fn verify(
        self: AccumulatorVerifier,
        kind: checkpoint.AccumulatorKind,
        root: checkpoint.Hash,
        leaf_hash: checkpoint.Hash,
        seq: u64,
        path_bytes: []const u8,
    ) bool {
        return self.verifyFn(self.ctx, kind, root, leaf_hash, seq, path_bytes);
    }
};

pub const MmrVerifierContext = struct {
    allocator: std.mem.Allocator,
};

pub fn mmrAccumulatorVerifier(ctx: *MmrVerifierContext) AccumulatorVerifier {
    return .{ .ctx = @ptrCast(ctx), .verifyFn = verifyMmrAccumulator };
}

fn verifyMmrAccumulator(
    raw_ctx: *anyopaque,
    kind: checkpoint.AccumulatorKind,
    root: checkpoint.Hash,
    leaf_hash: checkpoint.Hash,
    seq: u64,
    path_bytes: []const u8,
) bool {
    if (kind != .mmr_sha256_v1) return false;
    if (seq == 0) return false;

    const ctx: *MmrVerifierContext = @ptrCast(@alignCast(raw_ctx));
    var proof = mmr.decodeInclusionProof(ctx.allocator, path_bytes) catch return false;
    defer proof.deinit();

    if (proof.leaf_index != seq - 1) return false;
    return mmr.verifyInclusion(proof, leaf_hash[0..], root);
}

/// A self-contained proof packet for one event or a contiguous record range.
///
/// Slices are borrowed; serialization is expected to be owned by the FFI or
/// procedure layer once those APIs land. The verification contract is stable:
/// record bytes hash to record hashes, record hashes are included in signed
/// checkpoint roots, and checkpoint signatures/linkage are valid.
pub const ProofBundle = struct {
    version: u8 = checkpoint.VERSION,
    kind: BundleKind,
    log_id: []const u8,
    records: []const BundleRecord,
    inclusion_proofs: []const InclusionProof,
    checkpoints: []const checkpoint.CheckpointRecord,
    extension_bytes: []const u8 = &.{},

    pub fn validateShape(self: *const ProofBundle) !void {
        if (self.version != checkpoint.VERSION) return error.UnsupportedProofBundleVersion;
        if (self.log_id.len == 0) return error.EmptyLogId;
        if (self.records.len == 0) return error.EmptyProofBundle;
        if (self.checkpoints.len == 0) return error.MissingCheckpoint;
        if (self.inclusion_proofs.len < self.records.len) return error.MissingInclusionProof;

        switch (self.kind) {
            .single_event => if (self.records.len != 1) return error.BundleKindMismatch,
            .range => try validateContiguousRange(self.records),
        }
    }

    pub fn verify(
        self: *const ProofBundle,
        allocator: std.mem.Allocator,
        accumulator_verifier: AccumulatorVerifier,
    ) !void {
        try self.validateShape();

        try checkpoint.verifyIncludedCheckpointChain(allocator, self.checkpoints);

        for (self.checkpoints) |*cp| {
            if (!std.mem.eql(u8, cp.log_id, self.log_id)) return error.LogIdMismatch;
        }

        for (self.records) |*record| {
            try record.verifyHashes();

            const proof = self.findProofForRecord(record) orelse return error.MissingInclusionProof;
            if (!checkpoint.eqlHash(proof.leaf_hash, record.record_hash)) return error.InclusionLeafMismatch;

            const cp = try self.findCheckpointByHash(allocator, proof.checkpoint_hash);
            if (cp == null) return error.MissingCheckpoint;
            if (!cp.?.coversSeq(record.seq)) return error.CheckpointRangeMismatch;

            if (!accumulator_verifier.verify(
                cp.?.accumulator_kind,
                cp.?.accumulator_root,
                proof.leaf_hash,
                proof.seq,
                proof.path_bytes,
            )) {
                return error.InclusionProofRejected;
            }
        }
    }

    fn findProofForRecord(self: *const ProofBundle, record: *const BundleRecord) ?*const InclusionProof {
        for (self.inclusion_proofs) |*proof| {
            if (proof.seq == record.seq and checkpoint.eqlHash(proof.leaf_hash, record.record_hash)) {
                return proof;
            }
        }
        return null;
    }

    fn findCheckpointByHash(self: *const ProofBundle, allocator: std.mem.Allocator, hash: checkpoint.Hash) !?*const checkpoint.CheckpointRecord {
        for (self.checkpoints) |*cp| {
            const cp_hash = try cp.recordHash(allocator);
            if (checkpoint.eqlHash(cp_hash, hash)) return cp;
        }
        return null;
    }
};

fn validateContiguousRange(records: []const BundleRecord) !void {
    if (records.len == 0) return error.EmptyProofBundle;

    var expected_seq = records[0].seq;
    for (records, 0..) |record, i| {
        if (record.seq != expected_seq) return error.NonContiguousRange;
        if (i + 1 < records.len) {
            expected_seq = std.math.add(u64, expected_seq, 1) catch return error.SequenceOverflow;
        }
    }
}

fn acceptsLeafAsRoot(
    ctx: *anyopaque,
    kind: checkpoint.AccumulatorKind,
    root: checkpoint.Hash,
    leaf_hash: checkpoint.Hash,
    seq: u64,
    path_bytes: []const u8,
) bool {
    _ = ctx;
    _ = kind;
    _ = seq;
    return path_bytes.len == 0 and checkpoint.eqlHash(root, leaf_hash);
}

fn testVerifier() AccumulatorVerifier {
    return .{ .ctx = &test_verifier_context, .verifyFn = acceptsLeafAsRoot };
}

var test_verifier_context: u8 = 0;

fn signedCheckpointForRoot(
    allocator: std.mem.Allocator,
    log_id: []const u8,
    seq: u64,
    root: checkpoint.Hash,
    public_key: []const u8,
    secret_key: *const [checkpoint.SIGNATURE_LEN]u8,
) !checkpoint.CheckpointRecord {
    var cp = checkpoint.CheckpointRecord{
        .log_id = log_id,
        .from_seq = seq,
        .to_seq = seq,
        .accumulator_kind = .merkle_sha256_v1,
        .accumulator_root = root,
        .creator_identity = public_key,
        .created_at_ms = 100,
        .ingested_at_ms = 101,
    };
    cp.signature = try cp.signEd25519(allocator, secret_key);
    return cp;
}

test "single event proof verifies record hash, checkpoint signature, and inclusion callback" {
    const testing = std.testing;
    const kp = blk: {
        const raw = std.crypto.sign.Ed25519.KeyPair.generate(std.Io.Threaded.global_single_threaded.io());
        break :blk .{ .public_key = raw.public_key.toBytes(), .secret_key = raw.secret_key.toBytes() };
    };

    const record_bytes = "canonical append-log record bytes";
    const record_hash = checkpoint.hashBytes(record_bytes);
    const cp = try signedCheckpointForRoot(testing.allocator, "log:demo", 7, record_hash, kp.public_key[0..], &kp.secret_key);
    const cp_hash = try cp.recordHash(testing.allocator);

    const records = [_]BundleRecord{.{
        .seq = 7,
        .canonical_record_bytes = record_bytes,
        .record_hash = record_hash,
        .value_bytes = "payload",
        .value_hash = checkpoint.hashBytes("payload"),
    }};
    const proofs = [_]InclusionProof{.{
        .seq = 7,
        .leaf_hash = record_hash,
        .checkpoint_hash = cp_hash,
    }};
    const checkpoints = [_]checkpoint.CheckpointRecord{cp};
    const bundle = ProofBundle{
        .kind = .single_event,
        .log_id = "log:demo",
        .records = records[0..],
        .inclusion_proofs = proofs[0..],
        .checkpoints = checkpoints[0..],
    };

    try bundle.verify(testing.allocator, testVerifier());
}

test "range proof rejects non-contiguous record sequences" {
    const testing = std.testing;
    const public_key = checkpoint.ZERO_HASH;
    const records = [_]BundleRecord{
        .{ .seq = 1, .canonical_record_bytes = "a", .record_hash = checkpoint.hashBytes("a") },
        .{ .seq = 3, .canonical_record_bytes = "b", .record_hash = checkpoint.hashBytes("b") },
    };
    const proofs = [_]InclusionProof{
        .{ .seq = 1, .leaf_hash = records[0].record_hash, .checkpoint_hash = checkpoint.ZERO_HASH },
        .{ .seq = 3, .leaf_hash = records[1].record_hash, .checkpoint_hash = checkpoint.ZERO_HASH },
    };
    const checkpoints = [_]checkpoint.CheckpointRecord{.{
        .log_id = "log",
        .from_seq = 1,
        .to_seq = 3,
        .accumulator_root = checkpoint.ZERO_HASH,
        .creator_identity = public_key[0..],
        .created_at_ms = 1,
        .ingested_at_ms = 1,
    }};
    const bundle = ProofBundle{
        .kind = .range,
        .log_id = "log",
        .records = records[0..],
        .inclusion_proofs = proofs[0..],
        .checkpoints = checkpoints[0..],
    };

    try testing.expectError(error.NonContiguousRange, bundle.validateShape());
}

test "record verifier detects payload tampering" {
    const testing = std.testing;
    const record = BundleRecord{
        .seq = 1,
        .canonical_record_bytes = "tampered",
        .record_hash = checkpoint.hashBytes("original"),
    };

    try testing.expectError(error.RecordHashMismatch, record.verifyHashes());
}

fn fixedTestKeypair() !struct { public_key: checkpoint.PublicKey, secret_key: [checkpoint.SIGNATURE_LEN]u8 } {
    if (!builtin.is_test) @compileError("fixedTestKeypair is test-only");

    var public_key: checkpoint.PublicKey = undefined;
    var secret_key: [checkpoint.SIGNATURE_LEN]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        public_key[0..],
        "2d6f7455d97b4a3a10d7293909d1a4f2058cb9a370e43fa8154bb280db839083",
    );
    _ = try std.fmt.hexToBytes(
        secret_key[0..],
        "8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de1662d6f7455d97b4a3a10d7293909d1a4f2058cb9a370e43fa8154bb280db839083",
    );
    return .{ .public_key = public_key, .secret_key = secret_key };
}

fn signedMmrCheckpoint(
    allocator: std.mem.Allocator,
    log_id: []const u8,
    from_seq: u64,
    to_seq: u64,
    root: checkpoint.Hash,
    public_key: []const u8,
    secret_key: *const [checkpoint.SIGNATURE_LEN]u8,
) !checkpoint.CheckpointRecord {
    var cp = checkpoint.CheckpointRecord{
        .log_id = log_id,
        .from_seq = from_seq,
        .to_seq = to_seq,
        .accumulator_kind = .mmr_sha256_v1,
        .accumulator_root = root,
        .creator_identity = public_key,
        .created_at_ms = 1_800_000_000_000,
        .ingested_at_ms = 1_800_000_000_123,
    };
    cp.signature = try cp.signEd25519(allocator, secret_key);
    return cp;
}

fn hashHex(hash: checkpoint.Hash) [checkpoint.HASH_LEN * 2]u8 {
    const alphabet = "0123456789abcdef";
    var out: [checkpoint.HASH_LEN * 2]u8 = undefined;
    for (hash, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn expectHashHex(actual: checkpoint.Hash, expected: []const u8) !void {
    const actual_hex = hashHex(actual);
    try std.testing.expectEqualStrings(expected, actual_hex[0..]);
}

test "proof bundle verifies encoded MMR inclusion proofs" {
    const testing = std.testing;
    const kp = try fixedTestKeypair();

    const record_bytes = [_][]const u8{ "record-1", "record-2", "record-3" };
    var record_hashes: [record_bytes.len]checkpoint.Hash = undefined;
    var acc = mmr.Accumulator.init(testing.allocator);
    defer acc.deinit();
    for (record_bytes, 0..) |bytes, i| {
        record_hashes[i] = checkpoint.hashBytes(bytes);
        _ = try acc.append(record_hashes[i][0..]);
    }

    const cp = try signedMmrCheckpoint(testing.allocator, "log:mmr", 1, 3, acc.root(), kp.public_key[0..], &kp.secret_key);
    const cp_hash = try cp.recordHash(testing.allocator);

    var proof0 = try acc.prove(0, testing.allocator);
    defer proof0.deinit();
    const proof0_bytes = try mmr.encodeInclusionProof(testing.allocator, proof0);
    defer testing.allocator.free(proof0_bytes);

    const records = [_]BundleRecord{.{
        .seq = 1,
        .canonical_record_bytes = record_bytes[0],
        .record_hash = record_hashes[0],
    }};
    const proofs = [_]InclusionProof{.{
        .seq = 1,
        .leaf_hash = record_hashes[0],
        .checkpoint_hash = cp_hash,
        .path_bytes = proof0_bytes,
    }};
    const checkpoints = [_]checkpoint.CheckpointRecord{cp};
    const bundle = ProofBundle{
        .kind = .single_event,
        .log_id = "log:mmr",
        .records = records[0..],
        .inclusion_proofs = proofs[0..],
        .checkpoints = checkpoints[0..],
    };

    var verifier_ctx = MmrVerifierContext{ .allocator = testing.allocator };
    try bundle.verify(testing.allocator, mmrAccumulatorVerifier(&verifier_ctx));
}

test "proof bundle rejects encoded MMR proof mismatches" {
    const testing = std.testing;
    const kp = try fixedTestKeypair();

    const record_hash = checkpoint.hashBytes("record-1");
    var acc = mmr.Accumulator.init(testing.allocator);
    defer acc.deinit();
    _ = try acc.append(record_hash[0..]);

    var proof = try acc.prove(0, testing.allocator);
    defer proof.deinit();
    const proof_bytes = try mmr.encodeInclusionProof(testing.allocator, proof);
    defer testing.allocator.free(proof_bytes);

    const cp = try signedMmrCheckpoint(testing.allocator, "log:mmr", 1, 3, acc.root(), kp.public_key[0..], &kp.secret_key);
    const cp_hash = try cp.recordHash(testing.allocator);
    var verifier_ctx = MmrVerifierContext{ .allocator = testing.allocator };

    {
        const records = [_]BundleRecord{.{
            .seq = 2,
            .canonical_record_bytes = "record-1",
            .record_hash = record_hash,
        }};
        const proofs = [_]InclusionProof{.{
            .seq = 2,
            .leaf_hash = record_hash,
            .checkpoint_hash = cp_hash,
            .path_bytes = proof_bytes,
        }};
        const checkpoints = [_]checkpoint.CheckpointRecord{cp};
        const bundle = ProofBundle{
            .kind = .single_event,
            .log_id = "log:mmr",
            .records = records[0..],
            .inclusion_proofs = proofs[0..],
            .checkpoints = checkpoints[0..],
        };
        try testing.expectError(error.InclusionProofRejected, bundle.verify(testing.allocator, mmrAccumulatorVerifier(&verifier_ctx)));
    }

    {
        const bad_cp = try signedMmrCheckpoint(testing.allocator, "log:mmr", 1, 1, checkpoint.hashBytes("wrong-root"), kp.public_key[0..], &kp.secret_key);
        const bad_cp_hash = try bad_cp.recordHash(testing.allocator);
        const records = [_]BundleRecord{.{
            .seq = 1,
            .canonical_record_bytes = "record-1",
            .record_hash = record_hash,
        }};
        const proofs = [_]InclusionProof{.{
            .seq = 1,
            .leaf_hash = record_hash,
            .checkpoint_hash = bad_cp_hash,
            .path_bytes = proof_bytes,
        }};
        const checkpoints = [_]checkpoint.CheckpointRecord{bad_cp};
        const bundle = ProofBundle{
            .kind = .single_event,
            .log_id = "log:mmr",
            .records = records[0..],
            .inclusion_proofs = proofs[0..],
            .checkpoints = checkpoints[0..],
        };
        try testing.expectError(error.InclusionProofRejected, bundle.verify(testing.allocator, mmrAccumulatorVerifier(&verifier_ctx)));
    }

    {
        const records = [_]BundleRecord{.{
            .seq = 1,
            .canonical_record_bytes = "record-1",
            .record_hash = record_hash,
        }};
        const proofs = [_]InclusionProof{.{
            .seq = 1,
            .leaf_hash = record_hash,
            .checkpoint_hash = checkpoint.hashBytes("missing-checkpoint"),
            .path_bytes = proof_bytes,
        }};
        const checkpoints = [_]checkpoint.CheckpointRecord{cp};
        const bundle = ProofBundle{
            .kind = .single_event,
            .log_id = "log:mmr",
            .records = records[0..],
            .inclusion_proofs = proofs[0..],
            .checkpoints = checkpoints[0..],
        };
        try testing.expectError(error.MissingCheckpoint, bundle.verify(testing.allocator, mmrAccumulatorVerifier(&verifier_ctx)));
    }

    {
        const records = [_]BundleRecord{.{
            .seq = 1,
            .canonical_record_bytes = "tampered",
            .record_hash = record_hash,
        }};
        const proofs = [_]InclusionProof{.{
            .seq = 1,
            .leaf_hash = record_hash,
            .checkpoint_hash = cp_hash,
            .path_bytes = proof_bytes,
        }};
        const checkpoints = [_]checkpoint.CheckpointRecord{cp};
        const bundle = ProofBundle{
            .kind = .single_event,
            .log_id = "log:mmr",
            .records = records[0..],
            .inclusion_proofs = proofs[0..],
            .checkpoints = checkpoints[0..],
        };
        try testing.expectError(error.RecordHashMismatch, bundle.verify(testing.allocator, mmrAccumulatorVerifier(&verifier_ctx)));
    }
}

test "proof spine golden vector verifies append log, MMR, checkpoint, and bundle" {
    const testing = std.testing;
    const append_log = @import("append_log.zig");
    const Store = @import("../storage/store.zig").Store;
    const Config = @import("../core/config.zig").Config;
    const kp = try fixedTestKeypair();
    const log_id = "proof-spine:golden";

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var first = try append_log.append(testing.allocator, &store, log_id, "alpha payload", &.{}, .{ .ingest_time_ms = 1_800_000_001_000 });
    defer first.deinit(testing.allocator);
    var second = try append_log.append(testing.allocator, &store, log_id, "bravo payload", &.{}, .{ .ingest_time_ms = 1_800_000_002_000 });
    defer second.deinit(testing.allocator);
    var third = try append_log.append(testing.allocator, &store, log_id, "charlie payload", &.{}, .{ .ingest_time_ms = 1_800_000_003_000 });
    defer third.deinit(testing.allocator);

    const report = try append_log.verifyStore(testing.allocator, &store, log_id);
    try testing.expectEqual(@as(usize, 3), report.count);
    try testing.expectEqual(@as(u64, 3), report.last_seq);
    try testing.expect(checkpoint.eqlHash(third.event_hash, report.head_hash));

    const envelopes = [_][]const u8{ first.envelope, second.envelope, third.envelope };
    var record_hashes: [3]checkpoint.Hash = undefined;
    var acc = mmr.Accumulator.init(testing.allocator);
    defer acc.deinit();
    for (envelopes, 0..) |envelope, i| {
        record_hashes[i] = checkpoint.hashBytes(envelope);
        _ = try acc.append(record_hashes[i][0..]);
    }

    const root = acc.root();
    const cp = try signedMmrCheckpoint(testing.allocator, log_id, 1, 3, root, kp.public_key[0..], &kp.secret_key);
    const cp_hash = try cp.recordHash(testing.allocator);

    var proof0 = try acc.prove(0, testing.allocator);
    defer proof0.deinit();
    var proof1 = try acc.prove(1, testing.allocator);
    defer proof1.deinit();
    var proof2 = try acc.prove(2, testing.allocator);
    defer proof2.deinit();

    const proof0_bytes = try mmr.encodeInclusionProof(testing.allocator, proof0);
    defer testing.allocator.free(proof0_bytes);
    const proof1_bytes = try mmr.encodeInclusionProof(testing.allocator, proof1);
    defer testing.allocator.free(proof1_bytes);
    const proof2_bytes = try mmr.encodeInclusionProof(testing.allocator, proof2);
    defer testing.allocator.free(proof2_bytes);

    const records = [_]BundleRecord{
        .{ .seq = 1, .canonical_record_bytes = first.envelope, .record_hash = record_hashes[0] },
        .{ .seq = 2, .canonical_record_bytes = second.envelope, .record_hash = record_hashes[1] },
        .{ .seq = 3, .canonical_record_bytes = third.envelope, .record_hash = record_hashes[2] },
    };
    const proofs = [_]InclusionProof{
        .{ .seq = 1, .leaf_hash = record_hashes[0], .checkpoint_hash = cp_hash, .path_bytes = proof0_bytes },
        .{ .seq = 2, .leaf_hash = record_hashes[1], .checkpoint_hash = cp_hash, .path_bytes = proof1_bytes },
        .{ .seq = 3, .leaf_hash = record_hashes[2], .checkpoint_hash = cp_hash, .path_bytes = proof2_bytes },
    };
    const checkpoints = [_]checkpoint.CheckpointRecord{cp};
    const bundle = ProofBundle{
        .kind = .range,
        .log_id = log_id,
        .records = records[0..],
        .inclusion_proofs = proofs[0..],
        .checkpoints = checkpoints[0..],
    };

    var verifier_ctx = MmrVerifierContext{ .allocator = testing.allocator };
    try bundle.verify(testing.allocator, mmrAccumulatorVerifier(&verifier_ctx));

    try expectHashHex(first.event_hash, "87832c30e5bfea3d6a6493306e5ced774c68c2d5e9d34e14b8d1ff41c9be3da1");
    try expectHashHex(second.event_hash, "d50efb4e4f5ab725a3eeed61540e124f186e19ac63f722921973fba48f5429b0");
    try expectHashHex(third.event_hash, "cafe05fb1ac07c1170d1508465c362102b584ecb794c5d609dee20b6b6acca73");
    try expectHashHex(root, "4c54ffe73285539577648522f02edd900db8446ec6fbc96db32b2437759e0992");
    try expectHashHex(cp_hash, "223a06ecece492e00ab05c342061afe7ce72b8c180028d8acccb42f5480f071c");
}
