//! WormWire binary framing protocol (v1)
//!
//! Frame format:
//! [1 byte cmd/resp code][4 bytes payload length big-endian][payload...]

const std = @import("std");
const core = @import("../core/mod.zig");
const compat = core.compat;

const Command = core.types.Command;
pub const CommandId = core.types.CommandId;
const Response = core.types.Response;
const MAX_PAYLOAD_LENGTH = core.types.MAX_PAYLOAD_LENGTH;

pub const WIRE_MAGIC = [2]u8{ 0x57, 0x57 }; // "WW" — WormWire client
pub const REPL_MAGIC = [2]u8{ 0x57, 0x52 }; // "WR" — WormWire replication

pub const WireError = error{
    EndOfStream,
    Corruption,
    UnknownCommand,
    PayloadTooLarge,
    InvalidFlags,
    OutOfMemory,
};

pub const ResponseCode = enum(u8) {
    ok = 0x00,
    value = 0x01,
    null_value = 0x02,
    err = 0x03,
    event = 0x04,
};

/// Allocating frame reader: each field (key/value) is duped from the payload.
/// The caller must call `deinitCommand` to free them.
pub fn readFrameAlloc(reader: anytype, allocator: std.mem.Allocator) !Command {
    var header: [5]u8 = undefined;
    readExact(reader, &header) catch |err| {
        if (err == error.EndOfStream) return error.EndOfStream;
        return err;
    };

    const cmd_id_byte = header[0];
    const payload_len = std.mem.readInt(u32, header[1..5], .big);
    if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    if (payload_len > 0) {
        try readExact(reader, payload);
    }

    const cmd_id: CommandId = compat.intToEnum(CommandId, cmd_id_byte) catch return error.UnknownCommand;
    return parseCommandPayload(cmd_id, payload, allocator);
}

/// Zero-copy frame reader: fields are slices into the arena-allocated payload.
/// No per-field frees needed — the arena reset handles everything.
/// Only safe when the allocator is an ArenaAllocator (payload stays alive until reset).
pub fn readFrameZeroCopy(reader: anytype, allocator: std.mem.Allocator) !Command {
    var header: [5]u8 = undefined;
    readExact(reader, &header) catch |err| {
        if (err == error.EndOfStream) return error.EndOfStream;
        return err;
    };

    const cmd_id_byte = header[0];
    const payload_len = std.mem.readInt(u32, header[1..5], .big);
    if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

    // Payload stays alive until arena reset — fields are sliced from it.
    const payload = try allocator.alloc(u8, payload_len);
    if (payload_len > 0) {
        try readExact(reader, payload);
    }

    const cmd_id: CommandId = compat.intToEnum(CommandId, cmd_id_byte) catch return error.UnknownCommand;
    return parseCommandPayloadZeroCopy(cmd_id, payload, allocator);
}

