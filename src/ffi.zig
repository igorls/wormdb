//! WormDB embedding FFI — a small C ABI over the engine for native apps
//! (iOS/Swift, Android/JNI, or any C caller). Single-node, in-process: no socket
//! server, no clustering. This is Path A from meshguard#102 — the basic engine
//! (KV + WAL + snapshot) embedded directly, with std.crypto (no libsodium).
//!
//! Build: `zig build` produces zig-out/lib/libwormdb_ffi.{dylib,so,a}.
//! Header: ffi/wormdb.h.
//!
//! Memory: values returned by wormdb_get, wormdb_exec, and
//! wormdb_proof_build_mmr_bundle are owned by the library and must be released
//! with wormdb_free. Scan callback key/value pointers are borrowed and valid
//! only until the callback returns. All other buffers are caller-owned.
//!
//! Threading: the store is internally sharded with per-shard locks, so calls
//! from multiple threads are safe. A single Db handle may be shared freely.

const std = @import("std");
const wormdb = @import("wormdb");

const Store = wormdb.storage.Store;
const PersistenceMode = wormdb.core.config.PersistenceMode;
const proof = wormdb.proof;
const append_log = proof.append_log;
const checkpoint = proof.checkpoint;
const mmr = proof.mmr;
const Ctx = wormdb.procedures.context.Ctx;
const registry = wormdb.procedures.registry;

// libc malloc/free — so values handed across the boundary can be released by
// the caller (wormdb_free, or plain free()) without allocator bookkeeping.
const gpa = std.heap.c_allocator;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Opaque handle. Owns the store and the path strings the store's config borrows.
pub const Db = struct {
    store: Store,
    wal_path: []u8,
    snapshot_path: []u8,
};

// ─── Result / persistence codes (mirror ffi/wormdb.h) ───
const OK: c_int = 0;
const NOT_FOUND: c_int = 1;
const PROC_ERR: c_int = 2;
const ERR: c_int = -1;

const PERSIST_FULL: c_int = 0; // WAL on every write + snapshots (durable)
const PERSIST_SNAPSHOT: c_int = 1; // load/save only, no per-write IO
const PERSIST_NONE: c_int = 2; // pure in-memory

/// Stable receipt metadata exposed through the C ABI.
pub const EntryMeta = extern struct {
    timestamp_ms: u64,
    is_worm: c_int,
    value_len: usize,
    value_sha256: [32]u8,
};

pub const AppendReceipt = extern struct {
    seq: u64,
    ingest_time_ms: u64,
    prev_event_hash: [32]u8,
    payload_hash: [32]u8,
    event_hash: [32]u8,
    record_hash: [32]u8,
};

pub const AppendLogReport = extern struct {
    count: usize,
    last_seq: u64,
    head_hash: [32]u8,
};

pub const ProofBundleInfo = extern struct {
    kind: c_int,
    from_seq: u64,
    to_seq: u64,
    record_count: usize,
    checkpoint_count: usize,
    accumulator_kind: c_int,
    accumulator_root: [32]u8,
    checkpoint_hash: [32]u8,
};

pub const ExecArg = extern struct {
    ptr: [*]const u8,
    len: usize,
};

const ScanCallback = *const fn (
    ctx: ?*anyopaque,
    key: [*]const u8,
    key_len: usize,
    value: [*]const u8,
    value_len: usize,
    meta: *const EntryMeta,
) callconv(.c) c_int;

fn entryMetaFromScanResult(result: Store.ScanResult) EntryMeta {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.value, &digest, .{});
    return .{
        .timestamp_ms = result.timestamp,
        .is_worm = if (result.is_worm) 1 else 0,
        .value_len = result.value.len,
        .value_sha256 = digest,
    };
}

