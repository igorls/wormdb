//! Verifier-friendly proof-bundle scaffolding.
//!
//! Proof bundles gather records, accumulator inclusion material, and signed
//! checkpoints into a small packet that can be verified outside a live WormDB
//! node. The concrete accumulator path codec is injected by callback.

const std = @import("std");
const checkpoint = @import("checkpoint.zig");

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