fn readExact(reader: anytype, dest: []u8) !void {
    var offset: usize = 0;
    while (offset < dest.len) {
        const n = try reader.read(dest[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn parseCommandPayload(cmd_id: CommandId, payload: []const u8, allocator: std.mem.Allocator) !Command {
    var pos: usize = 0;

    switch (cmd_id) {
        .get, .delete, .subscribe, .unsubscribe => {
            const field = try readBytesField(payload, &pos, allocator);
            if (pos != payload.len) {
                allocator.free(field);
                return error.Corruption;
            }
            return switch (cmd_id) {
                .get => .{ .get = field },
                .delete => .{ .delete = field },
                .subscribe => .{ .subscribe = field },
                .unsubscribe => .{ .unsubscribe = field },
                else => unreachable,
            };
        },
        .set => {
            if (payload.len < 1) return error.Corruption;
            const flags = payload[0];
            if ((flags & 0b1111_1110) != 0) return error.InvalidFlags;
            pos = 1;

            const key = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(key);

            const value = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(value);

            if (pos != payload.len) return error.Corruption;

            return .{ .set = .{
                .key = key,
                .value = value,
                .worm = (flags & 0x01) != 0,
            } };
        },
        .publish => {
            const channel = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(channel);
            const message = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(message);
            if (pos != payload.len) return error.Corruption;

            return .{ .publish = .{
                .channel = channel,
                .message = message,
            } };
        },
        .status => {
            if (payload.len != 0) return error.Corruption;
            return .{ .status = {} };
        },
        .cluster_status => {
            if (payload.len != 0) return error.Corruption;
            return .{ .cluster_status = {} };
        },
        .cluster_peers => {
            if (payload.len != 0) return error.Corruption;
            return .{ .cluster_peers = {} };
        },
        .save => {
            if (payload.len != 0) return error.Corruption;
            return .{ .save = {} };
        },
        .exec => {
            // EXEC payload: [procedure_name][u32 arg_count][arg0][arg1]...
            const procedure = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(procedure);

            if (pos + 4 > payload.len) {
                allocator.free(procedure);
                return error.Corruption;
            }
            const arg_count = std.mem.readInt(u32, payload[pos..][0..4], .big);
            pos += 4;

            const args = allocator.alloc([]const u8, arg_count) catch {
                allocator.free(procedure);
                return error.OutOfMemory;
            };
            var initialized: u32 = 0;
            errdefer {
                for (args[0..initialized]) |a| allocator.free(a);
                allocator.free(args);
                allocator.free(procedure);
            }

            for (0..arg_count) |i| {
                args[i] = try readBytesField(payload, &pos, allocator);
                initialized += 1;
            }

            if (pos != payload.len) {
                for (args[0..initialized]) |a| allocator.free(a);
                allocator.free(args);
                allocator.free(procedure);
                return error.Corruption;
            }

            return .{ .exec = .{ .procedure = procedure, .args = args } };
        },
        .auth => {
            // AUTH payload: raw binary SCT token (single field)
            const token = try readBytesField(payload, &pos, allocator);
            if (pos != payload.len) {
                allocator.free(token);
                return error.Corruption;
            }
            return .{ .auth = token };
        },
        .vinsert => {
            // VINSERT payload:
            //   [key][vector][1B flags][namespace][metric][8B timestamp]
            const key = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(key);
            const vector = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(vector);

            if (pos + 1 > payload.len) return error.Corruption;
            const flags = payload[pos];
            pos += 1;
            // Bit 0: WORM. Bit 1: async HNSW build request. Rest reserved.
            if ((flags & 0b1111_1100) != 0) return error.InvalidFlags;

            const namespace = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(namespace);
            const metric = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(metric);

            if (pos + 8 > payload.len) return error.Corruption;
            const ts = std.mem.readInt(u64, payload[pos..][0..8], .big);
            pos += 8;
            if (pos != payload.len) return error.Corruption;

            return .{ .vinsert = .{
                .key = key,
                .vector = vector,
                .worm = (flags & 0x01) != 0,
                .namespace = namespace,
                .metric = metric,
                .timestamp = ts,
                .is_async = (flags & 0x02) != 0,
            } };
        },
        .vdelete => {
            const key = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(key);
            const namespace = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(namespace);
            if (pos != payload.len) return error.Corruption;
            return .{ .vdelete = .{ .key = key, .namespace = namespace } };
        },
        .vbulkinsert => {
            // VBULKINSERT payload:
            //   [namespace][metric][1B flags][4B count]
            //   For each item: [key][vector][8B timestamp]
            const namespace = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(namespace);
            const metric = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(metric);

            if (pos + 1 > payload.len) return error.Corruption;
            const flags = payload[pos];
            pos += 1;
            if ((flags & 0b1111_1100) != 0) return error.InvalidFlags;

            if (pos + 4 > payload.len) return error.Corruption;
            const count_u32 = std.mem.readInt(u32, payload[pos..][0..4], .big);
            pos += 4;
            const count: usize = @intCast(count_u32);

            const items = try allocator.alloc(Command.VbulkinsertParams.BulkItem, count);
            errdefer {
                for (items, 0..) |it, i| {
                    if (i >= count) break;
                    if (it.key.len > 0) allocator.free(@constCast(it.key));
                    if (it.vector.len > 0) allocator.free(@constCast(it.vector));
                }
                allocator.free(items);
            }

            for (items) |*it| {
                it.key = &.{};
                it.vector = &.{};
                it.timestamp = 0;
            }

            for (items) |*it| {
                const key = try readBytesField(payload, &pos, allocator);
                it.key = key;
                const vector = try readBytesField(payload, &pos, allocator);
                it.vector = vector;
                if (pos + 8 > payload.len) return error.Corruption;
                it.timestamp = std.mem.readInt(u64, payload[pos..][0..8], .big);
                pos += 8;
            }
            if (pos != payload.len) return error.Corruption;

            return .{ .vbulkinsert = .{
                .namespace = namespace,
                .metric = metric,
                .worm = (flags & 0x01) != 0,
                .is_async = (flags & 0x02) != 0,
                .items = items,
            } };
        },
        .vrabitq_install => {
            // [namespace][4B dim][8B seed][centroid][rotation]
            const namespace = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(namespace);

            if (pos + 4 > payload.len) return error.Corruption;
            const dim = std.mem.readInt(u32, payload[pos..][0..4], .big);
            pos += 4;
            if (pos + 8 > payload.len) return error.Corruption;
            const seed = std.mem.readInt(u64, payload[pos..][0..8], .big);
            pos += 8;

            const centroid = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(centroid);
            const rotation = try readBytesField(payload, &pos, allocator);
            errdefer allocator.free(rotation);

            // Sanity-check sizes against dim — the applier will hard-fail
            // on mismatch but failing earlier produces a cleaner error.
            const expected_centroid: usize = @as(usize, dim) * 4;
            const expected_rotation: usize = @as(usize, dim) * @as(usize, dim) * 4;
            if (centroid.len != expected_centroid or rotation.len != expected_rotation) {
                return error.Corruption;
            }

            if (pos != payload.len) return error.Corruption;
            return .{ .vrabitq_install = .{
                .namespace = namespace,
                .dim = dim,
                .seed = seed,
                .centroid = centroid,
                .rotation = rotation,
            } };
        },
    }
}

fn readBytesField(payload: []const u8, pos: *usize, allocator: std.mem.Allocator) ![]u8 {
    if (pos.* + 4 > payload.len) return error.Corruption;
    const field_len_u32 = std.mem.readInt(u32, payload[pos.*..][0..4], .big);
    pos.* += 4;

    const field_len: usize = @intCast(field_len_u32);
    if (pos.* + field_len > payload.len) return error.Corruption;

    const out = try allocator.dupe(u8, payload[pos.* .. pos.* + field_len]);
    pos.* += field_len;
    return out;
}

/// Zero-copy field extraction: returns a slice into the payload buffer.
/// The caller must ensure the payload buffer outlives the returned slice.
fn sliceBytesField(payload: []const u8, pos: *usize) ![]const u8 {
    if (pos.* + 4 > payload.len) return error.Corruption;
    const field_len_u32 = std.mem.readInt(u32, payload[pos.*..][0..4], .big);
    pos.* += 4;

    const field_len: usize = @intCast(field_len_u32);
    if (pos.* + field_len > payload.len) return error.Corruption;

    const out = payload[pos.* .. pos.* + field_len];
    pos.* += field_len;
    return out;
}

/// Zero-copy command parser: returns slices into the payload buffer.
/// Payload must be arena-allocated (not freed before command is processed).
pub fn parseCommandPayloadZeroCopy(cmd_id: CommandId, payload: []const u8, allocator: std.mem.Allocator) !Command {
    var pos: usize = 0;

    switch (cmd_id) {
        .get, .delete, .subscribe, .unsubscribe => {
            const field = try sliceBytesField(payload, &pos);
            if (pos != payload.len) return error.Corruption;
            // Cast const slice to mutable — safe because arena owns the backing memory
            // and the Command union requires []u8.
            const field_mut = @constCast(field);
            return switch (cmd_id) {
                .get => .{ .get = field_mut },
                .delete => .{ .delete = field_mut },
                .subscribe => .{ .subscribe = field_mut },
                .unsubscribe => .{ .unsubscribe = field_mut },
                else => unreachable,
            };
        },
        .set => {
            if (payload.len < 1) return error.Corruption;
            const flags = payload[0];
            if ((flags & 0b1111_1110) != 0) return error.InvalidFlags;
            pos = 1;

            const key = try sliceBytesField(payload, &pos);
            const value = try sliceBytesField(payload, &pos);
            if (pos != payload.len) return error.Corruption;

            return .{ .set = .{
                .key = @constCast(key),
                .value = @constCast(value),
                .worm = (flags & 0x01) != 0,
            } };
        },
        .publish => {
            const channel = try sliceBytesField(payload, &pos);
            const message = try sliceBytesField(payload, &pos);
            if (pos != payload.len) return error.Corruption;

            return .{ .publish = .{
                .channel = @constCast(channel),
                .message = @constCast(message),
            } };
        },
        .status => {
            if (payload.len != 0) return error.Corruption;
            return .{ .status = {} };
        },
        .cluster_status => {
            if (payload.len != 0) return error.Corruption;
            return .{ .cluster_status = {} };
        },
        .cluster_peers => {
            if (payload.len != 0) return error.Corruption;
            return .{ .cluster_peers = {} };
        },
        .save => {
            if (payload.len != 0) return error.Corruption;
            return .{ .save = {} };
        },
        .exec => {
            // EXEC still needs allocating due to variable args array
            return parseCommandPayload(cmd_id, payload, allocator);
        },
        .auth => {
            const token = try sliceBytesField(payload, &pos);
            if (pos != payload.len) return error.Corruption;
            return .{ .auth = @constCast(token) };
        },
        .vinsert => {
            const key = try sliceBytesField(payload, &pos);
            const vector = try sliceBytesField(payload, &pos);

            if (pos + 1 > payload.len) return error.Corruption;
            const flags = payload[pos];
            pos += 1;
            if ((flags & 0b1111_1100) != 0) return error.InvalidFlags;

            const namespace = try sliceBytesField(payload, &pos);
            const metric = try sliceBytesField(payload, &pos);

            if (pos + 8 > payload.len) return error.Corruption;
            const ts = std.mem.readInt(u64, payload[pos..][0..8], .big);
            pos += 8;
            if (pos != payload.len) return error.Corruption;

            return .{ .vinsert = .{
                .key = @constCast(key),
                .vector = @constCast(vector),
                .worm = (flags & 0x01) != 0,
                .namespace = @constCast(namespace),
                .metric = @constCast(metric),
                .timestamp = ts,
                .is_async = (flags & 0x02) != 0,
            } };
        },
        .vdelete => {
            const key = try sliceBytesField(payload, &pos);
            const namespace = try sliceBytesField(payload, &pos);
            if (pos != payload.len) return error.Corruption;
            return .{ .vdelete = .{
                .key = @constCast(key),
                .namespace = @constCast(namespace),
            } };
        },
        .vbulkinsert => {
            // Variable-length items array needs allocation — delegate.
            return parseCommandPayload(cmd_id, payload, allocator);
        },
        .vrabitq_install => {
            const namespace = try sliceBytesField(payload, &pos);
            if (pos + 4 > payload.len) return error.Corruption;
            const dim = std.mem.readInt(u32, payload[pos..][0..4], .big);
            pos += 4;
            if (pos + 8 > payload.len) return error.Corruption;
            const seed = std.mem.readInt(u64, payload[pos..][0..8], .big);
            pos += 8;
            const centroid = try sliceBytesField(payload, &pos);
            const rotation = try sliceBytesField(payload, &pos);
            const expected_centroid: usize = @as(usize, dim) * 4;
            const expected_rotation: usize = @as(usize, dim) * @as(usize, dim) * 4;
            if (centroid.len != expected_centroid or rotation.len != expected_rotation) {
                return error.Corruption;
            }
            if (pos != payload.len) return error.Corruption;
            return .{ .vrabitq_install = .{
                .namespace = @constCast(namespace),
                .dim = dim,
                .seed = seed,
                .centroid = @constCast(centroid),
                .rotation = @constCast(rotation),
            } };
        },
    }
}

/// Minimal fixed-buffer writer with a `.writeAll` method, used by callers
/// that previously relied on `std.io.fixedBufferStream` (removed in 0.16).
pub const FixedBufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn init(buf: []u8) FixedBufWriter {
        return .{ .buf = buf, .pos = 0 };
    }

    pub fn writeAll(self: *FixedBufWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn getWritten(self: *const FixedBufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

pub fn writeResponse(writer: anytype, response: Response) !void {
    var w = writer;
    switch (response) {
        .ok => {
            try writeHeader(w, @intFromEnum(ResponseCode.ok), 0);
        },
        .value => |maybe_val| {
            if (maybe_val) |val| {
                try writeHeader(w, @intFromEnum(ResponseCode.value), @intCast(val.len));
                if (val.len > 0) try w.writeAll(val);
            } else {
                try writeHeader(w, @intFromEnum(ResponseCode.null_value), 0);
            }
        },
        .err => |msg| {
            try writeHeader(w, @intFromEnum(ResponseCode.err), @intCast(msg.len));
            if (msg.len > 0) try w.writeAll(msg);
        },
        .event => |evt| {
            var payload_len: usize = 0;
            payload_len += 4 + evt.channel.len;
            payload_len += 4 + evt.message.len;
            if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

            try writeHeader(w, @intFromEnum(ResponseCode.event), @intCast(payload_len));
            try writeLenPrefixed(w, evt.channel);
            try writeLenPrefixed(w, evt.message);
        },
    }
}

pub fn writeCommand(writer: anytype, cmd: Command) !void {
    var w = writer;
    switch (cmd) {
        .get => |key| {
            try writeHeader(w, @intFromEnum(CommandId.get), @intCast(4 + key.len));
            try writeLenPrefixed(w, key);
        },
        .delete => |key| {
            try writeHeader(w, @intFromEnum(CommandId.delete), @intCast(4 + key.len));
            try writeLenPrefixed(w, key);
        },
        .subscribe => |channel| {
            try writeHeader(w, @intFromEnum(CommandId.subscribe), @intCast(4 + channel.len));
            try writeLenPrefixed(w, channel);
        },
        .unsubscribe => |channel| {
            try writeHeader(w, @intFromEnum(CommandId.unsubscribe), @intCast(4 + channel.len));
            try writeLenPrefixed(w, channel);
        },
        .status => {
            try writeHeader(w, @intFromEnum(CommandId.status), 0);
        },
        .cluster_status => {
            try writeHeader(w, @intFromEnum(CommandId.cluster_status), 0);
        },
        .cluster_peers => {
            try writeHeader(w, @intFromEnum(CommandId.cluster_peers), 0);
        },
        .save => {
            try writeHeader(w, @intFromEnum(CommandId.save), 0);
        },
        .set => |params| {
            var payload_len: usize = 1;
            payload_len += 4 + params.key.len;
            payload_len += 4 + params.value.len;
            if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

            try writeHeader(w, @intFromEnum(CommandId.set), @intCast(payload_len));
            const flags: u8 = if (params.worm) 0x01 else 0x00;
            try w.writeAll(&[_]u8{flags});
            try writeLenPrefixed(w, params.key);
            try writeLenPrefixed(w, params.value);
        },
        .publish => |params| {
            var payload_len: usize = 0;
            payload_len += 4 + params.channel.len;
            payload_len += 4 + params.message.len;
            if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

            try writeHeader(w, @intFromEnum(CommandId.publish), @intCast(payload_len));
            try writeLenPrefixed(w, params.channel);
            try writeLenPrefixed(w, params.message);
        },
        .exec => |params| {
            var payload_len: usize = 0;
            payload_len += 4 + params.procedure.len;
            payload_len += 4; // arg count
            for (params.args) |arg| {
                payload_len += 4 + arg.len;
            }
            if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

            try writeHeader(w, @intFromEnum(CommandId.exec), @intCast(payload_len));
            try writeLenPrefixed(w, params.procedure);
            var count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, count_buf[0..4], @intCast(params.args.len), .big);
            try w.writeAll(&count_buf);
            for (params.args) |arg| {
                try writeLenPrefixed(w, arg);
            }
        },
        .auth => |token| {
            try writeHeader(w, @intFromEnum(CommandId.auth), @intCast(4 + token.len));
            try writeLenPrefixed(w, token);
        },
        .vinsert => |params| {
            // [key][vec][1B flags][ns][metric][8B ts]
            var payload_len: usize = 0;
            payload_len += 4 + params.key.len;
            payload_len += 4 + params.vector.len;
            payload_len += 1;
            payload_len += 4 + params.namespace.len;
            payload_len += 4 + params.metric.len;
            payload_len += 8;
            if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

            try writeHeader(w, @intFromEnum(CommandId.vinsert), @intCast(payload_len));
            try writeLenPrefixed(w, params.key);
            try writeLenPrefixed(w, params.vector);
            var flags: u8 = 0;
            if (params.worm) flags |= 0x01;
            if (params.is_async) flags |= 0x02;
            try w.writeAll(&[_]u8{flags});
            try writeLenPrefixed(w, params.namespace);
            try writeLenPrefixed(w, params.metric);
            var ts_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, ts_buf[0..8], params.timestamp, .big);
            try w.writeAll(&ts_buf);
        },
        .vdelete => |params| {
            var payload_len: usize = 0;
            payload_len += 4 + params.key.len;
            payload_len += 4 + params.namespace.len;
            if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

            try writeHeader(w, @intFromEnum(CommandId.vdelete), @intCast(payload_len));
            try writeLenPrefixed(w, params.key);
            try writeLenPrefixed(w, params.namespace);
        },
        .vbulkinsert => |params| {
            var payload_len: usize = 0;
            payload_len += 4 + params.namespace.len;
            payload_len += 4 + params.metric.len;
            payload_len += 1; // flags
            payload_len += 4; // count
            for (params.items) |it| {
                payload_len += 4 + it.key.len;
                payload_len += 4 + it.vector.len;
                payload_len += 8;
            }
            if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

            try writeHeader(w, @intFromEnum(CommandId.vbulkinsert), @intCast(payload_len));
            try writeLenPrefixed(w, params.namespace);
            try writeLenPrefixed(w, params.metric);
            var flags: u8 = 0;
            if (params.worm) flags |= 0x01;
            if (params.is_async) flags |= 0x02;
            try w.writeAll(&[_]u8{flags});
            var count_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, count_buf[0..4], @intCast(params.items.len), .big);
            try w.writeAll(&count_buf);
            for (params.items) |it| {
                try writeLenPrefixed(w, it.key);
                try writeLenPrefixed(w, it.vector);
                var ts_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, ts_buf[0..8], it.timestamp, .big);
                try w.writeAll(&ts_buf);
            }
        },
        .vrabitq_install => |params| {
            // [namespace][4B dim][8B seed][centroid bytes][rotation bytes]
            var payload_len: usize = 0;
            payload_len += 4 + params.namespace.len;
            payload_len += 4; // dim
            payload_len += 8; // seed
            payload_len += 4 + params.centroid.len;
            payload_len += 4 + params.rotation.len;
            if (payload_len > MAX_PAYLOAD_LENGTH) return error.PayloadTooLarge;

            try writeHeader(w, @intFromEnum(CommandId.vrabitq_install), @intCast(payload_len));
            try writeLenPrefixed(w, params.namespace);
            var dim_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, dim_buf[0..4], params.dim, .big);
            try w.writeAll(&dim_buf);
            var seed_buf: [8]u8 = undefined;
            std.mem.writeInt(u64, seed_buf[0..8], params.seed, .big);
            try w.writeAll(&seed_buf);
            try writeLenPrefixed(w, params.centroid);
            try writeLenPrefixed(w, params.rotation);
        },
    }
}

fn writeHeader(writer: anytype, code: u8, payload_len: u32) !void {
    var w = writer;
    var header: [5]u8 = undefined;
    header[0] = code;
    std.mem.writeInt(u32, header[1..5], payload_len, .big);
    try w.writeAll(&header);
}

fn writeLenPrefixed(writer: anytype, data: []const u8) !void {
    var w = writer;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, len_buf[0..4], @intCast(data.len), .big);
    try w.writeAll(&len_buf);
    if (data.len > 0) try w.writeAll(data);
}

