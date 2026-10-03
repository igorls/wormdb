//! Generic verifiable append-log primitive for WORM namespaces.
//!
//! Each event is stored under a write-once key whose final 8 bytes are the
//! big-endian sequence number. The stored value is a canonical binary envelope.
//! Event hashes are SHA-256 over the canonical envelope preimage, excluding the
//! trailing `event_hash` field.

const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const Config = @import("../core/config.zig").Config;
const compat = @import("../core/compat.zig");
const mmr = @import("mmr.zig");

pub const HASH_LEN: usize = 32;
pub const Hash = [HASH_LEN]u8;

pub const ENVELOPE_MAGIC: []const u8 = "WDBALOG1";
pub const ENVELOPE_VERSION: u16 = 1;
pub const STORAGE_PREFIX: []const u8 = "proof:append-log:v1:";
pub const EVENT_SUFFIX: []const u8 = ":event:";
pub const ACCUMULATOR_STATE_PREFIX: []const u8 = "proof:append-log-mmr-state:v1:";
pub const ACCUMULATOR_STATE_SUFFIX: []const u8 = ":state:";
pub const ACCUMULATOR_STATE_MAGIC: []const u8 = "WDBMMRS1";
pub const ACCUMULATOR_STATE_VERSION: u16 = 1;
pub const ZERO_HASH: Hash = [_]u8{0} ** HASH_LEN;

const LOG_ID_MAX: usize = std.math.maxInt(u32);
const PAYLOAD_MAX: usize = std.math.maxInt(u32);
const ATTACHMENT_MAX: usize = std.math.maxInt(u32);

pub const AppendOptions = struct {
    /// Local database receipt time in UNIX epoch milliseconds. When omitted,
    /// WormDB assigns `nowMs()` and stores the same timestamp on the WORM entry.
    ingest_time_ms: ?u64 = null,
};

pub const EventInput = struct {
    log_id: []const u8,
    seq: u64,
    prev_event_hash: Hash,
    ingest_time_ms: u64,
    payload: []const u8,
    attachment_hashes: []const Hash = &.{},
};

pub const EventView = struct {
    bytes: []const u8,
    log_id: []const u8,
    seq: u64,
    prev_event_hash: Hash,
    ingest_time_ms: u64,
    payload_hash: Hash,
    attachment_hash_bytes: []const u8,
    attachment_count: u32,
    payload: []const u8,
    event_hash: Hash,
};

pub const AppendResult = struct {
    key: []u8,
    envelope: []u8,
    seq: u64,
    prev_event_hash: Hash,
    payload_hash: Hash,
    event_hash: Hash,
    accumulator_root: Hash,
    accumulator_leaf_count: u64,
    ingest_time_ms: u64,

    pub fn deinit(self: *AppendResult, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.envelope);
        self.* = undefined;
    }
};

pub const VerifyReport = struct {
    count: usize,
    last_seq: u64,
    head_hash: Hash,
};

pub const AccumulatorState = struct {
    peaks: []mmr.Peak,
    last_seq: u64,
    last_ingest_time_ms: u64,
    head_hash: Hash,
    accumulator_root: Hash,

    pub fn deinit(self: *AccumulatorState, allocator: std.mem.Allocator) void {
        allocator.free(self.peaks);
        self.* = undefined;
    }
};