fn receiptFromAppendResult(result: append_log.AppendResult) AppendReceipt {
    return .{
        .seq = result.seq,
        .ingest_time_ms = result.ingest_time_ms,
        .prev_event_hash = result.prev_event_hash,
        .payload_hash = result.payload_hash,
        .event_hash = result.event_hash,
        .record_hash = checkpoint.hashBytes(result.envelope),
    };
}

fn reportFromVerifyReport(report: append_log.VerifyReport) AppendLogReport {
    return .{
        .count = report.count,
        .last_seq = report.last_seq,
        .head_hash = report.head_hash,
    };
}

fn proofBundleInfoFromCore(info: proof.BundleInfo) ProofBundleInfo {
    return .{
        .kind = @intFromEnum(info.kind),
        .from_seq = info.from_seq,
        .to_seq = info.to_seq,
        .record_count = info.record_count,
        .checkpoint_count = info.checkpoint_count,
        .accumulator_kind = @intFromEnum(info.accumulator_kind),
        .accumulator_root = info.accumulator_root,
        .checkpoint_hash = info.checkpoint_hash,
    };
}

fn optionalBytes(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return null;
    return p[0..len];
}

fn attachmentHashSlice(ptr: ?[*]const u8, count: usize) ?[]const append_log.Hash {
    if (count == 0) return &.{};
    if (count > std.math.maxInt(usize) / append_log.HASH_LEN) return null;
    const p = ptr orelse return null;
    const hashes: [*]const append_log.Hash = @ptrCast(p);
    return hashes[0..count];
}

fn clearOut(out_val: *?[*]u8, out_len: *usize) void {
    out_val.* = null;
    out_len.* = 0;
}

fn putOwnedOut(bytes: []const u8, out_val: *?[*]u8, out_len: *usize) c_int {
    const copy = gpa.dupe(u8, bytes) catch return ERR;
    out_val.* = copy.ptr;
    out_len.* = copy.len;
    return OK;
}

fn putProcErr(bytes: []const u8, out_val: *?[*]u8, out_len: *usize) c_int {
    return if (putOwnedOut(bytes, out_val, out_len) == OK) PROC_ERR else ERR;
}

/// Open (or create) a database rooted at `dir`. WAL + snapshot live under it.
/// `persistence` is one of WORMDB_PERSIST_*. Returns null on failure.
export fn wormdb_open(dir_ptr: [*:0]const u8, persistence: c_int) ?*Db {
    const dir = std.mem.span(dir_ptr);

    // Ensure the data directory exists (app sandbox dir on mobile).
    std.Io.Dir.cwd().createDirPath(io(), dir) catch {};

    const wal_path = std.fmt.allocPrint(gpa, "{s}/wormdb.wal", .{dir}) catch return null;
    errdefer gpa.free(wal_path);
    const snapshot_path = std.fmt.allocPrint(gpa, "{s}/wormdb.snapshot", .{dir}) catch return null;
    errdefer gpa.free(snapshot_path);

    const mode: PersistenceMode = switch (persistence) {
        PERSIST_FULL => .full,
        PERSIST_SNAPSHOT => .snapshot,
        else => .none,
    };

    const db = gpa.create(Db) catch return null;
    db.* = .{
        .store = Store.init(gpa, .{
            .wal_path = wal_path,
            .snapshot_path = snapshot_path,
            .sync_writes = true,
            .persistence = mode,
        }) catch {
            gpa.destroy(db);
            gpa.free(wal_path);
            gpa.free(snapshot_path);
            return null;
        },
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
    };

    // Background WAL writer must start only after the store is at its final
    // (heap, non-moving) address — db is heap-allocated, so this is safe.
    if (mode == .full) db.store.startBackgroundTasks() catch {};

    return db;
}