/// Test-only helpers replacing `std.io.fixedBufferStream` + `ArrayList.writer`
/// (both removed in Zig 0.16). These implement just enough of the old
/// duck-typed reader/writer surface to drive readFrameAlloc/writeCommand.
const TestListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: *TestListWriter, data: []const u8) !void {
        try self.list.appendSlice(self.allocator, data);
    }
};

const TestSliceReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn read(self: *TestSliceReader, dest: []u8) !usize {
        const remaining = self.buffer.len - self.pos;
        const n = @min(remaining, dest.len);
        @memcpy(dest[0..n], self.buffer[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

test "wire write/read roundtrip SET with spaces" {
    const testing = std.testing;

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    const cmd = Command{ .set = .{ .key = "k", .value = "hello world", .worm = true } };
    var writer = TestListWriter{ .list = &bytes, .allocator = testing.allocator };
    try writeCommand(&writer, cmd);

    var reader = TestSliceReader{ .buffer = bytes.items };
    const parsed = try readFrameAlloc(&reader, testing.allocator);
    defer switch (parsed) {
        .set => |p| {
            testing.allocator.free(p.key);
            testing.allocator.free(p.value);
        },
        else => {},
    };

    try testing.expectEqualStrings("k", parsed.set.key);
    try testing.expectEqualStrings("hello world", parsed.set.value);
    try testing.expect(parsed.set.worm);
}

test "wire rejects oversized declared payload" {
    const testing = std.testing;

    var frame: [5]u8 = undefined;
    frame[0] = @intFromEnum(CommandId.get);
    std.mem.writeInt(u32, frame[1..5], MAX_PAYLOAD_LENGTH + 1, .big);

    var reader = TestSliceReader{ .buffer = &frame };
    try testing.expectError(error.PayloadTooLarge, readFrameAlloc(&reader, testing.allocator));
}

test "wire roundtrip VINSERT" {
    const testing = std.testing;

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    // Representative vector bytes: 4 f32 = 16 bytes, with values that would
    // exercise the full u8 range (catches endianness bugs).
    const vec_bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0xAB, 0xCD, 0xEF, 0x10, 0x00, 0xFF, 0x7F, 0x80, 0xCA, 0xFE, 0xBA, 0xBE };
    const cmd = Command{ .vinsert = .{
        .key = "vec:articles:doc-1",
        .vector = &vec_bytes,
        .worm = true,
        .namespace = "vec:articles:",
        .metric = "cosine",
        .timestamp = 0x0123_4567_89AB_CDEF,
    } };

    var writer = TestListWriter{ .list = &bytes, .allocator = testing.allocator };
    try writeCommand(&writer, cmd);

    var reader = TestSliceReader{ .buffer = bytes.items };
    const parsed = try readFrameAlloc(&reader, testing.allocator);
    defer switch (parsed) {
        .vinsert => |p| {
            testing.allocator.free(p.key);
            testing.allocator.free(p.vector);
            testing.allocator.free(p.namespace);
            testing.allocator.free(p.metric);
        },
        else => {},
    };

    try testing.expectEqualStrings("vec:articles:doc-1", parsed.vinsert.key);
    try testing.expectEqualSlices(u8, &vec_bytes, parsed.vinsert.vector);
    try testing.expect(parsed.vinsert.worm);
    try testing.expectEqualStrings("vec:articles:", parsed.vinsert.namespace);
    try testing.expectEqualStrings("cosine", parsed.vinsert.metric);
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), parsed.vinsert.timestamp);
}

