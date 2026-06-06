//! Domain manifest interface — the contract a serving DOMAIN (Light-API, AtomicAssets,
//! …) exposes so the engine can compose it WITHOUT naming it. A domain ships
//! `pub const manifest = Domain{ … }`; the composition root collects manifests into the
//! dispatch tables (the EXEC registry, and later the route + WS tables). This is the seam
//! that lets a domain live in its own module — and eventually its own repository (see the
//! sibling package `wormdb-domain-atomicassets`).
//!
//! Minimal first cut: identity + segment namespace + table-id range + procedures. Routes,
//! WS methods, and config/seed hooks are added as the registration inversion lands (WP-013).

const Ctx = @import("context.zig").Ctx;

/// A stored-procedure function — the exact ABI `registry.zig` already dispatches.
pub const ProcFn = *const fn (ctx: *Ctx) anyerror!Ctx.Result;

/// One named procedure a domain contributes to the EXEC registry.
pub const Entry = struct {
    name: []const u8,
    func: ProcFn,
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
};

test {
    @import("std").testing.refAllDecls(@This());
}