/// Append a payload to a named WORM log.
///
/// This helper loads the latest durable MMR state to find the tail, falling
/// back to a full WORM-chain scan/rebuild when state is missing or stale. It
/// then writes the next event under a WORM sequence key and persists a WORM
/// accumulator-state record for that sequence. A concurrent append that wins
/// the same sequence causes `error.SequenceReuse`; callers can retry.
pub fn append(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
    payload: []const u8,
    attachment_hashes: []const Hash,
    options: AppendOptions,
) !AppendResult {
    var tail = try loadOrRebuildAccumulatorState(allocator, store, log_id);
    defer tail.deinit(allocator);
    if (tail.last_seq == std.math.maxInt(u64)) return error.SequenceOverflow;

    const seq = tail.last_seq + 1;
    const ingest_time_ms: u64 = options.ingest_time_ms orelse @intCast(compat.nowMs());

    const envelope = try encodeEnvelope(allocator, .{
        .log_id = log_id,
        .seq = seq,
        .prev_event_hash = tail.head_hash,
        .ingest_time_ms = ingest_time_ms,
        .payload = payload,
        .attachment_hashes = attachment_hashes,
    });
    errdefer allocator.free(envelope);

    const view = try decodeEnvelope(envelope);
    try verifyEnvelope(log_id, view);

    const key = try eventKey(allocator, log_id, seq);
    errdefer allocator.free(key);

    store.setWithTimestamp(key, envelope, true, ingest_time_ms) catch |err| switch (err) {
        error.WormViolation => return error.SequenceReuse,
        else => return err,
    };

    const record_hash = hashBytes(envelope);
    var next_state = try advanceAccumulatorState(allocator, tail, record_hash, view.event_hash, ingest_time_ms);
    defer next_state.deinit(allocator);
    persistAccumulatorState(allocator, store, log_id, next_state) catch |err| {
        std.log.warn("append-log MMR state persist failed for '{s}' seq={d}: {s}", .{
            log_id,
            next_state.last_seq,
            @errorName(err),
        });
    };

    return .{
        .key = key,
        .envelope = envelope,
        .seq = seq,
        .prev_event_hash = view.prev_event_hash,
        .payload_hash = view.payload_hash,
        .event_hash = view.event_hash,
        .accumulator_root = next_state.accumulator_root,
        .accumulator_leaf_count = next_state.last_seq,
        .ingest_time_ms = ingest_time_ms,
    };
}

/// Verify every event currently stored for `log_id`.
pub fn verifyStore(allocator: std.mem.Allocator, store: *Store, log_id: []const u8) !VerifyReport {
    const prefix = try eventKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    const results = try store.scanPrefix(prefix, 0, allocator);
    defer {
        for (results) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(results);
    }

    var verifier = Verifier.init(log_id);
    for (results) |r| {
        if (!r.is_worm) return error.NonWormEvent;
        const key_seq = try seqFromEventKey(prefix, r.key);
        const view = try decodeEnvelope(r.value);
        if (view.seq != key_seq) return error.SequenceKeyMismatch;
        if (view.ingest_time_ms != r.timestamp) return error.ReceiptTimestampMismatch;
        try verifier.accept(view);
    }
    return verifier.report();
}

/// Verify a caller-supplied ordered sequence of canonical event envelopes.
pub fn verifyEnvelopes(log_id: []const u8, envelopes: []const []const u8) !VerifyReport {
    var verifier = Verifier.init(log_id);
    for (envelopes) |envelope| {
        try verifier.accept(try decodeEnvelope(envelope));
    }
    return verifier.report();
}

pub fn encodeEnvelope(allocator: std.mem.Allocator, input: EventInput) ![]u8 {
    if (input.log_id.len > LOG_ID_MAX) return error.EnvelopeTooLarge;
    if (input.payload.len > PAYLOAD_MAX) return error.EnvelopeTooLarge;
    if (input.attachment_hashes.len > ATTACHMENT_MAX) return error.EnvelopeTooLarge;

    const attachment_bytes_len = std.math.mul(usize, input.attachment_hashes.len, HASH_LEN) catch {
        return error.EnvelopeTooLarge;
    };
    var preimage_len: usize = 0;
    try addEnvelopeLen(&preimage_len, ENVELOPE_MAGIC.len);
    try addEnvelopeLen(&preimage_len, 2);
    try addEnvelopeLen(&preimage_len, 4);
    try addEnvelopeLen(&preimage_len, input.log_id.len);
    try addEnvelopeLen(&preimage_len, 8);
    try addEnvelopeLen(&preimage_len, HASH_LEN);
    try addEnvelopeLen(&preimage_len, 8);
    try addEnvelopeLen(&preimage_len, HASH_LEN);
    try addEnvelopeLen(&preimage_len, 4);
    try addEnvelopeLen(&preimage_len, attachment_bytes_len);
    try addEnvelopeLen(&preimage_len, 4);
    try addEnvelopeLen(&preimage_len, input.payload.len);
    const total_len = std.math.add(usize, preimage_len, HASH_LEN) catch return error.EnvelopeTooLarge;

    var buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    const payload_hash = hashBytes(input.payload);

    var pos: usize = 0;
    writeBytes(buf, &pos, ENVELOPE_MAGIC);
    writeU16(buf, &pos, ENVELOPE_VERSION);
    writeU32(buf, &pos, @intCast(input.log_id.len));
    writeBytes(buf, &pos, input.log_id);
    writeU64(buf, &pos, input.seq);
    writeHash(buf, &pos, input.prev_event_hash);
    writeU64(buf, &pos, input.ingest_time_ms);
    writeHash(buf, &pos, payload_hash);
    writeU32(buf, &pos, @intCast(input.attachment_hashes.len));
    for (input.attachment_hashes) |attachment_hash| writeHash(buf, &pos, attachment_hash);
    writeU32(buf, &pos, @intCast(input.payload.len));
    writeBytes(buf, &pos, input.payload);

    std.debug.assert(pos == preimage_len);
    const event_hash = hashBytes(buf[0..preimage_len]);
    writeHash(buf, &pos, event_hash);
    std.debug.assert(pos == total_len);

    return buf;
}

