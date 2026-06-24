//! Built-in verifiable append-log procedures.
//!
//! EXEC append_log_append <log_id> <payload> [ts=<ms>] [attachment_hash_hex...]
//! EXEC append_log_verify <log_id>
//! EXEC append_log_mmr_proof <log_id> <seq>
//! EXEC append_log_mmr_verify <record_hash_hex> <root_hex> <proof_hex>
//! EXEC append_log_checkpoint <log_id> <from_seq> <to_seq> <creator_pubkey_hex> sk=<secret_key_hex>|sig=<signature_hex> [created_at_ms=<ms>] [ingested_at_ms=<ms>] [prev=<checkpoint_hash_hex>] [ext=<hex>]
//! EXEC append_log_proof_bundle <log_id> <from_seq> <to_seq> <checkpoint_hash_hex>
//! EXEC append_log_proof_verify <log_id> <seq> <record_hash_hex> <checkpoint_hash_hex> <proof_hex>
//! EXEC append_log_witness <log_id> <checkpoint_hash_hex> [witness_pubkey_hex] [sk=<secret_key_hex>|sig=<signature_hex>] [observed_at_ms=<ms>] [ext=<hex>]
//! EXEC append_log_witness_import <log_id> <checkpoint_hash_hex> <canonical_witness_hex>
//! EXEC append_log_witness_verify <log_id> <checkpoint_hash_hex> <witness_pubkey_hex>
//!
//! Events are stored through the proof append-log primitive as WORM records
//! with canonical binary envelopes. Optional attachment hashes are 64-char
//! lowercase/uppercase hex SHA-256 values.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const Response = @import("../core/types.zig").Response;
const append_log = @import("../proof/append_log.zig");
const checkpoint = @import("../proof/checkpoint.zig");
const mmr = @import("../proof/mmr.zig");
const witness = @import("../proof/witness.zig");
const Store = @import("../storage/store.zig").Store;
const Config = @import("../core/config.zig").Config;

const CHECKPOINT_PREFIX = "proof:append-log-checkpoint:v1:";
const WITNESS_PREFIX = "proof:append-log-witness:v1:";

pub fn appendExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const log_id = ctx.arg(0) orelse
        return ctx.err("append_log_append requires: <log_id> <payload> [ts=<ms>] [attachment_hash_hex...]");
    const payload = ctx.arg(1) orelse
        return ctx.err("append_log_append requires: <log_id> <payload> [ts=<ms>] [attachment_hash_hex...]");

    var options = append_log.AppendOptions{};
    var hashes: std.ArrayListUnmanaged(append_log.Hash) = .empty;
    defer hashes.deinit(ctx.allocator);

    var i: usize = 2;
    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "ts=")) {
            options.ingest_time_ms = std.fmt.parseUnsigned(u64, arg["ts=".len..], 10) catch
                return ctx.err("append_log_append: invalid ts=<ms>");
            continue;
        }
        try hashes.append(ctx.allocator, parseHashHex(arg) catch
            return ctx.err("append_log_append: attachment hash must be 64 hex chars"));
    }

    var result = append_log.append(ctx.allocator, ctx.store, log_id, payload, hashes.items, options) catch |err| {
        return ctx.err(switch (err) {
            error.SequenceReuse => "append_log_append: sequence conflict, retry",
            error.SequenceOverflow => "append_log_append: sequence overflow",
            error.NonWormEvent => "append_log_append: existing log contains a non-WORM event",
            error.SequenceGap => "append_log_append: existing log has a sequence gap",
            error.PrevHashMismatch => "append_log_append: existing log hash chain is broken",
            error.PayloadHashMismatch => "append_log_append: existing log payload hash mismatch",
            error.EventHashMismatch => "append_log_append: existing log event hash mismatch",
            error.ReceiptTimestampMismatch => "append_log_append: existing log receipt timestamp mismatch",
            else => "append_log_append: append failed",
        });
    };
    defer result.deinit(ctx.allocator);

    return ctx.value(try appendResultJson(ctx.allocator, result));
}

pub fn verifyExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const log_id = ctx.arg(0) orelse
        return ctx.err("append_log_verify requires: <log_id>");
    if (ctx.argCount() != 1)
        return ctx.err("append_log_verify requires: <log_id>");

    const report = append_log.verifyStore(ctx.allocator, ctx.store, log_id) catch |err| {
        return ctx.err(switch (err) {
            error.NonWormEvent => "append_log_verify: non-WORM event",
            error.SequenceKeyMismatch => "append_log_verify: sequence key mismatch",
            error.ReceiptTimestampMismatch => "append_log_verify: receipt timestamp mismatch",
            error.SequenceReuse => "append_log_verify: duplicate sequence",
            error.SequenceGap => "append_log_verify: sequence gap",
            error.PrevHashMismatch => "append_log_verify: previous hash mismatch",
            error.PayloadHashMismatch => "append_log_verify: payload hash mismatch",
            error.EventHashMismatch => "append_log_verify: event hash mismatch",
            error.LogIdMismatch => "append_log_verify: log id mismatch",
            error.InvalidEnvelope => "append_log_verify: invalid envelope",
            error.UnsupportedEnvelopeVersion => "append_log_verify: unsupported envelope version",
            else => "append_log_verify: verification failed",
        });
    };

    return ctx.value(try verifyReportJson(ctx.allocator, report));
}

pub fn mmrProofExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const log_id = ctx.arg(0) orelse
        return ctx.err("append_log_mmr_proof requires: <log_id> <seq>");
    const seq = ctx.argInt(u64, 1) orelse
        return ctx.err("append_log_mmr_proof requires: <log_id> <seq>");
    if (seq == 0) return ctx.err("append_log_mmr_proof: seq must be >= 1");
    if (ctx.argCount() != 2) return ctx.err("append_log_mmr_proof requires: <log_id> <seq>");

    _ = append_log.verifyStore(ctx.allocator, ctx.store, log_id) catch |err| {
        return ctx.err(switch (err) {
            error.NonWormEvent => "append_log_mmr_proof: non-WORM event",
            error.SequenceGap => "append_log_mmr_proof: sequence gap",
            error.PrevHashMismatch => "append_log_mmr_proof: previous hash mismatch",
            error.PayloadHashMismatch => "append_log_mmr_proof: payload hash mismatch",
            error.EventHashMismatch => "append_log_mmr_proof: event hash mismatch",
            else => "append_log_mmr_proof: log verification failed",
        });
    };

    var proof_data = buildMmrProof(ctx.allocator, ctx.store, log_id, seq) catch |err| {
        return ctx.err(switch (err) {
            error.SequenceNotFound => "append_log_mmr_proof: seq not found",
            else => "append_log_mmr_proof: proof build failed",
        });
    };
    defer proof_data.deinit(ctx.allocator);

    return ctx.value(try mmrProofJson(ctx.allocator, proof_data));
}

