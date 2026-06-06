//! Domain manifest interface — the contract a serving DOMAIN (Light-API, AtomicAssets,
//! …) exposes so the engine can compose it WITHOUT naming it. A domain ships
//! `pub const manifest = Domain{ … }`; the composition root collects manifests into the
//! dispatch tables (the EXEC registry, and later the route + WS tables). This is the seam
//! that lets a domain live in its own module — and eventually its own repository (see the
//! sibling package `wormdb-domain-atomicassets`).
//!
//! Minimal first cut: identity + segment namespace + table-id range + procedures. Routes,
//! WS methods, and config/seed hooks are added as the registration inversion lands (WP-013).

const std = @import("std");
const Ctx = @import("context.zig").Ctx;

/// A stored-procedure function — the exact ABI `registry.zig` already dispatches.
pub const ProcFn = *const fn (ctx: *Ctx) anyerror!Ctx.Result;

/// One named procedure a domain contributes to the EXEC registry.
pub const Entry = struct {
    name: []const u8,
    func: ProcFn,
};

/// Captured request data passed to a Route's builder: the path segments AFTER the matched prefix,
/// plus the raw query string. The domain's builder maps these to procedure args — so all path-param,
/// query, and key-synthesis logic lives in the domain, not the engine gateway.
pub const Captures = struct {
    segs: []const []const u8,
    query: []const u8,

    /// The i-th captured path segment (after the matched prefix), or null if absent.
    pub fn seg(self: *const Captures, i: usize) ?[]const u8 {
        return if (i < self.segs.len) self.segs[i] else null;
    }
    /// A `key=value` query-string parameter (no URL-decoding), or null.
    pub fn param(self: *const Captures, key: []const u8) ?[]const u8 {
        var it = std.mem.tokenizeScalar(u8, self.query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
        return null;
    }
};

/// The procedure call a Route resolves to: which proc, with which args, JSON-vs-text, and the HTTP
/// status — either fixed, or derived from the response body (e.g. cc32d9's 503 on "OUT_OF_SYNC").
pub const ExecCall = struct {
    proc: []const u8,
    args: []const []const u8,
    json: bool = true,
    status: u16 = 200,
    status_from_body: ?*const fn (body: []const u8) u16 = null,
};

/// One HTTP route a domain contributes. `prefix` is the leading path segments to match (e.g.
/// `&.{"api","balances"}`); on match, `build` receives the remaining segments + query and returns the
/// ExecCall (or null → no match / 404). The builder lives in the domain, so the engine gateway holds
/// no domain URLs.
pub const Route = struct {
    prefix: []const []const u8,
    build: *const fn (alloc: std.mem.Allocator, caps: *const Captures) ?ExecCall,
};

/// The streaming context a WebSocket JSON-RPC handler receives. The gateway owns the WS framing +
/// the executor; the domain handler only emits data rows / end / err and runs procedures — so the
/// cc32d9 (or any) WS dialect (method names, param shapes, row JSON) lives in the domain, not the
/// engine. `impl` + the fn pointers are a small vtable the gateway fills in; handlers use the methods.
pub const WsCtx = struct {
    impl: *anyopaque,
    allocator: std.mem.Allocator,
    /// The JSON-RPC request's `params` object (or null). Handlers read arrays/fields directly.
    params: ?std.json.ObjectMap,

    emitFn: *const fn (impl: *anyopaque, data_json: []const u8) void,
    endFn: *const fn (impl: *anyopaque) void,
    errFn: *const fn (impl: *anyopaque, msg: []const u8) void,
    execFn: *const fn (impl: *anyopaque, proc: []const u8, args: []const []const u8) ?[]const u8,

    /// Stream one JSON data row to the client.
    pub fn emit(self: *const WsCtx, data_json: []const u8) void {
        self.emitFn(self.impl, data_json);
    }
    /// Terminate the request stream (status 200).
    pub fn end(self: *const WsCtx) void {
        self.endFn(self.impl);
    }
    /// Terminate the request stream with an error.
    pub fn fail(self: *const WsCtx, msg: []const u8) void {
        self.errFn(self.impl, msg);
    }
    /// Run an EXEC procedure through the engine; returns its value payload (or null).
    pub fn exec(self: *const WsCtx, proc: []const u8, args: []const []const u8) ?[]const u8 {
        return self.execFn(self.impl, proc, args);
    }
    /// A string `params` field, or null.
    pub fn param(self: *const WsCtx, field: []const u8) ?[]const u8 {
        const p = self.params orelse return null;
        const v = p.get(field) orelse return null;
        return if (v == .string) v.string else null;
    }
};

/// One WebSocket JSON-RPC method a domain contributes. `name` is the method string; `handler`
/// streams the response via the WsCtx.
pub const WsMethod = struct {
    name: []const u8,
    handler: *const fn (ctx: *const WsCtx) void,
};

/// Everything a domain contributes to the engine. The engine assigns `name` and the
/// table-id range no meaning beyond identity + cross-domain disjointness.
pub const Domain = struct {
    /// Identity (also the conventional default segment-registry key).
    name: []const u8,
    /// Segment-registry key(s) this domain mounts under (`store.segment(name)`).
    segment_names: []const []const u8 = &.{},
    /// The domain's claimed slice of the shared `.wseg` u32 table-id namespace (inclusive),
    /// so the composition root can comptime-assert ranges don't overlap. `{0,0}` = none.
    table_id_lo: u32 = 0,
    table_id_hi: u32 = 0,
    /// EXEC procedures this domain contributes (name -> fn).
    procedures: []const Entry = &.{},
    /// HTTP routes this domain contributes (path prefix -> proc-call builder).
    routes: []const Route = &.{},
    /// WebSocket JSON-RPC methods this domain contributes (method name -> streaming handler).
    ws_methods: []const WsMethod = &.{},
};

/// Flatten the procedures of several domain manifests into one slice at comptime — the composition
/// root passes the result to `registry.registerDomains`. `manifests` is a tuple/array of `Domain`s.
pub fn collectProcedures(comptime manifests: anytype) []const Entry {
    var list: []const Entry = &.{};
    inline for (manifests) |m| list = list ++ m.procedures;
    return list;
}

/// Flatten the HTTP routes of several domain manifests into one slice at comptime — the composition
/// root passes the result to the gateway's `registerRoutes`.
pub fn collectRoutes(comptime manifests: anytype) []const Route {
    var list: []const Route = &.{};
    inline for (manifests) |m| list = list ++ m.routes;
    return list;
}

/// Flatten the WebSocket methods of several domain manifests into one slice at comptime.
pub fn collectWsMethods(comptime manifests: anytype) []const WsMethod {
    var list: []const WsMethod = &.{};
    inline for (manifests) |m| list = list ++ m.ws_methods;
    return list;
}

test {
    @import("std").testing.refAllDecls(@This());
}
