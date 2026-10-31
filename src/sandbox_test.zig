//! Tests for sandboxed procedures (procedures/sandbox.zig) against a real law.
//!
//! Its own test root because it needs examples/laws/ford_toll.zig compiled to wasm, which build.zig
//! provides as the `ford_toll_wasm` import; the engine module itself never depends on an example.

const std = @import("std");
const testing = std.testing;
const Ctx = @import("procedures/context.zig").Ctx;
const Store = @import("storage/store.zig").Store;
const Config = @import("core/config.zig").Config;
const compat = @import("core/compat.zig");
const sandbox = @import("procedures/sandbox.zig");
const ford_toll = @embedFile("ford_toll_wasm");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    store: Store,

    fn init() !Fixture {
        return initWith(Config{ .persistence = .none });
    }

    fn initWith(config: Config) !Fixture {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .store = try Store.init(testing.allocator, config) };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.arena.deinit();
    }

    fn exec(self: *Fixture, func: anytype, args: []const []const u8) !Ctx.Result {
        var ctx = Ctx.init(&self.store, args, self.arena.allocator(), null, null, null, null);
        defer ctx.deinit();
        return func(&ctx);
    }

    fn value(self: *Fixture, func: anytype, args: []const []const u8) ![]const u8 {
        const res = try self.exec(func, args);
        if (res == .err) {
            std.debug.print("unexpected error: {s}\n", .{res.err});
            return error.UnexpectedErr;
        }
        return res.value orelse "";
    }

    fn get(self: *Fixture, key: []const u8) ?[]const u8 {
        return self.store.getValueDupe(key, self.arena.allocator()) catch null;
    }
};

const scope = "demo:ford:";

test "a law runs, keeps to its scope, and its calls replay to the same state" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const hash = try fx.value(sandbox.installExecute, &.{ scope, ford_toll });
    try testing.expectEqual(@as(usize, 64), hash.len);

    try testing.expectEqualStrings("90", try fx.value(sandbox.callExecute, &.{ scope, "pass", "ana", "100" }));
    try testing.expectEqualStrings("25", try fx.value(sandbox.callExecute, &.{ scope, "set_rate", "25" }));
    try testing.expectEqualStrings("30", try fx.value(sandbox.callExecute, &.{ scope, "pass", "bo", "40" }));
    try testing.expectEqualStrings("150", try fx.value(sandbox.callExecute, &.{ scope, "pass", "ana", "200" }));

    try testing.expectEqualStrings("70", fx.get(scope ++ "treasury").?);
    try testing.expectEqualStrings("60", fx.get(scope ++ "paid:ana").?);
    try testing.expectEqualStrings("10", fx.get(scope ++ "paid:bo").?);

    const verdict = try fx.value(sandbox.replayExecute, &.{scope});
    try testing.expect(std.mem.startsWith(u8, verdict, "ok 4 "));
}

test "a failed or trapped call changes nothing and is not logged" {
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.value(sandbox.installExecute, &.{ scope, ford_toll });
    _ = try fx.value(sandbox.callExecute, &.{ scope, "pass", "ana", "100" });

    const refused = try fx.exec(sandbox.callExecute, &.{ scope, "set_rate", "101" });
    try testing.expectEqualStrings("law_failed: rate must be 0 to 100", refused.err);

    const spun = try fx.exec(sandbox.callExecute, &.{ scope, "spin" });
    try testing.expectEqualStrings("law_trapped: OutOfFuel", spun.err);

    const missing = try fx.exec(sandbox.callExecute, &.{ scope, "no_such_entry" });
    try testing.expectEqualStrings("law_trapped: NoSuchExport", missing.err);

    try testing.expect(fx.get(scope ++ "rate") == null);
    try testing.expectEqualStrings("10", fx.get(scope ++ "treasury").?);
    try testing.expect(std.mem.startsWith(u8, try fx.value(sandbox.replayExecute, &.{scope}), "ok 1 "));
}