pub fn mmrVerifyExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const record_hash = parseHashHex(ctx.arg(0) orelse
        return ctx.err("append_log_mmr_verify requires: <record_hash_hex> <root_hex> <proof_hex>")) catch
        return ctx.err("append_log_mmr_verify: record hash must be 64 hex chars");
    const root = parseHashHex(ctx.arg(1) orelse
        return ctx.err("append_log_mmr_verify requires: <record_hash_hex> <root_hex> <proof_hex>")) catch
        return ctx.err("append_log_mmr_verify: root must be 64 hex chars");
    const proof_hex = ctx.arg(2) orelse
        return ctx.err("append_log_mmr_verify requires: <record_hash_hex> <root_hex> <proof_hex>");
    if (ctx.argCount() != 3)
        return ctx.err("append_log_mmr_verify requires: <record_hash_hex> <root_hex> <proof_hex>");

    const proof_bytes = parseHexBytes(ctx.allocator, proof_hex) catch
        return ctx.err("append_log_mmr_verify: proof must be even-length hex");
    defer ctx.allocator.free(proof_bytes);

    var proof = mmr.decodeInclusionProof(ctx.allocator, proof_bytes) catch {
        return ctx.value("{\"valid\":false}");
    };
    defer proof.deinit();

    const valid = mmr.verifyInclusion(proof, record_hash[0..], root);
    return ctx.value(if (valid) "{\"valid\":true}" else "{\"valid\":false}");
}

pub fn checkpointExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const log_id = ctx.arg(0) orelse
        return ctx.err("append_log_checkpoint requires: <log_id> <from_seq> <to_seq> <creator_pubkey_hex> sk=<secret_key_hex>|sig=<signature_hex> [created_at_ms=<ms>] [ingested_at_ms=<ms>] [prev=<checkpoint_hash_hex>] [ext=<hex>]");
    const from_seq = ctx.argInt(u64, 1) orelse
        return ctx.err("append_log_checkpoint requires: <log_id> <from_seq> <to_seq> <creator_pubkey_hex> sk=<secret_key_hex>|sig=<signature_hex> [created_at_ms=<ms>] [ingested_at_ms=<ms>] [prev=<checkpoint_hash_hex>] [ext=<hex>]");
    const to_seq = ctx.argInt(u64, 2) orelse
        return ctx.err("append_log_checkpoint requires: <log_id> <from_seq> <to_seq> <creator_pubkey_hex> sk=<secret_key_hex>|sig=<signature_hex> [created_at_ms=<ms>] [ingested_at_ms=<ms>] [prev=<checkpoint_hash_hex>] [ext=<hex>]");
    const creator_identity = parsePublicKeyHex(ctx.arg(3) orelse
        return ctx.err("append_log_checkpoint requires: <log_id> <from_seq> <to_seq> <creator_pubkey_hex> sk=<secret_key_hex>|sig=<signature_hex> [created_at_ms=<ms>] [ingested_at_ms=<ms>] [prev=<checkpoint_hash_hex>] [ext=<hex>]")) catch
        return ctx.err("append_log_checkpoint: creator public key must be 64 hex chars");
    if (from_seq == 0 or from_seq > to_seq) return ctx.err("append_log_checkpoint: invalid sequence range");

    var created_at_ms: ?u64 = null;
    var ingested_at_ms: ?u64 = null;
    var previous_checkpoint_hash: ?checkpoint.Hash = null;
    var signature: ?checkpoint.Signature = null;
    var secret_key: ?[checkpoint.SIGNATURE_LEN]u8 = null;
    var extension_bytes: []u8 = &.{};
    var owns_extension = false;
    defer if (owns_extension) ctx.allocator.free(extension_bytes);

    var i: usize = 4;
    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "created_at_ms=")) {
            created_at_ms = std.fmt.parseUnsigned(u64, arg["created_at_ms=".len..], 10) catch
                return ctx.err("append_log_checkpoint: invalid created_at_ms=<ms>");
        } else if (std.mem.startsWith(u8, arg, "ingested_at_ms=")) {
            ingested_at_ms = std.fmt.parseUnsigned(u64, arg["ingested_at_ms=".len..], 10) catch
                return ctx.err("append_log_checkpoint: invalid ingested_at_ms=<ms>");
        } else if (std.mem.startsWith(u8, arg, "prev=")) {
            previous_checkpoint_hash = parseHashHex(arg["prev=".len..]) catch
                return ctx.err("append_log_checkpoint: prev must be 64 hex chars");
        } else if (std.mem.startsWith(u8, arg, "sig=")) {
            signature = parseSignatureHex(arg["sig=".len..]) catch
                return ctx.err("append_log_checkpoint: sig must be 128 hex chars");
        } else if (std.mem.startsWith(u8, arg, "sk=")) {
            secret_key = parseSignatureHex(arg["sk=".len..]) catch
                return ctx.err("append_log_checkpoint: sk must be 128 hex chars");
        } else if (std.mem.startsWith(u8, arg, "ext=")) {
            if (owns_extension) ctx.allocator.free(extension_bytes);
            extension_bytes = parseHexBytes(ctx.allocator, arg["ext=".len..]) catch
                return ctx.err("append_log_checkpoint: ext must be even-length hex");
            owns_extension = true;
        } else {
            return ctx.err("append_log_checkpoint: unknown option");
        }
    }

    if (signature != null and secret_key != null)
        return ctx.err("append_log_checkpoint: pass either sig=<signature_hex> or sk=<secret_key_hex>, not both");
    if (signature == null and secret_key == null)
        return ctx.err("append_log_checkpoint: missing sig=<signature_hex> or sk=<secret_key_hex>");

    _ = append_log.verifyStore(ctx.allocator, ctx.store, log_id) catch |err| {
        return ctx.err(switch (err) {
            error.NonWormEvent => "append_log_checkpoint: non-WORM event",
            error.SequenceGap => "append_log_checkpoint: sequence gap",
            error.PrevHashMismatch => "append_log_checkpoint: previous hash mismatch",
            error.PayloadHashMismatch => "append_log_checkpoint: payload hash mismatch",
            error.EventHashMismatch => "append_log_checkpoint: event hash mismatch",
            else => "append_log_checkpoint: log verification failed",
        });
    };

    var root_data = buildMmrRoot(ctx.allocator, ctx.store, log_id, to_seq) catch |err| {
        return ctx.err(switch (err) {
            error.SequenceNotFound => "append_log_checkpoint: to_seq not found",
            else => "append_log_checkpoint: checkpoint root build failed",
        });
    };
    defer root_data.deinit(ctx.allocator);

    const ingested = ingested_at_ms orelse ctx.timestamp();
    var record = checkpoint.CheckpointRecord{
        .log_id = log_id,
        .from_seq = from_seq,
        .to_seq = to_seq,
        .accumulator_kind = .mmr_sha256_v1,
        .accumulator_root = root_data.root,
        .previous_checkpoint_hash = previous_checkpoint_hash,
        .creator_identity = creator_identity[0..],
        .signature = signature orelse checkpoint.ZERO_SIGNATURE,
        .created_at_ms = created_at_ms orelse ingested,
        .ingested_at_ms = ingested,
        .extension_bytes = extension_bytes,
    };
    if (secret_key) |*sk| record.signature = record.signEd25519(ctx.allocator, sk) catch
        return ctx.err("append_log_checkpoint: signing failed");
    if (!try record.verifySignature(ctx.allocator)) return ctx.err("append_log_checkpoint: signature verification failed");

    const canonical = try record.encodeCanonical(ctx.allocator);
    defer ctx.allocator.free(canonical);
    const record_hash = try record.recordHash(ctx.allocator);
    const key = try checkpointKey(ctx.allocator, log_id, record_hash);
    defer ctx.allocator.free(key);

    ctx.setDurableWormWithTimestamp(key, canonical, ingested) catch |err| switch (err) {
        error.WormViolation => return ctx.err("append_log_checkpoint: checkpoint already exists"),
        else => return ctx.err("append_log_checkpoint: checkpoint store failed"),
    };

    return ctx.value(try checkpointJson(ctx.allocator, record, record_hash, canonical));
}

