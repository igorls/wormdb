//! Command protocol parser
//!
//! Command grammar used by internal tests and tooling:
//!   SET <key> <value> [WORM]     -> +OK or -ERR <message>
//!   GET <key>                    -> $<len>\r\n<data>\r\n or $-1\r\n (null)
//!   DEL <key>                    -> +OK or -ERR <message>
//!   STATUS                       -> $<len>\r\n<data>\r\n
//!   CLUSTER STATUS               -> $<len>\r\n<data>\r\n
//!   SUB <channel>                -> +OK (then async events)
//!   UNSUB <channel>              -> +OK
//!   PUB <channel> <message>      -> +OK

const std = @import("std");
const core = @import("../core/mod.zig");

const Command = core.types.Command;
const Response = core.types.Response;

pub const ProtocolError = error{
    MalformedCommand,
    InvalidArgs,
    UnknownCommand,
    TooLarge,
    OutOfMemory,
};

pub fn parseCommand(allocator: std.mem.Allocator, input: []const u8) ProtocolError!Command {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    var tokens = std.mem.tokenizeAny(u8, trimmed, " \t");

    const cmd = tokens.next() orelse return error.MalformedCommand;

    if (std.mem.eql(u8, cmd, "GET")) {
        const key = tokens.next() orelse return error.InvalidArgs;
        return .{ .get = try allocator.dupe(u8, key) };
    }

    if (std.mem.eql(u8, cmd, "SET")) {
        const key = tokens.next() orelse return error.InvalidArgs;
        const value = tokens.next() orelse return error.InvalidArgs;
        var is_worm = false;
        while (tokens.next()) |flag| {
            if (std.mem.eql(u8, flag, "WORM")) is_worm = true;
        }
        return .{ .set = .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
            .worm = is_worm,
        } };
    }

    if (std.mem.eql(u8, cmd, "DEL")) {
        const key = tokens.next() orelse return error.InvalidArgs;
        return .{ .delete = try allocator.dupe(u8, key) };
    }

    if (std.mem.eql(u8, cmd, "STATUS")) {
        if (tokens.next() != null) return error.InvalidArgs;
        return .{ .status = {} };
    }

    if (std.mem.eql(u8, cmd, "SAVE")) {
        if (tokens.next() != null) return error.InvalidArgs;
        return .{ .save = {} };
    }

    if (std.mem.eql(u8, cmd, "CLUSTER")) {
        const sub = tokens.next() orelse return error.InvalidArgs;
        if (tokens.next() != null) return error.InvalidArgs;
        if (std.mem.eql(u8, sub, "STATUS")) return .{ .cluster_status = {} };
        if (std.mem.eql(u8, sub, "PEERS")) return .{ .cluster_peers = {} };
        return error.InvalidArgs;
    }

    if (std.mem.eql(u8, cmd, "SUB")) {
        const channel = tokens.next() orelse return error.InvalidArgs;
        return .{ .subscribe = try allocator.dupe(u8, channel) };
    }

    if (std.mem.eql(u8, cmd, "UNSUB")) {
        const channel = tokens.next() orelse return error.InvalidArgs;
        return .{ .unsubscribe = try allocator.dupe(u8, channel) };
    }

    if (std.mem.eql(u8, cmd, "PUB")) {
        const channel = tokens.next() orelse return error.InvalidArgs;
        const message = tokens.rest();
        if (message.len == 0) return error.InvalidArgs;
        return .{ .publish = .{
            .channel = try allocator.dupe(u8, channel),
            .message = try allocator.dupe(u8, message),
        } };
    }

    return error.UnknownCommand;
}

pub fn deinitCommand(allocator: std.mem.Allocator, cmd: Command) void {
    switch (cmd) {
        .get => |key| allocator.free(key),
        .set => |params| {
            allocator.free(params.key);
            allocator.free(params.value);
        },
        .delete => |key| allocator.free(key),
        .status => {},
        .cluster_status => {},
        .cluster_peers => {},
        .save => {},
        .subscribe => |channel| allocator.free(channel),
        .unsubscribe => |channel| allocator.free(channel),
        .publish => |params| {
            allocator.free(params.channel);
            allocator.free(params.message);
        },
        .exec => |params| {
            for (params.args) |a| allocator.free(a);
            allocator.free(params.args);
            allocator.free(params.procedure);
        },
        .auth => |token| allocator.free(token),
    }
}

pub fn formatResponse(allocator: std.mem.Allocator, response: Response) ![]const u8 {
    return switch (response) {
        .value => |val| if (val) |v|
            std.fmt.allocPrint(allocator, "${d}\r\n{s}\r\n", .{ v.len, v })
        else
            allocator.dupe(u8, "$-1\r\n"),
        .ok => allocator.dupe(u8, "+OK\r\n"),
        .err => |msg| std.fmt.allocPrint(allocator, "-ERR {s}\r\n", .{msg}),
        .event => |evt| std.fmt.allocPrint(allocator, ">EVENT {s}\r\n{s}\r\n", .{ evt.channel, evt.message }),
    };
}

pub fn deinitResponse(allocator: std.mem.Allocator, response: Response) void {
    switch (response) {
        .value => |val| if (val) |v| allocator.free(v),
        .err => |msg| allocator.free(msg),
        .event => |evt| {
            allocator.free(evt.channel);
            allocator.free(evt.message);
        },
        .ok => {},
    }
}

test "parse GET command" {
    const testing = std.testing;
    const cmd = try parseCommand(testing.allocator, "GET mykey");
    defer deinitCommand(testing.allocator, cmd);
    try testing.expectEqualStrings("mykey", cmd.get);
}

test "parse SET command" {
    const testing = std.testing;
    const cmd = try parseCommand(testing.allocator, "SET mykey myvalue");
    defer deinitCommand(testing.allocator, cmd);
    try testing.expectEqualStrings("mykey", cmd.set.key);
    try testing.expectEqualStrings("myvalue", cmd.set.value);
    try testing.expectEqual(false, cmd.set.worm);
}

test "parse SET WORM command" {
    const testing = std.testing;
    const cmd = try parseCommand(testing.allocator, "SET mykey myvalue WORM");
    defer deinitCommand(testing.allocator, cmd);
    try testing.expectEqual(true, cmd.set.worm);
}

test "parse STATUS command" {
    const testing = std.testing;
    const cmd = try parseCommand(testing.allocator, "STATUS");
    defer deinitCommand(testing.allocator, cmd);
    try testing.expectEqual(@as(Command, .{ .status = {} }), cmd);
}

test "parse STATUS with args fails" {
    const testing = std.testing;
    try testing.expectError(error.InvalidArgs, parseCommand(testing.allocator, "STATUS extra"));
}

test "parse CLUSTER STATUS command" {
    const testing = std.testing;
    const cmd = try parseCommand(testing.allocator, "CLUSTER STATUS");
    defer deinitCommand(testing.allocator, cmd);
    try testing.expectEqual(@as(Command, .{ .cluster_status = {} }), cmd);
}

test "parse CLUSTER PEERS command" {
    const testing = std.testing;
    const cmd = try parseCommand(testing.allocator, "CLUSTER PEERS");
    defer deinitCommand(testing.allocator, cmd);
    try testing.expectEqual(@as(Command, .{ .cluster_peers = {} }), cmd);
}

test "parse CLUSTER invalid subcommand fails" {
    const testing = std.testing;
    try testing.expectError(error.InvalidArgs, parseCommand(testing.allocator, "CLUSTER INVALID"));
}
