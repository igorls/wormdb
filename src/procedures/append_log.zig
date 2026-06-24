//! Built-in verifiable append-log procedures.
//!
//! EXEC append_log_append <log_id> <payload> [ts=<ms>] [attachment_hash_hex...]
//! EXEC append_log_verify <log_id>
//!
//! Events are stored through the proof append-log primitive as WORM records
//! with canonical binary envelopes. Optional attachment hashes are 64-char
//! lowercase/uppercase hex SHA-256 values.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const Response = @import("../core/types.zig").Response;
const append_log = @import("../proof/append_log.zig");
const Store = @import("../storage/store.zig").Store;
const Config = @import("../core/config.zig").Config;

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
    try json.appendSlice(allocator, "\"}");
    return json.toOwnedSlice(allocator);
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