pub fn proofBundleExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const log_id = ctx.arg(0) orelse
        return ctx.err("append_log_proof_bundle requires: <log_id> <from_seq> <to_seq> <checkpoint_hash_hex>");
    const from_seq = ctx.argInt(u64, 1) orelse
        return ctx.err("append_log_proof_bundle requires: <log_id> <from_seq> <to_seq> <checkpoint_hash_hex>");
    const to_seq = ctx.argInt(u64, 2) orelse
        return ctx.err("append_log_proof_bundle requires: <log_id> <from_seq> <to_seq> <checkpoint_hash_hex>");
    const checkpoint_hash = parseHashHex(ctx.arg(3) orelse
        return ctx.err("append_log_proof_bundle requires: <log_id> <from_seq> <to_seq> <checkpoint_hash_hex>")) catch
        return ctx.err("append_log_proof_bundle: checkpoint hash must be 64 hex chars");
    if (ctx.argCount() != 4)
        return ctx.err("append_log_proof_bundle requires: <log_id> <from_seq> <to_seq> <checkpoint_hash_hex>");
    if (from_seq == 0 or from_seq > to_seq) return ctx.err("append_log_proof_bundle: invalid sequence range");

    const loaded = loadCheckpoint(ctx.allocator, ctx.store, log_id, checkpoint_hash) catch |err| {
        return ctx.err(switch (err) {
            error.CheckpointNotFound => "append_log_proof_bundle: checkpoint not found",
            else => "append_log_proof_bundle: checkpoint load failed",
        });
    };
    defer loaded.deinit(ctx.allocator);
    if (!try loaded.record.verifySignature(ctx.allocator))
        return ctx.err("append_log_proof_bundle: checkpoint signature invalid");
    if (!std.mem.eql(u8, loaded.record.log_id, log_id))
        return ctx.err("append_log_proof_bundle: checkpoint log id mismatch");
    if (!loaded.record.coversSeq(from_seq) or !loaded.record.coversSeq(to_seq))
        return ctx.err("append_log_proof_bundle: checkpoint does not cover range");

    const bundle_json = proofBundleJson(ctx.allocator, ctx.store, log_id, from_seq, to_seq, loaded) catch |err| {
        return ctx.err(switch (err) {
            error.CheckpointRootMismatch => "append_log_proof_bundle: checkpoint root mismatch",
            error.SequenceNotFound => "append_log_proof_bundle: sequence not found",
            else => "append_log_proof_bundle: bundle build failed",
        });
    };
    return ctx.value(bundle_json);
}

pub fn proofVerifyExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const log_id = ctx.arg(0) orelse
        return ctx.err("append_log_proof_verify requires: <log_id> <seq> <record_hash_hex> <checkpoint_hash_hex> <proof_hex>");
    const seq = ctx.argInt(u64, 1) orelse
        return ctx.err("append_log_proof_verify requires: <log_id> <seq> <record_hash_hex> <checkpoint_hash_hex> <proof_hex>");
    const record_hash = parseHashHex(ctx.arg(2) orelse
        return ctx.err("append_log_proof_verify requires: <log_id> <seq> <record_hash_hex> <checkpoint_hash_hex> <proof_hex>")) catch
        return ctx.err("append_log_proof_verify: record hash must be 64 hex chars");
    const checkpoint_hash = parseHashHex(ctx.arg(3) orelse
        return ctx.err("append_log_proof_verify requires: <log_id> <seq> <record_hash_hex> <checkpoint_hash_hex> <proof_hex>")) catch
        return ctx.err("append_log_proof_verify: checkpoint hash must be 64 hex chars");
    const proof_hex = ctx.arg(4) orelse
        return ctx.err("append_log_proof_verify requires: <log_id> <seq> <record_hash_hex> <checkpoint_hash_hex> <proof_hex>");
    if (ctx.argCount() != 5)
        return ctx.err("append_log_proof_verify requires: <log_id> <seq> <record_hash_hex> <checkpoint_hash_hex> <proof_hex>");

    const proof_bytes = parseHexBytes(ctx.allocator, proof_hex) catch
        return ctx.err("append_log_proof_verify: proof must be even-length hex");
    defer ctx.allocator.free(proof_bytes);

    const loaded = loadCheckpoint(ctx.allocator, ctx.store, log_id, checkpoint_hash) catch {
        return ctx.value("{\"valid\":false}");
    };
    defer loaded.deinit(ctx.allocator);
    if (!std.mem.eql(u8, loaded.record.log_id, log_id)) return ctx.value("{\"valid\":false}");
    if (!loaded.record.coversSeq(seq)) return ctx.value("{\"valid\":false}");
    if (!try loaded.record.verifySignature(ctx.allocator)) return ctx.value("{\"valid\":false}");

    var proof = mmr.decodeInclusionProof(ctx.allocator, proof_bytes) catch {
        return ctx.value("{\"valid\":false}");
    };
    defer proof.deinit();
    if (proof.leaf_index != seq - 1) return ctx.value("{\"valid\":false}");

    const valid = mmr.verifyInclusion(proof, record_hash[0..], loaded.record.accumulator_root);
    return ctx.value(if (valid) "{\"valid\":true}" else "{\"valid\":false}");
}