pub fn decodeEnvelope(bytes: []const u8) !EventView {
    var pos: usize = 0;

    const magic = try readBytes(bytes, &pos, ENVELOPE_MAGIC.len);
    if (!std.mem.eql(u8, magic, ENVELOPE_MAGIC)) return error.InvalidEnvelope;

    const version = try readU16(bytes, &pos);
    if (version != ENVELOPE_VERSION) return error.UnsupportedEnvelopeVersion;

    const log_id_len = try readU32(bytes, &pos);
    const log_id = try readBytes(bytes, &pos, @intCast(log_id_len));
    const seq = try readU64(bytes, &pos);
    const prev_event_hash = try readHash(bytes, &pos);
    const ingest_time_ms = try readU64(bytes, &pos);
    const payload_hash = try readHash(bytes, &pos);
    const attachment_count = try readU32(bytes, &pos);
    const attachment_hash_bytes = try readBytes(bytes, &pos, try attachmentHashBytesLen(attachment_count));
    const payload_len = try readU32(bytes, &pos);
    const payload = try readBytes(bytes, &pos, payload_len);
    const event_hash = try readHash(bytes, &pos);

    if (pos != bytes.len) return error.InvalidEnvelope;

    return .{
        .bytes = bytes,
        .log_id = log_id,
        .seq = seq,
        .prev_event_hash = prev_event_hash,
        .ingest_time_ms = ingest_time_ms,
        .payload_hash = payload_hash,
        .attachment_hash_bytes = attachment_hash_bytes,
        .attachment_count = attachment_count,
        .payload = payload,
        .event_hash = event_hash,
    };
}

pub fn verifyEnvelope(expected_log_id: []const u8, view: EventView) !void {
    if (!std.mem.eql(u8, view.log_id, expected_log_id)) return error.LogIdMismatch;

    const payload_hash = hashBytes(view.payload);
    if (!hashEql(payload_hash, view.payload_hash)) return error.PayloadHashMismatch;

    const computed_event_hash = try hashEnvelopePreimage(view.bytes);
    if (!hashEql(computed_event_hash, view.event_hash)) return error.EventHashMismatch;

    if (view.attachment_hash_bytes.len != try attachmentHashBytesLen(view.attachment_count)) {
        return error.InvalidEnvelope;
    }
}

pub fn hashEnvelopePreimage(envelope: []const u8) !Hash {
    if (envelope.len < HASH_LEN) return error.InvalidEnvelope;
    return hashBytes(envelope[0 .. envelope.len - HASH_LEN]);
}

pub fn hashBytes(bytes: []const u8) Hash {
    var out: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

pub fn hashEql(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, a[0..], b[0..]);
}

pub fn accumulatorStateKeyPrefix(allocator: std.mem.Allocator, log_id: []const u8) ![]u8 {
    const log_hash = hashBytes(log_id);
    var hex: [HASH_LEN * 2]u8 = undefined;
    _ = hashToHex(log_hash, &hex);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ ACCUMULATOR_STATE_PREFIX, hex[0..], ACCUMULATOR_STATE_SUFFIX });
}

pub fn accumulatorStateKey(allocator: std.mem.Allocator, log_id: []const u8, seq: u64) ![]u8 {
    const prefix = try accumulatorStateKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    var key = try allocator.alloc(u8, prefix.len + 8);
    @memcpy(key[0..prefix.len], prefix);
    std.mem.writeInt(u64, key[prefix.len..][0..8], seq, .big);
    return key;
}

pub fn seqFromAccumulatorStateKey(prefix: []const u8, key: []const u8) !u64 {
    if (key.len != prefix.len + 8) return error.InvalidAccumulatorStateKey;
    if (!std.mem.eql(u8, key[0..prefix.len], prefix)) return error.InvalidAccumulatorStateKey;
    return std.mem.readInt(u64, key[prefix.len..][0..8], .big);
}

