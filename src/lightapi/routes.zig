//! Light-API request handlers for the WormDB gateway.
//!
//! The generic gateway (WS handshake, frame read/write, keep-alive HTTP, the
//! binary WormWire path) knows nothing about blockchains. This module supplies
//! the two app hooks the gateway calls when `-Dlightapi=true`:
//!
//!   * `routeHttp(ctx, alloc, path) ?RouteResult` — the `GET /api/...` drop-in,
//!     mapping each path to an EXEC procedure and returning its JSON/text value.
//!   * `handleWsText(ctx, sink, alloc, text)` — the cc32d9 WebSocket JSON-RPC 2.0
//!     dialect: a text frame carries `{method, params:{reqid, …}}`; results stream
//!     back as `reqdata` notifications via the gateway-provided `sink`.
//!
//! Both run through the SAME `server/executor.zig` pipeline as WormWire/WS binary
//! clients — no application tier. The gateway passes only neutral capabilities
//! (`ExecCtx` = store/bus/cluster, `Sink` = a text-frame writer); this file never
//! touches socket/WebSocket framing.

const std = @import("std");
const core = @import("../core/mod.zig");
const storage = @import("../storage/mod.zig");
const event_mod = @import("../event/mod.zig");
const cluster_mod = @import("../cluster/mod.zig");
const executor = @import("../server/executor.zig");

const Store = storage.Store;
const EventBus = event_mod.EventBus;
const Cluster = cluster_mod.Cluster;

/// Neutral execution context the gateway hands the Light-API handlers — exactly
/// the inputs `executor.execute` needs, with no socket state.
pub const ExecCtx = struct {
    store: *Store,
    event_bus: *EventBus,
    cluster: ?*Cluster,
};

/// One resolved HTTP response: a body, whether it is JSON, and a status code.
pub const RouteResult = struct { body: []const u8, json: bool, status: u16 = 200 };

/// A text-frame sink: the gateway wraps `writeText` so this module can stream WS
/// notifications without owning the socket or the WebSocket framing.
pub const Sink = struct {
    ptr: *anyopaque,
    writeText: *const fn (ptr: *anyopaque, text: []const u8) void,

    fn send(self: Sink, text: []const u8) void {
        self.writeText(self.ptr, text);
    }
};

/// Run a procedure through the shared executor; return its `value` payload (or null on error).
fn execProc(ctx: ExecCtx, alloc: std.mem.Allocator, proc: []const u8, args: []const []const u8) ?[]const u8 {
    const resp = executor.execute(.{
        .allocator = alloc,
        .store = ctx.store,
        .event_bus = ctx.event_bus,
        .cluster = ctx.cluster,
        .identity = null,
    }, .{ .exec = .{ .procedure = proc, .args = args } }) catch return null;
    return switch (resp) {
        .value => |v| v orelse "null",
        else => null,
    };
}

// --- Plain HTTP (Light-API drop-in) ---
//
// Answers `GET /api/...` by routing to an EXEC procedure and returning its JSON value — the SAME
// executor pipeline as WormWire/WS clients, no application tier. The DB *is* the API server.