pub fn witnessExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const usage = "append_log_witness requires: <log_id> <checkpoint_hash_hex> [witness_pubkey_hex] [sk=<secret_key_hex>|sig=<signature_hex>] [observed_at_ms=<ms>] [ext=<hex>]";
    const log_id = ctx.arg(0) orelse return ctx.err(usage);
    const checkpoint_hash = parseHashHex(ctx.arg(1) orelse return ctx.err(usage)) catch
        return ctx.err("append_log_witness: checkpoint hash must be 64 hex chars");

    var witness_identity: ?checkpoint.PublicKey = null;
    var signature: ?checkpoint.Signature = null;
    var secret_key: ?[checkpoint.SIGNATURE_LEN]u8 = null;
    var observed_at_ms: ?u64 = null;
    var extension_bytes: []u8 = &.{};
    var owns_extension = false;
    defer if (owns_extension) ctx.allocator.free(extension_bytes);

    var i: usize = 2;
    if (i < ctx.argCount()) {
        const maybe_identity = ctx.arg(i).?;
        if (!isWitnessOption(maybe_identity)) {
            witness_identity = parsePublicKeyHex(maybe_identity) catch
                return ctx.err("append_log_witness: witness public key must be 64 hex chars");
            i += 1;
        }
    }

    while (i < ctx.argCount()) : (i += 1) {
        const arg = ctx.arg(i).?;
        if (std.mem.startsWith(u8, arg, "observed_at_ms=")) {
            observed_at_ms = std.fmt.parseUnsigned(u64, arg["observed_at_ms=".len..], 10) catch
                return ctx.err("append_log_witness: invalid observed_at_ms=<ms>");
        } else if (std.mem.startsWith(u8, arg, "sig=")) {
            signature = parseSignatureHex(arg["sig=".len..]) catch
                return ctx.err("append_log_witness: sig must be 128 hex chars");
        } else if (std.mem.startsWith(u8, arg, "sk=")) {
            secret_key = parseSignatureHex(arg["sk=".len..]) catch
                return ctx.err("append_log_witness: sk must be 128 hex chars");
        } else if (std.mem.startsWith(u8, arg, "ext=")) {
            if (owns_extension) ctx.allocator.free(extension_bytes);
            extension_bytes = parseHexBytes(ctx.allocator, arg["ext=".len..]) catch
                return ctx.err("append_log_witness: ext must be even-length hex");
            owns_extension = true;
        } else {
            return ctx.err("append_log_witness: unknown option");
        }
    }

    if (signature != null and secret_key != null)
        return ctx.err("append_log_witness: pass either sig=<signature_hex> or sk=<secret_key_hex>, not both");

    const cluster_identity = if (ctx.cluster) |cluster| cluster.identityPublicKey() else null;
    const identity = witness_identity orelse cluster_identity orelse
        return ctx.err("append_log_witness: missing witness public key (or cluster identity)");

    const loaded = loadCheckpoint(ctx.allocator, ctx.store, log_id, checkpoint_hash) catch |err| {
        return ctx.err(switch (err) {
            error.CheckpointNotFound => "append_log_witness: checkpoint not found",
            else => "append_log_witness: checkpoint load failed",
        });
    };
    defer loaded.deinit(ctx.allocator);
    if (!try loaded.record.verifySignature(ctx.allocator))
        return ctx.err("append_log_witness: checkpoint signature invalid");
    if (!std.mem.eql(u8, loaded.record.log_id, log_id))
        return ctx.err("append_log_witness: checkpoint log id mismatch");

    var record = witness.WitnessRecord.fromCheckpoint(
        loaded.record,
        loaded.record_hash,
        identity[0..],
        observed_at_ms orelse ctx.timestamp(),
        extension_bytes,
    );

    if (secret_key) |*sk| {
        record.signature = record.signEd25519(ctx.allocator, sk) catch
            return ctx.err("append_log_witness: signing failed");
    } else if (signature) |sig| {
        record.signature = sig;
    } else if (ctx.cluster) |cluster| {
        const cluster_pub = cluster.identityPublicKey();
        if (!std.mem.eql(u8, identity[0..], cluster_pub[0..]))
            return ctx.err("append_log_witness: missing sig=<signature_hex> or sk=<secret_key_hex>");
        const payload = try record.encodeSigningPayload(ctx.allocator);
        defer ctx.allocator.free(payload);
        record.signature = cluster.signWithIdentity(payload) catch
            return ctx.err("append_log_witness: cluster identity signing failed");
    } else {
        return ctx.err("append_log_witness: missing sig=<signature_hex> or sk=<secret_key_hex>");
    }

    if (!try record.verifySignature(ctx.allocator))
        return ctx.err("append_log_witness: signature verification failed");

    const canonical = try record.encodeCanonical(ctx.allocator);
    defer ctx.allocator.free(canonical);
    _ = try storeWitnessCanonical(ctx, log_id, record, canonical);
    const record_hash = try record.recordHash(ctx.allocator);
    return ctx.value(try witnessJson(ctx.allocator, record, record_hash, canonical));
}

pub fn witnessImportExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const log_id = ctx.arg(0) orelse
        return ctx.err("append_log_witness_import requires: <log_id> <checkpoint_hash_hex> <canonical_witness_hex>");
    const checkpoint_hash = parseHashHex(ctx.arg(1) orelse
        return ctx.err("append_log_witness_import requires: <log_id> <checkpoint_hash_hex> <canonical_witness_hex>")) catch
        return ctx.err("append_log_witness_import: checkpoint hash must be 64 hex chars");
    const canonical_hex = ctx.arg(2) orelse
        return ctx.err("append_log_witness_import requires: <log_id> <checkpoint_hash_hex> <canonical_witness_hex>");
    if (ctx.argCount() != 3)
        return ctx.err("append_log_witness_import requires: <log_id> <checkpoint_hash_hex> <canonical_witness_hex>");

    const canonical = parseHexBytes(ctx.allocator, canonical_hex) catch
        return ctx.err("append_log_witness_import: canonical witness must be even-length hex");
    defer ctx.allocator.free(canonical);

    const loaded = loadCheckpoint(ctx.allocator, ctx.store, log_id, checkpoint_hash) catch |err| {
        return ctx.err(switch (err) {
            error.CheckpointNotFound => "append_log_witness_import: checkpoint not found",
            else => "append_log_witness_import: checkpoint load failed",
        });
    };
    defer loaded.deinit(ctx.allocator);
    if (!try loaded.record.verifySignature(ctx.allocator))
        return ctx.err("append_log_witness_import: checkpoint signature invalid");

    const record = witness.decodeCanonical(canonical) catch
        return ctx.err("append_log_witness_import: invalid canonical witness");
    if (!record.matchesCheckpoint(loaded.record, loaded.record_hash))
        return ctx.err("append_log_witness_import: witness checkpoint mismatch");
    if (!try record.verifySignature(ctx.allocator))
        return ctx.err("append_log_witness_import: signature verification failed");

    _ = try storeWitnessCanonical(ctx, log_id, record, canonical);
    const record_hash = try record.recordHash(ctx.allocator);
    return ctx.value(try witnessJson(ctx.allocator, record, record_hash, canonical));
}

