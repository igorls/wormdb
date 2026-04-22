//! Built-in VDELETE procedure — delete a vector and tombstone its HNSW node.
//!
//! EXEC vdelete <key> [<namespace>]
//!
//! - key:       full vector key (e.g. "vec:articles:memory-001")
//! - namespace: prefix the key lives under (default: "vec:"). Determines
//!              which HNSW index holds the node to tombstone.
//!
//! Behavior:
//!   1. Delete `<key>` from the store (WAL + cluster replication). Fails
//!      with `WormViolation` for WORM vectors — the rest of the procedure
//!      is skipped and the caller sees the error. This is intentional:
//!      WORM means immutable, so a failed delete is the correct outcome.
//!   2. Best-effort delete of `bq:<key>` (the binary-quantized hash). If
//!      that write is WORM too, the error is propagated (same rules).
//!   3. Mark the corresponding HNSW node as tombstoned in the namespace
//!      index. Search traversals will skip it from results while still
//!      using it as a routing node (preserving graph recall).
//!
//! Returns JSON: {"deleted":true|false,"tombstoned":"deleted"|"noop"|"missing"}
//!   deleted     — store DELETE succeeded
//!   tombstoned  — HNSW tombstone outcome (see TombstoneResult)
//!
//! Note: if the vector was inserted via a raw `SET vec:...` rather than
//! `EXEC vinsert`, it has no HNSW node and `tombstoned="missing"` is
//! expected and correct.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const IndexModule = @import("../vector/index.zig");

const DEFAULT_NAMESPACE: []const u8 = "vec:";
const BQ_PREFIX: []const u8 = "bq:";

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const key = ctx.arg(0) orelse
        return ctx.err("vdelete requires 1 arg: <key> [namespace]");

    const namespace = ctx.arg(1) orelse DEFAULT_NAMESPACE;

    // ── Sanity: the key must live under the declared namespace ──
    if (!std.mem.startsWith(u8, key, namespace)) {
        return ctx.err("vdelete: key does not start with namespace prefix");
    }

    // ── Build the BQ sibling key into a stable stack buffer ──
    const bq_key = ctx.fmt("{s}{s}", .{ BQ_PREFIX, key });
    var bq_buf: [512]u8 = undefined;
    if (bq_key.len > bq_buf.len) return ctx.err("vdelete: key too long");
    const bq_len = bq_key.len;
    @memcpy(bq_buf[0..bq_len], bq_key);
    const bq_key_stable = bq_buf[0..bq_len];

    // ── Delete the vec entry (WAL + replicate) ──
    try ctx.deleteDurable(key);

    // ── Delete the BQ sibling. Ignore "not found" — it may never have
    // existed (raw SET ingestion) or was already cleaned up. Propagate
    // WormViolation; that would be a configuration bug.
    ctx.deleteDurable(bq_key_stable) catch |e| switch (e) {
        error.WormViolation => return e,
        else => {}, // IoError, missing entry, etc — best-effort
    };

    // ── Tombstone in HNSW if an index exists ──
    var tombstone_status: []const u8 = "missing";
    if (ctx.vector_registry) |reg| {
        if (reg.get(namespace)) |ns_idx| {
            ns_idx.lock.lock();
            defer ns_idx.lock.unlock();
            tombstone_status = switch (ns_idx.markTombstoneLocked(key)) {
                .deleted => "deleted",
                .noop => "noop",
                .missing => "missing",
            };
        }
    }

    // ── Emit deletion event (channel parallels vinsert's) ──
    const event_channel = ctx.fmt("{s}deleted", .{namespace});
    ctx.publish(event_channel, key);

    // ── JSON response ──
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(ctx.allocator, "{\"deleted\":true,\"tombstoned\":\"");
    try json.appendSlice(ctx.allocator, tombstone_status);
    try json.appendSlice(ctx.allocator, "\"}");
    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}
