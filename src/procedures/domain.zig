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

/// Comptime-validate the composed domain set, turning what would otherwise be silent first-match-wins
/// collisions into BUILD errors at the composition site: (1) no duplicate procedure names across domains
/// or vs the engine builtins; (2) no duplicate WS method names; (3) no HTTP route whose prefix shadows
/// another's; (4) no overlapping table-id ranges among domains that share a segment. Call from the
/// composition root before the register* calls:
///   `comptime domain.validate(DOMAINS, registry.builtin_names);`
pub fn validate(comptime manifests: anytype, comptime builtin_proc_names: []const []const u8) void {
    @setEvalBranchQuota(100_000);
    comptime {
        // NB: the `manifests` loops below use a plain `for`, not `inline for`, on purpose. Inside this
        // `comptime` block the tuple is already iterated at comptime; Zig 0.16 rejects `inline for` here
        // with "redundant inline keyword in comptime scope". (The collect* helpers above are NOT in a
        // comptime block, so they must spell `inline for` — the asymmetry is required, not an oversight.)
        // (1) procedure names — unique across domains and disjoint from the engine builtins.
        var procs: []const []const u8 = builtin_proc_names;
        for (manifests) |m| {
            for (m.procedures) |p| {
                for (procs) |existing| {
                    if (std.mem.eql(u8, existing, p.name))
                        @compileError("WormDB compose error: procedure name '" ++ p.name ++ "' collides (duplicate domain proc or clash with an engine builtin)");
                }
                procs = procs ++ &[_][]const u8{p.name};
            }
        }
        // (2) WS method names — unique across domains.
        var ws: []const []const u8 = &.{};
        for (manifests) |m| {
            for (m.ws_methods) |w| {
                for (ws) |existing| {
                    if (std.mem.eql(u8, existing, w.name))
                        @compileError("WormDB compose error: duplicate WS method '" ++ w.name ++ "' across domains");
                }
                ws = ws ++ &[_][]const u8{w.name};
            }
        }
        // (3) route prefixes — none may be a leading prefix of another (first-match-wins would shadow).
        var routes: []const Route = &.{};
        for (manifests) |m| routes = routes ++ m.routes;
        for (routes, 0..) |a, ia| {
            for (routes, 0..) |bb, ib| {
                if (ia >= ib) continue;
                if (prefixShadows(a.prefix, bb.prefix) or prefixShadows(bb.prefix, a.prefix))
                    @compileError("WormDB compose error: HTTP route prefixes shadow each other (one is a leading prefix of the other)");
            }
        }
        // (4) table-id ranges — disjoint for domains that share a segment name (the co-mount case).
        for (manifests, 0..) |a, ia| {
            for (manifests, 0..) |bb, ib| {
                if (ia >= ib) continue;
                if (sharesSegment(a, bb) and rangesOverlap(a, bb))
                    @compileError("WormDB compose error: domains '" ++ a.name ++ "' and '" ++ bb.name ++ "' have overlapping table-id ranges on a shared segment");
            }
        }
    }
}

fn prefixShadows(comptime a: []const []const u8, comptime b: []const []const u8) bool {
    if (a.len > b.len) return false; // `a` can only shadow `b` if it's a leading prefix
    for (a, 0..) |seg, i| {
        if (!std.mem.eql(u8, seg, b[i])) return false;
    }
    return true;
}

fn sharesSegment(comptime a: Domain, comptime b: Domain) bool {
    for (a.segment_names) |sa| {
        for (b.segment_names) |sb| {
            if (std.mem.eql(u8, sa, sb)) return true;
        }
    }
    return false;
}

fn rangesOverlap(comptime a: Domain, comptime b: Domain) bool {
    // [lo,hi] inclusive; the default {0,0} means "no range claimed" → never overlaps.
    if (a.table_id_lo == 0 and a.table_id_hi == 0) return false;
    if (b.table_id_lo == 0 and b.table_id_hi == 0) return false;
    return a.table_id_lo <= b.table_id_hi and b.table_id_lo <= a.table_id_hi;
}

test {
    @import("std").testing.refAllDecls(@This());
}