pub fn witnessVerifyExecute(ctx: *Ctx) anyerror!Ctx.Result {
    const log_id = ctx.arg(0) orelse
        return ctx.err("append_log_witness_verify requires: <log_id> <checkpoint_hash_hex> <witness_pubkey_hex>");
    const checkpoint_hash = parseHashHex(ctx.arg(1) orelse
        return ctx.err("append_log_witness_verify requires: <log_id> <checkpoint_hash_hex> <witness_pubkey_hex>")) catch
        return ctx.err("append_log_witness_verify: checkpoint hash must be 64 hex chars");
    const witness_identity = parsePublicKeyHex(ctx.arg(2) orelse
        return ctx.err("append_log_witness_verify requires: <log_id> <checkpoint_hash_hex> <witness_pubkey_hex>")) catch
        return ctx.err("append_log_witness_verify: witness public key must be 64 hex chars");
    if (ctx.argCount() != 3)
        return ctx.err("append_log_witness_verify requires: <log_id> <checkpoint_hash_hex> <witness_pubkey_hex>");

    const loaded = loadCheckpoint(ctx.allocator, ctx.store, log_id, checkpoint_hash) catch {
        return ctx.value("{\"valid\":false}");
    };
    defer loaded.deinit(ctx.allocator);
    if (!try loaded.record.verifySignature(ctx.allocator)) return ctx.value("{\"valid\":false}");

    const key = try witnessKey(ctx.allocator, log_id, checkpoint_hash, witness_identity[0..]);
    defer ctx.allocator.free(key);
    const canonical = try ctx.store.getValueDupe(key, ctx.allocator) orelse {
        return ctx.value("{\"valid\":false}");
    };
    defer ctx.allocator.free(canonical);

    const record = witness.decodeCanonical(canonical) catch {
        return ctx.value("{\"valid\":false}");
    };
    if (!record.matchesCheckpoint(loaded.record, loaded.record_hash)) return ctx.value("{\"valid\":false}");
    if (!std.mem.eql(u8, record.witness_identity, witness_identity[0..])) return ctx.value("{\"valid\":false}");
    if (!try record.verifySignature(ctx.allocator)) return ctx.value("{\"valid\":false}");

    const record_hash = try record.recordHash(ctx.allocator);
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.appendSlice(ctx.allocator, "{\"valid\":true,\"witness\":");
    try appendWitnessJsonObject(&json, ctx.allocator, record, record_hash, canonical);
    try json.appendSlice(ctx.allocator, "}");
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

const MmrProofData = struct {
    seq: u64,
    leaf_index: u64,
    leaf_count: u64,
    root: mmr.Hash,
    record_hash: append_log.Hash,
    proof_bytes: []u8,

    fn deinit(self: *MmrProofData, allocator: std.mem.Allocator) void {
        allocator.free(self.proof_bytes);
        self.* = undefined;
    }
};

const MmrRootData = struct {
    leaf_count: u64,
    root: mmr.Hash,

    fn deinit(self: *MmrRootData, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

const LoadedCheckpoint = struct {
    canonical: []const u8,
    record: checkpoint.CheckpointRecord,
    record_hash: checkpoint.Hash,

    fn deinit(self: LoadedCheckpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical);
    }
};

fn buildMmrProof(allocator: std.mem.Allocator, store: *Store, log_id: []const u8, seq: u64) !MmrProofData {
    const prefix = try append_log.eventKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    const results = try store.scanPrefix(prefix, 0, allocator);
    defer {
        for (results) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(results);
    }

    var acc = mmr.Accumulator.init(allocator);
    defer acc.deinit();

    var record_hash: ?append_log.Hash = null;
    for (results) |r| {
        const view = try append_log.decodeEnvelope(r.value);
        const leaf = append_log.hashBytes(r.value);
        _ = try acc.append(leaf[0..]);
        if (view.seq == seq) record_hash = leaf;
    }
    const target_hash = record_hash orelse return error.SequenceNotFound;
    const leaf_index = seq - 1;
    var proof = try acc.prove(leaf_index, allocator);
    defer proof.deinit();
    const proof_bytes = try mmr.encodeInclusionProof(allocator, proof);
    errdefer allocator.free(proof_bytes);

    return .{
        .seq = seq,
        .leaf_index = leaf_index,
        .leaf_count = acc.len(),
        .root = acc.root(),
        .record_hash = target_hash,
        .proof_bytes = proof_bytes,
    };
}

fn buildMmrRoot(allocator: std.mem.Allocator, store: *Store, log_id: []const u8, to_seq: u64) !MmrRootData {
    const prefix = try append_log.eventKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    const results = try store.scanPrefix(prefix, 0, allocator);
    defer freeScanResults(allocator, results);

    var acc = mmr.Accumulator.init(allocator);
    defer acc.deinit();

    for (results) |r| {
        const view = try append_log.decodeEnvelope(r.value);
        if (view.seq > to_seq) break;
        const leaf = append_log.hashBytes(r.value);
        _ = try acc.append(leaf[0..]);
    }

    if (acc.len() < to_seq) return error.SequenceNotFound;
    return .{ .leaf_count = acc.len(), .root = acc.root() };
}

fn loadCheckpoint(allocator: std.mem.Allocator, store: *Store, log_id: []const u8, record_hash: checkpoint.Hash) !LoadedCheckpoint {
    const key = try checkpointKey(allocator, log_id, record_hash);
    defer allocator.free(key);

    const canonical = try store.getValueDupe(key, allocator) orelse return error.CheckpointNotFound;
    errdefer allocator.free(canonical);
    var record = try checkpoint.decodeCanonical(canonical);
    const actual_hash = try record.recordHash(allocator);
    if (!checkpoint.eqlHash(actual_hash, record_hash)) return error.CheckpointHashMismatch;
    return .{ .canonical = canonical, .record = record, .record_hash = actual_hash };
}

fn proofBundleJson(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
    from_seq: u64,
    to_seq: u64,
    loaded: LoadedCheckpoint,
) ![]u8 {
    const prefix = try append_log.eventKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    const results = try store.scanPrefix(prefix, 0, allocator);
    defer freeScanResults(allocator, results);

    var acc = mmr.Accumulator.init(allocator);
    defer acc.deinit();

    for (results) |r| {
        const view = try append_log.decodeEnvelope(r.value);
        if (view.seq > loaded.record.to_seq) break;
        const leaf = append_log.hashBytes(r.value);
        _ = try acc.append(leaf[0..]);
    }
    if (acc.len() < loaded.record.to_seq) return error.SequenceNotFound;
    if (!checkpoint.eqlHash(acc.root(), loaded.record.accumulator_root)) return error.CheckpointRootMismatch;

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"version\":1,\"kind\":\"");
    try json.appendSlice(allocator, if (from_seq == to_seq) "single_event" else "range");
    try json.appendSlice(allocator, "\",\"log_id\":");
    try appendJsonString(&json, allocator, log_id);
    try json.appendSlice(allocator, ",\"records\":[");

    var seq = from_seq;
    while (seq <= to_seq) : (seq += 1) {
        const r = findEventResult(results, prefix, seq) orelse return error.SequenceNotFound;
        const view = try append_log.decodeEnvelope(r.value);
        const record_hash = append_log.hashBytes(r.value);
        if (seq != from_seq) try json.appendSlice(allocator, ",");
        try json.appendSlice(allocator, "{\"seq\":");
        try appendU64(&json, allocator, seq);
        try json.appendSlice(allocator, ",\"canonical_record_hex\":\"");
        try appendHexBytes(&json, allocator, r.value);
        try json.appendSlice(allocator, "\",\"record_hash\":\"");
        try appendHashHex(&json, allocator, record_hash);
        try json.appendSlice(allocator, "\",\"payload_hash\":\"");
        try appendHashHex(&json, allocator, view.payload_hash);
        try json.appendSlice(allocator, "\",\"event_hash\":\"");
        try appendHashHex(&json, allocator, view.event_hash);
        try json.appendSlice(allocator, "\"}");
    }

    try json.appendSlice(allocator, "],\"inclusion_proofs\":[");
    seq = from_seq;
    while (seq <= to_seq) : (seq += 1) {
        const r = findEventResult(results, prefix, seq) orelse return error.SequenceNotFound;
        const record_hash = append_log.hashBytes(r.value);
        var proof = try acc.prove(seq - 1, allocator);
        defer proof.deinit();
        const proof_bytes = try mmr.encodeInclusionProof(allocator, proof);
        defer allocator.free(proof_bytes);

        if (seq != from_seq) try json.appendSlice(allocator, ",");
        try json.appendSlice(allocator, "{\"seq\":");
        try appendU64(&json, allocator, seq);
        try json.appendSlice(allocator, ",\"leaf_hash\":\"");
        try appendHashHex(&json, allocator, record_hash);
        try json.appendSlice(allocator, "\",\"checkpoint_hash\":\"");
        try appendHashHex(&json, allocator, loaded.record_hash);
        try json.appendSlice(allocator, "\",\"proof_hex\":\"");
        try appendHexBytes(&json, allocator, proof_bytes);
        try json.appendSlice(allocator, "\"}");
    }

    try json.appendSlice(allocator, "],\"checkpoint\":");
    try appendCheckpointJsonObject(&json, allocator, loaded.record, loaded.record_hash, loaded.canonical);
    try json.appendSlice(allocator, "}");
    return json.toOwnedSlice(allocator);
}

fn findEventResult(results: []const Store.ScanResult, prefix: []const u8, seq: u64) ?Store.ScanResult {
    for (results) |r| {
        const key_seq = append_log.seqFromEventKey(prefix, r.key) catch continue;
        if (key_seq == seq) return r;
    }
    return null;
}

fn freeScanResults(allocator: std.mem.Allocator, results: []Store.ScanResult) void {
    for (results) |r| {
        allocator.free(r.key);
        allocator.free(r.value);
    }
    allocator.free(results);
}

fn appendResultJson(allocator: std.mem.Allocator, result: append_log.AppendResult) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"seq\":");
    try appendU64(&json, allocator, result.seq);
    try json.appendSlice(allocator, ",\"ingest_time_ms\":");
    try appendU64(&json, allocator, result.ingest_time_ms);
    try json.appendSlice(allocator, ",\"key_hex\":\"");
    try appendHexBytes(&json, allocator, result.key);
    try json.appendSlice(allocator, "\",\"prev_event_hash\":\"");
    try appendHashHex(&json, allocator, result.prev_event_hash);
    try json.appendSlice(allocator, "\",\"payload_hash\":\"");
    try appendHashHex(&json, allocator, result.payload_hash);
    try json.appendSlice(allocator, "\",\"event_hash\":\"");
    try appendHashHex(&json, allocator, result.event_hash);
    try json.appendSlice(allocator, "\",\"accumulator_kind\":\"mmr_sha256_v1\",\"accumulator_root\":\"");
    try appendHashHex(&json, allocator, result.accumulator_root);
    try json.appendSlice(allocator, "\",\"accumulator_leaf_count\":");
    try appendU64(&json, allocator, result.accumulator_leaf_count);
    try json.appendSlice(allocator, "}");
    return json.toOwnedSlice(allocator);
}

