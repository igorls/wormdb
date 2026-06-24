//! EXEC auth_mint_scoped <namespace> [ttl_s] [subject] [mode]
//!
//! Mints a short-lived namespace-scoped SCT using the optional server-side
//! signing key. Existing auth-disabled/trusted deployments keep behaving as
//! before; enforced callers need admin or namespace mint authority.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const auth = @import("../server/auth.zig");

const MAX_NS_LEN: usize = 64;

fn isSafeToken(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_' or c == '.' or c == '/';
}

fn validateNs(ns: []const u8) bool {
    if (ns.len == 0 or ns.len > MAX_NS_LEN) return false;
    for (ns) |c| if (!isSafeToken(c)) return false;
    return true;
}

fn appendJsonEscaped(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            else => try list.append(alloc, c),
        }
    }
}

fn canMint(ctx: *Ctx, ns: []const u8) !bool {
    if (ctx.permits(.all, "")) return true;
    if (!ctx.permits(.exec, "auth_mint_scoped")) return false;
    const target = try std.fmt.allocPrint(ctx.allocator, "auth:mint:{s}", .{ns});
    defer ctx.allocator.free(target);
    return ctx.permits(.exec, target);
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const ns = ctx.arg(0) orelse
        return ctx.err("auth_mint_scoped requires: <namespace> [ttl_s] [subject] [mode]");
    if (!validateNs(ns)) return ctx.err("auth_mint_scoped: invalid namespace");

    const mint = ctx.authMintConfig() orelse
        return ctx.err("auth_mint_scoped: auth mint not configured");

    if (!try canMint(ctx, ns)) return ctx.err("permission denied");

    const ttl_s = if (ctx.arg(1)) |raw| blk: {
        const parsed = std.fmt.parseInt(u64, raw, 10) catch
            return ctx.err("auth_mint_scoped: ttl_s must be a positive integer");
        if (parsed == 0) return ctx.err("auth_mint_scoped: ttl_s must be positive");
        break :blk parsed;
    } else mint.default_ttl_s;
    if (mint.max_ttl_s > 0 and ttl_s > mint.max_ttl_s)
        return ctx.err("auth_mint_scoped: ttl_s exceeds auth token_max_age_s");

    const subject = ctx.arg(2) orelse try std.fmt.allocPrint(ctx.allocator, "mem:{s}", .{ns});
    const mode = if (ctx.arg(3)) |raw|
        auth.namespaceModeFromStr(raw) orelse return ctx.err("auth_mint_scoped: mode must be read|write|readwrite")
    else
        auth.NamespaceMode.readwrite;

    var caps: std.ArrayListUnmanaged(auth.Capability) = .empty;
    defer {
        for (caps.items) |cap| ctx.allocator.free(cap.pattern);
        caps.deinit(ctx.allocator);
    }
    try auth.appendNamespaceCapabilities(ctx.allocator, &caps, ns, mode);

    var jti_bytes: [4]u8 = undefined;
    @import("../core/compat.zig").randomBytes(&jti_bytes);
    const jti = std.mem.readInt(u32, &jti_bytes, .big);
    const now_s: u64 = @intCast(@divFloor(ctx.timestamp(), 1000));
    const exp = now_s + ttl_s;

    const token = try auth.encode(subject, now_s, exp, jti, caps.items, mint.secret_key, ctx.allocator);
    defer ctx.allocator.free(token);

    const token_b64 = try ctx.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(token.len));
    _ = std.base64.standard.Encoder.encode(token_b64, token);

    var json: std.ArrayListUnmanaged(u8) = .empty;
    errdefer json.deinit(ctx.allocator);
    try json.appendSlice(ctx.allocator, "{\"token\":\"");
    try json.appendSlice(ctx.allocator, token_b64);
    try json.appendSlice(ctx.allocator, "\",\"subject\":\"");
    try appendJsonEscaped(&json, ctx.allocator, subject);
    try json.appendSlice(ctx.allocator, "\",\"namespace\":\"");
    try appendJsonEscaped(&json, ctx.allocator, ns);
    try json.appendSlice(ctx.allocator, "\",\"mode\":\"");
    try json.appendSlice(ctx.allocator, @tagName(mode));
    try json.appendSlice(ctx.allocator, "\",\"exp\":");
    var exp_buf: [32]u8 = undefined;
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&exp_buf, "{d}", .{exp}) catch "0");
    try json.appendSlice(ctx.allocator, ",\"jti\":");
    var jti_buf: [16]u8 = undefined;
    try json.appendSlice(ctx.allocator, std.fmt.bufPrint(&jti_buf, "{d}", .{jti}) catch "0");
    try json.append(ctx.allocator, '}');

    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