fn appendLeafToPeaks(allocator: std.mem.Allocator, peaks_in: []const mmr.Peak, leaf_index: u64, leaf: []const u8) ![]mmr.Peak {
    var peaks: std.ArrayListUnmanaged(mmr.Peak) = .empty;
    errdefer peaks.deinit(allocator);
    try peaks.appendSlice(allocator, peaks_in);

    var carry = mmr.Peak{
        .height = 0,
        .hash = mmr.hashLeaf(leaf_index, leaf),
    };
    while (peaks.items.len > 0) {
        const left = peaks.items[peaks.items.len - 1];
        if (left.height != carry.height) break;
        _ = peaks.pop();
        carry = .{
            .height = left.height + 1,
            .hash = mmr.hashParent(left.height + 1, left.hash, carry.hash),
        };
    }
    try peaks.append(allocator, carry);
    return peaks.toOwnedSlice(allocator);
}

fn advanceAccumulatorState(
    allocator: std.mem.Allocator,
    state: AccumulatorState,
    record_hash: Hash,
    event_hash: Hash,
    ingest_time_ms: u64,
) !AccumulatorState {
    if (!mmr.peaksAreCanonical(state.last_seq, state.peaks)) return error.InvalidAccumulatorState;

    const next_seq = state.last_seq + 1;
    const next_peaks = try appendLeafToPeaks(allocator, state.peaks, state.last_seq, record_hash[0..]);
    errdefer allocator.free(next_peaks);
    return .{
        .peaks = next_peaks,
        .last_seq = next_seq,
        .last_ingest_time_ms = ingest_time_ms,
        .head_hash = event_hash,
        .accumulator_root = mmr.rootFromPeaks(next_seq, next_peaks),
    };
}

fn loadOrRebuildAccumulatorState(allocator: std.mem.Allocator, store: *Store, log_id: []const u8) !AccumulatorState {
    const maybe_state = loadLatestAccumulatorState(allocator, store, log_id) catch |err| blk: {
        std.log.warn("append-log MMR state load failed for '{s}', rebuilding: {s}", .{ log_id, @errorName(err) });
        break :blk null;
    };
    if (maybe_state) |state| {
        if (try accumulatorStateUsable(allocator, store, log_id, state)) return state;
        var stale = state;
        stale.deinit(allocator);
    }
    return rebuildAccumulatorState(allocator, store, log_id);
}

fn loadLatestAccumulatorState(allocator: std.mem.Allocator, store: *Store, log_id: []const u8) !?AccumulatorState {
    const prefix = try accumulatorStateKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    const results = try store.scanPrefix(prefix, 1, allocator);
    defer {
        for (results) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(results);
    }
    if (results.len == 0) return null;
    if (!results[0].is_worm) return error.NonWormAccumulatorState;

    const key_seq = try seqFromAccumulatorStateKey(prefix, results[0].key);
    var state = try decodeAccumulatorState(allocator, log_id, results[0].value);
    errdefer state.deinit(allocator);
    if (state.last_seq != key_seq) return error.AccumulatorStateKeyMismatch;
    return state;
}

fn accumulatorStateUsable(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
    state: AccumulatorState,
) !bool {
    if (!mmr.peaksAreCanonical(state.last_seq, state.peaks)) return false;
    if (!hashEql(mmr.rootFromPeaks(state.last_seq, state.peaks), state.accumulator_root)) return false;

    if (state.last_seq > 0) {
        const last_event = try loadEventValue(allocator, store, log_id, state.last_seq) orelse return false;
        defer allocator.free(last_event);
        const view = decodeEnvelope(last_event) catch return false;
        if (view.seq != state.last_seq) return false;
        if (!hashEql(view.event_hash, state.head_hash)) return false;
        if (view.ingest_time_ms != state.last_ingest_time_ms) return false;
    } else if (!hashEql(state.head_hash, ZERO_HASH)) {
        return false;
    }

    const next = try loadEventValue(allocator, store, log_id, state.last_seq + 1);
    if (next) |bytes| {
        allocator.free(bytes);
        return false;
    }
    return true;
}

fn loadEventValue(allocator: std.mem.Allocator, store: *Store, log_id: []const u8, seq: u64) !?[]const u8 {
    const key = try eventKey(allocator, log_id, seq);
    defer allocator.free(key);
    return try store.getValueDupe(key, allocator);
}