/// Open (or create) a database rooted at `dir` with synchronous per-write WAL sync.
/// Does not start the background writer thread, so every write is flushed and fsynced
/// directly before returning. Returns null on failure.
export fn wormdb_open_sync(dir_ptr: [*:0]const u8) ?*Db {
    const dir = std.mem.span(dir_ptr);

    // Ensure the data directory exists (app sandbox dir on mobile).
    std.Io.Dir.cwd().createDirPath(io(), dir) catch {};

    const wal_path = std.fmt.allocPrint(gpa, "{s}/wormdb.wal", .{dir}) catch return null;
    errdefer gpa.free(wal_path);
    const snapshot_path = std.fmt.allocPrint(gpa, "{s}/wormdb.snapshot", .{dir}) catch return null;
    errdefer gpa.free(snapshot_path);

    const db = gpa.create(Db) catch return null;
    db.* = .{
        .store = Store.init(gpa, .{
            .wal_path = wal_path,
            .snapshot_path = snapshot_path,
            .sync_writes = true,
            .persistence = .full,
        }) catch {
            gpa.destroy(db);
            gpa.free(wal_path);
            gpa.free(snapshot_path);
            return null;
        },
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
    };

    // Intentionally do NOT call db.store.startBackgroundTasks().
    // writer_started remains false, so all writes execute synchronous writeAll + sync.

    return db;
}

/// Flush, close, and free a database handle. The handle is invalid afterwards.
export fn wormdb_close(db: *Db) void {
    db.store.deinit();
    gpa.free(db.wal_path);
    gpa.free(db.snapshot_path);
    gpa.destroy(db);
}

/// Set key → value (mutable; not WORM). Returns WORMDB_OK or WORMDB_ERR.
export fn wormdb_set(db: *Db, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) c_int {
    db.store.set(key[0..key_len], val[0..val_len], false) catch return ERR;
    return OK;
}

/// Set key → value as a WORM (write-once) entry. Overwriting a WORM key fails.
export fn wormdb_set_worm(db: *Db, key: [*]const u8, key_len: usize, val: [*]const u8, val_len: usize) c_int {
    db.store.set(key[0..key_len], val[0..val_len], true) catch return ERR;
    return OK;
}

/// Get key. On WORMDB_OK, *out_val/*out_len point to a library-owned buffer the
/// caller must release with wormdb_free. WORMDB_NOT_FOUND leaves them null/0.
export fn wormdb_get(db: *Db, key: [*]const u8, key_len: usize, out_val: *?[*]u8, out_len: *usize) c_int {
    const maybe = db.store.getValueDupe(key[0..key_len], gpa) catch return ERR;
    if (maybe) |v| {
        // Caller owns this buffer and releases it via wormdb_free, so handing
        // back a mutable pointer to the freshly-duped bytes is correct.
        out_val.* = @constCast(v.ptr);
        out_len.* = v.len;
        return OK;
    }
    out_val.* = null;
    out_len.* = 0;
    return NOT_FOUND;
}

/// Get entry receipt metadata. On WORMDB_OK, out_meta is populated with the
/// local ingest timestamp, WORM flag, value length, and SHA-256(value).
export fn wormdb_get_meta(db: *Db, key: [*]const u8, key_len: usize, out_meta: *EntryMeta) c_int {
    const maybe = db.store.getEntryMetadata(key[0..key_len]);
    if (maybe) |meta| {
        out_meta.* = .{
            .timestamp_ms = meta.timestamp,
            .is_worm = if (meta.is_worm) 1 else 0,
            .value_len = meta.value_len,
            .value_sha256 = meta.value_sha256,
        };
        return OK;
    }
    return NOT_FOUND;
}

/// Scan entries with keys matching prefix in lexicographic key order. `limit`
/// follows Store.scanPrefix semantics: 0 means no limit; otherwise the newest
/// lexicographic tail is returned. Callback key/value pointers and the metadata
/// pointer are borrowed and valid only until the callback returns. If callback
/// returns non-zero, scanning stops early and WORMDB_OK is returned.
export fn wormdb_scan_prefix(
    db: *Db,
    prefix: [*]const u8,
    prefix_len: usize,
    limit: usize,
    ctx: ?*anyopaque,
    callback: ?ScanCallback,
) c_int {
    const cb = callback orelse return ERR;
    const results = db.store.scanPrefix(prefix[0..prefix_len], limit, gpa) catch return ERR;
    defer {
        for (results) |result| {
            gpa.free(result.key);
            gpa.free(result.value);
        }
        gpa.free(results);
    }

    for (results) |result| {
        const meta = entryMetaFromScanResult(result);
        if (cb(ctx, result.key.ptr, result.key.len, result.value.ptr, result.value.len, &meta) != 0) {
            break;
        }
    }
    return OK;
}