const testing = std.testing;

fn extractJsonString(json: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{field}) catch return null;
    const start_rel = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = start_rel + needle.len;
    const end_rel = std.mem.indexOfScalar(u8, json[start..], '"') orelse return null;
    return json[start .. start + end_rel];
}

test "auth_mint_scoped: mints verifiable namespace read token for admin" {
    const kp = auth.generateKeypair();
    const mint = @import("context.zig").AuthMintConfig{
        .secret_key = &kp.secret_key,
        .default_ttl_s = 60,
        .max_ttl_s = 3600,
    };
    const admin_caps = [_]auth.Capability{
        .{ .op = .all, .match_type = .wildcard, .pattern = "" },
    };
    const admin = auth.TokenState{
        .subject = "admin",
        .iat = 0,
        .exp = 0,
        .jti = 0,
        .capabilities = &admin_caps,
    };

    var store = try @import("../storage/store.zig").Store.init(testing.allocator, .{
        .wal_path = "unused.wal",
        .snapshot_path = "unused.snapshot",
        .persistence = .none,
    });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = Ctx.initWithAuth(
        &store,
        &.{ "astrid", "60", "agent-astrid", "read" },
        arena,
        .{ .enforce = &admin },
        mint,
        null,
        null,
        null,
    );
    defer ctx.deinit();

    const result = try execute(&ctx);
    try testing.expect(result == .value);

    const token_b64 = extractJsonString(result.value.?, "token") orelse return error.TestUnexpectedResult;
    const token_len = try std.base64.standard.Decoder.calcSizeForSlice(token_b64);
    const token = try arena.alloc(u8, token_len);
    try std.base64.standard.Decoder.decode(token, token_b64);

    const parsed = try auth.verifyAndParse(token, &[_]auth.PublicKey{kp.public_key}, arena, 3600);
    try testing.expectEqualStrings("agent-astrid", parsed.subject);
    try testing.expect(parsed.permits(.get, "mem:astrid:doc-1"));
    try testing.expect(parsed.permits(.subscribe, "mem:astrid:added"));
    try testing.expect(parsed.permits(.exec, "mem_query"));
    try testing.expect(!parsed.permits(.get, "mem:raven:doc-1"));
    try testing.expect(!parsed.permits(.set, "mem:astrid:doc-1"));
}

test "auth_mint_scoped: rejects missing config and missing mint authority" {
    var store = try @import("../storage/store.zig").Store.init(testing.allocator, .{
        .wal_path = "unused.wal",
        .snapshot_path = "unused.snapshot",
        .persistence = .none,
    });
    defer store.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var no_config = Ctx.initWithAuth(
        &store,
        &.{"astrid"},
        arena,
        .trusted,
        null,
        null,
        null,
        null,
    );
    defer no_config.deinit();
    const missing = try execute(&no_config);
    try testing.expect(missing == .err);
    try testing.expect(std.mem.indexOf(u8, missing.err, "not configured") != null);

    const kp = auth.generateKeypair();
    const mint = @import("context.zig").AuthMintConfig{
        .secret_key = &kp.secret_key,
        .default_ttl_s = 60,
        .max_ttl_s = 3600,
    };
    const caps = [_]auth.Capability{
        .{ .op = .exec, .match_type = .exact, .pattern = "auth_mint_scoped" },
    };
    const non_admin = auth.TokenState{
        .subject = "operator",
        .iat = 0,
        .exp = 0,
        .jti = 0,
        .capabilities = &caps,
    };
    var no_scope = Ctx.initWithAuth(
        &store,
        &.{"astrid"},
        arena,
        .{ .enforce = &non_admin },
        mint,
        null,
        null,
        null,
    );
    defer no_scope.deinit();
    const denied = try execute(&no_scope);
    try testing.expect(denied == .err);
    try testing.expectEqualStrings("permission denied", denied.err);
}