test "wire roundtrip VDELETE" {
    const testing = std.testing;

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    const cmd = Command{ .vdelete = .{
        .key = "vec:articles:doc-1",
        .namespace = "vec:articles:",
    } };

    var writer = TestListWriter{ .list = &bytes, .allocator = testing.allocator };
    try writeCommand(&writer, cmd);

    var reader = TestSliceReader{ .buffer = bytes.items };
    const parsed = try readFrameAlloc(&reader, testing.allocator);
    defer switch (parsed) {
        .vdelete => |p| {
            testing.allocator.free(p.key);
            testing.allocator.free(p.namespace);
        },
        else => {},
    };

    try testing.expectEqualStrings("vec:articles:doc-1", parsed.vdelete.key);
    try testing.expectEqualStrings("vec:articles:", parsed.vdelete.namespace);
}


test "wire roundtrip VRABITQ_INSTALL" {
    const testing = std.testing;

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(testing.allocator);

    // d=4 to keep the test data small but exercise the centroid +
    // rotation length-prefix paths.
    const dim: u32 = 4;
    const centroid_f32 = [_]f32{ 1.5, -2.25, 3.125, 0.0 };
    const rotation_f32 = [_]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    const centroid_bytes_ptr: [*]const u8 = @ptrCast(&centroid_f32);
    const rotation_bytes_ptr: [*]const u8 = @ptrCast(&rotation_f32);

    const cmd = Command{ .vrabitq_install = .{
        .namespace = "vec:roundtrip:",
        .dim = dim,
        .seed = 0xDEAD_BEEF_C0DE_F00D,
        .centroid = centroid_bytes_ptr[0 .. dim * 4],
        .rotation = rotation_bytes_ptr[0 .. dim * dim * 4],
    } };

    var writer = TestListWriter{ .list = &bytes, .allocator = testing.allocator };
    try writeCommand(&writer, cmd);

    var reader = TestSliceReader{ .buffer = bytes.items };
    const parsed = try readFrameAlloc(&reader, testing.allocator);
    defer switch (parsed) {
        .vrabitq_install => |p| {
            testing.allocator.free(p.namespace);
            testing.allocator.free(p.centroid);
            testing.allocator.free(p.rotation);
        },
        else => {},
    };

    try testing.expectEqualStrings("vec:roundtrip:", parsed.vrabitq_install.namespace);
    try testing.expectEqual(@as(u32, 4), parsed.vrabitq_install.dim);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_C0DE_F00D), parsed.vrabitq_install.seed);
    try testing.expectEqualSlices(u8, centroid_bytes_ptr[0 .. dim * 4], parsed.vrabitq_install.centroid);
    try testing.expectEqualSlices(u8, rotation_bytes_ptr[0 .. dim * dim * 4], parsed.vrabitq_install.rotation);
}