fn rebuildAccumulatorState(allocator: std.mem.Allocator, store: *Store, log_id: []const u8) !AccumulatorState {
    const prefix = try eventKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    const results = try store.scanPrefix(prefix, 0, allocator);
    defer {
        for (results) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(results);
    }

    var verifier = Verifier.init(log_id);
    var peaks: std.ArrayListUnmanaged(mmr.Peak) = .empty;
    errdefer peaks.deinit(allocator);
    var last_ingest_time_ms: u64 = 0;

    for (results) |r| {
        if (!r.is_worm) return error.NonWormEvent;
        const key_seq = try seqFromEventKey(prefix, r.key);
        const view = try decodeEnvelope(r.value);
        if (view.seq != key_seq) return error.SequenceKeyMismatch;
        if (view.ingest_time_ms != r.timestamp) return error.ReceiptTimestampMismatch;
        try verifier.accept(view);

        const record_hash = hashBytes(r.value);
        const next_peaks = try appendLeafToPeaks(allocator, peaks.items, view.seq - 1, record_hash[0..]);
        peaks.deinit(allocator);
        peaks = std.ArrayListUnmanaged(mmr.Peak).empty;
        try peaks.appendSlice(allocator, next_peaks);
        allocator.free(next_peaks);
        last_ingest_time_ms = r.timestamp;
    }

    const report = verifier.report();
    const owned_peaks = try peaks.toOwnedSlice(allocator);
    errdefer allocator.free(owned_peaks);
    return .{
        .peaks = owned_peaks,
        .last_seq = report.last_seq,
        .last_ingest_time_ms = last_ingest_time_ms,
        .head_hash = report.head_hash,
        .accumulator_root = mmr.rootFromPeaks(report.last_seq, owned_peaks),
    };
}

fn persistAccumulatorState(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
    state: AccumulatorState,
) !void {
    const key = try accumulatorStateKey(allocator, log_id, state.last_seq);
    defer allocator.free(key);
    const value = try encodeAccumulatorState(allocator, log_id, state);
    defer allocator.free(value);
    try store.setWithTimestamp(key, value, true, state.last_ingest_time_ms);
}

fn encodeAccumulatorState(allocator: std.mem.Allocator, log_id: []const u8, state: AccumulatorState) ![]u8 {
    if (log_id.len > std.math.maxInt(u32)) return error.AccumulatorStateTooLarge;
    if (state.peaks.len > mmr.PROOF_MAX_PEAKS) return error.AccumulatorStateTooLarge;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendBytes(&out, allocator, ACCUMULATOR_STATE_MAGIC);
    try appendU16(&out, allocator, ACCUMULATOR_STATE_VERSION);
    try appendU32(&out, allocator, @intCast(log_id.len));
    try appendBytes(&out, allocator, log_id);
    try appendU64(&out, allocator, state.last_seq);
    try appendU64(&out, allocator, state.last_ingest_time_ms);
    try appendBytes(&out, allocator, state.head_hash[0..]);
    try appendBytes(&out, allocator, state.accumulator_root[0..]);
    try appendU32(&out, allocator, @intCast(state.peaks.len));
    for (state.peaks) |peak| {
        try appendU8(&out, allocator, peak.height);
        try appendBytes(&out, allocator, peak.hash[0..]);
    }
    return out.toOwnedSlice(allocator);
}

fn decodeAccumulatorState(allocator: std.mem.Allocator, expected_log_id: []const u8, bytes: []const u8) !AccumulatorState {
    var pos: usize = 0;
    const magic = try readBytes(bytes, &pos, ACCUMULATOR_STATE_MAGIC.len);
    if (!std.mem.eql(u8, magic, ACCUMULATOR_STATE_MAGIC)) return error.InvalidAccumulatorState;
    const version = try readU16(bytes, &pos);
    if (version != ACCUMULATOR_STATE_VERSION) return error.UnsupportedAccumulatorStateVersion;
    const log_id_len = try readU32(bytes, &pos);
    const log_id = try readBytes(bytes, &pos, log_id_len);
    if (!std.mem.eql(u8, log_id, expected_log_id)) return error.AccumulatorStateLogMismatch;

    const last_seq = try readU64(bytes, &pos);
    const last_ingest_time_ms = try readU64(bytes, &pos);
    const head_hash = try readHash(bytes, &pos);
    const accumulator_root = try readHash(bytes, &pos);
    const peak_count_raw = try readU32(bytes, &pos);
    const peak_count: usize = @intCast(peak_count_raw);
    if (peak_count > mmr.PROOF_MAX_PEAKS) return error.InvalidAccumulatorState;

    const peaks = try allocator.alloc(mmr.Peak, peak_count);
    errdefer allocator.free(peaks);
    for (peaks) |*peak| {
        peak.height = try readU8(bytes, &pos);
        peak.hash = try readHash(bytes, &pos);
    }
    if (pos != bytes.len) return error.InvalidAccumulatorState;
    if (!mmr.peaksAreCanonical(last_seq, peaks)) return error.InvalidAccumulatorState;
    if (!hashEql(mmr.rootFromPeaks(last_seq, peaks), accumulator_root)) return error.InvalidAccumulatorState;

    return .{
        .peaks = peaks,
        .last_seq = last_seq,
        .last_ingest_time_ms = last_ingest_time_ms,
        .head_hash = head_hash,
        .accumulator_root = accumulator_root,
    };
}

