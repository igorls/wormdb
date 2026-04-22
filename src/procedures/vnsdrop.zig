//! Built-in VNSDROP procedure — drop a namespace's HNSW index (+ optional data).
//!
//! EXEC vnsdrop <namespace> [<purge>]
//!
//! - namespace: prefix to drop (e.g. "vec:articles:"). Required.
//! - purge:     "1" to also delete every `<namespace>*` and `bq:<namespace>*`
//!              store entry. Default "0" (index only, non-destructive).
//!
//! ── purge=0 (default) ───────────────────────────────────────────────
//! Removes the HNSW index from the registry. Store + BQ entries remain
//! intact; a subsequent `EXEC vreindex <namespace>` rebuilds the graph.
//! Useful for:
//!   - Reclaiming HNSW memory for cold namespaces
//!   - Forcing a rebuild with different HNSW params
//!   - Switching a namespace's metric (drop → next vinsert sets new metric)
//!
//! ── purge=1 ────────────────────────────────────────────────────────
//! Best-effort delete of every data entry. WORM entries are skipped and
//! reported; other errors abort the scan. Replicates each DELETE via the
//! normal cluster path. Returns counts of removed / skipped_worm / errors.
//! Idempotent for non-WORM namespaces.
//!
//! Returns JSON:
//!   purge=0: {"namespace":"...","index_dropped":true|false}
//!   purge=1: {"namespace":"...","index_dropped":true|false,
//!             "vec_deleted":N,"bq_deleted":N,"skipped_worm":N,"errors":N}

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const Store = @import("../storage/store.zig").Store;

const BQ_PREFIX: []const u8 = "bq:";

const PurgeCtx = struct {
    ctx: *Ctx,
    deleted: usize,
    skipped_worm: usize,
    errors: usize,
    keys_to_delete: std.ArrayListUnmanaged([]u8),
    allocator: std.mem.Allocator,
    oom: bool,
};

/// Collect keys during scan — we can't delete while scanning the same
/// shards (delete acquires shard locks, scan already holds them).
fn collectKeys(
    raw_ctx: *anyopaque,
    key: []const u8,
    value: []const u8,
    timestamp: u64,
    is_worm: bool,
) Store.ScanAction {
    _ = value;
    _ = timestamp;
    _ = is_worm;
    const sc: *PurgeCtx = @ptrCast(@alignCast(raw_ctx));
    const key_copy = sc.allocator.dupe(u8, key) catch {
        sc.oom = true;
        return .stop;
    };
    sc.keys_to_delete.append(sc.allocator, key_copy) catch {
        sc.allocator.free(key_copy);
        sc.oom = true;
        return .stop;
    };
    return .cont;
}

/// Delete every collected key. WormViolation is counted separately from
/// other errors; the rest abort nothing — we keep trying siblings.
fn purgePrefix(ctx: *Ctx, prefix: []const u8, stats: *PurgeCtx) !void {
    stats.keys_to_delete = .empty;
    defer {
        for (stats.keys_to_delete.items) |k| stats.allocator.free(k);
        stats.keys_to_delete.deinit(stats.allocator);
    }

    // Phase 1: collect keys (scan holds shard locks; can't delete inside)
    ctx.scanCallback(prefix, @ptrCast(stats), collectKeys);
    if (stats.oom) return error.OutOfMemory;

    // Phase 2: delete one-by-one. Each deleteDurable handles locking,
    // replication, and WORM checks.
    for (stats.keys_to_delete.items) |k| {
        ctx.deleteDurable(k) catch |e| switch (e) {
            error.WormViolation => stats.skipped_worm += 1,
            else => stats.errors += 1,
        };
        if (stats.oom) return error.OutOfMemory;
    }
    stats.deleted += stats.keys_to_delete.items.len -
        stats.skipped_worm -
        stats.errors;
}

pub fn execute(ctx: *Ctx) anyerror!Ctx.Result {
    const namespace = ctx.arg(0) orelse
        return ctx.err("vnsdrop requires 1 arg: <namespace> [purge]");

    const purge = if (ctx.arg(1)) |p| std.mem.eql(u8, p, "1") else false;

    // ── Drop the HNSW index (if any) ──
    var index_dropped = false;
    if (ctx.vector_registry) |reg| {
        if (reg.get(namespace) != null) {
            reg.remove(namespace);
            index_dropped = true;
        }
    }

    if (!purge) {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
        try json.appendSlice(ctx.allocator, namespace);
        try json.appendSlice(ctx.allocator, "\",\"index_dropped\":");
        try json.appendSlice(ctx.allocator, if (index_dropped) "true" else "false");
        try json.append(ctx.allocator, '}');
        return ctx.value(try json.toOwnedSlice(ctx.allocator));
    }

    // ── purge=1: remove store + BQ entries ──
    var vec_stats = PurgeCtx{
        .ctx = ctx,
        .deleted = 0,
        .skipped_worm = 0,
        .errors = 0,
        .keys_to_delete = .empty,
        .allocator = ctx.allocator,
        .oom = false,
    };
    purgePrefix(ctx, namespace, &vec_stats) catch {
        return ctx.err("vnsdrop: out of memory collecting keys");
    };

    // BQ prefix = "bq:" + namespace (matches vinsert's key layout).
    const bq_prefix = ctx.fmt("{s}{s}", .{ BQ_PREFIX, namespace });
    var bq_buf: [512]u8 = undefined;
    if (bq_prefix.len > bq_buf.len) return ctx.err("vnsdrop: namespace too long");
    const bq_len = bq_prefix.len;
    @memcpy(bq_buf[0..bq_len], bq_prefix);
    const bq_prefix_stable = bq_buf[0..bq_len];

    var bq_stats = PurgeCtx{
        .ctx = ctx,
        .deleted = 0,
        .skipped_worm = 0,
        .errors = 0,
        .keys_to_delete = .empty,
        .allocator = ctx.allocator,
        .oom = false,
    };
    purgePrefix(ctx, bq_prefix_stable, &bq_stats) catch {
        return ctx.err("vnsdrop: out of memory collecting BQ keys");
    };

    // ── Build JSON response ──
    var json: std.ArrayListUnmanaged(u8) = .empty;
    try json.appendSlice(ctx.allocator, "{\"namespace\":\"");
    try json.appendSlice(ctx.allocator, namespace);
    try json.appendSlice(ctx.allocator, "\",\"index_dropped\":");
    try json.appendSlice(ctx.allocator, if (index_dropped) "true" else "false");

    try json.appendSlice(ctx.allocator, ",\"vec_deleted\":");
    try writeUsize(&json, ctx.allocator, vec_stats.deleted);
    try json.appendSlice(ctx.allocator, ",\"bq_deleted\":");
    try writeUsize(&json, ctx.allocator, bq_stats.deleted);
    try json.appendSlice(ctx.allocator, ",\"skipped_worm\":");
    try writeUsize(&json, ctx.allocator, vec_stats.skipped_worm + bq_stats.skipped_worm);
    try json.appendSlice(ctx.allocator, ",\"errors\":");
    try writeUsize(&json, ctx.allocator, vec_stats.errors + bq_stats.errors);
    try json.append(ctx.allocator, '}');

    return ctx.value(try json.toOwnedSlice(ctx.allocator));
}

fn writeUsize(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, n: usize) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
    try list.appendSlice(alloc, s);
}
