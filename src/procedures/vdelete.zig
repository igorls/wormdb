//! Built-in VDELETE procedure — thin wrapper over `vector_ops.applyVdelete`.
//!
//! EXEC vdelete <key> [<namespace>]
//!
//! - key:       full vector key (e.g. "vec:articles:memory-001")
//! - namespace: prefix the key lives under (default: "vec:")
//!
//! Returns JSON: {"deleted":true,"tombstoned":"deleted"|"noop"|"missing"}
//!   deleted     — store DELETE succeeded (else error.WormViolation bubbled up)
//!   tombstoned  — HNSW tombstone outcome (see `NamespaceIndex.markTombstoneLocked`)
//!
//! WORM entries error on the underlying store.delete — the rest of the
//! procedure is skipped and the caller sees WormViolation. That's the
//! correct behavior; WORM means immutable.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const vector_ops = @import("vector_ops.zig");

const DEFAULT_NAMESPACE: []const u8 = "vec:";

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse
        return ctx.err("vdelete requires 1 arg: <key> [namespace]");

    const namespace = ctx.arg(1) orelse DEFAULT_NAMESPACE;

    if (!std.mem.startsWith(u8, key, namespace))
        return ctx.err("vdelete: key does not start with namespace prefix");

    // Query the tombstone state *before* apply so the JSON response can
    // distinguish "deleted (was live)" from "noop (already tombstoned)" from
    // "missing (no HNSW entry)". applyVdelete itself is void-returning for
    // tombstone status (the real work always happens regardless).
    var tombstone_status: []const u8 = "missing";
    if (ctx.vector_registry) |reg| {
        if (reg.get(namespace)) |ns_idx| {
            ns_idx.lock.lockShared();
            defer ns_idx.lock.unlockShared();
            if (ns_idx.nodeIdFor(key)) |node_id| {
                tombstone_status = if (ns_idx.isTombstoned(node_id)) "noop" else "deleted";
            }
        }
    }

    vector_ops.applyVdelete(
        ctx.store,
        ctx.cluster,
        ctx.event_bus,
        ctx.vector_registry,
        ctx.allocator,
        key,
        namespace,
        true, // procedure is client-originated — replicate
    ) catch |err| {
        return switch (err) {
            error.WormViolation => ctx.err("WORM violation: vector key is immutable"),
            else => ctx.err(ctx.fmt("vdelete: {s}", .{@errorName(err)})),
        };
    };

    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(ctx.allocator, "{\"deleted\":true,\"tombstoned\":\"");
    try json.appendSlice(ctx.allocator, tombstone_status);
    try json.appendSlice(ctx.allocator, "\"}");
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}