fn mmrProofJson(allocator: std.mem.Allocator, proof: MmrProofData) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"seq\":");
    try appendU64(&json, allocator, proof.seq);
    try json.appendSlice(allocator, ",\"leaf_index\":");
    try appendU64(&json, allocator, proof.leaf_index);
    try json.appendSlice(allocator, ",\"leaf_count\":");
    try appendU64(&json, allocator, proof.leaf_count);
    try json.appendSlice(allocator, ",\"root\":\"");
    try appendHashHex(&json, allocator, proof.root);
    try json.appendSlice(allocator, "\",\"record_hash\":\"");
    try appendHashHex(&json, allocator, proof.record_hash);
    try json.appendSlice(allocator, "\",\"proof_hex\":\"");
    try appendHexBytes(&json, allocator, proof.proof_bytes);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

fn checkpointJson(
    allocator: std.mem.Allocator,
    record: checkpoint.CheckpointRecord,
    record_hash: checkpoint.Hash,
    canonical: []const u8,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try appendCheckpointJsonObject(&json, allocator, record, record_hash, canonical);
    return json.toOwnedSlice(allocator);
}

fn appendCheckpointJsonObject(
    json: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    record: checkpoint.CheckpointRecord,
    record_hash: checkpoint.Hash,
    canonical: []const u8,
) !void {
    try json.appendSlice(allocator, "{\"log_id\":");
    try appendJsonString(json, allocator, record.log_id);
    try json.appendSlice(allocator, ",\"from_seq\":");
    try appendU64(json, allocator, record.from_seq);
    try json.appendSlice(allocator, ",\"to_seq\":");
    try appendU64(json, allocator, record.to_seq);
    try json.appendSlice(allocator, ",\"accumulator_kind\":\"");
    try json.appendSlice(allocator, switch (record.accumulator_kind) {
        .opaque_root => "opaque_root",
        .merkle_sha256_v1 => "merkle_sha256_v1",
        .mmr_sha256_v1 => "mmr_sha256_v1",
    });
    try json.appendSlice(allocator, "\",\"accumulator_root\":\"");
    try appendHashHex(json, allocator, record.accumulator_root);
    try json.appendSlice(allocator, "\",\"previous_checkpoint_hash\":");
    if (record.previous_checkpoint_hash) |prev| {
        try json.appendSlice(allocator, "\"");
        try appendHashHex(json, allocator, prev);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, "null");
    }
    try json.appendSlice(allocator, ",\"creator_identity\":\"");
    try appendHexBytes(json, allocator, record.creator_identity);
    try json.appendSlice(allocator, "\",\"signature\":\"");
    try appendHexBytes(json, allocator, record.signature[0..]);
    try json.appendSlice(allocator, "\",\"created_at_ms\":");
    try appendU64(json, allocator, record.created_at_ms);
    try json.appendSlice(allocator, ",\"ingested_at_ms\":");
    try appendU64(json, allocator, record.ingested_at_ms);
    try json.appendSlice(allocator, ",\"extension_hex\":\"");
    try appendHexBytes(json, allocator, record.extension_bytes);
    try json.appendSlice(allocator, "\",\"checkpoint_hash\":\"");
    try appendHashHex(json, allocator, record_hash);
    try json.appendSlice(allocator, "\",\"canonical_record_hex\":\"");
    try appendHexBytes(json, allocator, canonical);
    try json.appendSlice(allocator, "\"}");
}

fn verifyReportJson(allocator: std.mem.Allocator, report: append_log.VerifyReport) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"count\":");
    try appendUsize(&json, allocator, report.count);
    try json.appendSlice(allocator, ",\"last_seq\":");
    try appendU64(&json, allocator, report.last_seq);
    try json.appendSlice(allocator, ",\"head_hash\":\"");
    try appendHashHex(&json, allocator, report.head_hash);
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
}

fn checkpointKeyPrefix(allocator: std.mem.Allocator, log_id: []const u8) ![]u8 {
    const log_hash = append_log.hashBytes(log_id);
    var hex: [append_log.HASH_LEN * 2]u8 = undefined;
    _ = append_log.hashToHex(log_hash, &hex);
    return std.fmt.allocPrint(allocator, "{s}{s}:", .{ CHECKPOINT_PREFIX, hex[0..] });
}

fn checkpointKey(allocator: std.mem.Allocator, log_id: []const u8, record_hash: checkpoint.Hash) ![]u8 {
    const prefix = try checkpointKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    var hex: [checkpoint.HASH_LEN * 2]u8 = undefined;
    _ = append_log.hashToHex(record_hash, &hex);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, hex[0..] });
}

