//! Verifier-friendly proof-bundle scaffolding.
//!
//! Proof bundles gather records, accumulator inclusion material, and signed
//! checkpoints into a small packet that can be verified outside a live WormDB
//! node. The concrete accumulator path codec is injected by callback.

const std = @import("std");
const builtin = @import("builtin");
const append_log = @import("append_log.zig");
const checkpoint = @import("checkpoint.zig");
const mmr = @import("mmr.zig");
const Store = @import("../storage/store.zig").Store;
const compat = @import("../core/compat.zig");

pub const BUNDLE_MAGIC = "WDBPBND1";
pub const BUNDLE_CODEC_VERSION: u16 = 1;
const MIN_RECORD_BYTES: usize = 8 + checkpoint.HASH_LEN + 4 + 1 + 4;
const MIN_PROOF_BYTES: usize = 8 + checkpoint.HASH_LEN + checkpoint.HASH_LEN + 4 + 4;
const MIN_CHECKPOINT_BYTES: usize = 1 + 4 + 8 + 8 + 1 + checkpoint.HASH_LEN + 1 + 4 + 1 + checkpoint.SIGNATURE_LEN + 8 + 8 + 4;

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

pub const BundleInfo = struct {
    kind: BundleKind,
    from_seq: u64,
    to_seq: u64,
    record_count: usize,
    checkpoint_count: usize,
    accumulator_kind: checkpoint.AccumulatorKind,
    accumulator_root: checkpoint.Hash,
    checkpoint_hash: checkpoint.Hash,
};