/// Map a `/api/...` path to an EXEC. Returns the body + whether it is JSON, or null → 404.
pub fn routeHttp(ctx: ExecCtx, alloc: std.mem.Allocator, path: []const u8) ?RouteResult {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    if (!std.mem.eql(u8, it.next() orelse return null, "api")) return null;
    const ep = it.next() orelse return null;
    const eql = std.mem.eql;

    if (eql(u8, ep, "balances")) {
        const chain = it.next() orelse return null;
        const acct = it.next() orelse return null;
        if (it.next() != null) return null;
        return jsonRoute(execProc(ctx, alloc, "lightapi_balances", &.{ chain, acct }));
    }
    if (eql(u8, ep, "account")) {
        const chain = it.next() orelse return null;
        const acct = it.next() orelse return null;
        if (it.next() != null) return null;
        return jsonRoute(execProc(ctx, alloc, "lightapi_account", &.{ chain, acct }));
    }
    if (eql(u8, ep, "accinfo")) {
        const chain = it.next() orelse return null;
        const acct = it.next() orelse return null;
        if (it.next() != null) return null;
        return jsonRoute(execProc(ctx, alloc, "lightapi_accinfo", &.{ chain, acct }));
    }
    if (eql(u8, ep, "tokenbalance")) {
        const chain = it.next() orelse return null;
        const acct = it.next() orelse return null;
        const contract = it.next() orelse return null;
        const symbol = it.next() orelse return null;
        return textRoute(execProc(ctx, alloc, "lightapi_tokenbalance", &.{ chain, acct, contract, symbol }));
    }
    if (eql(u8, ep, "usercount")) {
        const chain = it.next() orelse return null;
        const key = std.fmt.allocPrint(alloc, "uc:{s}", .{chain}) catch return null;
        return textRoute(execProc(ctx, alloc, "lightapi_get", &.{ key, "0" }));
    }
    if (eql(u8, ep, "holdercount")) {
        const chain = it.next() orelse return null;
        const contract = it.next() orelse return null;
        const symbol = it.next() orelse return null;
        return textRoute(execProc(ctx, alloc, "lightapi_holdercount", &.{ chain, contract, symbol }));
    }
    if (eql(u8, ep, "networks")) {
        return jsonRoute(execProc(ctx, alloc, "lightapi_get", &.{ "lanet", "[]" }));
    }
    if (eql(u8, ep, "codehash")) {
        const hash = it.next() orelse return null;
        const key = std.fmt.allocPrint(alloc, "chh:{s}", .{hash}) catch return null;
        return jsonRoute(execProc(ctx, alloc, "lightapi_get", &.{ key, "{}" }));
    }
    if (eql(u8, ep, "key")) {
        const pubkey = it.next() orelse return null;
        const key = std.fmt.allocPrint(alloc, "pk:{s}", .{pubkey}) catch return null;
        return jsonRoute(execProc(ctx, alloc, "lightapi_get", &.{ key, "{}" }));
    }
    if (eql(u8, ep, "topholders")) {
        const chain = it.next() orelse return null;
        const contract = it.next() orelse return null;
        const symbol = it.next() orelse return null;
        const n = it.next() orelse return null;
        return jsonRoute(execProc(ctx, alloc, "lightapi_topholders", &.{ chain, contract, symbol, n }));
    }
    if (eql(u8, ep, "topram") or eql(u8, ep, "topstake")) {
        const chain = it.next() orelse return null;
        const n = it.next() orelse return null;
        // key = "topram:<chain>" / "topstake:<chain>" (materialized at load time).
        // topram rows are [acct,ram] (1 int); topstake rows are [acct,cpu,net] (2 ints).
        const key = std.fmt.allocPrint(alloc, "{s}:{s}", .{ ep, chain }) catch return null;
        const fmt: []const u8 = if (eql(u8, ep, "topstake")) "nn" else "n";
        return jsonRoute(execProc(ctx, alloc, "lightapi_topn", &.{ key, n, fmt }));
    }
    if (eql(u8, ep, "rexbalance")) {
        const chain = it.next() orelse return null;
        const acct = it.next() orelse return null;
        return jsonRoute(execProc(ctx, alloc, "lightapi_rexbalance", &.{ chain, acct }));
    }
    if (eql(u8, ep, "rexraw")) {
        const chain = it.next() orelse return null;
        const key = std.fmt.allocPrint(alloc, "rexraw:{s}", .{chain}) catch return null;
        return textRoute(execProc(ctx, alloc, "lightapi_get", &.{ key, "REX is not enabled" }));
    }
    if (eql(u8, ep, "sync")) {
        const chain = it.next() orelse return null;
        return textRoute(execProc(ctx, alloc, "lightapi_sync", &.{chain}));
    }
    if (eql(u8, ep, "status")) {
        const body = execProc(ctx, alloc, "lightapi_status", &.{}) orelse return null;
        // cc32d9 returns HTTP 503 when any network is out of sync (body starts "OUT_OF_SYNC").
        const status: u16 = if (std.mem.startsWith(u8, body, "OUT_OF_SYNC")) 503 else 200;
        return .{ .body = body, .json = false, .status = status };
    }
    return null;
}

fn jsonRoute(body: ?[]const u8) ?RouteResult {
    return .{ .body = body orelse return null, .json = true };
}
fn textRoute(body: ?[]const u8) ?RouteResult {
    return .{ .body = body orelse return null, .json = false };
}

// --- cc32d9 WebSocket JSON-RPC API (jsonrpc2-ws dialect) ---
//
// A text WS frame carries a JSON-RPC 2.0 request {method, params:{reqid, …}}. We stream results
// back as `reqdata` notifications — one per row `{method, reqid, data}` — terminated by
// `{method, reqid, end:true, status:200, error:null}`. Mirrors cc32d9's wsapi/lightapi_wsapi.js.

pub fn handleWsText(ctx: ExecCtx, sink: Sink, a: std.mem.Allocator, text: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;
    const method = root.get("method") orelse return;
    if (method != .string) return;
    const m = method.string;
    const params: ?std.json.ObjectMap = if (root.get("params")) |p| (if (p == .object) p.object else null) else null;

    var reqid_buf: [80]u8 = undefined;
    const reqid = reqidStr(params, &reqid_buf);

    if (std.mem.eql(u8, m, "get_networks")) {
        const lanet = execProc(ctx, a, "lightapi_get", &.{ "lanet", "[]" }) orelse "[]";
        wsData(sink, a, "get_networks", reqid, lanet);
        wsEnd(sink, a, "get_networks", reqid);
    } else if (std.mem.eql(u8, m, "get_balances")) {
        wsBalances(ctx, sink, a, params, reqid);
    } else if (std.mem.eql(u8, m, "get_token_holders")) {
        wsTokenHolders(ctx, sink, a, params, reqid);
    } else if (std.mem.eql(u8, m, "get_accounts_from_keys")) {
        wsAccountsFromKeys(ctx, sink, a, params, reqid);
    } else {
        wsErr(sink, a, m, reqid, "unknown method");
    }
}