fn addEnvelopeLen(total: *usize, amount: usize) !void {
    total.* = std.math.add(usize, total.*, amount) catch return error.EnvelopeTooLarge;
}

fn appendU8(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u8) !void {
    try out.append(allocator, value);
}

fn appendU16(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], value, .big);
    try out.appendSlice(allocator, buf[0..]);
}

fn appendU32(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], value, .big);
    try out.appendSlice(allocator, buf[0..]);
}

fn appendU64(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], value, .big);
    try out.appendSlice(allocator, buf[0..]);
}

fn appendBytes(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
}

fn attachmentHashBytesLen(count: u32) !usize {
    return std.math.mul(usize, @as(usize, count), HASH_LEN) catch return error.InvalidEnvelope;
}

pub fn eventKeyPrefix(allocator: std.mem.Allocator, log_id: []const u8) ![]u8 {
    const log_hash = hashBytes(log_id);
    var hex: [HASH_LEN * 2]u8 = undefined;
    _ = hashToHex(log_hash, &hex);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ STORAGE_PREFIX, hex[0..], EVENT_SUFFIX });
}

pub fn eventKey(allocator: std.mem.Allocator, log_id: []const u8, seq: u64) ![]u8 {
    const prefix = try eventKeyPrefix(allocator, log_id);
    defer allocator.free(prefix);

    var key = try allocator.alloc(u8, prefix.len + 8);
    @memcpy(key[0..prefix.len], prefix);
    std.mem.writeInt(u64, key[prefix.len..][0..8], seq, .big);
    return key;
}

pub fn seqFromEventKey(prefix: []const u8, key: []const u8) !u64 {
    if (key.len != prefix.len + 8) return error.InvalidEventKey;
    if (!std.mem.eql(u8, key[0..prefix.len], prefix)) return error.InvalidEventKey;
    return std.mem.readInt(u64, key[prefix.len..][0..8], .big);
}

pub fn hashToHex(hash: Hash, out: *[HASH_LEN * 2]u8) []const u8 {
    const alphabet = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out[0..];
}

const Verifier = struct {
    log_id: []const u8,
    expected_seq: u64 = 1,
    previous_hash: Hash = ZERO_HASH,
    count: usize = 0,
    last_seq: u64 = 0,

    fn init(log_id: []const u8) Verifier {
        return .{ .log_id = log_id };
    }

    fn accept(self: *Verifier, view: EventView) !void {
        try verifyEnvelope(self.log_id, view);

        if (view.seq < self.expected_seq) return error.SequenceReuse;
        if (view.seq > self.expected_seq) return error.SequenceGap;
        if (!hashEql(view.prev_event_hash, self.previous_hash)) return error.PrevHashMismatch;

        self.previous_hash = view.event_hash;
        self.last_seq = view.seq;
        self.count += 1;
        if (self.expected_seq != std.math.maxInt(u64)) {
            self.expected_seq += 1;
        }
    }

    fn report(self: *const Verifier) VerifyReport {
        return .{
            .count = self.count,
            .last_seq = self.last_seq,
            .head_hash = self.previous_hash,
        };
    }
};

fn writeU16(buf: []u8, pos: *usize, value: u16) void {
    std.mem.writeInt(u16, buf[pos.*..][0..2], value, .big);
    pos.* += 2;
}

fn writeU32(buf: []u8, pos: *usize, value: u32) void {
    std.mem.writeInt(u32, buf[pos.*..][0..4], value, .big);
    pos.* += 4;
}

fn writeU64(buf: []u8, pos: *usize, value: u64) void {
    std.mem.writeInt(u64, buf[pos.*..][0..8], value, .big);
    pos.* += 8;
}

fn writeHash(buf: []u8, pos: *usize, hash: Hash) void {
    @memcpy(buf[pos.*..][0..HASH_LEN], hash[0..]);
    pos.* += HASH_LEN;
}