pub const OwnedProofBundle = struct {
    arena: std.heap.ArenaAllocator,
    log_id: []const u8,
    records: []const BundleRecord,
    inclusion_proofs: []const InclusionProof,
    checkpoints: []const checkpoint.CheckpointRecord,
    extension_bytes: []const u8,
    kind: BundleKind,
    version: u8 = checkpoint.VERSION,

    pub fn asBundle(self: *const OwnedProofBundle) ProofBundle {
        return .{
            .version = self.version,
            .kind = self.kind,
            .log_id = self.log_id,
            .records = self.records,
            .inclusion_proofs = self.inclusion_proofs,
            .checkpoints = self.checkpoints,
            .extension_bytes = self.extension_bytes,
        };
    }

    pub fn deinit(self: *OwnedProofBundle) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const EncodedBundle = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    info: BundleInfo,

    pub fn deinit(self: *EncodedBundle) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const AppendLogMmrBundleOptions = struct {
    log_id: []const u8,
    from_seq: u64,
    to_seq: u64,
    creator_public_key: []const u8,
    creator_secret_key: *const [checkpoint.SIGNATURE_LEN]u8,
    created_at_ms: ?u64 = null,
    ingested_at_ms: ?u64 = null,
    checkpoint_extension_bytes: []const u8 = &.{},
    bundle_extension_bytes: []const u8 = &.{},
};

fn freeScanResult(allocator: std.mem.Allocator, result: Store.ScanResult) void {
    allocator.free(result.key);
    allocator.free(result.value);
}

fn freeScanResultsFrom(allocator: std.mem.Allocator, results: []Store.ScanResult, start: usize) void {
    for (results[start..]) |result| freeScanResult(allocator, result);
}

/// Encode a proof bundle into canonical self-contained bytes for FFI and
/// transport. The encoded form is verifier-friendly; all variable fields are
/// length-prefixed and all integers are big-endian.
pub fn encodeCanonical(allocator: std.mem.Allocator, bundle: ProofBundle) ![]u8 {
    try bundle.validateShape();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendRaw(&out, allocator, BUNDLE_MAGIC);
    try appendU16(&out, allocator, BUNDLE_CODEC_VERSION);
    try appendU8(&out, allocator, bundle.version);
    try appendU8(&out, allocator, @intFromEnum(bundle.kind));
    try appendLenBytes(&out, allocator, bundle.log_id);
    try appendLenBytes(&out, allocator, bundle.extension_bytes);

    try appendU32(&out, allocator, try checkedU32(bundle.records.len));
    for (bundle.records) |record| {
        try appendU64(&out, allocator, record.seq);
        try appendHash(&out, allocator, record.record_hash);
        try appendLenBytes(&out, allocator, record.canonical_record_bytes);
        if (record.value_bytes) |value| {
            const value_hash = record.value_hash orelse return error.MissingValueHash;
            try appendU8(&out, allocator, 1);
            try appendHash(&out, allocator, value_hash);
            try appendLenBytes(&out, allocator, value);
        } else {
            try appendU8(&out, allocator, 0);
        }
        try appendLenBytes(&out, allocator, record.extension_bytes);
    }

    try appendU32(&out, allocator, try checkedU32(bundle.inclusion_proofs.len));
    for (bundle.inclusion_proofs) |proof| {
        try appendU64(&out, allocator, proof.seq);
        try appendHash(&out, allocator, proof.leaf_hash);
        try appendHash(&out, allocator, proof.checkpoint_hash);
        try appendLenBytes(&out, allocator, proof.path_bytes);
        try appendLenBytes(&out, allocator, proof.extension_bytes);
    }

    try appendU32(&out, allocator, try checkedU32(bundle.checkpoints.len));
    for (bundle.checkpoints) |cp| try encodeCheckpoint(&out, allocator, cp);

    return try out.toOwnedSlice(allocator);
}

/// Decode bytes produced by `encodeCanonical`. The returned bundle owns all
/// decoded slices through an arena and must be deinitialized by the caller.
pub fn decodeCanonical(allocator: std.mem.Allocator, bytes: []const u8) !OwnedProofBundle {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var pos: usize = 0;
    const magic = try readBytes(bytes, &pos, BUNDLE_MAGIC.len);
    if (!std.mem.eql(u8, magic, BUNDLE_MAGIC)) return error.InvalidProofBundleBytes;
    const codec_version = try readU16(bytes, &pos);
    if (codec_version != BUNDLE_CODEC_VERSION) return error.UnsupportedProofBundleCodecVersion;

    const version = try readU8(bytes, &pos);
    const kind = try decodeBundleKind(try readU8(bytes, &pos));
    const log_id = try readLenBytesAlloc(aa, bytes, &pos);
    const extension_bytes = try readLenBytesAlloc(aa, bytes, &pos);

    const record_count = try readU32(bytes, &pos);
    try ensureRemainingItems(bytes, pos, @intCast(record_count), MIN_RECORD_BYTES, 4);
    const records = try aa.alloc(BundleRecord, @intCast(record_count));
    for (records) |*record| {
        const seq = try readU64(bytes, &pos);
        const record_hash = try readHash(bytes, &pos);
        const canonical_record_bytes = try readLenBytesAlloc(aa, bytes, &pos);
        const has_value = try readBool(bytes, &pos);
        const value_hash: ?checkpoint.Hash = if (has_value) try readHash(bytes, &pos) else null;
        const value_bytes: ?[]const u8 = if (has_value) try readLenBytesAlloc(aa, bytes, &pos) else null;
        const record_extension_bytes = try readLenBytesAlloc(aa, bytes, &pos);
        record.* = .{
            .seq = seq,
            .canonical_record_bytes = canonical_record_bytes,
            .record_hash = record_hash,
            .value_bytes = value_bytes,
            .value_hash = value_hash,
            .extension_bytes = record_extension_bytes,
        };
    }

    const proof_count = try readU32(bytes, &pos);
    try ensureRemainingItems(bytes, pos, @intCast(proof_count), MIN_PROOF_BYTES, 4);
    const inclusion_proofs = try aa.alloc(InclusionProof, @intCast(proof_count));
    for (inclusion_proofs) |*proof| {
        proof.* = .{
            .seq = try readU64(bytes, &pos),
            .leaf_hash = try readHash(bytes, &pos),
            .checkpoint_hash = try readHash(bytes, &pos),
            .path_bytes = try readLenBytesAlloc(aa, bytes, &pos),
            .extension_bytes = try readLenBytesAlloc(aa, bytes, &pos),
        };
    }

    const checkpoint_count = try readU32(bytes, &pos);
    try ensureRemainingItems(bytes, pos, @intCast(checkpoint_count), MIN_CHECKPOINT_BYTES, 0);
    const checkpoints = try aa.alloc(checkpoint.CheckpointRecord, @intCast(checkpoint_count));
    for (checkpoints) |*cp| cp.* = try decodeCheckpoint(aa, bytes, &pos);

    if (pos != bytes.len) return error.InvalidProofBundleBytes;

    const owned = OwnedProofBundle{
        .arena = arena,
        .log_id = log_id,
        .records = records,
        .inclusion_proofs = inclusion_proofs,
        .checkpoints = checkpoints,
        .extension_bytes = extension_bytes,
        .kind = kind,
        .version = version,
    };
    try owned.asBundle().validateShape();
    return owned;
}

pub fn bundleInfo(allocator: std.mem.Allocator, bundle: ProofBundle) !BundleInfo {
    try bundle.validateShape();
    const first_record = bundle.records[0];
    const last_record = bundle.records[bundle.records.len - 1];
    const primary_checkpoint = bundle.checkpoints[0];
    return .{
        .kind = bundle.kind,
        .from_seq = first_record.seq,
        .to_seq = last_record.seq,
        .record_count = bundle.records.len,
        .checkpoint_count = bundle.checkpoints.len,
        .accumulator_kind = primary_checkpoint.accumulator_kind,
        .accumulator_root = primary_checkpoint.accumulator_root,
        .checkpoint_hash = try primary_checkpoint.recordHash(allocator),
    };
}

pub fn verifyAppendLogMmrBundle(allocator: std.mem.Allocator, bundle: ProofBundle) !BundleInfo {
    try verifyAppendLogRecords(bundle);
    var verifier_ctx = MmrVerifierContext{ .allocator = allocator };
    try bundle.verify(allocator, mmrAccumulatorVerifier(&verifier_ctx));
    return try bundleInfo(allocator, bundle);
}

pub fn verifyEncodedAppendLogMmrBundle(allocator: std.mem.Allocator, bytes: []const u8) !BundleInfo {
    var decoded = try decodeCanonical(allocator, bytes);
    defer decoded.deinit();
    return try verifyAppendLogMmrBundle(allocator, decoded.asBundle());
}

pub fn buildAppendLogMmrBundle(
    allocator: std.mem.Allocator,
    store: *Store,
    options: AppendLogMmrBundleOptions,
) !EncodedBundle {
    if (options.from_seq == 0) return error.InvalidSequenceRange;
    if (options.from_seq > options.to_seq) return error.InvalidSequenceRange;
    if (options.creator_public_key.len != checkpoint.PUBLIC_KEY_LEN) return error.InvalidPublicKeyLength;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const log_id = try aa.dupe(u8, options.log_id);
    const bundle_extension_bytes = try aa.dupe(u8, options.bundle_extension_bytes);
    const checkpoint_extension_bytes = try aa.dupe(u8, options.checkpoint_extension_bytes);
    const creator_identity = try aa.dupe(u8, options.creator_public_key);

    var acc = mmr.Accumulator.init(allocator);
    defer acc.deinit();

    var records_list: std.ArrayListUnmanaged(BundleRecord) = .empty;
    const expected_record_count = try rangeLen(options.from_seq, options.to_seq);
    try records_list.ensureTotalCapacity(aa, expected_record_count);

    const prefix = try append_log.eventKeyPrefix(allocator, options.log_id);
    defer allocator.free(prefix);

    const results = try store.scanPrefix(prefix, 0, allocator);
    defer allocator.free(results);

    var expected_seq: u64 = 1;
    var previous_hash = append_log.ZERO_HASH;
    var result_index: usize = 0;
    errdefer freeScanResultsFrom(allocator, results, result_index);
    while (result_index < results.len) : (result_index += 1) {
        const result = results[result_index];
        const key_seq = try append_log.seqFromEventKey(prefix, result.key);
        if (key_seq > options.to_seq) {
            freeScanResultsFrom(allocator, results, result_index);
            result_index = results.len;
            break;
        }
        if (!result.is_worm) return error.NonWormEvent;

        const view = try append_log.decodeEnvelope(result.value);
        if (view.seq != key_seq) return error.SequenceKeyMismatch;
        if (view.seq < expected_seq) return error.SequenceReuse;
        if (view.seq > expected_seq) return error.SequenceGap;
        if (view.ingest_time_ms != result.timestamp) return error.ReceiptTimestampMismatch;
        if (!append_log.hashEql(view.prev_event_hash, previous_hash)) return error.PrevHashMismatch;
        try append_log.verifyEnvelope(options.log_id, view);

        const record_hash = checkpoint.hashBytes(result.value);
        _ = try acc.append(record_hash[0..]);
        if (key_seq >= options.from_seq) {
            try records_list.append(aa, .{
                .seq = key_seq,
                .canonical_record_bytes = try aa.dupe(u8, result.value),
                .record_hash = record_hash,
            });
        }

        previous_hash = view.event_hash;
        if (expected_seq != std.math.maxInt(u64)) expected_seq += 1;
        freeScanResult(allocator, result);
    }

    if (expected_seq <= options.to_seq) return error.SequenceGap;
    const records = try records_list.toOwnedSlice(aa);
    if (records.len != expected_record_count) return error.SequenceGap;

    const root = acc.root();
    var cp = checkpoint.CheckpointRecord{
        .log_id = log_id,
        .from_seq = options.from_seq,
        .to_seq = options.to_seq,
        .accumulator_kind = .mmr_sha256_v1,
        .accumulator_root = root,
        .creator_identity = creator_identity,
        .created_at_ms = options.created_at_ms orelse @intCast(compat.nowMs()),
        .ingested_at_ms = options.ingested_at_ms orelse @intCast(compat.nowMs()),
        .extension_bytes = checkpoint_extension_bytes,
    };
    cp.signature = try cp.signEd25519(allocator, options.creator_secret_key);
    const cp_hash = try cp.recordHash(allocator);

    const proofs = try aa.alloc(InclusionProof, records.len);
    for (records, proofs) |record, *proof_out| {
        var proof = try acc.prove(record.seq - 1, allocator);
        defer proof.deinit();
        const proof_bytes = try mmr.encodeInclusionProof(aa, proof);
        proof_out.* = .{
            .seq = record.seq,
            .leaf_hash = record.record_hash,
            .checkpoint_hash = cp_hash,
            .path_bytes = proof_bytes,
        };
    }

    const checkpoints = try aa.alloc(checkpoint.CheckpointRecord, 1);
    checkpoints[0] = cp;

    const bundle = ProofBundle{
        .kind = if (records.len == 1) .single_event else .range,
        .log_id = log_id,
        .records = records,
        .inclusion_proofs = proofs,
        .checkpoints = checkpoints,
        .extension_bytes = bundle_extension_bytes,
    };
    _ = try verifyAppendLogMmrBundle(allocator, bundle);

    const bytes = try encodeCanonical(allocator, bundle);
    errdefer allocator.free(bytes);
    return .{
        .allocator = allocator,
        .bytes = bytes,
        .info = try bundleInfo(allocator, bundle),
    };
}

fn verifyAppendLogRecords(bundle: ProofBundle) !void {
    try bundle.validateShape();

    var expected_seq = bundle.records[0].seq;
    var previous_event_hash: ?append_log.Hash = null;
    for (bundle.records) |record| {
        if (record.seq != expected_seq) return error.NonContiguousRange;
        const view = try append_log.decodeEnvelope(record.canonical_record_bytes);
        if (view.seq != record.seq) return error.SequenceKeyMismatch;
        try append_log.verifyEnvelope(bundle.log_id, view);

        if (previous_event_hash) |prev| {
            if (!append_log.hashEql(view.prev_event_hash, prev)) return error.PrevHashMismatch;
        } else if (record.seq == 1 and !append_log.hashEql(view.prev_event_hash, append_log.ZERO_HASH)) {
            return error.PrevHashMismatch;
        }
        previous_event_hash = view.event_hash;
        if (expected_seq != std.math.maxInt(u64)) {
            expected_seq += 1;
        }
    }
}

fn encodeCheckpoint(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cp: checkpoint.CheckpointRecord) !void {
    try appendU8(out, allocator, cp.version);
    try appendLenBytes(out, allocator, cp.log_id);
    try appendU64(out, allocator, cp.from_seq);
    try appendU64(out, allocator, cp.to_seq);
    try appendU8(out, allocator, @intFromEnum(cp.accumulator_kind));
    try appendHash(out, allocator, cp.accumulator_root);
    if (cp.previous_checkpoint_hash) |previous| {
        try appendU8(out, allocator, 1);
        try appendHash(out, allocator, previous);
    } else {
        try appendU8(out, allocator, 0);
    }
    try appendLenBytes(out, allocator, cp.creator_identity);
    try appendU8(out, allocator, @intFromEnum(cp.signature_scheme));
    try appendRaw(out, allocator, cp.signature[0..]);
    try appendU64(out, allocator, cp.created_at_ms);
    try appendU64(out, allocator, cp.ingested_at_ms);
    try appendLenBytes(out, allocator, cp.extension_bytes);
}

fn decodeBundleKind(raw: u8) !BundleKind {
    return switch (raw) {
        @intFromEnum(BundleKind.single_event) => .single_event,
        @intFromEnum(BundleKind.range) => .range,
        else => error.InvalidProofBundleBytes,
    };
}

fn decodeAccumulatorKind(raw: u8) !checkpoint.AccumulatorKind {
    return switch (raw) {
        @intFromEnum(checkpoint.AccumulatorKind.opaque_root) => .opaque_root,
        @intFromEnum(checkpoint.AccumulatorKind.merkle_sha256_v1) => .merkle_sha256_v1,
        @intFromEnum(checkpoint.AccumulatorKind.mmr_sha256_v1) => .mmr_sha256_v1,
        else => error.InvalidProofBundleBytes,
    };
}

fn decodeSignatureScheme(raw: u8) !checkpoint.SignatureScheme {
    return switch (raw) {
        @intFromEnum(checkpoint.SignatureScheme.ed25519) => .ed25519,
        else => error.InvalidProofBundleBytes,
    };
}

fn decodeCheckpoint(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) !checkpoint.CheckpointRecord {
    const version = try readU8(bytes, pos);
    const log_id = try readLenBytesAlloc(allocator, bytes, pos);
    const from_seq = try readU64(bytes, pos);
    const to_seq = try readU64(bytes, pos);
    const accumulator_kind = try decodeAccumulatorKind(try readU8(bytes, pos));
    const accumulator_root = try readHash(bytes, pos);
    const has_previous = try readBool(bytes, pos);
    const previous_checkpoint_hash: ?checkpoint.Hash = if (has_previous) try readHash(bytes, pos) else null;
    const creator_identity = try readLenBytesAlloc(allocator, bytes, pos);
    const signature_scheme = try decodeSignatureScheme(try readU8(bytes, pos));
    const signature_bytes = try readBytes(bytes, pos, checkpoint.SIGNATURE_LEN);
    var signature: checkpoint.Signature = undefined;
    @memcpy(signature[0..], signature_bytes);
    const created_at_ms = try readU64(bytes, pos);
    const ingested_at_ms = try readU64(bytes, pos);
    const extension_bytes = try readLenBytesAlloc(allocator, bytes, pos);

    return .{
        .version = version,
        .log_id = log_id,
        .from_seq = from_seq,
        .to_seq = to_seq,
        .accumulator_kind = accumulator_kind,
        .accumulator_root = accumulator_root,
        .previous_checkpoint_hash = previous_checkpoint_hash,
        .creator_identity = creator_identity,
        .signature_scheme = signature_scheme,
        .signature = signature,
        .created_at_ms = created_at_ms,
        .ingested_at_ms = ingested_at_ms,
        .extension_bytes = extension_bytes,
    };
}

fn checkedU32(value: usize) !u32 {
    if (value > std.math.maxInt(u32)) return error.FieldTooLarge;
    return @intCast(value);
}

fn rangeLen(from_seq: u64, to_seq: u64) !usize {
    const span = std.math.sub(u64, to_seq, from_seq) catch return error.InvalidSequenceRange;
    const count = std.math.add(u64, span, 1) catch return error.InvalidSequenceRange;
    if (count > std.math.maxInt(usize)) return error.InvalidSequenceRange;
    return @intCast(count);
}

fn appendU8(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u8) !void {
    try out.append(allocator, value);
}

fn appendU16(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendU32(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendU64(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendHash(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, hash: checkpoint.Hash) !void {
    try appendRaw(out, allocator, hash[0..]);
}

fn appendRaw(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
}

fn appendLenBytes(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try appendU32(out, allocator, try checkedU32(bytes.len));
    try appendRaw(out, allocator, bytes);
}

fn readU8(bytes: []const u8, pos: *usize) !u8 {
    const b = try readBytes(bytes, pos, 1);
    return b[0];
}

fn readBool(bytes: []const u8, pos: *usize) !bool {
    return switch (try readU8(bytes, pos)) {
        0 => false,
        1 => true,
        else => error.InvalidProofBundleBytes,
    };
}

fn readU16(bytes: []const u8, pos: *usize) !u16 {
    const b = try readBytes(bytes, pos, 2);
    return std.mem.readInt(u16, b[0..2], .big);
}

fn readU32(bytes: []const u8, pos: *usize) !u32 {
    const b = try readBytes(bytes, pos, 4);
    return std.mem.readInt(u32, b[0..4], .big);
}

fn readU64(bytes: []const u8, pos: *usize) !u64 {
    const b = try readBytes(bytes, pos, 8);
    return std.mem.readInt(u64, b[0..8], .big);
}

fn readHash(bytes: []const u8, pos: *usize) !checkpoint.Hash {
    const b = try readBytes(bytes, pos, checkpoint.HASH_LEN);
    var hash: checkpoint.Hash = undefined;
    @memcpy(hash[0..], b);
    return hash;
}

fn readLenBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8, pos: *usize) ![]const u8 {
    const len = try readU32(bytes, pos);
    const b = try readBytes(bytes, pos, @intCast(len));
    return try allocator.dupe(u8, b);
}

fn readBytes(bytes: []const u8, pos: *usize, len: usize) ![]const u8 {
    if (pos.* > bytes.len) return error.InvalidProofBundleBytes;
    if (len > bytes.len - pos.*) return error.InvalidProofBundleBytes;
    const out = bytes[pos.* .. pos.* + len];
    pos.* += len;
    return out;
}

fn ensureRemainingItems(bytes: []const u8, pos: usize, count: usize, item_len: usize, min_trailing: usize) !void {
    if (pos > bytes.len) return error.InvalidProofBundleBytes;
    const item_bytes = std.math.mul(usize, count, item_len) catch return error.InvalidProofBundleBytes;
    const needed = std.math.add(usize, item_bytes, min_trailing) catch return error.InvalidProofBundleBytes;
    if (needed > bytes.len - pos) return error.InvalidProofBundleBytes;
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

test "append-log MMR bundle builder encodes and verifies a subrange" {
    const testing = std.testing;
    const Config = @import("../core/config.zig").Config;
    const kp = try fixedTestKeypair();
    const log_id = "proof-builder:subrange";

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var first = try append_log.append(testing.allocator, &store, log_id, "alpha", &.{}, .{ .ingest_time_ms = 1_800_000_010_000 });
    defer first.deinit(testing.allocator);
    var second = try append_log.append(testing.allocator, &store, log_id, "bravo", &.{}, .{ .ingest_time_ms = 1_800_000_020_000 });
    defer second.deinit(testing.allocator);
    var third = try append_log.append(testing.allocator, &store, log_id, "charlie", &.{}, .{ .ingest_time_ms = 1_800_000_030_000 });
    defer third.deinit(testing.allocator);

    var encoded = try buildAppendLogMmrBundle(testing.allocator, &store, .{
        .log_id = log_id,
        .from_seq = 2,
        .to_seq = 3,
        .creator_public_key = kp.public_key[0..],
        .creator_secret_key = &kp.secret_key,
        .created_at_ms = 1_800_000_040_000,
        .ingested_at_ms = 1_800_000_040_123,
        .checkpoint_extension_bytes = "checkpoint claims",
        .bundle_extension_bytes = "transport hints",
    });
    defer encoded.deinit();

    try testing.expectEqual(BundleKind.range, encoded.info.kind);
    try testing.expectEqual(@as(u64, 2), encoded.info.from_seq);
    try testing.expectEqual(@as(u64, 3), encoded.info.to_seq);
    try testing.expectEqual(@as(usize, 2), encoded.info.record_count);
    try testing.expectEqual(checkpoint.AccumulatorKind.mmr_sha256_v1, encoded.info.accumulator_kind);

    const verified = try verifyEncodedAppendLogMmrBundle(testing.allocator, encoded.bytes);
    try testing.expectEqual(encoded.info.kind, verified.kind);
    try testing.expectEqual(encoded.info.from_seq, verified.from_seq);
    try testing.expectEqual(encoded.info.to_seq, verified.to_seq);
    try testing.expectEqualSlices(u8, encoded.info.accumulator_root[0..], verified.accumulator_root[0..]);
    try testing.expectEqualSlices(u8, encoded.info.checkpoint_hash[0..], verified.checkpoint_hash[0..]);

    var decoded = try decodeCanonical(testing.allocator, encoded.bytes);
    defer decoded.deinit();
    const reencoded = try encodeCanonical(testing.allocator, decoded.asBundle());
    defer testing.allocator.free(reencoded);
    try testing.expectEqualSlices(u8, encoded.bytes, reencoded);
}

test "encoded append-log MMR bundle verification rejects tampering" {
    const testing = std.testing;
    const Config = @import("../core/config.zig").Config;
    const kp = try fixedTestKeypair();
    const log_id = "proof-builder:tamper";

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var first = try append_log.append(testing.allocator, &store, log_id, "alpha", &.{}, .{ .ingest_time_ms = 1_800_000_010_000 });
    defer first.deinit(testing.allocator);

    var encoded = try buildAppendLogMmrBundle(testing.allocator, &store, .{
        .log_id = log_id,
        .from_seq = 1,
        .to_seq = 1,
        .creator_public_key = kp.public_key[0..],
        .creator_secret_key = &kp.secret_key,
        .created_at_ms = 1_800_000_040_000,
        .ingested_at_ms = 1_800_000_040_123,
    });
    defer encoded.deinit();

    {
        var bad = try testing.allocator.dupe(u8, encoded.bytes);
        defer testing.allocator.free(bad);
        const payload_offset = std.mem.indexOf(u8, bad, "alpha").?;
        bad[payload_offset] ^= 0xff;
        try testing.expectError(error.PayloadHashMismatch, verifyEncodedAppendLogMmrBundle(testing.allocator, bad));
    }

    {
        var bad = try testing.allocator.dupe(u8, encoded.bytes);
        defer testing.allocator.free(bad);
        const record_count_offset = BUNDLE_MAGIC.len + 2 + 1 + 1 + 4 + log_id.len + 4;
        std.mem.writeInt(u32, bad[record_count_offset .. record_count_offset + 4][0..4], std.math.maxInt(u32), .big);
        try testing.expectError(error.InvalidProofBundleBytes, decodeCanonical(testing.allocator, bad));
    }
}

test "proof spine golden vector verifies append log, MMR, checkpoint, and bundle" {
    const testing = std.testing;
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