fn witnessKeyPrefix(allocator: std.mem.Allocator, log_id: []const u8, checkpoint_hash: checkpoint.Hash) ![]u8 {
    const log_hash = append_log.hashBytes(log_id);
    var log_hex: [append_log.HASH_LEN * 2]u8 = undefined;
    _ = append_log.hashToHex(log_hash, &log_hex);
    var cp_hex: [checkpoint.HASH_LEN * 2]u8 = undefined;
    _ = append_log.hashToHex(checkpoint_hash, &cp_hex);
    return std.fmt.allocPrint(allocator, "{s}{s}:{s}:", .{ WITNESS_PREFIX, log_hex[0..], cp_hex[0..] });
}

fn witnessKey(
    allocator: std.mem.Allocator,
    log_id: []const u8,
    checkpoint_hash: checkpoint.Hash,
    witness_identity: []const u8,
) ![]u8 {
    const prefix = try witnessKeyPrefix(allocator, log_id, checkpoint_hash);
    defer allocator.free(prefix);

    const identity_hash = checkpoint.hashBytes(witness_identity);
    var identity_hex: [checkpoint.HASH_LEN * 2]u8 = undefined;
    _ = append_log.hashToHex(identity_hash, &identity_hex);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, identity_hex[0..] });
}

fn storeWitnessCanonical(ctx: *Ctx, log_id: []const u8, record: witness.WitnessRecord, canonical: []const u8) !bool {
    const key = try witnessKey(ctx.allocator, log_id, record.checkpoint_hash, record.witness_identity);
    defer ctx.allocator.free(key);

    if (try ctx.store.getValueDupe(key, ctx.allocator)) |existing| {
        defer ctx.allocator.free(existing);
        if (std.mem.eql(u8, existing, canonical)) return false;
        return error.WormViolation;
    }

    ctx.setDurableWormWithTimestamp(key, canonical, record.observed_at_ms) catch |err| switch (err) {
        error.WormViolation => return error.WormViolation,
        else => return error.WitnessStoreFailed,
    };
    return true;
}

fn isWitnessOption(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "sk=") or
        std.mem.startsWith(u8, arg, "sig=") or
        std.mem.startsWith(u8, arg, "observed_at_ms=") or
        std.mem.startsWith(u8, arg, "ext=");
}

fn witnessJson(
    allocator: std.mem.Allocator,
    record: witness.WitnessRecord,
    record_hash: witness.Hash,
    canonical: []const u8,
) ![]u8 {
    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(allocator);
    try appendWitnessJsonObject(&json, allocator, record, record_hash, canonical);
    return json.toOwnedSlice(allocator);
}

fn appendWitnessJsonObject(
    json: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    record: witness.WitnessRecord,
    record_hash: witness.Hash,
    canonical: []const u8,
) !void {
    try json.appendSlice(allocator, "{\"log_id\":");
    try appendJsonString(json, allocator, record.log_id);
    try json.appendSlice(allocator, ",\"from_seq\":");
    try appendU64(json, allocator, record.from_seq);
    try json.appendSlice(allocator, ",\"to_seq\":");
    try appendU64(json, allocator, record.to_seq);
    try json.appendSlice(allocator, ",\"accumulator_kind\":\"");
    try json.appendSlice(allocator, switch (record.accumulator_kind) {
        .opaque_root => "opaque_root",
        .merkle_sha256_v1 => "merkle_sha256_v1",
        .mmr_sha256_v1 => "mmr_sha256_v1",
    });
    try json.appendSlice(allocator, "\",\"accumulator_root\":\"");
    try appendHashHex(json, allocator, record.accumulator_root);
    try json.appendSlice(allocator, "\",\"checkpoint_hash\":\"");
    try appendHashHex(json, allocator, record.checkpoint_hash);
    try json.appendSlice(allocator, "\",\"witness_identity\":\"");
    try appendHexBytes(json, allocator, record.witness_identity);
    try json.appendSlice(allocator, "\",\"signature\":\"");
    try appendHexBytes(json, allocator, record.signature[0..]);
    try json.appendSlice(allocator, "\",\"observed_at_ms\":");
    try appendU64(json, allocator, record.observed_at_ms);
    try json.appendSlice(allocator, ",\"extension_hex\":\"");
    try appendHexBytes(json, allocator, record.extension_bytes);
    try json.appendSlice(allocator, "\",\"witness_record_hash\":\"");
    try appendHashHex(json, allocator, record_hash);
    try json.appendSlice(allocator, "\",\"canonical_record_hex\":\"");
    try appendHexBytes(json, allocator, canonical);
    try json.appendSlice(allocator, "\"}");
}

fn parseHexBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    for (out, 0..) |*byte, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
    return out;
}

fn parseHashHex(hex: []const u8) !append_log.Hash {
    if (hex.len != append_log.HASH_LEN * 2) return error.InvalidHashHex;
    var out: append_log.Hash = undefined;
    for (&out, 0..) |*byte, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
    return out;
}

fn parsePublicKeyHex(hex: []const u8) !checkpoint.PublicKey {
    if (hex.len != checkpoint.PUBLIC_KEY_LEN * 2) return error.InvalidPublicKeyHex;
    var out: checkpoint.PublicKey = undefined;
    try parseFixedHex(hex, out[0..]);
    return out;
}

fn parseSignatureHex(hex: []const u8) !checkpoint.Signature {
    if (hex.len != checkpoint.SIGNATURE_LEN * 2) return error.InvalidSignatureHex;
    var out: checkpoint.Signature = undefined;
    try parseFixedHex(hex, out[0..]);
    return out;
}

fn parseFixedHex(hex: []const u8, out: []u8) !void {
    if (hex.len != out.len * 2) return error.InvalidHex;
    for (out, 0..) |*byte, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHashHex,
    };
}

fn appendHashHex(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, hash: append_log.Hash) !void {
    try appendHexBytes(list, allocator, hash[0..]);
}

fn appendHexBytes(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    for (bytes) |byte| {
        try list.append(allocator, alphabet[byte >> 4]);
        try list.append(allocator, alphabet[byte & 0x0f]);
    }
}

fn appendJsonString(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try list.append(allocator, '"');
    for (bytes) |byte| {
        switch (byte) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...0x1f => {
                try list.appendSlice(allocator, "\\u00");
                const alphabet = "0123456789abcdef";
                try list.append(allocator, alphabet[byte >> 4]);
                try list.append(allocator, alphabet[byte & 0x0f]);
            },
            else => try list.append(allocator, byte),
        }
    }
    try list.append(allocator, '"');
}

fn appendU64(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: u64) !void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(allocator, s);
}

fn appendUsize(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, n: usize) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(allocator, s);
}

fn runProc(store: *Store, func: *const fn (*Ctx) anyerror!Response, args: []const []const u8, allocator: std.mem.Allocator) !Response {
    var ctx = Ctx.init(store, args, allocator, null, null, null, null);
    defer ctx.deinit();
    return try func(&ctx);
}