/// reqid re-emitted verbatim (number or JSON string); defaults to null.
fn reqidStr(params: ?std.json.ObjectMap, buf: []u8) []const u8 {
    const p = params orelse return "null";
    const v = p.get("reqid") orelse return "null";
    return switch (v) {
        .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch "null",
        .string => |s| std.fmt.bufPrint(buf, "\"{s}\"", .{s}) catch "null",
        else => "null",
    };
}

fn wsData(sink: Sink, a: std.mem.Allocator, method: []const u8, reqid: []const u8, data_json: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"reqdata\",\"params\":{\"method\":\"") catch return;
    buf.appendSlice(a, method) catch return;
    buf.appendSlice(a, "\",\"reqid\":") catch return;
    buf.appendSlice(a, reqid) catch return;
    buf.appendSlice(a, ",\"data\":") catch return;
    buf.appendSlice(a, data_json) catch return;
    buf.appendSlice(a, "}}") catch return;
    sink.send(buf.items);
}

fn wsEnd(sink: Sink, a: std.mem.Allocator, method: []const u8, reqid: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"reqdata\",\"params\":{\"method\":\"") catch return;
    buf.appendSlice(a, method) catch return;
    buf.appendSlice(a, "\",\"reqid\":") catch return;
    buf.appendSlice(a, reqid) catch return;
    buf.appendSlice(a, ",\"end\":true,\"status\":200,\"error\":null}}") catch return;
    sink.send(buf.items);
}

fn wsErr(sink: Sink, a: std.mem.Allocator, method: []const u8, reqid: []const u8, msg: []const u8) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(a);
    buf.appendSlice(a, "{\"jsonrpc\":\"2.0\",\"method\":\"reqdata\",\"params\":{\"method\":\"") catch return;
    buf.appendSlice(a, method) catch return;
    buf.appendSlice(a, "\",\"reqid\":") catch return;
    buf.appendSlice(a, reqid) catch return;
    buf.appendSlice(a, ",\"end\":true,\"status\":500,\"error\":\"") catch return;
    buf.appendSlice(a, msg) catch return;
    buf.appendSlice(a, "\"}}") catch return;
    sink.send(buf.items);
}

fn paramStr(params: ?std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const p = params orelse return null;
    const v = p.get(field) orelse return null;
    return if (v == .string) v.string else null;
}

fn wsBalances(ctx: ExecCtx, sink: Sink, a: std.mem.Allocator, params: ?std.json.ObjectMap, reqid: []const u8) void {
    const network = paramStr(params, "network") orelse "";
    const accounts = if (params) |p| p.get("accounts") else null;
    if (accounts == null or accounts.? != .array) {
        wsErr(sink, a, "get_balances", reqid, "accounts required");
        return;
    }
    var n: usize = 0;
    for (accounts.?.array.items) |acc| {
        if (acc != .string or n >= 100) break;
        n += 1;
        if (execProc(ctx, a, "lightapi_ws_balances", &.{ network, acc.string })) |row| {
            wsData(sink, a, "get_balances", reqid, row);
        }
    }
    wsEnd(sink, a, "get_balances", reqid);
}

fn wsTokenHolders(ctx: ExecCtx, sink: Sink, a: std.mem.Allocator, params: ?std.json.ObjectMap, reqid: []const u8) void {
    const contract = paramStr(params, "contract") orelse "";
    const currency = paramStr(params, "currency") orelse "";
    const lines = execProc(ctx, a, "lightapi_ws_holders", &.{ contract, currency }) orelse "";
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const acct = f.next() orelse continue;
        const amount = f.next() orelse continue;
        const data = std.fmt.allocPrint(a, "{{\"account\":\"{s}\",\"amount\":\"{s}\"}}", .{ acct, amount }) catch continue;
        wsData(sink, a, "get_token_holders", reqid, data);
    }
    wsEnd(sink, a, "get_token_holders", reqid);
}

fn wsAccountsFromKeys(ctx: ExecCtx, sink: Sink, a: std.mem.Allocator, params: ?std.json.ObjectMap, reqid: []const u8) void {
    const keys = if (params) |p| p.get("keys") else null;
    if (keys == null or keys.? != .array) {
        wsErr(sink, a, "get_accounts_from_keys", reqid, "keys required");
        return;
    }
    var n: usize = 0;
    for (keys.?.array.items) |k| {
        if (k != .string or n >= 100) break;
        n += 1;
        const rows = execProc(ctx, a, "lightapi_ws_keyrows", &.{k.string}) orelse "";
        var it = std.mem.splitScalar(u8, rows, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var f = std.mem.splitScalar(u8, line, '\t');
            const acct = f.next() orelse continue;
            const perm = f.next() orelse continue;
            const weight = f.next() orelse continue;
            const data = std.fmt.allocPrint(a, "{{\"account_name\":\"{s}\",\"perm\":\"{s}\",\"weight\":{s},\"pubkey\":\"{s}\"}}", .{ acct, perm, weight, k.string }) catch continue;
            wsData(sink, a, "get_accounts_from_keys", reqid, data);
        }
    }
    wsEnd(sink, a, "get_accounts_from_keys", reqid);
}

test {
    std.testing.refAllDecls(@This());
}