fn writeBytes(buf: []u8, pos: *usize, bytes: []const u8) void {
    @memcpy(buf[pos.*..][0..bytes.len], bytes);
    pos.* += bytes.len;
}

fn readU16(buf: []const u8, pos: *usize) !u16 {
    const bytes = try readBytes(buf, pos, 2);
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn readU8(buf: []const u8, pos: *usize) !u8 {
    const bytes = try readBytes(buf, pos, 1);
    return bytes[0];
}

fn readU32(buf: []const u8, pos: *usize) !u32 {
    const bytes = try readBytes(buf, pos, 4);
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn readU64(buf: []const u8, pos: *usize) !u64 {
    const bytes = try readBytes(buf, pos, 8);
    return std.mem.readInt(u64, bytes[0..8], .big);
}

fn readHash(buf: []const u8, pos: *usize) !Hash {
    const bytes = try readBytes(buf, pos, HASH_LEN);
    var hash: Hash = undefined;
    @memcpy(hash[0..], bytes);
    return hash;
}

fn readBytes(buf: []const u8, pos: *usize, len: usize) ![]const u8 {
    if (pos.* > buf.len) return error.InvalidEnvelope;
    if (len > buf.len - pos.*) return error.InvalidEnvelope;
    const out = buf[pos.* .. pos.* + len];
    pos.* += len;
    return out;
}

test "canonical envelope hash is stable" {
    const testing = std.testing;
    const attachment = hashBytes("photo:sha256");
    const envelope = try encodeEnvelope(testing.allocator, .{
        .log_id = "field-log",
        .seq = 7,
        .prev_event_hash = ZERO_HASH,
        .ingest_time_ms = 1_700_000_000_123,
        .payload = "payload-v1",
        .attachment_hashes = &[_]Hash{attachment},
    });
    defer testing.allocator.free(envelope);

    const view = try decodeEnvelope(envelope);
    try verifyEnvelope("field-log", view);

    var actual: [HASH_LEN * 2]u8 = undefined;
    _ = hashToHex(view.event_hash, &actual);
    try testing.expectEqualStrings(
        "1fd34bbbb25e2a394e30c2c7b06b73e355d26ce4f3be83164f6d7160ab47adb1",
        actual[0..],
    );
}

test "verify catches previous hash mismatch" {
    const testing = std.testing;
    const first = try encodeEnvelope(testing.allocator, .{
        .log_id = "log",
        .seq = 1,
        .prev_event_hash = ZERO_HASH,
        .ingest_time_ms = 10,
        .payload = "one",
    });
    defer testing.allocator.free(first);

    const second_wrong_prev = try encodeEnvelope(testing.allocator, .{
        .log_id = "log",
        .seq = 2,
        .prev_event_hash = ZERO_HASH,
        .ingest_time_ms = 11,
        .payload = "two",
    });
    defer testing.allocator.free(second_wrong_prev);

    try testing.expectError(error.PrevHashMismatch, verifyEnvelopes("log", &[_][]const u8{ first, second_wrong_prev }));
}

test "verify catches sequence reuse and gaps" {
    const testing = std.testing;
    const first = try encodeEnvelope(testing.allocator, .{
        .log_id = "log",
        .seq = 1,
        .prev_event_hash = ZERO_HASH,
        .ingest_time_ms = 10,
        .payload = "one",
    });
    defer testing.allocator.free(first);
    const first_view = try decodeEnvelope(first);

    const duplicate_first = try encodeEnvelope(testing.allocator, .{
        .log_id = "log",
        .seq = 1,
        .prev_event_hash = ZERO_HASH,
        .ingest_time_ms = 12,
        .payload = "one-replacement",
    });
    defer testing.allocator.free(duplicate_first);

    const third = try encodeEnvelope(testing.allocator, .{
        .log_id = "log",
        .seq = 3,
        .prev_event_hash = first_view.event_hash,
        .ingest_time_ms = 13,
        .payload = "three",
    });
    defer testing.allocator.free(third);

    try testing.expectError(error.SequenceReuse, verifyEnvelopes("log", &[_][]const u8{ first, duplicate_first }));
    try testing.expectError(error.SequenceGap, verifyEnvelopes("log", &[_][]const u8{ first, third }));
}

test "append writes WORM sequence events and verifies store chain" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var first = try append(testing.allocator, &store, "site-a", "payload-one", &.{}, .{ .ingest_time_ms = 100 });
    defer first.deinit(testing.allocator);
    var second = try append(testing.allocator, &store, "site-a", "payload-two", &.{}, .{ .ingest_time_ms = 101 });
    defer second.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 1), first.seq);
    try testing.expectEqual(@as(u64, 2), second.seq);
    try testing.expect(hashEql(first.event_hash, second.prev_event_hash));

    const report = try verifyStore(testing.allocator, &store, "site-a");
    try testing.expectEqual(@as(usize, 2), report.count);
    try testing.expectEqual(@as(u64, 2), report.last_seq);
    try testing.expect(hashEql(second.event_hash, report.head_hash));
}

