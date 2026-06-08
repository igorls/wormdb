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

pub const HASH_LEN: usize = 32;
pub const Hash = [HASH_LEN]u8;

pub const ENVELOPE_MAGIC: []const u8 = "WDBALOG1";
pub const ENVELOPE_VERSION: u16 = 1;
pub const STORAGE_PREFIX: []const u8 = "proof:append-log:v1:";
pub const EVENT_SUFFIX: []const u8 = ":event:";
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

/// Append a payload to a named WORM log.
///
/// This helper scans and verifies the current chain to find the tail, then
/// writes the next event under a WORM sequence key. A concurrent append that
/// wins the same sequence causes `error.SequenceReuse`; callers can retry.
pub fn append(
    allocator: std.mem.Allocator,
    store: *Store,
    log_id: []const u8,
    payload: []const u8,
    attachment_hashes: []const Hash,
    options: AppendOptions,
) !AppendResult {
    const tail = try verifyStore(allocator, store, log_id);
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

    return .{
        .key = key,
        .envelope = envelope,
        .seq = seq,
        .prev_event_hash = view.prev_event_hash,
        .payload_hash = view.payload_hash,
        .event_hash = view.event_hash,
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

    const preimage_len =
        ENVELOPE_MAGIC.len +
        2 +
        4 + input.log_id.len +
        8 +
        HASH_LEN +
        8 +
        HASH_LEN +
        4 + input.attachment_hashes.len * HASH_LEN +
        4 + input.payload.len;
    const total_len = preimage_len + HASH_LEN;

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
    const log_id = try readBytes(bytes, &pos, log_id_len);
    const seq = try readU64(bytes, &pos);
    const prev_event_hash = try readHash(bytes, &pos);
    const ingest_time_ms = try readU64(bytes, &pos);
    const payload_hash = try readHash(bytes, &pos);
    const attachment_count = try readU32(bytes, &pos);
    const attachment_hash_bytes = try readBytes(bytes, &pos, @as(usize, attachment_count) * HASH_LEN);
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

    if (view.attachment_hash_bytes.len != @as(usize, view.attachment_count) * HASH_LEN) {
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