/// Append a payload to a WORM append log. `attachment_hashes` is an optional
/// contiguous array of 32-byte hashes. `ingest_time_ms == 0` lets WormDB assign
/// the local receipt time. On success, `out_receipt` is populated when non-null.
export fn wormdb_append_log(
    db: *Db,
    log_id: [*]const u8,
    log_id_len: usize,
    payload: [*]const u8,
    payload_len: usize,
    attachment_hashes: ?[*]const u8,
    attachment_hash_count: usize,
    ingest_time_ms: u64,
    out_receipt: ?*AppendReceipt,
) c_int {
    const attachments = attachmentHashSlice(attachment_hashes, attachment_hash_count) orelse return ERR;
    var result = append_log.append(
        gpa,
        &db.store,
        log_id[0..log_id_len],
        payload[0..payload_len],
        attachments,
        .{ .ingest_time_ms = if (ingest_time_ms == 0) null else ingest_time_ms },
    ) catch return ERR;
    defer result.deinit(gpa);

    if (out_receipt) |receipt| receipt.* = receiptFromAppendResult(result);
    return OK;
}

/// Verify the stored WORM append-log chain for `log_id`.
export fn wormdb_append_log_verify(
    db: *Db,
    log_id: [*]const u8,
    log_id_len: usize,
    out_report: ?*AppendLogReport,
) c_int {
    const report = append_log.verifyStore(gpa, &db.store, log_id[0..log_id_len]) catch return ERR;
    if (out_report) |r| r.* = reportFromVerifyReport(report);
    return OK;
}

/// Build a self-contained encoded proof bundle for an append-log sequence range.
/// The bundle must be released with `wormdb_free`.
export fn wormdb_proof_build_mmr_bundle(
    db: *Db,
    log_id: [*]const u8,
    log_id_len: usize,
    from_seq: u64,
    to_seq: u64,
    public_key: ?[*]const u8,
    secret_key: ?[*]const u8,
    created_at_ms: u64,
    ingested_at_ms: u64,
    checkpoint_extension: ?[*]const u8,
    checkpoint_extension_len: usize,
    bundle_extension: ?[*]const u8,
    bundle_extension_len: usize,
    out_bundle: *?[*]u8,
    out_bundle_len: *usize,
    out_info: ?*ProofBundleInfo,
) c_int {
    out_bundle.* = null;
    out_bundle_len.* = 0;

    const pub_ptr = public_key orelse return ERR;
    const sec_ptr = secret_key orelse return ERR;
    const checkpoint_ext = optionalBytes(checkpoint_extension, checkpoint_extension_len) orelse return ERR;
    const bundle_ext = optionalBytes(bundle_extension, bundle_extension_len) orelse return ERR;

    var secret: [checkpoint.SIGNATURE_LEN]u8 = undefined;
    @memcpy(secret[0..], sec_ptr[0..checkpoint.SIGNATURE_LEN]);

    const built = proof.buildAppendLogMmrBundle(gpa, &db.store, .{
        .log_id = log_id[0..log_id_len],
        .from_seq = from_seq,
        .to_seq = to_seq,
        .creator_public_key = pub_ptr[0..checkpoint.PUBLIC_KEY_LEN],
        .creator_secret_key = &secret,
        .created_at_ms = if (created_at_ms == 0) null else created_at_ms,
        .ingested_at_ms = if (ingested_at_ms == 0) null else ingested_at_ms,
        .checkpoint_extension_bytes = checkpoint_ext,
        .bundle_extension_bytes = bundle_ext,
    }) catch return ERR;

    out_bundle.* = built.bytes.ptr;
    out_bundle_len.* = built.bytes.len;
    if (out_info) |info| info.* = proofBundleInfoFromCore(built.info);
    return OK;
}