fn extractJsonStringField(allocator: std.mem.Allocator, json: []const u8, field: []const u8) ![]const u8 {
    const needle = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{field});
    defer allocator.free(needle);
    const start = std.mem.indexOf(u8, json, needle) orelse return error.FieldNotFound;
    const value_start = start + needle.len;
    const rel_end = std.mem.indexOfScalar(u8, json[value_start..], '"') orelse return error.FieldNotFound;
    return try allocator.dupe(u8, json[value_start .. value_start + rel_end]);
}

test "append_log procedures append and verify WORM chain" {
    const testing = std.testing;

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const hash_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const appended = try runProc(&store, appendExecute, &.{ "audit-log", "payload-one", "ts=100", hash_hex }, allocator);
    const appended_value = appended.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, appended_value, 1, "\"seq\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, appended_value, 1, "\"ingest_time_ms\":100"));
    try testing.expect(std.mem.containsAtLeast(u8, appended_value, 1, "\"payload_hash\""));

    const verified = try runProc(&store, verifyExecute, &.{"audit-log"}, allocator);
    const verified_value = verified.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, verified_value, 1, "\"count\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, verified_value, 1, "\"last_seq\":1"));
}

test "append_log append rejects malformed attachment hash" {
    const testing = std.testing;

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const response = try runProc(&store, appendExecute, &.{ "audit-log", "payload-one", "not-hex" }, allocator);
    try testing.expectEqualStrings("append_log_append: attachment hash must be 64 hex chars", response.err);
}

test "append_log MMR proof procedure returns verifier-friendly proof" {
    const testing = std.testing;

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try runProc(&store, appendExecute, &.{ "audit-log", "payload-one", "ts=100" }, allocator);
    _ = try runProc(&store, appendExecute, &.{ "audit-log", "payload-two", "ts=101" }, allocator);
    const response = try runProc(&store, mmrProofExecute, &.{ "audit-log", "2" }, allocator);
    const value = response.value.?;

    try testing.expect(std.mem.containsAtLeast(u8, value, 1, "\"seq\":2"));
    try testing.expect(std.mem.containsAtLeast(u8, value, 1, "\"leaf_index\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, value, 1, "\"root\""));
    try testing.expect(std.mem.containsAtLeast(u8, value, 1, "\"record_hash\""));
    try testing.expect(std.mem.containsAtLeast(u8, value, 1, "\"proof_hex\""));
}

test "append_log MMR verify procedure accepts generated proof" {
    const testing = std.testing;

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try runProc(&store, appendExecute, &.{ "audit-log", "payload-one", "ts=100" }, allocator);
    _ = try runProc(&store, appendExecute, &.{ "audit-log", "payload-two", "ts=101" }, allocator);
    var proof_data = try buildMmrProof(allocator, &store, "audit-log", 2);
    defer proof_data.deinit(allocator);

    var root_hex: std.ArrayListUnmanaged(u8) = .empty;
    try appendHashHex(&root_hex, allocator, proof_data.root);
    const root = try root_hex.toOwnedSlice(allocator);

    var record_hash_hex: std.ArrayListUnmanaged(u8) = .empty;
    try appendHashHex(&record_hash_hex, allocator, proof_data.record_hash);
    const record_hash = try record_hash_hex.toOwnedSlice(allocator);

    var proof_hex_buf: std.ArrayListUnmanaged(u8) = .empty;
    try appendHexBytes(&proof_hex_buf, allocator, proof_data.proof_bytes);
    const proof_hex = try proof_hex_buf.toOwnedSlice(allocator);

    const response = try runProc(&store, mmrVerifyExecute, &.{ record_hash, root, proof_hex }, allocator);
    try testing.expectEqualStrings("{\"valid\":true}", response.value.?);
}

test "append_log checkpoint, bundle, and proof verify procedures round trip" {
    const testing = std.testing;

    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const public_key_hex = "2d6f7455d97b4a3a10d7293909d1a4f2058cb9a370e43fa8154bb280db839083";
    const secret_key_hex = "8052030376d47112be7f73ed7a019293dd12ad910b654455798b4667d73de1662d6f7455d97b4a3a10d7293909d1a4f2058cb9a370e43fa8154bb280db839083";
    const signing_arg = try std.fmt.allocPrint(allocator, "sk={s}", .{secret_key_hex});

    _ = try runProc(&store, appendExecute, &.{ "audit-log", "payload-one", "ts=100" }, allocator);
    _ = try runProc(&store, appendExecute, &.{ "audit-log", "payload-two", "ts=101" }, allocator);

    const checkpoint_response = try runProc(&store, checkpointExecute, &.{
        "audit-log",
        "1",
        "2",
        public_key_hex,
        signing_arg,
        "created_at_ms=200",
        "ingested_at_ms=201",
        "ext=6669656c64",
    }, allocator);
    const checkpoint_value = checkpoint_response.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, checkpoint_value, 1, "\"from_seq\":1"));
    try testing.expect(std.mem.containsAtLeast(u8, checkpoint_value, 1, "\"to_seq\":2"));
    try testing.expect(std.mem.containsAtLeast(u8, checkpoint_value, 1, "\"accumulator_kind\":\"mmr_sha256_v1\""));
    const checkpoint_hash = try extractJsonStringField(allocator, checkpoint_value, "checkpoint_hash");

    const witness_response = try runProc(&store, witnessExecute, &.{
        "audit-log",
        checkpoint_hash,
        public_key_hex,
        signing_arg,
        "observed_at_ms=300",
        "ext=7769746e657373",
    }, allocator);
    const witness_value = witness_response.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, witness_value, 1, "\"witness_identity\""));
    try testing.expect(std.mem.containsAtLeast(u8, witness_value, 1, "\"observed_at_ms\":300"));
    const canonical_witness = try extractJsonStringField(allocator, witness_value, "canonical_record_hex");

    const imported_witness = try runProc(&store, witnessImportExecute, &.{ "audit-log", checkpoint_hash, canonical_witness }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, imported_witness.value.?, 1, "\"witness_record_hash\""));

    const witness_verified = try runProc(&store, witnessVerifyExecute, &.{ "audit-log", checkpoint_hash, public_key_hex }, allocator);
    try testing.expect(std.mem.containsAtLeast(u8, witness_verified.value.?, 1, "\"valid\":true"));

    const bundle_response = try runProc(&store, proofBundleExecute, &.{ "audit-log", "2", "2", checkpoint_hash }, allocator);
    const bundle_value = bundle_response.value.?;
    try testing.expect(std.mem.containsAtLeast(u8, bundle_value, 1, "\"kind\":\"single_event\""));
    try testing.expect(std.mem.containsAtLeast(u8, bundle_value, 1, "\"canonical_record_hex\""));
    try testing.expect(std.mem.containsAtLeast(u8, bundle_value, 1, "\"proof_hex\""));
    const record_hash = try extractJsonStringField(allocator, bundle_value, "record_hash");
    const proof_hex = try extractJsonStringField(allocator, bundle_value, "proof_hex");

    const verified = try runProc(&store, proofVerifyExecute, &.{ "audit-log", "2", record_hash, checkpoint_hash, proof_hex }, allocator);
    try testing.expectEqualStrings("{\"valid\":true}", verified.value.?);
}