test "append writes durable WORM MMR state records" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    var first = try append(testing.allocator, &store, "site-a", "payload-one", &.{}, .{ .ingest_time_ms = 100 });
    defer first.deinit(testing.allocator);
    var second = try append(testing.allocator, &store, "site-a", "payload-two", &.{}, .{ .ingest_time_ms = 101 });
    defer second.deinit(testing.allocator);

    const prefix = try accumulatorStateKeyPrefix(testing.allocator, "site-a");
    defer testing.allocator.free(prefix);
    const states = try store.scanPrefix(prefix, 0, testing.allocator);
    defer {
        for (states) |s| {
            testing.allocator.free(s.key);
            testing.allocator.free(s.value);
        }
        testing.allocator.free(states);
    }
    try testing.expectEqual(@as(usize, 2), states.len);
    try testing.expect(states[0].is_worm);
    try testing.expect(states[1].is_worm);

    var latest = (try loadLatestAccumulatorState(testing.allocator, &store, "site-a")).?;
    defer latest.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 2), latest.last_seq);
    try testing.expect(hashEql(second.event_hash, latest.head_hash));
    try testing.expect(hashEql(second.accumulator_root, latest.accumulator_root));
    try testing.expectEqual(@as(u64, 2), second.accumulator_leaf_count);

    var acc = mmr.Accumulator.init(testing.allocator);
    defer acc.deinit();
    _ = try acc.append(hashBytes(first.envelope)[0..]);
    const expected_root = try acc.append(hashBytes(second.envelope)[0..]);
    try testing.expect(hashEql(expected_root, latest.accumulator_root));
}

test "append MMR state survives WAL replay" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try compat.Dir.realPathAlloc(tmp_dir.dir, testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/append_mmr_state.wal", .{tmp_path});
    defer testing.allocator.free(wal_path);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/append_mmr_state.snapshot", .{tmp_path});
    defer testing.allocator.free(snapshot_path);

    const wal_file = try compat.Dir.createFile(tmp_dir.dir, "append_mmr_state.wal", .{});
    compat.File.close(wal_file);

    const cfg = Config{
        .wal_path = wal_path,
        .snapshot_path = snapshot_path,
        .sync_writes = false,
        .persistence = .full,
    };

    var expected_root: Hash = undefined;
    {
        var store = try Store.init(testing.allocator, cfg);
        defer store.deinit();
        var first = try append(testing.allocator, &store, "site-a", "payload-one", &.{}, .{ .ingest_time_ms = 100 });
        defer first.deinit(testing.allocator);
        var second = try append(testing.allocator, &store, "site-a", "payload-two", &.{}, .{ .ingest_time_ms = 101 });
        defer second.deinit(testing.allocator);
        expected_root = second.accumulator_root;
    }
    {
        var reopened = try Store.init(testing.allocator, cfg);
        defer reopened.deinit();
        var latest = (try loadLatestAccumulatorState(testing.allocator, &reopened, "site-a")).?;
        defer latest.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 2), latest.last_seq);
        try testing.expect(hashEql(expected_root, latest.accumulator_root));
    }
}

test "verifyStore rejects receipt timestamp mismatch" {
    const testing = std.testing;
    var store = try Store.init(testing.allocator, Config{ .persistence = .none });
    defer store.deinit();

    const envelope = try encodeEnvelope(testing.allocator, .{
        .log_id = "site-a",
        .seq = 1,
        .prev_event_hash = ZERO_HASH,
        .ingest_time_ms = 100,
        .payload = "payload-one",
    });
    defer testing.allocator.free(envelope);

    const key = try eventKey(testing.allocator, "site-a", 1);
    defer testing.allocator.free(key);

    try store.setWithTimestamp(key, envelope, true, 101);
    try testing.expectError(error.ReceiptTimestampMismatch, verifyStore(testing.allocator, &store, "site-a"));
}