/// Verify an encoded append-log MMR proof bundle without opening a database.
export fn wormdb_proof_verify_bundle(
    bundle: [*]const u8,
    bundle_len: usize,
    out_info: ?*ProofBundleInfo,
) c_int {
    const info = proof.verifyEncodedAppendLogMmrBundle(gpa, bundle[0..bundle_len]) catch return ERR;
    if (out_info) |out| out.* = proofBundleInfoFromCore(info);
    return OK;
}

/// Verify canonical MMR proof path bytes against a leaf hash and expected root.
/// `seq` is the append-log sequence, so the proof leaf index must be `seq - 1`.
export fn wormdb_mmr_proof_verify(
    proof_bytes: [*]const u8,
    proof_len: usize,
    seq: u64,
    leaf_hash: ?[*]const u8,
    expected_root: ?[*]const u8,
) c_int {
    if (seq == 0) return ERR;
    const leaf_ptr = leaf_hash orelse return ERR;
    const root_ptr = expected_root orelse return ERR;

    var leaf: checkpoint.Hash = undefined;
    var root: checkpoint.Hash = undefined;
    @memcpy(leaf[0..], leaf_ptr[0..checkpoint.HASH_LEN]);
    @memcpy(root[0..], root_ptr[0..checkpoint.HASH_LEN]);

    var decoded = mmr.decodeInclusionProof(gpa, proof_bytes[0..proof_len]) catch return ERR;
    defer decoded.deinit();
    if (decoded.leaf_index != seq - 1) return ERR;
    return if (mmr.verifyInclusion(decoded, leaf[0..], root)) OK else ERR;
}