test "replay catches state written behind the law's back" {
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.value(sandbox.installExecute, &.{ scope, ford_toll });
    _ = try fx.value(sandbox.callExecute, &.{ scope, "pass", "ana", "100" });

    try fx.store.set(scope ++ "treasury", "1000000", false);
    const res = try fx.exec(sandbox.replayExecute, &.{scope});
    try testing.expectEqualStrings("state differs from the law at 'demo:ford:treasury'", res.err);
}

test "scopes may not nest, and a module with floats is refused" {
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.value(sandbox.installExecute, &.{ scope, ford_toll });
    const nested = try fx.exec(sandbox.installExecute, &.{ scope ++ "inner:", ford_toll });
    try testing.expectEqualStrings("scope overlaps the scope 'demo:ford:'", nested.err);
    const reserved = try fx.exec(sandbox.installExecute, &.{ "sbx:evil:", ford_toll });
    try testing.expectEqualStrings("a scope may not start with sbx:", reserved.err);

    const floats = "\x00asm\x01\x00\x00\x00" ++ "\x01\x05\x01\x60\x00\x01\x7d";
    const res = try fx.exec(sandbox.installExecute, &.{ "demo:other:", floats });
    try testing.expectEqualStrings("invalid module: FloatsNotAllowed", res.err);
}

test "a pointer outside the law's memory traps instead of reaching the host" {
    var fx = try Fixture.init();
    defer fx.deinit();
    // (module (import "wormdb" "get" (func (param i32 i32 i32 i32) (result i32))) (memory 1)
    //   (func (export "peek") i32.const 0x7fffffff i32.const 8 i32.const 0 i32.const 8 call 0 drop))
    const peek = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x0c\x02\x60\x04\x7f\x7f\x7f\x7f\x01\x7f\x60\x00\x00" ++
        "\x02\x0e\x01\x06wormdb\x03get\x00\x00" ++
        "\x03\x02\x01\x01" ++ "\x05\x03\x01\x00\x01" ++ "\x07\x08\x01\x04peek\x00\x01" ++
        "\x0a\x13\x01\x11\x00\x41\xff\xff\xff\xff\x07\x41\x08\x41\x00\x41\x08\x10\x00\x1a\x0b";
    _ = try fx.value(sandbox.installExecute, &.{ scope, peek });
    const res = try fx.exec(sandbox.callExecute, &.{ scope, "peek" });
    try testing.expectEqualStrings("law_trapped: MemoryOutOfBounds", res.err);
}

test "a law's state and log survive a restart and still replay" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try compat.Dir.realPathAlloc(tmp.dir, testing.allocator, ".");
    defer testing.allocator.free(dir);
    const wal_path = try std.fmt.allocPrint(testing.allocator, "{s}/sandbox.wal", .{dir});
    defer testing.allocator.free(wal_path);
    const snapshot_path = try std.fmt.allocPrint(testing.allocator, "{s}/sandbox.snapshot", .{dir});
    defer testing.allocator.free(snapshot_path);
    const config = Config{ .wal_path = wal_path, .snapshot_path = snapshot_path, .sync_writes = false };

    var before: []const u8 = undefined;
    {
        var fx = try Fixture.initWith(config);
        defer fx.deinit();
        _ = try fx.value(sandbox.installExecute, &.{ scope, ford_toll });
        _ = try fx.value(sandbox.callExecute, &.{ scope, "pass", "ana", "100" });
        _ = try fx.value(sandbox.callExecute, &.{ scope, "set_rate", "50" });
        _ = try fx.value(sandbox.callExecute, &.{ scope, "pass", "bo", "10" });
        before = try testing.allocator.dupe(u8, try fx.value(sandbox.replayExecute, &.{scope}));
    }
    defer testing.allocator.free(before);
    try testing.expect(std.mem.startsWith(u8, before, "ok 3 "));

    var fx = try Fixture.initWith(config);
    defer fx.deinit();
    try testing.expectEqualStrings("15", fx.get(scope ++ "treasury").?);
    try testing.expectEqualStrings(before, try fx.value(sandbox.replayExecute, &.{scope}));
    try testing.expectEqualStrings("5", try fx.value(sandbox.callExecute, &.{ scope, "pass", "ana", "10" }));
    try testing.expect(std.mem.startsWith(u8, try fx.value(sandbox.replayExecute, &.{scope}), "ok 4 "));
}