/// Execute a stored procedure in-process. On WORMDB_OK with a value, or
/// WORMDB_PROC_ERR with an error string, out_val/out_len receive a
/// library-owned buffer released with wormdb_free. OK without a value leaves
/// out_val null and out_len 0.
export fn wormdb_exec(
    db: *Db,
    name: [*]const u8,
    name_len: usize,
    args: ?[*]const ExecArg,
    argc: usize,
    out_val: *?[*]u8,
    out_len: *usize,
) c_int {
    clearOut(out_val, out_len);
    if (argc > 0 and args == null) return ERR;

    const func = registry.lookup(name[0..name_len]) orelse
        return putProcErr("unknown procedure", out_val, out_len);

    const proc_args = gpa.alloc([]const u8, argc) catch return ERR;
    defer gpa.free(proc_args);
    if (args) |raw_args| {
        for (proc_args, 0..) |*slot, i| {
            const arg = raw_args[i];
            slot.* = arg.ptr[0..arg.len];
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var ctx = Ctx.init(&db.store, proc_args, arena.allocator(), null, null, null, null);
    defer ctx.deinit();

    const response = func(&ctx) catch return ERR;
    return switch (response) {
        .ok => OK,
        .value => |maybe| blk: {
            const bytes = maybe orelse break :blk OK;
            break :blk putOwnedOut(bytes, out_val, out_len);
        },
        .err => |msg| putProcErr(msg, out_val, out_len),
        .event => ERR,
    };
}

/// Delete key. Missing keys succeed; deleting a WORM key returns WORMDB_ERR.
export fn wormdb_delete(db: *Db, key: [*]const u8, key_len: usize) c_int {
    db.store.delete(key[0..key_len]) catch return ERR;
    return OK;
}

/// Release a buffer returned by wormdb_get, wormdb_exec, or proof builders.
export fn wormdb_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| gpa.free(p[0..len]);
}

/// Library version string (static, do not free).
export fn wormdb_version() [*:0]const u8 {
    return "wormdb-ffi 0.3";
}

test "ffi append-log proof bundle round trip" {
    const testing = std.testing;
    const Ed25519 = std.crypto.sign.Ed25519;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try wormdb.core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const zpath = try testing.allocator.dupeZ(u8, tmp_path);
    defer testing.allocator.free(zpath);

    const db = wormdb_open(zpath.ptr, PERSIST_NONE) orelse return error.OpenFailed;
    defer wormdb_close(db);

    const log_id = "ffi:proof";
    const first_payload = "alpha";
    const second_payload = "bravo";

    var first_receipt: AppendReceipt = undefined;
    try testing.expectEqual(OK, wormdb_append_log(
        db,
        log_id.ptr,
        log_id.len,
        first_payload.ptr,
        first_payload.len,
        null,
        0,
        1_800_000_001_000,
        &first_receipt,
    ));
    try testing.expectEqual(@as(u64, 1), first_receipt.seq);

    var second_receipt: AppendReceipt = undefined;
    try testing.expectEqual(OK, wormdb_append_log(
        db,
        log_id.ptr,
        log_id.len,
        second_payload.ptr,
        second_payload.len,
        null,
        0,
        1_800_000_002_000,
        &second_receipt,
    ));
    try testing.expectEqual(@as(u64, 2), second_receipt.seq);

    var report: AppendLogReport = undefined;
    try testing.expectEqual(OK, wormdb_append_log_verify(db, log_id.ptr, log_id.len, &report));
    try testing.expectEqual(@as(usize, 2), report.count);
    try testing.expectEqual(@as(u64, 2), report.last_seq);

    const kp = Ed25519.KeyPair.generate(io());
    const public_key = kp.public_key.toBytes();
    const secret_key = kp.secret_key.toBytes();

    var bundle_ptr: ?[*]u8 = null;
    var bundle_len: usize = 0;
    var build_info: ProofBundleInfo = undefined;
    try testing.expectEqual(OK, wormdb_proof_build_mmr_bundle(
        db,
        log_id.ptr,
        log_id.len,
        1,
        2,
        public_key[0..].ptr,
        secret_key[0..].ptr,
        1_800_000_003_000,
        1_800_000_003_123,
        null,
        0,
        null,
        0,
        &bundle_ptr,
        &bundle_len,
        &build_info,
    ));
    defer wormdb_free(bundle_ptr, bundle_len);
    try testing.expect(bundle_ptr != null);
    try testing.expect(bundle_len > 0);
    try testing.expectEqual(@as(c_int, @intFromEnum(proof.BundleKind.range)), build_info.kind);
    try testing.expectEqual(@as(c_int, @intFromEnum(checkpoint.AccumulatorKind.mmr_sha256_v1)), build_info.accumulator_kind);

    var verify_info: ProofBundleInfo = undefined;
    try testing.expectEqual(OK, wormdb_proof_verify_bundle(bundle_ptr.?, bundle_len, &verify_info));
    try testing.expectEqual(build_info.from_seq, verify_info.from_seq);
    try testing.expectEqual(build_info.to_seq, verify_info.to_seq);
    try testing.expectEqualSlices(u8, build_info.accumulator_root[0..], verify_info.accumulator_root[0..]);
    try testing.expectEqualSlices(u8, build_info.checkpoint_hash[0..], verify_info.checkpoint_hash[0..]);
}

test "ffi verifies canonical MMR proof bytes" {
    const testing = std.testing;

    const leaf_hash = checkpoint.hashBytes("record bytes");
    var acc = mmr.Accumulator.init(testing.allocator);
    defer acc.deinit();
    const root = try acc.append(leaf_hash[0..]);

    var proof_value = try acc.prove(0, testing.allocator);
    defer proof_value.deinit();

    const proof_bytes = try mmr.encodeInclusionProof(testing.allocator, proof_value);
    defer testing.allocator.free(proof_bytes);

    try testing.expectEqual(OK, wormdb_mmr_proof_verify(
        proof_bytes.ptr,
        proof_bytes.len,
        1,
        leaf_hash[0..].ptr,
        root[0..].ptr,
    ));
    try testing.expectEqual(ERR, wormdb_mmr_proof_verify(
        proof_bytes.ptr,
        proof_bytes.len,
        2,
        leaf_hash[0..].ptr,
        root[0..].ptr,
    ));
}

test "ffi exec runs stored procedures and returns owned values" {
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try wormdb.core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const zpath = try testing.allocator.dupeZ(u8, tmp_path);
    defer testing.allocator.free(zpath);

    const db = wormdb_open(zpath.ptr, PERSIST_NONE) orelse return error.OpenFailed;
    defer wormdb_close(db);

    const append_name = "append_log_append";
    const append_args = [_]ExecArg{
        .{ .ptr = "ffi:exec".ptr, .len = "ffi:exec".len },
        .{ .ptr = "payload-one".ptr, .len = "payload-one".len },
        .{ .ptr = "ts=100".ptr, .len = "ts=100".len },
    };
    var out: ?[*]u8 = null;
    var out_len: usize = 0;
    try testing.expectEqual(OK, wormdb_exec(db, append_name.ptr, append_name.len, &append_args, append_args.len, &out, &out_len));
    defer wormdb_free(out, out_len);
    try testing.expect(out != null);
    try testing.expect(std.mem.containsAtLeast(u8, out.?[0..out_len], 1, "\"seq\":1"));

    const verify_name = "append_log_verify";
    const verify_args = [_]ExecArg{.{ .ptr = "ffi:exec".ptr, .len = "ffi:exec".len }};
    var verify_out: ?[*]u8 = null;
    var verify_len: usize = 0;
    try testing.expectEqual(OK, wormdb_exec(db, verify_name.ptr, verify_name.len, &verify_args, verify_args.len, &verify_out, &verify_len));
    defer wormdb_free(verify_out, verify_len);
    try testing.expect(std.mem.containsAtLeast(u8, verify_out.?[0..verify_len], 1, "\"count\":1"));

    const missing_name = "does_not_exist";
    var err_out: ?[*]u8 = null;
    var err_len: usize = 0;
    try testing.expectEqual(PROC_ERR, wormdb_exec(db, missing_name.ptr, missing_name.len, null, 0, &err_out, &err_len));
    defer wormdb_free(err_out, err_len);
    try testing.expectEqualStrings("unknown procedure", err_out.?[0..err_len]);
}

test "ffi open_sync provides immediate synchronous WAL durability" {
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try wormdb.core.compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const zpath = try testing.allocator.dupeZ(u8, tmp_path);
    defer testing.allocator.free(zpath);

    const db = wormdb_open_sync(zpath.ptr) orelse return error.OpenFailed;
    // Writer thread must NOT be started
    try testing.expect(!db.store.wal.?.writer_started);

    const k = "sync-test-key";
    const v = "sync-test-val";
    try testing.expectEqual(OK, wormdb_set(db, k.ptr, k.len, v.ptr, v.len));

    // File should immediately have content before close
    const wal_size = try db.store.wal.?.size();
    try testing.expect(wal_size > 0);

    wormdb_close(db);

    // Reopen to verify WAL replay
    const db2 = wormdb_open_sync(zpath.ptr) orelse return error.OpenFailed;
    defer wormdb_close(db2);

    var out_val: ?[*]u8 = null;
    var out_len: usize = 0;
    try testing.expectEqual(OK, wormdb_get(db2, k.ptr, k.len, &out_val, &out_len));
    defer wormdb_free(out_val, out_len);
    try testing.expect(out_val != null);
    try testing.expectEqualStrings(v, out_val.?[0..out_len]);
}

